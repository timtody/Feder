import Foundation
import SwiftData
import Observation

/// Composition root, injected with `.environment(services)` and read with `@Environment(AppServices.self)`.
/// On the simulator (DEBUG) the fake engines are used because SpeechTranscriber is unavailable there.
@MainActor @Observable
final class AppServices {
    /// UserDefaults key of the "Live Speaker Labels" toggle (Settings). Absent means on.
    nonisolated static let liveSpeakerLabelsKey = "liveSpeakerLabels"
    static var liveSpeakerLabelsEnabled: Bool {
        UserDefaults.standard.object(forKey: liveSpeakerLabelsKey) as? Bool ?? true
    }

    let container: ModelContainer
    let identifier: SpeakerIdentifier
    let liveDiarizer: any LiveDiarizer
    let parakeet = ParakeetModel()
    let nemotron: NemotronModel                      // the Nemotron speaker model's download (Settings)
    let people: PeopleDirectory
    let betterSummaries = BetterSummaries()          // Gemma for titles and summaries (Settings)
    let usesFakes: Bool
    private let nemotronDiarizer: NemotronDiarizer
    @ObservationIgnored private var prewarmed = false
    /// The live model is loaded. Only then does a new recording get live labels; a recording never waits for it.
    private(set) var isLiveModelReady = false

    init(container: ModelContainer) {
        self.container = container
        let nemotronDiarizer = NemotronDiarizer()
        self.nemotronDiarizer = nemotronDiarizer
        nemotron = NemotronModel(diarizer: nemotronDiarizer)
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
        identifier = SpeakerIdentifier(diarizer: diarizer, fileTranscriber: fileTranscriber, people: people,
                                       betterSummaries: betterSummaries, modelContext: container.mainContext)
        // Gemma downloaded or turned on: the transcripts are described again with it (newest first), wherever the user is.
        betterSummaries.onBecameActive = { [identifier] in Task { await identifier.prepareAndRetryPending() } }
    }

    /// Launch, every return to the foreground, and switching the toggle on: downloads (once, ~45 MB) and loads the live
    /// model in the background. Failures (typically offline) are silent: recordings have no live labels until a later
    /// call succeeds.
    func prepareLiveDiarizer() async {
        guard Self.liveSpeakerLabelsEnabled, !isLiveModelReady else { return }
        do {
            try await liveDiarizer.prepare()
            isLiveModelReady = true
        } catch {
            isLiveModelReady = false
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

    /// A fresh session (fresh capture + transcriber) for every recording.
    func makeRecordingSession() -> RecordingSession {
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
