import SwiftUI
import SwiftData

/// Settings (a tab; its heading scrolls away with the form, no navigation-bar title). Grouped by what the user is
/// doing, not by the pipeline's modules: People first and alone (a list you maintain, used in both stages), then
/// "Recording" (in the order they happen: live speaker labels while recording, then the post-stop pass: transcription,
/// speaker identification, summaries; split into "While Recording" and "After Recording" until October 2026, a divide
/// with one switch on one side that didn't help) and "Vocabulary". Each model has a detail page with its
/// explanation, download and options; the main page shows only the outcome as the row's value ("Parakeet",
/// "Downloading 40 %", "Not downloaded"), and every footer is one line. Everything applies from the next recording.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(ParakeetModel.engineKey) private var engine = ParakeetModel.defaultEngine
    @Query private var people: [Person]
    private var peopleCount: Int { people.count }
    @AppStorage(AppServices.liveSpeakerLabelsKey) private var liveSpeakerLabels = true
    @AppStorage(PlaceLocator.saveLocationKey) private var saveLocation = true
    @State private var showsWelcome = false
    #if DEBUG
    @State private var resetPages: [OnboardingPage] = []
    @AppStorage(AppServices.liveLabelsModelKey) private var liveLabelsModel = LiveLabelsModel.lsEEND
    #endif
    @AppStorage(PeopleDirectory.recognitionKey) private var recognizesVoices = false
    @AppStorage(SpotlightIndex.enabledKey) private var showsInSearch = false
    @Environment(\.modelContext) private var modelContext
    @State private var confirmsVoiceDeletion = false
    /// The stack's path (untyped: People pushes person pages too) lives in AppNavigation, so "Go to Person" can push here.
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.settings) {
            Form {
                Section {
                    Toggle("Recognize People by Voice", isOn: recognition)
                    NavigationLink(value: SettingsRoute.people) {
                        LabeledContent("People", value: peopleCount == 0 ? "" : "\(peopleCount)")
                    }
                    .accessibilityIdentifier("People")
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Settings")                   // the heading scrolls away with the form
                            .font(.largeTitle.bold())
                            .foregroundStyle(Color(uiColor: .label))   // section headers are grey otherwise
                            .textCase(nil)
                            // Where "Transcripts" sits (x 20 pt, the list's row text; same top): a section header is
                            // inset further and placed lower than a list row.
                            .padding(.leading, -11)
                            .padding(.top, -5)
                            .padding(.bottom, 8)
                            .accessibilityAddTraits(.isHeader)
                        Text("People")                     // the group's own header, as the others have
                    }
                } footer: {
                    Text(recognizesVoices
                         ? "Feder keeps a voice profile of each speaker, only on this iPhone, and recognizes people you've named in new recordings."
                         : "Off: we keep no voice profiles and recognize no one. Speakers are still told apart.")
                }

                Section {
                    Toggle("Live Speaker Labels", isOn: $liveSpeakerLabels)
                    Toggle("Save Location", isOn: $saveLocation)
                    NavigationLink(value: SettingsRoute.transcription) {
                        LabeledContent("Transcription", value: transcriptionValue)
                    }
                    .accessibilityIdentifier("Transcription")
                    NavigationLink(value: SettingsRoute.speakers) {
                        LabeledContent("Speaker Identification", value: Self.value(services.nemotron.state, ready: "Nemotron", missing: String(localized: "Standard")))
                    }
                    .accessibilityIdentifier("Speaker Identification")
                    NavigationLink(value: SettingsRoute.summaries) {
                        LabeledContent("Summaries", value: summariesValue)
                    }
                    .accessibilityIdentifier("Summaries")
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Live Speaker Labels show who is speaking as you record. Save Location keeps where a recording was made; the place name comes from Apple Maps. After you stop, each recording is transcribed again and its speakers are identified more accurately.")
                }

                Section {
                    NavigationLink(value: SettingsRoute.vocabulary) {
                        LabeledContent("Your Words", value: Vocabulary.custom.isEmpty ? "" : "\(Vocabulary.custom.count)")
                    }
                } header: {
                    Text("Vocabulary")
                } footer: {
                    Text("Names and terms the transcription often gets wrong.")
                }

                // Opt-in (SpotlightIndex): turned on, the transcripts are indexed at once; off, the index is deleted.
                Section {
                    Toggle("Show in iPhone Search", isOn: $showsInSearch)
                        .onChange(of: showsInSearch) { Task { await SpotlightIndex.sync(modelContext) } }
                } header: {
                    Text("iPhone Search")
                } footer: {
                    Text(showsInSearch
                         ? "Your transcripts can be found in the iPhone's search. The index stays on this iPhone and can be read only while it is unlocked. What you type there can go to Apple for suggestions; that is set in the iPhone's Settings › Search."
                         : "Off: your transcripts are not in the iPhone's search.")
                }

                // App Review 5.1.1(i): the privacy policy reachable in the app; § 5 DDG: the legal notice; the HIG
                // (Onboarding): what the onboarding said stays findable; the licences of the code and models.
                Section {
                    Button("Welcome") { showsWelcome = true }
                    NavigationLink("Privacy Policy", value: SettingsRoute.privacy)
                    NavigationLink("Legal Notice", value: SettingsRoute.legalNotice)
                    NavigationLink("Acknowledgements", value: SettingsRoute.acknowledgements)
                    #if DEBUG
                    Button("Reset Onboarding") { resetOnboarding() }   // Debug builds only: no reinstall to see it again
                    liveLabelsModelPicker
                    #endif
                } header: {
                    Text("About")
                } footer: {
                    Text(Self.version)
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
                case .privacy: LegalTextView(document: .privacy)
                case .legalNotice: LegalTextView(document: .legalNotice)
                case .acknowledgements: AcknowledgementsView()
                }
            }
            .personDestination(stack: .settings)
            .alert("Delete Voice Profiles?", isPresented: $confirmsVoiceDeletion) {
                Button("Turn Off and Delete", role: .destructive) {
                    recognizesVoices = false
                    Task { services.people.deleteAllVoiceProfiles() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Turning this off deletes the voice profiles of your people and of the speakers in your transcripts. Names stay. Turned on again, it works from the next recording.")
            }
            .sheet(isPresented: $showsWelcome) {
                Onboarding(pages: [.welcome, .beforeYouRecord], isReplay: true)
            }
            #if DEBUG
            .sheet(isPresented: Binding(get: { !resetPages.isEmpty }, set: { if !$0 { resetPages = [] } })) {
                Onboarding(pages: resetPages)
            }
            #endif
            #if DEBUG
            .task {                                    // QA hook: `-showPeople` opens Settings with People pushed
                if ProcessInfo.processInfo.arguments.contains("-showPeople"), navigation.settings.isEmpty {
                    navigation.settings.append(SettingsRoute.people)
                }
            }
            #endif
            .onChange(of: liveSpeakerLabels) {
                // On: load the model (or wait for Wi-Fi); off: nothing waits any more. Applies from the next recording.
                Task { await services.prepareLiveDiarizer() }
            }
        }
    }

    /// "Recognize People by Voice": on at once; off at once while no voice profile exists, otherwise only after the
    /// confirmation, which deletes them (PeopleDirectory.deleteAllVoiceProfiles). The check fetches the store, so it
    /// runs after the tap's frame.
    private var recognition: Binding<Bool> {
        Binding(get: { recognizesVoices }, set: { on in
            guard !on else { recognizesVoices = true; return }
            Task {
                if services.people.hasVoiceProfiles() { confirmsVoiceDeletion = true } else { recognizesVoices = false }
            }
        })
    }

    #if DEBUG
    /// Debug builds: forgets that the onboarding was seen and shows it at once as on a new install (Welcome, Before You
    /// Record, the voice page, Optional Improvements when something can still be added); the tips come back at the next
    /// launch (TipKit's store can only be reset before it is configured). Downloaded models and settings stay.
    private func resetOnboarding() {
        let defaults = UserDefaults.standard
        for key in [AppServices.welcomeShownKey, Onboarding.recordingNoticeKey, Onboarding.voiceProfilesShownKey, Onboarding.spotlightShownKey,
                    Onboarding.improvementsShownKey, Onboarding.legacyGemmaShownKey] {
            defaults.removeObject(forKey: key)
        }
        NameSpeakersTip.showAgain()
        resetPages = [.welcome, .beforeYouRecord, .voiceProfiles, .spotlight]
            + (services.offersParakeet || services.offersGemma ? [.improvements] : [])
    }

    /// Debug builds: the live-labels model, LS-EEND or Sortformer, to compare the two on the iPhone. Applies from the
    /// next recording once the chosen model is loaded (a missing one downloads on Wi-Fi, like LS-EEND's); the line
    /// below the name says how far it is. Not localized: release builds never show it.
    private var liveLabelsModelPicker: some View {
        Picker(selection: $liveLabelsModel) {
            Text(verbatim: "LS-EEND").tag(LiveLabelsModel.lsEEND)
            Text(verbatim: "Sortformer").tag(LiveLabelsModel.sortformer)
        } label: {
            VStack(alignment: .leading) {
                Text(verbatim: "Live Labels Model")
                Text(verbatim: liveModelStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: liveLabelsModel) { services.liveLabelsModelChanged() }
    }

    private var liveModelStatus: String {
        if !liveSpeakerLabels { return "Live Speaker Labels are off" }
        if services.isLiveModelReady { return "Loaded" }
        if services.isLiveModelDownloading { return "Downloading \(services.liveModel.downloadMB) MB…" }
        if services.isLiveModelWaiting { return "Waiting for Wi-Fi (\(services.liveModel.downloadMB) MB)" }
        return "Not loaded"
    }
    #endif

    /// "Feder 1.0 (12)": the About section's footer.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "Feder \(short) (\(build))"
    }

    /// The engine that runs (Parakeet only once downloaded and chosen), or the download's progress.
    private var transcriptionValue: String {
        if case .downloading = services.parakeet.state { return Self.value(services.parakeet.state, ready: "", missing: "") }
        return engine == "parakeet" && services.parakeet.isReady ? "Parakeet" : String(localized: "Apple Speech")
    }

    /// Only Gemma writes titles and summaries: its name, "Off", the download's state, or "Not available" on an
    /// iPhone without 8 GB.
    private var summariesValue: String {
        let better = services.betterSummaries
        guard BetterSummaries.isSupported else { return String(localized: "Not available") }
        if better.state == .ready { return better.isEnabled ? better.variant.displayName : String(localized: "Off") }
        if better.state == .waitingForWiFi { return String(localized: "Waiting for Wi-Fi") }
        return Self.value(better.state, ready: better.variant.displayName, missing: String(localized: "Not downloaded"))
    }

    /// A model row's value from its download: the model's name once there, "Downloading 40 %" meanwhile, the
    /// stand-in before (what is used until then).
    static func value(_ state: ModelDownloadState, ready: String, missing: String) -> String {
        switch state {
        case .ready: ready
        case .downloading(let fraction): String(localized: "Downloading \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .failed: String(localized: "Download failed")
        case .notDownloaded, .waitingForWiFi: missing
        }
    }

}

/// A downloadable model's row: downloaded, progress, "Download <name> (<size>)" or the failure with "Try Again". Every
/// state names the model: a bare "Download Now" under "Model: Apple Intelligence" (before October 2026) read as if
/// Apple's model were being downloaded.
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
                Text("Each recording is transcribed again on this iPhone after you stop. Apple Speech uses the speech model iOS keeps for your language; Parakeet is more accurate for German and other European languages and needs a one-time 610 MB download.")
            }
            if !services.parakeet.isReady {
                Section {
                    ModelDownloadRow(name: "Parakeet", state: services.parakeet.state, size: "610 MB") { await services.parakeet.download(force: true) }
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
    @State private var asksLowData = false

    /// MB of speaker models that wait for Wi-Fi: Nemotron (100) and the live-label model (45; Debug builds' Sortformer 246).
    private var waitingMB: Int {
        (services.nemotron.state == .waitingForWiFi ? 100 : 0) + (services.isLiveModelWaiting ? services.liveModel.downloadMB : 0)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Model", value: services.nemotron.state == .ready ? "NVIDIA Nemotron" : String(localized: "Standard"))
                if waitingMB > 0 {
                    waiting
                } else if services.nemotron.state != .ready {
                    ModelDownloadRow(name: "Nemotron", state: services.nemotron.state, size: "100 MB") { await services.nemotron.download(force: true) }
                }
            } footer: {
                Text("NVIDIA Nemotron tells speakers apart on this iPhone after you stop, much more reliably than the standard model, also when people talk in quick succession. It downloads once (100 MB), by itself on Wi-Fi, together with the model for live speaker labels (45 MB). Until then the standard model is used.")
            }
        }
        .navigationTitle("Speaker Identification")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Low Data Mode Is On", isPresented: $asksLowData) {
            Button("Download") { services.downloadSpeakerModelsNow() }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("The speaker models are \(waitingMB) MB. Download them now, or wait for Wi-Fi.")
        }
    }

    /// The models wait: why, and how to get them now. Like the App Store's and Podcasts' cellular downloads, the
    /// button names the network and the size; Low Data Mode asks once more; offline there is nothing to offer.
    @ViewBuilder private var waiting: some View {
        switch services.network.kind {
        case .offline:
            LabeledContent("No Internet Connection") { Image(systemName: "wifi.slash").foregroundStyle(.secondary) }
        case .lowData:
            LabeledContent("Paused by Low Data Mode") { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
            Button("Download Now (\(waitingMB) MB)") { asksLowData = true }
        default:
            LabeledContent("Waiting for Wi-Fi") { Image(systemName: "wifi").foregroundStyle(.secondary) }
            Button("Download Now Using Cellular (\(waitingMB) MB)") { services.downloadSpeakerModelsNow() }
        }
    }
}

