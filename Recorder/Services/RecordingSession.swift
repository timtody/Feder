import Foundation
import AVFoundation
import SwiftData
import Observation

/// Orchestrates ONE recording: permission -> speech model -> capture + live transcription -> stop -> persist ->
/// hand off to SpeakerIdentifier. Create a fresh instance per recording (AppServices.makeRecordingSession()).
@MainActor @Observable
final class RecordingSession: Identifiable {
    enum State: Equatable {
        case idle
        case preparing                  // mic permission, locale, speech asset check
        case downloadingSpeechModel     // first use per locale; `downloadProgress` is set
        case recording(since: Date)
        case finishing                  // Stop tapped: draining, finalizing, saving
        case finished(Recording)        // saved; MainView's card turns into the transcript
        case discarded                  // nothing was transcribed; file deleted; the card closes
        case failed(RecorderError)      // shown as an in-screen overlay
    }

    let id = UUID()

    /// From Record until it is saved, discarded or has failed (idle: just made, `start()` follows).
    var isOngoing: Bool {
        switch state {
        case .idle, .preparing, .downloadingSpeechModel, .recording, .finishing: true
        case .finished, .discarded, .failed: false
        }
    }

    /// Each change also tells SpeakerIdentifier whether a recording is being made (from Record until it is saved or
    /// dropped): its sweeps over older transcripts start nothing new meanwhile.
    private(set) var state: State = .idle {
        didSet {
            switch state {
            case .preparing, .downloadingSpeechModel, .recording, .finishing: identifier.setRecording(true)
            case .idle, .finished, .discarded, .failed: identifier.setRecording(false)
            }
        }
    }
    private(set) var text = LiveText()                     // what the live screen shows (LiveTranscript)
    private(set) var level: Float = 0                      // microphone level 0...1 for the meter, while recording
    private(set) var downloadProgress: Progress?
    private(set) var locale: Locale?
    /// The name the transcript will be saved with ("New Transcript N"), fixed when the session is made (at Record): the
    /// recording card shows it in the title's place from its first frame, so it never changes under the user (not even
    /// when transcripts are deleted meanwhile). Not in `start()`: that runs 0.12 s after the card has begun zooming in
    /// (MainView.startDelay), which showed the title field's grey "Title" placeholder until then.
    let transcriptName: String
    /// Where the recording started, once PlaceLocator has it (the recording card shows it in the date line).
    private(set) var place: RecordingPlace?
    /// The recorded length (the file's), from Stop on: the duration the transcript will show.
    private(set) var recordedDuration: TimeInterval?

    private let capture: any AudioCapture
    private let transcriber: any Transcriber
    private let modelContext: ModelContext
    private let identifier: SpeakerIdentifier
    private let liveDiarizer: (any LiveDiarizer)?          // nil: live labels off, or the model isn't loaded yet
    private var live = LiveTranscript()                    // words, provisional words, live labels -> `text`
    private var liveTurns = LiveSpeakerTurns()             // the newest snapshot, also after recording (for saving)
    private var liveTask: Task<Void, Never>?
    private var placeTask: Task<RecordingPlace?, Never>?  // where the recording started, looked up in parallel
    private var refresh: Task<Void, Never>?               // re-shows the text when a pending live label comes due
    private var fileName: String?
    private var transcriptionEnded = false                 // Stop saved the words: later transcriber events are dropped
    private var interruptionObserver: (any NSObjectProtocol)?

    init(capture: any AudioCapture, transcriber: any Transcriber, modelContext: ModelContext, identifier: SpeakerIdentifier,
         liveDiarizer: (any LiveDiarizer)? = nil) {
        self.capture = capture
        self.transcriber = transcriber
        self.modelContext = modelContext
        self.identifier = identifier
        self.liveDiarizer = liveDiarizer
        let count = (try? modelContext.fetchCount(FetchDescriptor<Recording>())) ?? 0
        transcriptName = String(localized: "New Transcript \(count + 1)")   // stored: TranscriptTitler.isDefaultName knows both languages
    }

    /// The language to transcribe in: the one chosen in the record accessory, else the phone's (TranscriptionLanguage).
    static var transcriptionLocale: Locale { TranscriptionLanguage.current }

