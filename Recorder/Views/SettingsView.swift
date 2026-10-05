import SwiftUI
import SwiftData

/// Settings (a tab; its heading scrolls away with the form, no navigation-bar title): Live Speaker Labels and People, the engine of the full-accuracy pass after Stop (Parakeet or Apple),
/// the speaker model (Nemotron's download), the model for titles and summaries (Gemma's download), the vocabulary (your words plus built-in German consulting, banking and
/// finance terms) and the experimental smart corrections (Gemma). Everything applies from the next recording.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(ParakeetModel.engineKey) private var engine = "parakeet"
    @Query private var people: [Person]
    private var peopleCount: Int { people.count }
    @State private var words = Vocabulary.custom
    @State private var usesBuiltIn = Vocabulary.usesBuiltIn
    @AppStorage(TranscriptCorrector.settingKey) private var smartCorrections = false
    /// Smart Corrections run on Gemma: downloaded under Titles and Summaries (not on the simulator).
    private var correctionsAvailable: Bool { BetterSummaries.isSupported && services.betterSummaries.state == .ready }
    @State private var draft = ""
    @FocusState private var isAdding: Bool
    @AppStorage(AppServices.liveSpeakerLabelsKey) private var liveSpeakerLabels = true
    @State private var path = NavigationPath()          // untyped: People pushes Person values too

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Toggle("Live Speaker Labels", isOn: $liveSpeakerLabels)
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
                    Text("Live Speaker Labels show who is speaking while you record; speakers are identified again, more accurately, after you stop. People are everyone you have named; their voices are recognized in new recordings.")
                }

                Section {
                    Picker("Engine", selection: $engine) {
                        Text("Parakeet").tag("parakeet")
                        Text("Apple Speech").tag("apple")
                    }
                    if engine == "parakeet" {
                        downloadStatus(services.parakeet.state, size: "610 MB") { await services.parakeet.download(force: true) }
                    }
                } header: {
                    Text("Transcription After Recording")
                } footer: {
                    Text(engine == "parakeet" ? Self.parakeetFooter : Self.appleFooter)
                }

                Section {
                    LabeledContent("Model", value: services.nemotron.state == .ready ? "NVIDIA Nemotron" : "Standard")
                    if services.nemotron.state != .ready {
                        downloadStatus(services.nemotron.state, size: "100 MB") { await services.nemotron.download(force: true) }
                    }
                } header: {
                    Text("Speaker Identification")
                } footer: {
                    Text(Self.nemotronFooter)
                }

                summariesSection

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

                Section {
                    Toggle("Smart Corrections (Experimental)", isOn: $smartCorrections)
                        .disabled(!correctionsAvailable)
                } footer: {
                    if correctionsAvailable {
                        Text(Self.correctionsFooter)
                    } else if BetterSummaries.isSupported {
                        Text("Needs Gemma on this iPhone: download it under Titles and Summaries.")
                    } else {
                        Text("Smart Corrections need an iPhone (not the simulator).")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)     // no bar title: the heading above says it
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .people: PeopleView()
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
            .onDisappear {                               // leaving the tab: a word typed but not submitted is kept
                guard !draft.isEmpty else { return }
                add()
                isAdding = false
            }
            .onChange(of: words) { _, new in Vocabulary.custom = new }
            .onChange(of: usesBuiltIn) { _, new in Vocabulary.usesBuiltIn = new }
        }
    }

    private static let parakeetFooter = "Parakeet re-transcribes each recording on this iPhone after you stop, more accurately than Apple Speech. It needs a one-time 610 MB download, which starts automatically on Wi-Fi. Until then Apple Speech is used."
    private static let appleFooter = "Apple Speech re-transcribes each recording on this iPhone after you stop. No download needed."
    private static let nemotronFooter = "NVIDIA Nemotron tells speakers apart on this iPhone after you stop, much more reliably than the standard model, also when people talk in quick succession. It needs a one-time 100 MB download, which starts automatically on Wi-Fi. Until then the standard model is used."
    /// Titles and summaries: Apple Intelligence or, downloaded, Gemma 4 E2B ("Better Summaries").
    @ViewBuilder
    private var summariesSection: some View {
        @Bindable var better = services.betterSummaries
        Section {
            LabeledContent("Model", value: better.activeModel != nil ? LocalLanguageModel.displayName : "Apple Intelligence")
            if BetterSummaries.isSupported {
                if better.state == .ready {
                    Toggle("Better Summaries", isOn: $better.isEnabled)
                    if better.isWorking {
                        LabeledContent("Writing summaries…") { ProgressView() }
                    }
                    Button("Delete Gemma (3.6 GB)", role: .destructive) { Task { await better.delete() } }
                } else {
                    downloadStatus(better.state, size: "3.6 GB") { better.download() }
                }
            }
        } header: {
            Text("Titles and Summaries")
        } footer: {
            Text(BetterSummaries.isSupported ? Self.summariesFooter : "Better Summaries need an iPhone (not the simulator).")
        }
    }

    private static let summariesFooter = "Better Summaries use Google's Gemma 4 E2B on this iPhone instead of Apple Intelligence: it reads a whole meeting at once, keeps who said what, and writes more precise titles and summaries. It needs a one-time 3.6 GB download (keep Scribe open meanwhile) and works while Scribe is open. Existing transcripts get new summaries too; titles you typed stay."
    private static let correctionsFooter = "After a recording, Gemma on this iPhone corrects grammar, spelling, punctuation and obviously misheard words, about a dozen speaker turns at a time, without changing what was said; a fragment that belongs to the previous speaker is moved there. German transcripts only, while Scribe is open. Applies from the next recording."

    /// A downloadable model's row: downloaded, progress, "Download Now" or the failure with "Try Again".
    @ViewBuilder
    private func downloadStatus(_ state: ModelDownloadState, size: String,
                                download: @escaping () async -> Void) -> some View {
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
    case people
}