/// Settings › Summaries: automatic titles and summaries, written only by Gemma 4 E2B (Apple's model wrote them until
/// October 2026; its results were too weak). Its download, the on/off switch and Delete.
struct SummariesModelView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var better = services.betterSummaries
        Form {
            Section {
                if BetterSummaries.isSupported {
                    if better.state == .ready {
                        Toggle("Titles and Summaries", isOn: $better.isEnabled)
                        if better.isWorking {
                            LabeledContent("Writing summaries…") { ProgressView() }
                        }
                        Button("Delete \(better.variant.displayName) (\(better.variant.sizeText))", role: .destructive) {
                            Task { await better.delete() }
                        }
                    } else if better.state == .waitingForWiFi {
                        // The background download moves no byte off Wi-Fi: it says so instead of a Download button.
                        ProgressView(value: better.downloadedFraction) {
                            switch services.network.kind {
                            case .offline: Text("No Internet Connection")
                            case .lowData: Text("Paused by Low Data Mode")
                            default: Text("Waiting for Wi-Fi…")
                            }
                        } currentValueLabel: {
                            Text("\(better.variant.displayName) downloads when this iPhone is on Wi-Fi.")
                        }
                    } else {
                        ModelDownloadRow(name: better.variant.displayName, state: better.state, size: better.variant.sizeText) { better.download() }
                    }
                    switch better.state {
                    case .downloading, .waitingForWiFi:
                        Button("Cancel Download", role: .destructive) { Task { await better.delete() } }
                    default:
                        EmptyView()
                    }
                } else {
                    LabeledContent("Model", value: String(localized: "Not available"))
                }
            } header: {
                Text("Titles and Summaries")
            } footer: {
                Text(BetterSummaries.isSupported
                     ? "Google's Gemma 4 E2B writes a title and a short summary of every transcript, on this iPhone: it reads a whole meeting at once and keeps who said what. It needs a one-time 3.6 GB download over Wi-Fi, which goes on in the background, also when Feder is closed. Existing transcripts get summaries too; titles you typed stay."
                     : "Automatic titles and summaries need an iPhone with at least 8 GB of memory.")
            }
        }
        .navigationTitle("Summaries")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Your Words: the user's vocabulary, one word per row, swipe to delete, a field to add.
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
        .environment(AppNavigation())
}
#endif

enum SettingsRoute: Hashable {
    case people, transcription, speakers, summaries, vocabulary, privacy, legalNotice, acknowledgements
}