    func start() async {
        guard state == .idle else { return }
        state = .preparing
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed(.microphoneDenied)
            return
        }
        do {
            try await capture.activateSession()              // audio session first, then the analyzer (Apple's order)
            #if DEBUG
            print("[Scribe] audio session active, requested locale \(Self.transcriptionLocale.identifier), preferred \(Locale.preferredLanguages)")
            #endif
            let setup = try await transcriber.prepare(locale: Self.transcriptionLocale) { [weak self] progress in
                guard let self, self.state == .preparing else { return }   // not after cancel()
                self.downloadProgress = progress
                self.state = .downloadingSpeechModel
            }
            guard state != .discarded else {                  // cancelled during prepare/download: nothing captured yet
                await capture.shutDown()                      // deactivates the audio session
                return
            }
            downloadProgress = nil
            locale = setup.locale
            let fileName = AudioFileStore.newFileName()
            self.fileName = fileName
            // Live labels: capture yields the frames it writes, from file frame 0, into this unbounded stream. It buffers
            // until the live diarizer gets it below, once recording has really started, so nothing is lost.
            let liveSamples = liveDiarizer.map { _ in AsyncStream<[Float]>.makeStream() }
            let levels = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let input = try await capture.start(writingTo: AudioFileStore.url(for: fileName), analyzerFormat: setup.audioFormat,
                                                liveSamples: liveSamples?.continuation, levels: levels.continuation)
            try await transcriber.start(input: input) { [weak self] event in self?.handle(event) }
            guard state != .discarded else {                  // cancelled while the analyzer was starting
                _ = capture.seal()
                await capture.shutDown()
                try? await transcriber.finish()
                AudioFileStore.delete(fileName: fileName)
                return
            }
            observeInterruptions()
            state = .recording(since: .now)
            if PlaceLocator.isEnabled, !PlaceLocator.isUndetermined { lookUpPlace() }   // first recording: at Stop
            showLevels(levels.stream)
            if let liveDiarizer, let liveSamples { startLiveDiarization(liveDiarizer, samples: liveSamples.stream) }
        } catch {
            _ = capture.seal()
            await capture.shutDown()
            if let fileName { AudioFileStore.delete(fileName: fileName) }
            guard state != .discarded else { return }         // a cancelled start may still throw; keep .discarded
            state = .failed(error as? RecorderError ?? .audioEngineFailed(error.localizedDescription))
        }
    }

    /// "Cancel" on the preparing / downloading overlays, i.e. before anything was captured. The cover dismisses via
    /// `.discarded`; `start()` re-checks the state after each await and releases whatever it had started. A speech
    /// model download already in flight keeps going in the system, so the next attempt finds the asset installed.
    func cancel() {
        switch state {
        case .idle, .preparing, .downloadingSpeechModel: state = .discarded
        case .recording, .finishing, .finished, .discarded, .failed: break
        }
    }

    /// Stop button, audio interruption, or a mid-session transcriber failure. Saves whatever was transcribed.
    func stop() async { await stop(failure: nil) }

    private func stop(failure: RecorderError?) async {
        guard case .recording(let since) = state, let fileName else { return }
        #if DEBUG
        let stopped = ContinuousClock.now
        #endif
        state = .finishing
        stopObservingInterruptions()
        refresh?.cancel()
        let duration = capture.seal()                         // finishes the input, live sample and level streams
        recordedDuration = duration                           // same update as .finishing: RecordView's timer shows it
                                                              // from the first frame of the turn and lands on it
        // Stopping the engine and deactivating the session (~70 ms) run on the audio hardware's actor, so the first
        // frame of the card's turn isn't held up; the next recording's activation queues behind them there.
        Task { await capture.shutDown() }
        let finished = await finishTranscription(within: .seconds(2))
        transcriptionEnded = true                             // a late finish() delivers into the void
        // Past the cap the provisional tail is kept as words; the full-accuracy pass after Stop re-transcribes anyway.
        let words = finished ? live.words : live.words + live.provisionalWords
        await finishLiveDiarization()                         // usually done already: it finalized during finish()
        LiveTrace.summary()
        guard !words.isEmpty else {
            AudioFileStore.delete(fileName: fileName)
            state = failure.map { .failed($0) } ?? .discarded
            return
        }
        // The first recording asks for location now, after Stop, instead of over the live recording (PlaceLocator); its
        // budget includes the time the user reads the alert. Save Location turned off meanwhile: no place, and the
        // lookup stops before anything goes to Apple's geocoder.
        if PlaceLocator.isEnabled {
            if placeTask == nil { lookUpPlace(timeout: .seconds(60)) }
        } else {
            placeTask?.cancel()
            placeTask = nil
            place = nil
        }
        let recording = Recording(name: transcriptName,
                                  audioFileName: fileName,
                                  localeIdentifier: (locale ?? Self.transcriptionLocale).identifier(.bcp47))
        // What the recording card showed: the start time (not the moment of saving) and the place, when it was found
        // already, so the transcript's date line is the card's and nothing pops in after the turn.
        recording.createdAt = since
        recording.duration = duration
        if let place { recording.apply(place) }
        recording.words = words
        // Live labels (if any) are saved as preliminary segments; speakerStatus stays .pending (Recording.init), and
        // SpeakerIdentifier's offline pass replaces them (offline is the source of truth).
        recording.segments = TranscriptAligner.segments(words: words, turns: liveTurns.turns,
                                                        labelledUntil: liveTurns.processedUntil)
        modelContext.insert(recording)
        try? modelContext.save()                              // transcript is safe before diarization starts
        #if DEBUG
        print("[Scribe] Stop -> saved in \((ContinuousClock.now - stopped).formatted(.units(allowed: [.milliseconds])))")
        #endif
        state = .finished(recording)
        identifier.enqueue(recording)
        if place == nil, let placeTask {                       // not found yet: added when it is; never holds up saving
            Task { [modelContext] in
                guard let place = await placeTask.value, PlaceLocator.isEnabled, !recording.isDeleted,
                      recording.modelContext != nil else { return }
                recording.apply(place)
                try? modelContext.save()
            }
        }
    }

    /// Where the recording is, looked up in parallel; the transcript gets it when it arrives (never holds anything up).
    private func lookUpPlace(timeout: Duration = .seconds(15)) {
        placeTask = Task { [weak self] in
            let place = await PlaceLocator.current(timeout: timeout)
            self?.place = place
            return place
        }
    }

    private func handle(_ event: TranscriptionEvent) {
        guard !transcriptionEnded else { return }
        switch event {
        case .volatile(let tail):
            LiveTrace.received("volatile")
            live.revise(tail)
        case .finalized(let newWords):
            LiveTrace.received("final")
            live.finalize(newWords)
        case .failed(let error):
            Task { await self.stop(failure: error) }
            return
        }
        show()
    }

    // MARK: Live speaker labels (preliminary; replaced by the offline pass after Stop)

    private func startLiveDiarization(_ diarizer: any LiveDiarizer, samples: AsyncStream<[Float]>) {
        let snapshots = diarizer.start(samples: samples)
        liveTask = Task { [weak self] in                      // MainActor; only applies snapshots, no CoreML work
            for await snapshot in snapshots { self?.apply(snapshot) }
        }
    }

    /// At most one snapshot per 0.5 s of audio arrives (the diarizer rate-limits, bufferingNewest(1) absorbs bursts),
    /// so each one re-labels the transcript right away (incrementally: LiveSpeakers, SteadyLabels).
    private func apply(_ snapshot: LiveSpeakerTurns) {
        liveTurns = snapshot
        guard case .recording = state else { return }         // stop() builds the saved segments itself
        LiveTrace.received("labels")
        live.apply(snapshot)
        show()
    }

    /// Publishes the live text. A live label shows its speaker only once it held (SteadyLabels.hold); while one is
    /// pending, this runs again as it comes due, even if no new words or snapshot arrive meanwhile.
    private func show() {
        // Frozen from Stop on: the words finalized while saving re-split the paragraphs (a turn merged into the one
        // above it) just before the card turned into the transcript. The saved transcript shows the final words.
        guard state != .finishing else { return }
        let changed = live.text != text
        if changed { text = live.text }
        LiveTrace.published(changed: changed, words: live.words.count, paragraphs: text.segments.count)
        guard refresh == nil, let due = live.nextChange else { return }
        refresh = Task { [weak self] in
            try? await Task.sleep(until: due)
            guard let self, case .recording = self.state else { return }
            self.refresh = nil
            LiveTrace.received("due")
            self.live.refresh()
            self.show()
        }
    }

    /// Level meter: rises at once, falls back over about a second (one step per tap buffer, about 0.1 s), then rests at 0.
    private func showLevels(_ levels: AsyncStream<Float>) {
        Task { [weak self] in
            for await input in levels {
                guard let self else { return }
                let next = max(input, level * 0.7)
                level = next < 0.02 ? 0 : next        // settle at exactly 0, so silence stops redrawing the meter
            }
            self?.level = 0                                   // the stream ends with the recording (capture.seal())
        }
    }

    /// Waits at most `limit` for the transcriber's last words: usually about 0.1 s, but up to 47 s were measured on a
    /// loaded Mac. Returns false on timeout; finish() then completes in the background and its late words are ignored.
    private func finishTranscription(within limit: Duration) async -> Bool {
        let transcriber = transcriber
        let finish = Task { try? await transcriber.finish() }     // unstructured: past the cap it still finishes cleanly
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await finish.value; return true }
            group.addTask { try? await Task.sleep(for: limit); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Waits at most 0.5 s for the last snapshot. Past that, the last one received is kept: words it doesn't cover
    /// are saved unlabelled and get their speaker from the offline pass, so live labels never hold up saving.
    private func finishLiveDiarization() async {
        guard let liveTask else { return }
        let deadline = Task { try? await Task.sleep(for: .milliseconds(500)); liveTask.cancel() }
        await liveTask.value
        deadline.cancel()
        self.liveTask = nil
    }

    // MARK: Interruptions (phone call, Siri): treated exactly like Stop.

    private func observeInterruptions() {
        let name: Notification.Name
        if #available(iOS 27.0, *) {
            name = AVAudioSession.didBecomeInactiveNotification
        } else {
            name = AVAudioSession.interruptionNotification
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            guard Self.isInterruption(note) else { return }
            MainActor.assumeIsolated {                        // queue: .main => main thread
                guard let self else { return }
                Task { await self.stop() }
            }
        }
    }

    /// iOS 27 replaced the interruption notification (deprecated): the session "became inactive", and the system,
    /// not this app's own setActive(false), deactivated it. Older systems: an interruption "began".
    nonisolated private static func isInterruption(_ note: Notification) -> Bool {
        if #available(iOS 27.0, *) {
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            return context?.source != .app
        } else {
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            return type == AVAudioSession.InterruptionType.began.rawValue
        }
    }

    private func stopObservingInterruptions() {
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        interruptionObserver = nil
    }
}
