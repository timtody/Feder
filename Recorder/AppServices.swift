import Foundation
import SwiftData
import Observation
import UIKit
import FluidAudio   // ModelRegistry (revision pins)

/// Composition root, injected with `.environment(services)` and read with `@Environment(AppServices.self)`.
/// On the simulator (DEBUG) the fake engines are used because SpeechTranscriber is unavailable there.
@MainActor @Observable
final class AppServices {
    /// UserDefaults key of the "Live Speaker Labels" toggle (Settings). Absent means on.
    nonisolated static let liveSpeakerLabelsKey = "liveSpeakerLabels"
    static var liveSpeakerLabelsEnabled: Bool {
        UserDefaults.standard.object(forKey: liveSpeakerLabelsKey) as? Bool ?? true
    }
    /// UserDefaults key: the user has passed the Welcome page, so the speaker models may download. App Review 4.2.3(ii):
    /// an app that downloads resources on first launch discloses their size and asks first, so a fresh install
    /// downloads nothing (Hugging Face doesn't even see its IP address) until the Welcome page has said what and how
    /// much. Existing users count as having passed it (`migrateExistingUser`).
    nonisolated static let welcomeShownKey = "welcomeShown"
    static var modelDownloadsAllowed: Bool { UserDefaults.standard.bool(forKey: welcomeShownKey) }

    /// Hugging Face commits pinned for FluidAudio's downloads, so a change upstream can't alter what users get without
    /// an app update. Only LS-EEND (the commit that was `main` on 2026-10-07, the one tested): its whole model is one
    /// download whose revision marker sits inside the model folder. FluidAudio 0.17.4 pins pyannote itself. Nemotron
    /// and Parakeet stay on `main`, because for a revision other than "main" FluidAudio deletes a repo folder that has no
    /// `.fluidaudio-revision` marker of its own (ModelCache.swift:43-45): Nemotron's loader downloads its bundle and then
    /// the repo root, which wiped the bundle it had just fetched (a fresh install failed once and downloaded twice), and
    /// Parakeet folders downloaded before the pin have no marker (610 MB fetched again at the next transcription).
    /// Nemotron is guarded by FluidAudio's weights-version marker instead (`discardStaleCache`).
    nonisolated static let modelRevisions = [
        "FluidInference/ls-eend-coreml": "28ce1b1f8ef186729df63b3886fbaae7bc10c4a1",
    ]

    let container: ModelContainer
    let identifier: SpeakerIdentifier
    let liveDiarizer: any LiveDiarizer
    let parakeet: ParakeetModel                      // Parakeet Ultra for the pass after Stop (optional download)
    let network = NetworkPath()                      // Wi-Fi, cellular, Low Data Mode or offline, watched
    let nemotron: NemotronModel                      // the Nemotron speaker model's download (Settings)
    let people: PeopleDirectory
    /// Plays a transcript's audio (the card's player bar, a tapped word).
    let player = TranscriptPlayer()
    let betterSummaries: BetterSummaries             // Gemma for titles and summaries (Settings)
    let usesFakes: Bool
    private let nemotronDiarizer: NemotronDiarizer
    @ObservationIgnored private var prewarmed = false
    /// The live model is loaded. Only then does a new recording get live labels; a recording never waits for it.
    private(set) var isLiveModelReady = false
    /// The live model isn't downloaded and waits for Wi-Fi (Settings › Speaker Identification offers it on cellular).
    private(set) var isLiveModelWaiting = false
    /// The live model is being downloaded right now (a prepare that has to fetch it first).
    private(set) var isLiveModelDownloading = false
    /// A prepare is running: a second call (a foreground or a network change meanwhile) neither starts another nor
    /// marks the model as waiting again.
    @ObservationIgnored private var isPreparingLiveModel = false

