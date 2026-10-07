import SwiftUI
import SwiftData

/// Settings (a tab; its heading scrolls away with the form, no navigation-bar title). Grouped by what the user is
/// doing, not by the pipeline's modules: People first and alone (a list you maintain, used in both stages), then
/// "While Recording" (live speaker labels), "After Recording" (the post-stop pass in its order: transcription,
/// speaker identification, summaries) and "Vocabulary". Each model has a detail page with its
/// explanation, download and options; the main page shows only the outcome as the row's value ("Parakeet",
/// "Downloading 40 %", "Apple Intelligence"), and every footer is one line. Everything applies from the next recording.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(ParakeetModel.engineKey) private var engine = ParakeetModel.defaultEngine
    @Query private var people: [Person]
    private var peopleCount: Int { people.count }
    @AppStorage(AppServices.liveSpeakerLabelsKey) private var liveSpeakerLabels = true
    @State private var path = NavigationPath()          // untyped: People pushes Person values too

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: SettingsRoute.people) {
                        LabeledContent("People", value: peopleCount == 0 ? "" : "\(peopleCount)")
                    }
                    .accessibilityIdentifier("People")
                } header: {
                    Text("Settings")                       // the heading scrolls away with the form
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color(uiColor: .label))   // section headers are grey otherwise
                        .textCase(nil)
                        // Where "Transcripts" sits (x 20 pt, the list's row text; same top): a section header is
                        // inset further and placed lower than a list row.
                        .padding(.leading, -11)
                        .padding(.top, -5)
                        .padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("The voices Feder knows. Named speakers are recognized in new recordings.")
                }

                Section {
                    Toggle("Live Speaker Labels", isOn: $liveSpeakerLabels)
                } header: {
                    Text("While Recording")
                } footer: {
                    Text("Shows who is speaking as you record. Speakers are identified again, more accurately, after you stop.")
                }

                Section {
                    NavigationLink(value: SettingsRoute.transcription) {
                        LabeledContent("Transcription", value: transcriptionValue)
                    }
                    .accessibilityIdentifier("Transcription")
                    NavigationLink(value: SettingsRoute.speakers) {
                        LabeledContent("Speaker Identification", value: Self.value(services.nemotron.state, ready: "Nemotron", missing: "Standard"))
                    }
                    .accessibilityIdentifier("Speaker Identification")
                    NavigationLink(value: SettingsRoute.summaries) {
                        LabeledContent("Summaries", value: summariesValue)
                    }
                    .accessibilityIdentifier("Summaries")
                } header: {
                    Text("After Recording")
                } footer: {
                    Text("Each recording is transcribed again more accurately after you stop.")
                }

                Section {
                    NavigationLink(value: SettingsRoute.vocabulary) {
                        LabeledContent("Your Words", value: Vocabulary.custom.isEmpty ? "" : "\(Vocabulary.custom.count)")
                    }
                    Toggle("Consulting & Banking Terms", isOn: usesBuiltIn)
                } header: {
                    Text("Vocabulary")
                } footer: {
                    Text("Names and terms the transcription often gets wrong.")
                }


            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)     // no bar title: the heading above says it
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .people: PeopleView()
                case .transcription: TranscriptionModelView()
                case .speakers: SpeakerModelView()
                case .summaries: SummariesModelView()
                case .vocabulary: VocabularyView()
                }
            }
            #if DEBUG
            .task {                                    // QA hook: `-showPeople` opens Settings with People pushed
                if ProcessInfo.processInfo.arguments.contains("-showPeople"), path.isEmpty { path.append(SettingsRoute.people) }
            }
            #endif
            .onChange(of: liveSpeakerLabels) { _, on in
                if on { Task { await services.prepareLiveDiarizer() } }   // applies from the next recording
            }
        }
    }

    private var usesBuiltIn: Binding<Bool> {
        Binding(get: { Vocabulary.usesBuiltIn }, set: { Vocabulary.usesBuiltIn = $0 })
    }

    /// The engine that runs (Parakeet only once downloaded and chosen), or the download's progress.
    private var transcriptionValue: String {
        if case .downloading = services.parakeet.state { return Self.value(services.parakeet.state, ready: "", missing: "") }
        return engine == "parakeet" && services.parakeet.isReady ? "Parakeet" : "Apple Speech"
    }

    private var summariesValue: String {
        let better = services.betterSummaries
        guard BetterSummaries.isSupported else { return "Apple Intelligence" }
        if better.activeModel != nil { return better.variant.displayName }
        return Self.value(better.state, ready: "Apple Intelligence", missing: "Apple Intelligence")
    }

    /// A model row's value from its download: the model's name once there, "Downloading 40 %" meanwhile, the
    /// stand-in before (what is used until then).
    static func value(_ state: ModelDownloadState, ready: String, missing: String) -> String {
        switch state {
        case .ready: ready
        case .downloading(let fraction): "Downloading \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .failed: "Download failed"
        case .notDownloaded, .waitingForWiFi: missing
        }
    }

}

/// A downloadable model's row: downloaded, progress, "Download <name> (<size>)" or the failure with "Try Again". Every
/// state names the model: a bare "Download Now" under "Model: Apple Intelligence" read as if Apple's model were being
/// downloaded.
struct ModelDownloadRow: View {
    let name: String
    let state: ModelDownloadState
    let size: String
    let download: () async -> Void

