import Foundation
import SwiftData
import Observation

/// Owns the work after Stop, one recording at a time (the models are large: Parakeet alone is ~600 MB):
/// 1. the full-accuracy words (FileTranscriber.transcribe: Parakeet, or Apple's recognizer);
/// 2. diarization of the saved file (SpeakerDiarizer: Nemotron, or pyannote until its model is downloaded);
/// 3. final alignment of the words with the turns (TranscriptAligner.finalSegments);
/// 4. each speaker's voice from those final labels (VoiceWindows);
/// 5. recognition of known people (PeopleDirectory), then `.done`: the user sees the speakers.
/// Then, in the background and on its own queue, the vocabulary pass (FileTranscriber.applyVocabulary): its words are
/// aligned with the stored turns again, so speaker numbers, names and links stay; then the automatic title and summary
/// (TranscriptTitler). Re-runs everything still `.pending` / `.processing` / vocabulary-pending / without a summary on
/// launch and when the app returns to the foreground.
/// Two one-time sweeps over older transcripts run behind that work: new voices (`refreshVoices`) and titles and
/// summaries. A stopped recording's own steps always go first (the sweeps wait for at most the transcript they are on),
/// and while a recording is being made (`setRecording`) the sweeps start nothing new.
@MainActor @Observable
final class SpeakerIdentifier {
    /// Version of Recording.speakerVoices: 1 = VoiceWindows + VoiceEmbedder from the final labels (0: the offline
    /// diarizer's centroids, or no voices after the old live fallback). Older voices are recomputed once (refreshVoices).
    nonisolated static let voicesVersion = 1

    private(set) var modelError: RecorderError?      // last prepare() failure (typically: offline on first launch)
    private(set) var inFlight: Set<UUID> = []        // Recording.ids queued or being identified (or getting new voices)
    /// The steps after Stop per transcript in flight (the card's status row); dropped shortly after the last step.
    private(set) var progress: [UUID: PipelineProgress] = [:]
    /// The speaker model is still being prepared (AppServices.prewarmModels: after a new build iOS compiles it for the
    /// Neural Engine again, about 35 s on an iPhone 17): a speakers step waits for it, and the card says so.
    var isPreparingSpeakerModel = false
    /// Words a pass just replaced, per transcript, for a few seconds (the card flashes them).
    private(set) var recentChanges: [UUID: [WordChange]] = [:]
    /// The summary as the model writes it, per transcript, until it is saved.
    private(set) var partialSummaries: [UUID: String] = [:]

    private let diarizer: any SpeakerDiarizer
    private let fileTranscriber: any FileTranscriber
    private let modelContext: ModelContext
    private let people: PeopleDirectory
    private let titler = TranscriptTitler()
    private let betterSummaries: BetterSummaries
    @ObservationIgnored private var queue: Task<Void, Never>?       // the last queued job: identification and voice refreshes
    @ObservationIgnored private var backgroundQueued: Set<UUID> = []
    @ObservationIgnored private var freshPasses: [BackgroundPass] = []   // finished recordings: before the sweep
    @ObservationIgnored private var sweepPasses: [BackgroundPass] = []   // older transcripts' titles, newest first
    @ObservationIgnored private var backgroundWorker: Task<Void, Never>?
    @ObservationIgnored private var isRecording = false
    @ObservationIgnored private var waitingForGemma: [(id: UUID, recording: Recording)] = []   // described when the recording ends
    @ObservationIgnored private var sweepWaiters: [CheckedContinuation<Void, Never>] = []   // sweeps waiting for Stop
    @ObservationIgnored private var migratingVoices = false        // refreshVoices() is running
    @ObservationIgnored private var fingerprintsMigrated = true    // false while it still refreshes people's samples
    @ObservationIgnored private var awaitingRecognition: Set<UUID> = []   // finished meanwhile: recognized after that