    init(container: ModelContainer) {
        self.container = container
        ModelRegistry.revisionOverrides = Self.modelRevisions
        Self.migrateExistingUser(container: container)
        let nemotronDiarizer = NemotronDiarizer()
        self.nemotronDiarizer = nemotronDiarizer
        nemotron = NemotronModel(diarizer: nemotronDiarizer, network: network)
        betterSummaries = BetterSummaries(network: network)
        parakeet = ParakeetModel(network: network)
        #if DEBUG && targetEnvironment(simulator)
        usesFakes = true
        let diarizer: any SpeakerDiarizer = FakeDiarizer()
        let fileTranscriber: any FileTranscriber = FakeFileTranscriber()
        liveDiarizer = FakeLiveDiarizer()
        #else
        usesFakes = false
        let diarizer: any SpeakerDiarizer = DiarizerSelector(nemotron: nemotronDiarizer, pyannote: FluidAudioDiarizer())
        let fileTranscriber: any FileTranscriber = SpeechFileTranscriber(parakeet: parakeet)
        liveDiarizer = LSEENDLiveDiarizer()
        #endif
        people = PeopleDirectory(modelContext: container.mainContext)
        // Recognition became opt-in (October 2026). Someone who already has voice profiles had it on: it stays on (and
        // the onboarding's voice page still comes once, showing it on), so their profiles don't sit unused.
        if UserDefaults.standard.object(forKey: PeopleDirectory.recognitionKey) == nil, people.hasVoiceProfiles() {
            UserDefaults.standard.set(true, forKey: PeopleDirectory.recognitionKey)
        }
        #if DEBUG && targetEnvironment(simulator)
        // UI tests: `-voiceRecognitionOn` stores it on (ScribeUITestCase's default, so the seeded people get voice
        // profiles); `-resetVoiceRecognition` removes the stored value, as on a new install. Written, not passed as
        // an argument value, so a test can still flip the switch.
        if ProcessInfo.processInfo.arguments.contains("-resetVoiceRecognition") {
            UserDefaults.standard.removeObject(forKey: PeopleDirectory.recognitionKey)
        } else if ProcessInfo.processInfo.arguments.contains("-voiceRecognitionOn") {
            UserDefaults.standard.set(true, forKey: PeopleDirectory.recognitionKey)
        }
        // Likewise "Show in iPhone Search": `-spotlightOn` stores it on, `-resetSpotlight` removes it.
        if ProcessInfo.processInfo.arguments.contains("-resetSpotlight") {
            UserDefaults.standard.removeObject(forKey: SpotlightIndex.enabledKey)
        } else if ProcessInfo.processInfo.arguments.contains("-spotlightOn") {
            UserDefaults.standard.set(true, forKey: SpotlightIndex.enabledKey)
        }
        #endif
        identifier = SpeakerIdentifier(diarizer: diarizer, fileTranscriber: fileTranscriber, people: people,
                                       betterSummaries: betterSummaries, modelContext: container.mainContext)
        // Gemma downloaded or turned on: the transcripts are described again with it (newest first), wherever the user is.
        betterSummaries.onBecameActive = { [identifier] in Task { await identifier.prepareAndRetryPending() } }
        network.onChange { [weak self] kind in self?.networkChanged(kind) }
    }

