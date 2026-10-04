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
    /// The live model is loaded. Only then does a new recording get live labels; a recording never waits for it.
    private(set) var isLiveModelReady = false

    init(container: ModelContainer) {
        self.container = container
        let nemotronDiarizer = NemotronDiarizer()
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
