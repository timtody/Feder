import SwiftUI

/// The legal texts shipped with the app (Legal.json, English and German): the privacy policy (App Review 5.1.1(i)
/// wants it reachable inside the app; it is shown from the bundle, so it works offline and matches the version
/// installed) and the legal notice (Impressum, § 5 DDG). The same privacy text is hosted for App Store Connect.
nonisolated struct LegalDocument: Decodable, Sendable {
    struct Section: Decodable, Sendable {
        var heading: String
        var body: String
    }

    var title: String
    var updated: String?
    var sections: [Section]

    enum Kind: String, Sendable {
        case privacy, legalNotice
    }

    /// The document in the app's language (German when the app runs in German, English otherwise), nil without the file.
    static func load(_ kind: Kind) -> LegalDocument? {
        guard let url = Bundle.main.url(forResource: "Legal", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: [String: LegalDocument]].self, from: data),
              let languages = all[kind.rawValue] else { return nil }
        return languages[language] ?? languages["en"]
    }

    /// The app's language for the JSON texts: German when the app runs in German, English otherwise.
    static var language: String { Bundle.main.preferredLocalizations.first == "de" ? "de" : "en" }
}

/// A legal document as a plain reading page: its sections as headed paragraphs.
struct LegalTextView: View {
    let document: LegalDocument.Kind
    @State private var loaded: LegalDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loaded {
                    if let updated = loaded.updated {
                        Text("Last updated: \(updated)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(loaded.sections.indices, id: \.self) { index in
                        let section = loaded.sections[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.heading)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text(Self.linked(section.body))
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle(loaded?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { loaded = await Self.read(document) }
    }

    /// The text with its web addresses and email addresses as links (the legal notice and the contact point to the
    /// website and the email; the full address isn't in the app).
    nonisolated static func linked(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let found = attributed.range(of: String(text[range])) else { continue }
            attributed[found].link = url
        }
        return attributed
    }

    /// Off the main actor: a bundle file read and a JSON decode.
    @concurrent
    nonisolated private static func read(_ kind: LegalDocument.Kind) async -> LegalDocument? {
        LegalDocument.load(kind)
    }
}

/// Acknowledgements.json: the models Feder downloads and the open-source code compiled into it, with their licences
/// (the code's licence and NOTICE texts are required in the app; crediting the models is good practice and what
/// their CC BY / OpenMDW / Apache terms ask of anyone who passes them on).
nonisolated struct Acknowledgements: Decodable, Sendable {
    struct Model: Decodable, Sendable, Hashable {
        var name: String
        var use: [String: String]?               // "en", "de": what Feder uses it for
        /// `use` in the app's language.
        var localizedUse: String? { use?[LegalDocument.language] ?? use?["en"] }
        var credit: String
        var license: String
        var url: String?
    }

    struct Code: Decodable, Sendable, Hashable {
        var name: String
        var credit: String
        var license: String
        var notice: String?
        var url: String?
    }

    struct License: Decodable, Sendable, Hashable {
        var title: String
        var text: String
    }

    var models: [Model]
    var code: [Code]
    var licenses: [String: License]

    static func load() -> Acknowledgements? {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Acknowledgements.self, from: data)
    }
}

/// Settings › About › Acknowledgements: models, then code; each row opens its credit, notice and licence text.
struct AcknowledgementsView: View {
    @State private var loaded: Acknowledgements?

    var body: some View {
        List {
            if let loaded {
                Section("Models") {
                    ForEach(loaded.models, id: \.self) { model in
                        NavigationLink {
                            AcknowledgementDetail(name: model.name, credit: model.credit, notice: nil, url: model.url,
                                                  license: loaded.licenses[model.license])
                        } label: {
                            LabeledContent {
                                Text(model.license)
                            } label: {
                                Text(model.name)
                                if let use = model.localizedUse { Text(use) }
                            }
                        }
                    }
                }
                Section("Code") {
                    ForEach(loaded.code, id: \.self) { code in
                        NavigationLink {
                            AcknowledgementDetail(name: code.name, credit: code.credit, notice: code.notice, url: code.url,
                                                  license: loaded.licenses[code.license])
                        } label: {
                            LabeledContent(code.name, value: code.license)
                        }
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .task { loaded = await Self.read() }
    }

    @concurrent
    nonisolated private static func read() async -> Acknowledgements? {
        Acknowledgements.load()
    }
}

private struct AcknowledgementDetail: View {
    let name: String
    let credit: String
    let notice: String?
    let url: String?
    let license: Acknowledgements.License?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(credit)
                    .font(.subheadline)
                if let url, let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(.footnote)
                }
                if let notice {
                    Text(notice)
                        .font(.caption.monospaced())
                }
                if let license {
                    Text(license.title)
                        .font(.headline)
                    Text(license.text)
                        .font(.caption.monospaced())
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