    /// Someone who used Feder before the Welcome page existed (October 2026) has passed it: transcripts or a downloaded
    /// speaker model say so. They don't see it, and their downloads go on as before; they still see "Before You
    /// Record" once. One fetchCount at launch (RecorderApp's init fetches the store anyway).
    private static func migrateExistingUser(container: ModelContainer) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: welcomeShownKey) == nil else { return }
        let transcripts = (try? container.mainContext.fetchCount(FetchDescriptor<Recording>())) ?? 0
        // Decided once, on the first launch of this version: a new install stores false, so a recording made before
        // its Welcome page appeared doesn't make it look like an existing user at the next launch.
        let existing = transcripts > 0 || NemotronDiarizer.isDownloaded
            || defaults.object(forKey: Onboarding.legacyGemmaShownKey) != nil
        defaults.set(existing, forKey: welcomeShownKey)
    }

    /// The Welcome page's Continue: the speaker models may download from now on.
    func allowModelDownloads() {
        UserDefaults.standard.set(true, forKey: Self.welcomeShownKey)
        startModelDownloads()
    }

    /// Launch, every return to the foreground, the Welcome page and a connection coming back: the speaker models.
    /// pyannote (21 MB, needed for any speakers and for recognizing people) on any connection, through the identifier's
    /// pending sweep; the live model (45 MB) and Nemotron (100 MB) on Wi-Fi only. Nothing before the Welcome page.
    func startModelDownloads() {
        guard Self.modelDownloadsAllowed else { return }
        Task {
            await identifier.prepareAndRetryPending()
            await identifier.refreshVoices()       // once per transcript: voices from final labels
        }
        if downloadsNemotron { Task { await nemotron.download(force: false) } }
        if downloadsParakeet { parakeet.resumeIfWanted() }   // asked for in the onboarding, Wi-Fi only
        betterSummaries.resumeIfWanted()                     // Gemma: a failed download the user asked for goes on
        Task { await prepareLiveDiarizer() }       // independent: neither waits for the other
        prewarmModels()                            // once per launch: Nemotron compiled before Stop
    }

    /// "Download Now Using Cellular" (Settings › Speaker Identification): the speaker models that wait for Wi-Fi, now,
    /// on whatever connection there is.
    func downloadSpeakerModelsNow() {
        Task { await nemotron.download(force: true) }
        Task { await prepareLiveDiarizer(force: true) }
    }

    /// Every network change while the app runs. A connection coming back retries what failed offline (pyannote,
    /// pending speakers); Wi-Fi starts the downloads that wait for it.
    private func networkChanged(_ kind: NetworkPath.Kind) {
        betterSummaries.networkChanged(kind)
        // Before the active check: Wi-Fi switched off in Control Center leaves the app inactive.
        if downloadsParakeet, kind != .wifi { parakeet.networkChanged(kind) }
        guard Self.modelDownloadsAllowed, UIApplication.shared.applicationState == .active else { return }
        if downloadsNemotron { nemotron.networkChanged(kind, allowed: true) }
        if downloadsParakeet, kind == .wifi { parakeet.networkChanged(kind) }
        guard kind != .offline else { return }
        Task { await identifier.prepareAndRetryPending() }
        Task { await prepareLiveDiarizer() }
    }

    /// Launch, every return to the foreground, and switching the toggle on: downloads (once, ~45 MB) and loads the live
    /// model in the background. Failures (typically offline) are silent: recordings have no live labels until a later
    /// call succeeds.
    /// A model already on the phone is only loaded (any connection, or none); a missing one downloads on Wi-Fi only,
    /// or anywhere with `force` ("Download Now Using Cellular").
    func prepareLiveDiarizer(force: Bool = false) async {
        guard Self.liveSpeakerLabelsEnabled, !isLiveModelReady, Self.modelDownloadsAllowed || usesFakes else {
            isLiveModelWaiting = false              // switched off (or ready): nothing waits
            return
        }
        guard !isPreparingLiveModel else { return }
        let downloaded = usesFakes || LSEENDLiveDiarizer.isDownloaded
        if !force, !downloaded, await network.current() != .wifi {
            isLiveModelWaiting = true
            return
        }
        isLiveModelWaiting = false
        isPreparingLiveModel = true
        isLiveModelDownloading = !downloaded
        defer { isPreparingLiveModel = false; isLiveModelDownloading = false }
        do {
            try await liveDiarizer.prepare()
            isLiveModelReady = true
            isLiveModelWaiting = false
        } catch {
            isLiveModelReady = false
            isLiveModelWaiting = !LSEENDLiveDiarizer.isDownloaded && network.kind != .wifi
        }
    }

    /// Once per launch, in the background: loads the downloaded Nemotron model before the first recording needs it.
    /// After every new build iOS compiles CoreML models for the Neural Engine again on first use; measured on an
    /// iPhone 17 right after an install: Nemotron 178 s (then 0.1-0.4 s), pyannote 2.5 s (then 0.1 s; already loaded
    /// at launch by SpeakerIdentifier.prepareAndRetryPending). Without this the first recording after a build waited
    /// minutes for its speakers. Utility priority; downloads nothing. (Parakeet, about 14 s the first time, is left
    /// alone: it is optional and the fallback at most.)
    /// While it runs, `identifier.isPreparingSpeakerModel` is set, so a recording stopped meanwhile says "Preparing
    /// speaker model…" instead of an unexplained long "Refining speakers…".
    func prewarmModels() {
        guard !prewarmed else { return }
        prewarmed = true
        #if DEBUG
        // QA (simulator): `-fakeSpeakerModelSeconds <s>` pretends the speaker model takes that long to prepare.
        let fake = UserDefaults.standard.double(forKey: "fakeSpeakerModelSeconds")
        if usesFakes, fake > 0 {
            identifier.isPreparingSpeakerModel = true
            Task { [identifier] in
                try? await Task.sleep(for: .seconds(fake))
                identifier.isPreparingSpeakerModel = false
            }
            return
        }
        #endif
        guard !usesFakes, NemotronDiarizer.isDownloaded else { return }
        let nemotron = nemotronDiarizer
        identifier.isPreparingSpeakerModel = true
        Task { [identifier] in
            #if DEBUG
            let start = ContinuousClock.now
            #endif
            await Task.detached(priority: .utility) { await nemotron.prewarm() }.value
            identifier.isPreparingSpeakerModel = false
            #if DEBUG
            print("[Scribe] prewarm: Nemotron after \(ContinuousClock.now - start)")
            #endif
        }
    }

    /// Nemotron downloads here: on an iPhone, and on the simulator only when `-fakeNemotronDownload` simulates it (the
    /// simulator never fetches the real model, also not when the Mac's network changes).
    private var downloadsNemotron: Bool { !usesFakes || fakesNemotronDownload }

    /// Parakeet likewise: the simulator only with `-fakeParakeetDownload`, and only on an iPhone that can transcribe
    /// at all (not the iPhone 11 or SE 2, Onboarding.canTranscribe).
    var downloadsParakeet: Bool {
        #if DEBUG
        (!usesFakes || ParakeetModel.fakesDownload) && Onboarding.canTranscribe
        #else
        Onboarding.canTranscribe
        #endif
    }

    /// A model that makes transcripts better is still to come: the live speaker model, Nemotron (the final speakers)
    /// and Parakeet when the user asked for it; not Gemma, which writes titles and summaries, not the transcript. The
    /// recording card says meanwhile that the quality is preliminary (RecordView), so a first recording made while
    /// they download doesn't pass for what Feder can do.
    var awaitsTranscriptModels: Bool {
        guard Self.modelDownloadsAllowed || usesFakes else { return false }
        let liveLabels = Self.liveSpeakerLabelsEnabled && (isLiveModelWaiting || isLiveModelDownloading)
        let speakers = downloadsNemotron && nemotron.state != .ready
        let words = downloadsParakeet && parakeet.isWanted && !parakeet.isReady
        return liveLabels || speakers || words
    }

    /// The onboarding's Optional Improvements offers Parakeet (MainView decides whether the page comes, the page lists it).
    var offersParakeet: Bool { downloadsParakeet && !parakeet.isReady && !parakeet.isWanted }

    /// …and Gemma: on an iPhone that runs it, while it is neither downloaded nor on its way, and not to someone who
    /// already saw the Gemma-only page it replaced (October 2026) and declined.
    var offersGemma: Bool {
        BetterSummaries.isSupported && betterSummaries.state == .notDownloaded
            && !UserDefaults.standard.bool(forKey: Onboarding.legacyGemmaShownKey)
    }

    /// Simulator QA: Nemotron's download is simulated (`-fakeNemotronDownload`).
    var fakesNemotronDownload: Bool {
        #if DEBUG
        NemotronModel.fakesDownload
        #else
        false
        #endif
    }

    /// A fresh session (fresh capture + transcriber) for every recording.
    func makeRecordingSession() -> RecordingSession {
        player.stop()                                  // recording and playback never overlap (both on AudioHardware)
        #if DEBUG && targetEnvironment(simulator)
        let transcriber: any Transcriber = FakeTranscriber()
        #else
        let transcriber: any Transcriber = SpeechTranscriberEngine()
        #endif
        let live = Self.liveSpeakerLabelsEnabled && isLiveModelReady ? liveDiarizer : nil
        return RecordingSession(capture: MicrophoneCapture(), transcriber: transcriber,
                                modelContext: container.mainContext, identifier: identifier, liveDiarizer: live)
    }
}
