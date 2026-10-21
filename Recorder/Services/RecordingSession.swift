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
            // The Live Activity on the lock screen and in the Dynamic Island (RecordingLiveActivity).
            switch state {
            case .recording(let since): RecordingLiveActivity.start(name: transcriptName, since: since)
            case .finishing: RecordingLiveActivity.saving()
            case .finished, .discarded, .failed: RecordingLiveActivity.end()
            case .idle, .preparing, .downloadingSpeechModel: break
            }
            switch state {
            case .finishing, .finished, .discarded, .failed: calendarFollow?.cancel()   // the offer is settled
            case .idle, .preparing, .downloadingSpeechModel, .recording: break
            }
        }
    }
    private(set) var text = LiveText()                     // what the live screen shows (LiveTranscript)
    private(set) var level: Float = 0                      // microphone level 0...1 for the meter, while recording
    private(set) var downloadProgress: Progress?
    private(set) var locale: Locale?
    /// The name the transcript will be saved with: "New Transcript N" (`defaultName`), or the calendar event's title
    /// once the user taps Use as Title on the recording card (`useCalendarTitle`). The default is fixed when the session
    /// is made (at Record): the recording card shows it in the title's place from its first frame, so it never changes
    /// under the user (not even when transcripts are deleted meanwhile). Not in `start()`: that runs 0.12 s after the
    /// card has begun zooming in (MainView.startDelay), which showed the title field's grey "Title" placeholder until
    /// then. The Live Activity gets it at `.recording` but doesn't show it (RecordingActivityAttributes.name).
    private(set) var transcriptName: String
    /// "New Transcript N": what the transcript is called unless the user takes the calendar event's title; Gemma titles
    /// it after the summary (TranscriptTitler.isDefaultName).
    private let defaultName: String
    /// The calendar event the recording was started in (CalendarContext; nil: none, or Name from Calendar is off): its
    /// title is offered under the date line (`calendarTitleOffer`, never given by itself, FED-11), and its title and
    /// invitees are saved with the transcript.
    private(set) var calendarEvent: CalendarEvent?
    /// Use as Title was tapped on the recording card: the name is the event's title.
    private(set) var calendarTitleTaken = false
    /// The row's ⊗ was tapped: the event's title is not offered again, here or in the saved transcript.
    private(set) var calendarTitleDismissed = false
    /// When Transcribe was pressed: the moment the calendar event is picked for.
    let pressedAt: Date
    /// The calendar cache's read at the press (`CalendarContext.generation`): a later one is picked from again.
    private let pressedCalendarRead: Int
    /// Where the recording started, once PlaceLocator has it (the recording card shows it in the date line).
    private(set) var place: RecordingPlace?
    /// The recorded length (the file's), from Stop on: the duration the transcript will show.
    private(set) var recordedDuration: TimeInterval?
    /// Moments marked while recording (Bookmarks), in seconds from its start; saved with the transcript at Stop.
    private(set) var bookmarks: [TimeInterval] = []

    private let capture: any AudioCapture
    private let transcriber: any Transcriber
    private let modelContext: ModelContext
    private let identifier: SpeakerIdentifier
    private let liveDiarizer: (any LiveDiarizer)?          // nil: live labels off, or the model isn't loaded yet
    private let calendar: CalendarContext?                 // nil: Name from Calendar is off
    private var live = LiveTranscript()                    // words, provisional words, live labels -> `text`
    private var liveTurns = LiveSpeakerTurns()             // the newest snapshot, also after recording (for saving)
    private var liveTask: Task<Void, Never>?
    private var placeTask: Task<RecordingPlace?, Never>?  // where the recording started, looked up in parallel
    private var refresh: Task<Void, Never>?               // re-shows the text when a pending live label comes due
    private var fileName: String?
    private var transcriptionEnded = false                 // Stop saved the words: later transcriber events are dropped
    private var interruptionObserver: (any NSObjectProtocol)?
    private var calendarFollow: Task<Void, Never>?        // followCalendar, until Stop or the end

    init(capture: any AudioCapture, transcriber: any Transcriber, modelContext: ModelContext, identifier: SpeakerIdentifier,
         liveDiarizer: (any LiveDiarizer)? = nil, calendar: CalendarContext? = nil) {
        self.capture = capture
        self.transcriber = transcriber
        self.modelContext = modelContext
        self.identifier = identifier
        self.liveDiarizer = liveDiarizer
        self.calendar = calendar
        let pressedAt = Date.now
        self.pressedAt = pressedAt
        pressedCalendarRead = calendar?.generation ?? 0
        // From the calendar's in-memory cache: no EventKit call in the press. Only offered: the name is the app's own.
        calendarEvent = calendar?.event(at: pressedAt)
        defaultName = Self.defaultName(in: modelContext)
        transcriptName = defaultName
    }

    /// "New Transcript N": one more than the transcripts there are (a synchronous count; a few milliseconds).
    private static func defaultName(in modelContext: ModelContext) -> String {
        let count = (try? modelContext.fetchCount(FetchDescriptor<Recording>())) ?? 0
        return String(localized: "New Transcript \(count + 1)")   // stored: TranscriptTitler.isDefaultName knows both languages
    }

    /// The language to transcribe in: the one chosen in the record accessory, else the phone's (TranscriptionLanguage).
    static var transcriptionLocale: Locale { TranscriptionLanguage.current }

    func start() async {
        guard state == .idle else { return }
        state = .preparing
        if let calendar { calendarFollow = Task { await followCalendar(calendar) } }   // beside it: nothing waits
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed(.microphoneDenied)
            return
        }
        guard state != .discarded else { return }             // cancelled while the permission was asked
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
            // Live labels: capture yields the frames it writes, from file frame 0, at the live model's rate, into this
            // unbounded stream. It buffers until the live diarizer gets it below, once recording has really started, so
            // nothing is lost.
            let liveSamples = liveDiarizer.map { diarizer in
                let (stream, continuation) = AsyncStream<[Float]>.makeStream()
                return (stream: stream, audio: LiveAudio(sampleRate: diarizer.sampleRate, samples: continuation))
            }
            let levels = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let input = try await capture.start(writingTo: AudioFileStore.url(for: fileName), analyzerFormat: setup.audioFormat,
                                                liveSamples: liveSamples?.audio, levels: levels.continuation)
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

    /// The press picked from the cache as it was; a later read may know better (CalendarContext.read(after:)). A cold
    /// launch from outside the app (Control Center, the Action Button, Siri, the widget) presses within about a second
    /// of launching, often before the first read has finished, and so finds no event. A press that resumes a suspended
    /// Feder finds what was read before it was suspended: a meeting cancelled, moved or declined on the Mac meanwhile is
    /// still there until the return's read has ended. Each read that ends while recording replaces the offer under the
    /// date line with what it finds for the press (another event, or none; a read past midnight, which doesn't cover
    /// the press, is skipped), until the user takes or dismisses it (their choice stands) or Stop (cancelled in
    /// `state`'s didSet: the card turns into the transcript, which shows what was saved). Recording doesn't wait for it.
    private func followCalendar(_ calendar: CalendarContext) async {
        calendar.refreshUnlessCovering(pressedAt)
        var seen = pressedCalendarRead
        while !Task.isCancelled, !calendarTitleTaken, !calendarTitleDismissed {
            seen = await calendar.read(after: seen)
            guard !Task.isCancelled, !calendarTitleTaken, !calendarTitleDismissed, calendar.covers(pressedAt)
            else { continue }
            let event = calendar.event(at: pressedAt)
            if event != calendarEvent { calendarEvent = event }
        }
    }

    /// The row under the recording card's date line (CalendarTitleRow): the event's title to take, or ⊗ back to "New
    /// Transcript N" once taken; nil when there is none, it was dismissed, or Name from Calendar is turned off while
    /// recording (`CalendarContext.isOn`): Stop then saves no event, so the transcript would have no row, and a title
    /// taken now would stay with no ⊗ to give the app's name back. A title taken before stays as shown; turned on again
    /// before Stop, the row comes back as it was.
    var calendarTitleOffer: CalendarTitleOffer? {
        guard calendar?.isOn == true else { return nil }
        return CalendarRules.titleOffer(event: calendarEvent?.title, name: transcriptName,
                                        nameBefore: calendarTitleTaken ? defaultName : nil,
                                        dismissed: calendarTitleDismissed, nameIsUserSet: false)
    }

    /// Use as Title on the recording card: the transcript is named after the event at once, and saved so (not marked
    /// as typed: Recording.useCalendarTitle).
    func useCalendarTitle() {
        guard isOngoing, state != .finishing, case .offer(let title) = calendarTitleOffer else { return }
        calendarTitleTaken = true
        transcriptName = title
    }

    /// The row's ⊗ on the recording card: hides the offer for good (the saved transcript doesn't show it either), and
    /// after Use as Title gives the name back ("New Transcript N").
    func dismissCalendarTitle() {
        guard isOngoing, state != .finishing, calendarTitleOffer != nil else { return }
        calendarTitleTaken = false
        transcriptName = defaultName
        calendarTitleDismissed = true
    }

    /// "Cancel" on the preparing / downloading overlays, i.e. before anything was captured. The cover dismisses via
    /// `.discarded`; `start()` re-checks the state after each await and releases whatever it had started. A speech
    /// model download already in flight keeps going in the system, so the next attempt finds the asset installed. The
    /// audio session is let go of at once, not when start() notices (the download can take minutes): until then
    /// nothing could play (AudioSessionUse), and a transcript played meanwhile would be cut off by the late shutdown.
    func cancel() {
        switch state {
        case .idle, .preparing, .downloadingSpeechModel:
            state = .discarded
            let capture = capture
            Task { await capture.shutDown() }
        case .recording, .finishing, .finished, .discarded, .failed: break
        }
    }

    /// Marks this moment (the card's bookmark button, the Live Activity's, or a start from outside while recording:
    /// the Action Button). Measured from `.recording`'s start, as the timer counts (the file starts a few
    /// milliseconds earlier: a bookmark lands that much early, within the word being said). False when not recording,
    /// or when one was set within `Bookmarks.minimumGap`.
    @discardableResult
    func addBookmark() -> Bool {
        guard case .recording(let since) = state,
              let marks = Bookmarks.adding(max(0, Date.now.timeIntervalSince(since)), to: bookmarks) else { return false }
        bookmarks = marks
        RecordingLiveActivity.bookmarked(count: marks.count)
        return true
    }

    /// Stop button, audio interruption, or a mid-session transcriber failure. Saves whatever was transcribed.
    func stop() async { await stop(failure: nil) }

    private func stop(failure: RecorderError?) async {
        guard case .recording(let since) = state, let fileName else { return }
        #if DEBUG
        let stopped = ContinuousClock.now
        #endif
        // Name from Calendar turned off meanwhile: no event is saved (below); the card's row went with the switch
        // (`calendarTitleOffer`), and the transcript has none either.
        if calendar?.isOn != true { calendarEvent = nil }
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
        // The calendar event it was started in: its title (offered as the name, or taken) and invitees' names (the
        // rename sheet offers them, also when the title was dismissed). Not when Name from Calendar was turned off
        // before Stop, as Save Location keeps no place then; the name stays as shown.
        if let calendarEvent {
            recording.calendarEventTitle = calendarEvent.title
            recording.calendarAttendees = calendarEvent.attendees
            recording.calendarTitleDismissed = calendarTitleDismissed
            if calendarTitleTaken { recording.nameBeforeCalendarTitle = defaultName }
        }
        recording.words = words
        #if DEBUG
        // Nemotron's live words are the final ones (FED-196, Settings › About › Live Words Model): no words pass after
        // Stop (Apple or Parakeet) and no Dictation vocabulary pass, since the vocabulary went in as decoder hints.
        // Speakers and the summary run as always. vocabularyPending stays false: only the words pass sets it.
        if transcriber is NemotronLiveTranscriber {
            recording.wordsRefined = true
            print("[Scribe] Nemotron live words: words pass and vocabulary pass skipped")
        }
        #endif
        recording.bookmarks = bookmarks.filter { $0 <= duration }
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

    /// At most one snapshot per model step arrives (0.5 s of audio for LS-EEND, 0.48 s for Sortformer; the diarizer
    /// publishes once per step, bufferingNewest(1) absorbs bursts), so each one re-labels the transcript right away
    /// (incrementally: LiveSpeakers, SteadyLabels).
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
        if changed {
            text = live.text
            RecordingLiveActivity.show(text: text, level: level)
        }
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
                RecordingLiveActivity.show(text: nil, level: level)
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
