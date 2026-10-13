import Foundation

// Summary styles bench (FED-15): every style with the English and the German instructions on the given texts, through
// the app's own TranscriptTitler (requests, map-reduce, parsing) and Gemma 4 E2B. Prints each request's tokens
// (instructions, transcript, answer), the time, the raw answer and the stored summary, so format adherence, invented
// content and the token reserve can be checked by reading.
//
// usage: SummaryBench <modelDir> <styles: all|brief,meeting,…> <languages: en|de|both> <repeat> <text.txt>…
//        SummaryBench parse        (the parser on canned answers, no model)
// A text is one "Name: text" paragraph per line; <repeat> joins it that many times (the long-transcript case).

/// Forwards to Gemma and keeps what each request was, for the token counts.
final class MeasuringWriter: TextWriter, @unchecked Sendable {
    let model: LocalLanguageModel
    var requests: [(instructions: String, prompt: String, answer: String, seconds: Double)] = []

    init(model: LocalLanguageModel) { self.model = model }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String {
        let start = Date()
        let answer = try await model.respond(instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                                             temperature: temperature, partial: nil)
        requests.append((instructions, prompt, answer, Date().timeIntervalSince(start)))
        return answer
    }

    func unload() async { await model.unload() }
}

let args = CommandLine.arguments

if args.count > 1, args[1] == "parse" {
    let answers: [(SummaryStyle, Bool, String)] = [
        (.meeting, false, "Topics: budget; travel\nSummary:\nDecisions:\n- Part of the licence budget moves to travel.\nTo-dos:\n- Anna sends the numbers by Friday.\nOpen questions:\n- none\nTitle: Budget Review"),
        (.meeting, true, "**Themen:** Testphase; Abnahme\n**Zusammenfassung:**\n**Entscheidungen:**\n* Die Abnahme verschiebt sich auf den 25. November.\n**Aufgaben:**\n1. Lena passt die Erwartungswerte bis Freitag an.\n**Offene Fragen:**\n- Keine offenen Fragen.\n**Titel:** Kreditprojekt: Abnahme"),
        (.interview, false, "Topics: career\nSummary:\nQ: How did you start?\nA: Anna started as a tester in 2019.\nQ: What is next?\nA: She leads the team from January.\nTitle: Career Interview"),
        (.lecture, true, "Themen: Gletscher\nZusammenfassung:\nKernaussagen:\n- Gletscher formen Täler zu U-Tälern.\n- Moränen sind Schutt.\nTitel: Gletscher und Moränen"),
        (.bulletPoints, false, "Topics: a\nSummary: - First point\n- Second point\nTitle: Points"),
        (.bulletPoints, false, "Topics: a\nThe first point.\nThe second point.\nTitle: Points"),
    ]
    for (style, german, answer) in answers {
        let parsed = TranscriptTitler.parseStyled(answer, style: style, german: german)
        print("== \(style.rawValue) \(german ? "de" : "en"): title \(parsed?.title ?? "-") topics \(parsed?.topics ?? [])\n\(parsed?.summary ?? "nil")\n")
    }
    exit(0)
}

guard args.count > 5 else {
    print("usage: SummaryBench <modelDir> <styles> <en|de|both> <repeat> <text.txt>…  |  SummaryBench parse")
    exit(1)
}
let model = LocalLanguageModel(variant: .e2b, directory: URL(fileURLWithPath: args[1]))
let styles = args[2] == "all" ? SummaryStyle.allCases : args[2].split(separator: ",").compactMap { SummaryStyle(rawValue: String($0)) }
let languages = args[3] == "both" ? ["en", "de"] : [args[3]]
let repeatCount = Int(args[4]) ?? 1
let titler = TranscriptTitler()
var loadStart = Date()
try await model.load()
print("Gemma load: \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s")

for path in args[5...] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let paragraphs = Array(repeating: lines, count: repeatCount).flatMap { $0 }
    let characters = paragraphs.joined(separator: "\n").count
    let tokens = try await model.tokenCount(paragraphs.joined(separator: "\n"))
    print("\n######## \((path as NSString).lastPathComponent) ×\(repeatCount): \(characters) characters, \(tokens) tokens")
    for language in languages {
        for style in styles {
            let writer = MeasuringWriter(model: model)
            let reserved = style == .brief ? TranscriptTitler.reservedTokens : TranscriptTitler.styledReservedTokens
            let start = Date()
            let description: TranscriptTitler.Description?
            do {
                description = try await titler.describe(paragraphs, locale: Locale(identifier: language), writer: writer,
                                                        bookmarked: false, style: style, needsTitle: true,
                                                        limit: TranscriptTitler.chunkCharacters(
                                                            contextSize: LocalLanguageModel.contextTokens, reserved: reserved),
                                                        partial: nil)
            } catch {
                print("== \(style.rawValue) \(language): error \(error)")
                continue
            }
            let seconds = Date().timeIntervalSince(start)
            print("\n======== \(style.rawValue) · \(language) · \(String(format: "%.1f", seconds)) s · \(writer.requests.count) request(s)")
            for (index, request) in writer.requests.enumerated() {
                let instructionTokens = try await model.tokenCount(request.instructions)
                let promptTokens = try await model.tokenCount(request.prompt)
                let answerTokens = try await model.tokenCount(request.answer)
                print("-- request \(index + 1): instructions \(instructionTokens) tokens, prompt \(promptTokens), answer \(answerTokens), \(String(format: "%.1f", request.seconds)) s")
            }
            // The final request's answer; with a styled one's title fallback (Brief's request after it), both.
            for request in writer.requests.suffix(style != .brief && writer.requests.count > 1 ? 2 : 1) {
                print("-- raw answer:\n\(request.answer)")
            }
            print("-- stored: title \(description?.title ?? "-") · topics \(description?.topics ?? [])\n\(description?.summary ?? "nil")")
        }
    }
}