    var body: some View {
        switch state {
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading \(name)…")
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
            }
        case .notDownloaded, .waitingForWiFi:
            Button("Download \(name) (\(size))") { Task { await download() } }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("\(name) Download Failed", systemImage: "exclamationmark.triangle")
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { Task { await download() } }
            }
        }
    }
}

// MARK: - Detail pages

/// Settings › Transcription: the model of the full-accuracy pass after Stop. Apple Speech by default; Parakeet is an
/// optional 610 MB download, listed in the picker once it is there (a finished download selects it). The picker shows
/// what runs: a stored "parakeet" without the model reads as Apple Speech.
struct TranscriptionModelView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(ParakeetModel.engineKey) private var engine = ParakeetModel.defaultEngine

    private var selection: Binding<String> {
        Binding(get: { engine == "parakeet" && services.parakeet.isReady ? "parakeet" : "apple" },
                set: { engine = $0 })
    }

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: selection) {
                    Text("Apple Speech").tag("apple")
                    if services.parakeet.isReady {
                        Text("Parakeet").tag("parakeet")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Each recording is transcribed again on this iPhone after you stop. Apple Speech needs no download; Parakeet is more accurate for German and other European languages and needs a one-time 610 MB download.")
            }
            if !services.parakeet.isReady {
                Section {
                    ModelDownloadRow(name: "Parakeet", state: services.parakeet.state, size: "610 MB") { await services.parakeet.download() }
                }
            }
        }
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Speaker Identification: Nemotron's download; the standard model until then.
struct SpeakerModelView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Form {
            Section {
                LabeledContent("Model", value: services.nemotron.state == .ready ? "NVIDIA Nemotron" : "Standard")
                if services.nemotron.state != .ready {
                    ModelDownloadRow(name: "Nemotron", state: services.nemotron.state, size: "100 MB") { await services.nemotron.download(force: true) }
                }
            } footer: {
                Text("NVIDIA Nemotron tells speakers apart on this iPhone after you stop, much more reliably than the standard model, also when people talk in quick succession. It needs a one-time 100 MB download, which starts automatically on Wi-Fi. Until then the standard model is used.")
            }
        }
        .navigationTitle("Speaker Identification")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Summaries: Apple Intelligence or, downloaded, the local model ("Better Summaries", Gemma 4 E2B).
struct SummariesModelView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var better = services.betterSummaries
        Form {
            Section {
                LabeledContent("Model", value: better.activeModel != nil ? better.variant.displayName : "Apple Intelligence")
                if BetterSummaries.isSupported {
                    if better.state == .ready {
                        Toggle("Better Summaries", isOn: $better.isEnabled)
                        if better.isWorking {
                            LabeledContent("Writing summaries…") { ProgressView() }
                        }
                        Button("Delete \(better.variant.displayName) (\(better.variant.sizeText))", role: .destructive) {
                            Task { await better.delete() }
                        }
                    } else {
                        ModelDownloadRow(name: better.variant.displayName, state: better.state, size: better.variant.sizeText) { better.download() }
                    }
                }
            } header: {
                Text("Titles and Summaries")
            } footer: {
                Text(BetterSummaries.isSupported
                     ? "Better Summaries use Google's Gemma 4 E2B on this iPhone instead of Apple Intelligence: it reads a whole meeting at once, keeps who said what, and writes more precise titles and summaries. It needs a one-time 3.6 GB download (keep Feder open meanwhile) and works while Feder is open. Existing transcripts get new summaries too; titles you typed stay."
                     : "Better Summaries need an iPhone (not the simulator).")
            }
        }
        .navigationTitle("Summaries")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Your Words: the user's vocabulary, one word per row, swipe to delete, a field to add. The built-in terms
/// are the Consulting & Banking Terms toggle on the main Settings page (it was here too, twice in two screens).
struct VocabularyView: View {
    @State private var words = Vocabulary.custom
    @State private var draft = ""
    @FocusState private var isAdding: Bool

    var body: some View {
        Form {
            Section {
                ForEach(words, id: \.self) { word in
                    Text(word)
                }
                .onDelete { words.remove(atOffsets: $0) }
                TextField("Add a word or name", text: $draft)
                    .focused($isAdding)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(add)
            } header: {
                Text("Your Words")
            } footer: {
                Text("Names, products and terms the transcription often gets wrong. Applies from the next recording.")
            }
        }
        .navigationTitle("Your Words")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {                               // leaving the page: a word typed but not submitted is kept
            guard !draft.isEmpty else { return }
            add()
            isAdding = false
        }
        .onChange(of: words) { _, new in Vocabulary.custom = new }
    }

    /// Adds the draft (comma-separated input becomes several words); skips blanks and case-insensitive duplicates.
    private func add() {
        for part in draft.split(separator: ",") {
            let word = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { continue }
            words.append(word)
        }
        draft = ""
        isAdding = true
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .environment(AppServices(container: PreviewData.container))
}
#endif

enum SettingsRoute: Hashable {
    case people, transcription, speakers, summaries, vocabulary
}
