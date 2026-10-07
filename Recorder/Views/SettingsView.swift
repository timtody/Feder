import SwiftUI
import SwiftData

/// Settings (a tab; its heading scrolls away with the form, no navigation-bar title). Grouped by what the user is
/// doing, not by the pipeline's modules: People first and alone (a list you maintain, used in both stages), then
/// "While Recording" (live speaker labels), "After Recording" (the post-stop pass in its order: transcription,
/// speaker identification, summaries, smart corrections) and "Vocabulary". Each model has a detail page with its
/// explanation, download and options; the main page shows only the outcome as the row's value ("Parakeet",
/// "Downloading 40 %", "Apple Intelligence"), and every footer is one line. The model comparison (E4B, Qwen) is a
/// Developer section in DEBUG builds only. Everything applies from the next recording.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(ParakeetModel.engineKey) private var engine = "parakeet"
    @Query private var people: [Person]
    private var peopleCount: Int { people.count }
    @AppStorage(TranscriptCorrector.settingKey) private var smartCorrections = false
    /// Smart Corrections run on the local model: downloaded under Summaries (not on the simulator).
    private var correctionsAvailable: Bool { BetterSummaries.isSupported && services.betterSummaries.state == .ready }
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
                    Toggle("Smart Corrections", isOn: $smartCorrections)
                        .disabled(!correctionsAvailable)
                } header: {
                    Text("After Recording")
                } footer: {
                    if correctionsAvailable || !BetterSummaries.isSupported {
                        Text("Each recording is transcribed again more accurately after you stop. Smart Corrections (experimental) let the summary model fix grammar, spelling and misheard words for you to review.")
                    } else {
                        Text("Each recording is transcribed again more accurately after you stop. Smart Corrections need the local model: download it under Summaries.")
                    }
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


                #if DEBUG
                if BetterSummaries.isSupported {
                    developerSection
                }
                #endif
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

    private var transcriptionValue: String {
        engine == "parakeet" ? Self.value(services.parakeet.state, ready: "Parakeet", missing: "Apple Speech") : "Apple Speech"
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

    #if DEBUG
    /// The model comparison (Gemma 4 E4B, Qwen3.5 4B against E2B), for testing: DEBUG builds only.
    @ViewBuilder
    private var developerSection: some View {
        @Bindable var better = services.betterSummaries
        Section {
            Picker("Local Model", selection: $better.variant) {
                ForEach(LocalLanguageModel.Variant.allCases, id: \.self) { Text($0.shortName).tag($0) }
            }
            if better.state != .ready {
                ModelDownloadRow(state: better.state, size: better.variant.sizeText) { better.download() }
            } else {
                Button("Delete \(better.variant.displayName) (\(better.variant.sizeText))", role: .destructive) {
                    Task { await better.delete() }
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Which local model writes summaries and corrections. E4B and Qwen3.5 are here to compare with E2B; each is its own download.")
        }
    }
    #endif
}

/// A downloadable model's row: downloaded, progress, "Download Now" or the failure with "Try Again".
struct ModelDownloadRow: View {
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
                Text("Downloading model…")
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
            }
        case .notDownloaded, .waitingForWiFi:
            Button("Download Now (\(size))") { Task { await download() } }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("Download failed", systemImage: "exclamationmark.triangle")
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { Task { await download() } }
            }
        }
    }
}

// MARK: - Detail pages

/// Settings › Transcription: the model of the full-accuracy pass after Stop (Parakeet or Apple Speech) and
/// Parakeet's download.
struct TranscriptionModelView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(ParakeetModel.engineKey) private var engine = "parakeet"

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $engine) {
                    Text("Parakeet").tag("parakeet")
                    Text("Apple Speech").tag("apple")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(engine == "parakeet"
                     ? "Parakeet re-transcribes each recording on this iPhone after you stop, more accurately than Apple Speech. It needs a one-time 610 MB download, which starts automatically on Wi-Fi. Until then Apple Speech is used."
                     : "Apple Speech re-transcribes each recording on this iPhone after you stop. No download needed.")
            }
            if engine == "parakeet" {
                Section {
                    ModelDownloadRow(state: services.parakeet.state, size: "610 MB") { await services.parakeet.download(force: true) }
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
                    ModelDownloadRow(state: services.nemotron.state, size: "100 MB") { await services.nemotron.download(force: true) }
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
                        ModelDownloadRow(state: better.state, size: better.variant.sizeText) { better.download() }
                    }
                }
            } header: {
                Text("Titles and Summaries")
            } footer: {
                Text(BetterSummaries.isSupported
                     ? "Better Summaries use Google's Gemma 4 E2B on this iPhone instead of Apple Intelligence: it reads a whole meeting at once, keeps who said what, and writes more precise titles and summaries. It needs a one-time 3.6 GB download (keep Feder open meanwhile) and works while Feder is open. Existing transcripts get new summaries too; titles you typed stay. Smart Corrections use the same model."
                     : "Better Summaries need an iPhone (not the simulator).")
            }
        }
        .navigationTitle("Summaries")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Your Words: the user's vocabulary, one word per row, swipe to delete, a field to add; and the built-in
/// German consulting and banking list to read.
struct VocabularyView: View {
    @State private var words = Vocabulary.custom
    @State private var usesBuiltIn = Vocabulary.usesBuiltIn
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

            Section {
                Toggle("Consulting & Banking Terms", isOn: $usesBuiltIn)
                if usesBuiltIn {
                    DisclosureGroup("\(Vocabulary.builtIn.count) terms") {
                        Text(Vocabulary.builtIn.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("German office, consulting, banking and finance vocabulary, e.g. Cofinpro, Jour fixe, MaRisk, BaFin, Baufinanzierung.")
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
        .onChange(of: usesBuiltIn) { _, new in Vocabulary.usesBuiltIn = new }
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