    init(diarizer: any SpeakerDiarizer, fileTranscriber: any FileTranscriber, people: PeopleDirectory,
         betterSummaries: BetterSummaries, modelContext: ModelContext) {
        self.diarizer = diarizer
        self.betterSummaries = betterSummaries
        self.fileTranscriber = fileTranscriber
        self.people = people
        self.modelContext = modelContext
    }

    /// RecordingSession: whether a recording is being made (from Record until it is saved or dropped). Meanwhile the
    /// one-time sweeps start nothing new (the transcript in progress is finished), so they never compete with live
    /// transcription; a stopped recording's own work is not held up.
    func setRecording(_ active: Bool) {
        guard active != isRecording else { return }
        isRecording = active
        betterSummaries.isRecording = active             // no Gemma (GPU, ~3.7 GB) while recording: it waits
        if active { Task { await betterSummaries.unload() } }
        #if DEBUG
        print("[Scribe] queue: \(active ? "recording: sweeps pause" : "not recording: sweeps resume")")
        #endif
        guard !active else { return }
        // Transcripts whose Gemma description waited for the recording to end (or were stopped by it)
        // go again first.
        let waiting = waitingForGemma
        waitingForGemma = []
        for entry in waiting where !isGone(entry.recording) {
            enqueueBackgroundPass(entry.recording, fresh: true)
        }
        let waiters = sweepWaiters
        sweepWaiters = []
        for waiter in waiters { waiter.resume() }
        startBackgroundWorker()
    }

    /// RecorderApp calls this at launch and on every scenePhase == .active; returns once the queue is empty.
    func prepareAndRetryPending() async {
        let done = SpeakerStatus.done.rawValue
        let unfinished = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.speakerStatusRaw == done && $0.vocabularyPending == true },
            sortBy: [SortDescriptor(\.createdAt)])
        for recording in (try? modelContext.fetch(unfinished)) ?? [] {     // a kill or the background interrupted it
            enqueueBackgroundPass(recording, fresh: true)
        }
        if betterSummaries.activeModel != nil {                       // also the sweep of older ones, newest first
            let version = summaryVersion
            let undescribed = FetchDescriptor<Recording>(
                predicate: #Predicate { $0.speakerStatusRaw == done && $0.summaryVersion < version },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            for recording in (try? modelContext.fetch(undescribed)) ?? [] {
                enqueueBackgroundPass(recording, fresh: false)
            }
        }

        let pending = SpeakerStatus.pending.rawValue
        let processing = SpeakerStatus.processing.rawValue
        guard await prepareModel() else {
            // Crash recovery while the model can't be prepared: rows a killed app left `.processing` go back to
            // `.pending`, so the detail view shows the download note + Try Again instead of an endless spinner.
            let orphaned = FetchDescriptor<Recording>(predicate: #Predicate { $0.speakerStatusRaw == processing })
            for recording in (try? modelContext.fetch(orphaned)) ?? [] where !inFlight.contains(recording.id) {
                recording.speakerStatus = .pending
            }
            try? modelContext.save()
            return
        }
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.speakerStatusRaw == pending || $0.speakerStatusRaw == processing },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        for recording in (try? modelContext.fetch(descriptor)) ?? [] where !isGone(recording) { enqueue(recording) }
        await queue?.value
    }

    /// Used right after a recording is saved, by "Try Again" in the detail view and by the launch sweep.
    func enqueue(_ recording: Recording) {
        guard !inFlight.contains(recording.id) else { return }
        let wordsToCome = !recording.wordsRefined
        progress[recording.id] = nil                   // a re-run (Try Again, Speakers: n) starts from a clean row
        track(recording.id) { progress in              // what the card will show while the recording is queued
            if wordsToCome { progress.expect(.words) }
            progress.expect(.speakers)
            if wordsToCome || recording.vocabularyPending { progress.expect(.vocabulary) }
            if canDescribe { progress.expect(.summary) }
        }
        enqueueJob(for: recording) { await self.identify(recording) }
    }

    /// Gemma, which writes titles and summaries, is there.
    private var canDescribe: Bool { betterSummaries.activeModel != nil }

    /// Shows the words a pass replaced for a few seconds.
    private func flash(_ changes: [WordChange], in id: UUID) {
        guard !changes.isEmpty else { return }
        recentChanges[id] = changes
        Task {
            try? await Task.sleep(for: .seconds(6))
            if recentChanges[id] == changes { recentChanges[id] = nil }
        }
    }

    /// Records a step of `id`'s pipeline; once every listed step has ended, the record goes after a moment (the
    /// row shows the last checkmark, then disappears).
    private func track(_ id: UUID, _ change: (inout PipelineProgress) -> Void) {
        var record = progress[id] ?? PipelineProgress()
        change(&record)
        // Nothing listed (a sweep found nothing to do): no record, so no empty row.
        progress[id] = record.steps.isEmpty ? nil : record
        guard record.isComplete else { return }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if progress[id]?.isComplete == true { progress[id] = nil }
        }
    }

    /// The detail menu's "Speakers" choice: stores it, resets the speaker names (indices change), and re-runs
    /// diarization with exactly that many speakers (`nil` = automatic again). The transcript's words are kept.
    func setSpeakerCount(_ count: Int?, for recording: Recording) {
        guard !isGone(recording), !inFlight.contains(recording.id) else { return }
        recording.speakerCountOverride = count
        people.resetSpeakers(of: recording)                   // speaker numbers change: links and samples go
        recording.speakerNames = [:]
        recording.speakerStatus = .pending
        try? modelContext.save()
        enqueue(recording)
    }

    /// One-time migration at launch (after prepareAndRetryPending): finished transcripts whose voices predate
    /// `voicesVersion` get voices from the labels they show, their people's samples are replaced (PeopleDirectory
    /// .replaceVoices), and recognition runs again everywhere. A transcript that fails keeps its old voices until the
    /// next launch. One transcript at a time, behind every recording stopped meanwhile and never while recording; the
    /// transcripts people's fingerprints come from go first, and a recording finished before they are done is recognized
    /// right after them, with the new fingerprints (calibration: people enrolled in older transcripts named correctly in
    /// 94 % of new ones with migrated samples, 79 % with the old ones).
    func refreshVoices() async {
        guard !migratingVoices, PeopleDirectory.isRecognitionEnabled else { return }   // running, or recognition off
        migratingVoices = true
        defer { migratingVoices = false }
        let done = SpeakerStatus.done.rawValue
        let current = Self.voicesVersion
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.speakerStatusRaw == done && $0.voicesVersion < current },
            sortBy: [SortDescriptor(\.createdAt)])
        let stale = (try? modelContext.fetch(descriptor)) ?? []
        guard !stale.isEmpty, await prepareModel() else { return }
        let sources = people.fingerprintSources()
        let first = stale.filter { !isGone($0) && sources.contains($0.id) }
        let rest = stale.filter { !isGone($0) && !sources.contains($0.id) }
        fingerprintsMigrated = first.isEmpty
        for recording in first { await migrateVoices(of: recording) }
        if !fingerprintsMigrated {
            fingerprintsMigrated = true
            recognizeAwaiting()
        }
        for recording in rest { await migrateVoices(of: recording) }
        people.recognizeEverywhere()
    }

    // MARK: Jobs

    /// Runs `job` after every job queued before it. A recording is queued at most once at a time.
    private func enqueueJob(for recording: Recording, _ job: @escaping @MainActor () async -> Void) {
        let id = recording.id
        guard inFlight.insert(id).inserted else { return }
        let previous = queue
        queue = Task {
            await previous?.value
            await job()
            inFlight.remove(id)
        }
    }

    /// One transcript of the voice migration, queued once no recording is being made and every job queued before has
    /// finished (a recording stopped meanwhile goes first).
    private func migrateVoices(of recording: Recording) async {
        await sweepTurn()
        guard !isGone(recording) else { return }
        #if DEBUG
        print("[Scribe] queue: voice migration \(recording.id.uuidString.prefix(8))")
        #endif
        enqueueJob(for: recording) { await self.refreshVoices(of: recording) }
        await queue?.value
    }

    /// Returns once no recording is being made and the queue has run everything queued so far.
    private func sweepTurn() async {
        while true {
            if isRecording {
                await withCheckedContinuation { sweepWaiters.append($0) }
                continue
            }
            guard let tail = queue else { return }
            await tail.value
            if queue == tail, !isRecording { return }        // nothing queued meanwhile
        }
    }

    /// The transcripts whose recognition waited for the migrated fingerprints.
    private func recognizeAwaiting() {
        let ids = awaitingRecognition
        awaitingRecognition = []
        guard !ids.isEmpty else { return }
        let done = SpeakerStatus.done.rawValue
        let finished = FetchDescriptor<Recording>(predicate: #Predicate { $0.speakerStatusRaw == done })
        for recording in (try? modelContext.fetch(finished)) ?? [] where ids.contains(recording.id) {
            #if DEBUG
            print("[Scribe] queue: recognition with the migrated fingerprints \(recording.id.uuidString.prefix(8))")
            #endif
            people.recognize(recording)
        }
    }

    private func identify(_ recording: Recording) async {
        guard !isGone(recording) else { return }
        let id = recording.id
        guard recording.speakerStatus != .done else { progress[id] = nil; return }
        #if DEBUG
        print("[Scribe] queue: identify \(id.uuidString.prefix(8))")
        #endif
        // Read every attribute before the first suspension: a deleted+saved model is detached from its context and
        // resolving an attribute fault on it traps.
        let url = recording.audioURL
        let override = recording.speakerCountOverride
        let liveTurns = TranscriptAligner.turns(from: recording.segments)    // the live labels until speakers are final
        let needsWords = !recording.wordsRefined
        let locale = Locale(identifier: recording.localeIdentifier)
        recording.speakerStatus = .processing

        // 1. The full-accuracy words. They replace the live ones right away (with the live labels re-applied); if the
        // pass fails or finds nothing, the live words stay. Either way it runs once per recording, and the vocabulary
        // pass is due once speakers are done.
        if needsWords {
            track(id) { $0.begin(.words) }
            let transcript = try? await fileTranscriber.transcribe(fileURL: url, locale: locale)
            guard !isGone(recording) else { progress[id] = nil; return }
            if let transcript, !transcript.words.isEmpty {
                let changes = WordChange.changes(from: recording.words, to: transcript.words, vocabulary: false)
                recording.words = transcript.words
                recording.alignmentOffset = transcript.alignmentOffset
                recording.segments = TranscriptAligner.keepingIDsByOverlap(   // the same rows, new words: nothing flies in
                    of: recording.segments, in: TranscriptAligner.segments(words: transcript.words, turns: liveTurns))
                flash(changes, in: id)
            }
            recording.wordsRefined = true
            recording.vocabularyPending = true
            try? modelContext.save()
            track(id) { $0.finish(.words, failed: transcript == nil) }   // threw; "nothing better" is still done
        }

        // 2. Diarization of the same file. DEBUG: the parts of the speakers step, since "Speakers · 36 s" on an iPhone
        // says nothing about which of them it was (the first-run model compile, the turns, or the voices).
        track(id) { $0.begin(.speakers) }
        let speakersStarted = ContinuousClock.now
        let ready = await prepareModel()
        #if DEBUG
        print("[Scribe] queue: speakers \(id.uuidString.prefix(8)): model ready after \(Self.ms(since: speakersStarted))")
        #endif
        guard !isGone(recording) else { progress[id] = nil; return }
        guard ready else {
            recording.speakerStatus = .pending                // retried by the next prepareAndRetryPending()
            try? modelContext.save()
            progress[id] = nil                                // the row shows the download note instead
            return
        }
        do {
            let diarization = try await diarizer.diarization(fileURL: url,
                                                             speakers: override.map { .exactly($0) } ?? .automatic)
            #if DEBUG
            print("[Scribe] queue: speakers \(id.uuidString.prefix(8)): turns after \(Self.ms(since: speakersStarted))")
            #endif
            guard !isGone(recording) else { progress[id] = nil; return }
            // 3. + 4. The final labels, and each speaker's voice from them.
            let words = recording.words
            let labels = TranscriptAligner.finalSpeakers(words: words, turns: diarization.turns,
                                                         offset: recording.alignmentOffset)
            // Recognition off (Settings › People): no voice is computed or kept, and nobody is recognized.
            let recognizes = PeopleDirectory.isRecognitionEnabled
            let voices = recognizes
                ? try? await diarizer.voices(fileURL: url, windows: VoiceWindows.windows(words: words, speakers: labels))
                : nil
            #if DEBUG
            print("[Scribe] queue: speakers \(id.uuidString.prefix(8)): voices after \(Self.ms(since: speakersStarted))")
            #endif
            guard !isGone(recording) else { progress[id] = nil; return }
            recording.speakerTurns = diarization.turns
            recording.diarizer = diarization.diarizer            // pyannote's speakers are recognized more strictly
            recording.segments = Self.finalSegments(of: recording, keepingIDsOf: recording.segments)   // current words
            recording.speakerVoices = (voices ?? [:]).mapValues(\.embedding)
            // Failed: refreshVoices retries. Off: current, so turning recognition on later computes nothing for it.
            recording.voicesVersion = voices == nil && recognizes ? 0 : Self.voicesVersion
            recording.speakerStatus = .done
            // 5. Known voices get their names, once the voice migration has refreshed people's samples.
            if recognizes {
                if fingerprintsMigrated { people.recognize(recording, save: false) } else { awaitingRecognition.insert(id) }
            }
            track(id) { $0.finish(.speakers) }
        } catch {
            guard !isGone(recording) else { progress[id] = nil; return }
            recording.speakerStatus = .failed
            progress[id] = nil                                // the row shows the failure instead
        }
        try? modelContext.save()
        if recording.speakerStatus == .done,
           recording.vocabularyPending || recording.summaryVersion < summaryVersion {
            enqueueBackgroundPass(recording, fresh: true)
        } else if recording.speakerStatus == .done {
            track(id) { $0.drop(.vocabulary); $0.drop(.summary) }
        }
    }

    /// Voices from the labels the transcript shows (older transcripts have no stored turns: their segments are the
    /// labels; no smoothing, so every word keeps the speaker it is shown with).
    private func refreshVoices(of recording: Recording) async {
        guard !isGone(recording), recording.speakerStatus == .done, recording.voicesVersion < Self.voicesVersion else {
            return
        }
        let url = recording.audioURL
        let words = recording.words
        let labels = TranscriptAligner.speakers(words: words, turns: TranscriptAligner.turns(from: recording.segments),
                                                smoothing: false)
        guard let voices = try? await diarizer.voices(fileURL: url, windows: VoiceWindows.windows(words: words, speakers: labels)),
              !isGone(recording), recording.speakerStatus == .done else { return }
        people.replaceVoices(of: recording, with: voices.mapValues(\.embedding))
        recording.voicesVersion = Self.voicesVersion
        try? modelContext.save()
    }

    // MARK: Background pass: vocabulary, then title and summary (after speakers are done, never holding them up)

    private struct BackgroundPass {
        let id: UUID                                      // read when queued: a deleted (detached) model traps later
        let recording: Recording
    }

    /// One worker, one pass at a time. `fresh` (a recording that was just identified, or whose vocabulary pass a kill
    /// interrupted) goes before the sweep of older transcripts, which waits while a recording is being made.
    private func enqueueBackgroundPass(_ recording: Recording, fresh: Bool) {
        let id = recording.id
        if !backgroundQueued.insert(id).inserted {
            // Already queued: only a sweep entry moves up ("Speakers: n" on an older transcript still waiting).
            guard fresh, let index = sweepPasses.firstIndex(where: { $0.id == id }) else { return }
            sweepPasses.remove(at: index)
        }
        let pass = BackgroundPass(id: id, recording: recording)
        if fresh { freshPasses.append(pass) } else { sweepPasses.append(pass) }
        startBackgroundWorker()
    }

    private func startBackgroundWorker() {
        guard backgroundWorker == nil else { return }
        backgroundWorker = Task {
            while let pass = nextBackgroundPass() {
                await applyVocabulary(to: pass.recording)
                await describe(pass.recording)                // from the final words
                backgroundQueued.remove(pass.id)
            }
            backgroundWorker = nil                            // no suspension since the check: no pass can be missed
        }
    }

    private func nextBackgroundPass() -> BackgroundPass? {
        if !freshPasses.isEmpty {
            #if DEBUG
            print("[Scribe] queue: background pass (new) \(freshPasses[0].id.uuidString.prefix(8))")
            #endif
            return freshPasses.removeFirst()
        }
        guard !isRecording, !sweepPasses.isEmpty else { return nil }
        #if DEBUG
        print("[Scribe] queue: background pass (sweep) \(sweepPasses[0].id.uuidString.prefix(8))")
        #endif
        return sweepPasses.removeFirst()
    }

    /// The words get the vocabulary terms and are aligned with the stored turns again: speaker numbers stay, so names,
    /// links and voices stay valid. If something else replaced the words meanwhile, the result is dropped.
    #if DEBUG
    private static func ms(since start: ContinuousClock.Instant) -> String {
        (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
    }
    #endif

    private func applyVocabulary(to recording: Recording) async {
        guard !isGone(recording) else { return }
        let id = recording.id
        guard recording.vocabularyPending else { track(id) { $0.drop(.vocabulary) }; return }
        track(id) { $0.begin(.vocabulary) }
        let words = recording.words
        let improved = await fileTranscriber.applyVocabulary(to: words, fileURL: recording.audioURL,
                                                             locale: Locale(identifier: recording.localeIdentifier))
        guard !isGone(recording) else { progress[id] = nil; return }
        if improved != words, recording.words == words {
            recording.words = improved
            recording.segments = Self.finalSegments(of: recording, keepingIDsOf: recording.segments)
            flash(WordChange.changes(from: words, to: improved, vocabulary: true), in: id)
        }
        recording.vocabularyPending = false
        try? modelContext.save()
        track(id) { $0.finish(.vocabulary) }
    }

    /// The summary, and the title while the transcript still has a name the app gave it ("New Transcript 3") and the
    /// user never edited it. Once per transcript (`summaryVersion`), by Gemma only; without it (not downloaded, off,
    /// an iPhone too small for it) nothing changes, and when Gemma can't answer right now (the app left the foreground)
    /// the next return to the foreground tries again.
    private func describe(_ recording: Recording) async {
        let target = summaryVersion
        guard !isGone(recording) else { return }
        let id = recording.id
        guard recording.speakerStatus == .done, recording.summaryVersion < target else {
            track(id) { $0.drop(.summary) }
            return
        }
        track(id) { $0.begin(.summary) }
        defer {
            partialSummaries[id] = nil
            if case .running = progress[id]?.state(of: .summary) {   // not now: waiting for Stop, or given up
                let waits = waitingForGemma.contains { $0.id == id }
                track(id) { waits ? $0.expect(.summary, again: true) : $0.drop(.summary) }
            }
        }
        // Each piece hops to the main actor; one arriving after the summary was saved (or given up) is dropped.
        let partial: @Sendable (String) -> Void = { text in
            Task { @MainActor in
                guard case .running = self.progress[id]?.state(of: .summary) else { return }
                self.partialSummaries[id] = text.isEmpty ? nil : text   // "": a new attempt, the shimmer again
            }
        }
        let locale = Locale(identifier: recording.localeIdentifier)
        let paragraphs = recording.segments.map { segment in
            TranscriptTitler.paragraph(segment.text, speaker: segment.speakerIndex.map(recording.speakerName))
        }
        guard betterSummaries.activeModel != nil else { return }      // only Gemma writes them (TranscriptTitler)
        guard !isRecording else {                                   // Gemma never runs while recording: after Stop
            waitForGemma(recording, id: id)
            return
        }
        let description: TranscriptTitler.Description?
        let version = TranscriptTitler.localVersion
        do {
            let titler = titler
            description = try await betterSummaries.run { model in
                try await titler.describe(paragraphs: paragraphs, locale: locale, writer: model, partial: partial)
            }
        } catch {
            // RetryLater: not marked described, tried again later; stopped because a recording started: again right
            // after it. LocalModelFailed (damaged files): BetterSummaries offers the download again, and the transcript
            // is described once Gemma is back.
            if isRecording, !isGone(recording) { waitForGemma(recording, id: id) }
            return
        }
        guard !isGone(recording) else { return }
        if let description {
            recording.summary = description.summary
            // Checked after the wait: the user may have renamed it meanwhile. A name the app gave, or the title a model
            // gave it before (a better model's title replaces it), never one the user typed.
            if let title = description.title, !recording.nameIsUserSet,
               TranscriptTitler.isDefaultName(recording.name) || recording.name == recording.automaticTitle {
                recording.name = title
                recording.automaticTitle = title
            }
        }
        recording.summaryVersion = max(recording.summaryVersion, version)
        try? modelContext.save()
        track(id) { $0.finish(.summary) }
    }

    /// Gemma can't run while a recording is made: described right after Stop (setRecording). Ids, not
    /// models, are compared: a transcript deleted meanwhile is detached, and reading it traps.
    private func waitForGemma(_ recording: Recording, id: UUID) {
        if !waitingForGemma.contains(where: { $0.id == id }) { waitingForGemma.append((id, recording)) }
    }

    /// The summaryVersion transcripts should have: Gemma's. (Transcripts Apple's model described are at
    /// `TranscriptTitler.version` and get Gemma's once it is there.)
    private var summaryVersion: Int { TranscriptTitler.localVersion }

    // MARK: Helpers

    private static func finalSegments(of recording: Recording,
                                      keepingIDsOf previous: [TranscriptSegment] = []) -> [TranscriptSegment] {
        TranscriptAligner.finalSegments(words: recording.words, turns: recording.speakerTurns,
                                        offset: recording.alignmentOffset, keepingIDsOf: previous)
    }

    /// `isDeleted` covers an unsaved delete; after `modelContext.save()` the model is detached and `isDeleted` is false
    /// again, but `modelContext` is nil. Reading attributes of a detached model traps, so callers must not touch one.
    private func isGone(_ recording: Recording) -> Bool {
        recording.isDeleted || recording.modelContext == nil
    }

    private func prepareModel() async -> Bool {
        // Nothing downloads before the Welcome page has said what and how much (App Review 4.2.3(ii)), also when a
        // new user records before it appeared: the transcript stays pending and is identified after its Continue.
        guard AppServices.modelDownloadsAllowed else { return false }
        do {
            try await diarizer.prepare()
            if modelError != nil { modelError = nil }      // only a change is published: the open card re-renders on it
            return true
        } catch {
            modelError = error as? RecorderError ?? .diarizationFailed(error.localizedDescription)
            return false
        }
    }
}
