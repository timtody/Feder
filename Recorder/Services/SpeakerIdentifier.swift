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
/// (TranscriptTitler) and the action items (ActionItemExtractor). Re-runs everything still `.pending` / `.processing` /
/// vocabulary-pending / without a summary or action items on launch and when the app returns to the foreground.
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

    private let diarizer: any SpeakerDiarizer
    private let fileTranscriber: any FileTranscriber
    private let modelContext: ModelContext
    private let people: PeopleDirectory
    private let titler = TranscriptTitler()
    private let actionItemExtractor = ActionItemExtractor()
    private let betterSummaries: BetterSummaries
    @ObservationIgnored private var queue: Task<Void, Never>?       // the last queued job: identification and voice refreshes
    @ObservationIgnored private var backgroundQueued: Set<UUID> = []
    @ObservationIgnored private var freshPasses: [BackgroundPass] = []   // finished recordings: before the sweep
    @ObservationIgnored private var sweepPasses: [BackgroundPass] = []   // older transcripts' titles, newest first
    @ObservationIgnored private var backgroundWorker: Task<Void, Never>?
    /// A recording is being made (RecordingSession): the card's player is off meanwhile.
    private(set) var isRecording = false
    /// Transcripts whose vocabulary pass is running right now (corrections wait: canCorrectSpeakers).
    private(set) var vocabularyRunning: Set<UUID> = []
    /// Transcripts in Edit Text right now: their vocabulary pass waits until Done or Cancel (it would write the words
    /// under the drafts, and Done would then be refused or put the old spellings back).
    private(set) var editingText: Set<UUID> = []
    /// Passes asked for again while they were running (an Undo, the end of Edit Text): queued once more after it.
    @ObservationIgnored private var passAgain: Set<UUID> = []
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
        // Names, links or voices changed outside a correction (a rename, recognition, a person or the voice profiles
        // deleted): Undo of a correction there would throw that change away, so it goes.
        people.onTranscriptsChanged = { [weak self] ids in self?.invalidateCorrection(of: ids) }
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
            let actions = ActionItemExtractor.version                  // and their action items (a version of their own)
            let undescribed = FetchDescriptor<Recording>(
                predicate: #Predicate {
                    $0.speakerStatusRaw == done && ($0.summaryVersion < version || $0.actionItemsVersion < actions)
                },
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
            // Only when they will be looked for: listed, the card holds their place, and a re-run ("Speakers: n") of a
            // transcript whose items are current left a blank row (ActionItemsSlot).
            if canDescribe, recording.actionItemsVersion < ActionItemExtractor.version { progress.expect(.actions) }
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
        if lastCorrection?.recordingID == recording.id { lastCorrection = nil }   // its speakers are about to change
        people.resetSpeakers(of: recording)                   // speaker numbers change: links and samples go
        recording.speakerNames = [:]
        recording.speakerStatus = .pending
        try? modelContext.save()
        enqueue(recording)
    }

    // MARK: Hand corrections (SpeakerCorrection)

    /// Whether the speakers of `recording` can be corrected by hand now: final, nothing running on it, and its
    /// vocabulary pass not running (it writes the words when it ends, which a correction made meanwhile would lose or
    /// undo).
    func canCorrectSpeakers(of recording: Recording) -> Bool {
        !isGone(recording) && recording.speakerStatus == .done && !inFlight.contains(recording.id)
            && !vocabularyRunning.contains(recording.id)
    }

    /// The last hand correction (any transcript), which Undo takes back: one level, replaced by the next correction and
    /// dropped as soon as the transcript changes in another way (a rename, the vocabulary pass, recognition, a person
    /// deleted, voice profiles deleted, "Speakers: n"): undoing then would throw that change away too.
    struct UndoableCorrection: Identifiable {
        enum Kind { case assign, merge, edit }
        let id = UUID()
        let recordingID: UUID
        let kind: Kind
        fileprivate let before: CorrectionSnapshot
        /// The transcript right after the correction: Undo only puts `before` back while it is still this.
        fileprivate let after: CorrectionState
    }
    private(set) var lastCorrection: UndoableCorrection?

    /// What a correction changes in a transcript, and in the people (their samples from it).
    fileprivate struct CorrectionSnapshot {
        var state: CorrectionState
        var speakerVoices: [Int: [Float]]
        var voicesVersion: Int
        var vocabularyPending: Bool
        var people: PeopleDirectory.Snapshot
    }

    /// The parts of a transcript a correction or anything else can change, compared for Undo.
    fileprivate struct CorrectionState: Equatable {
        var words: [TranscriptWord]
        var segments: [TranscriptSegment]
        var speakerTurns: [SpeakerTurn]
        var speakerNames: [Int: String]
        var speakerPeople: [Int: UUID]

        @MainActor init(_ recording: Recording) {
            words = recording.words
            segments = recording.segments
            speakerTurns = recording.speakerTurns
            speakerNames = recording.speakerNames
            speakerPeople = recording.speakerPeople
        }
    }

    private func snapshot(of recording: Recording) -> CorrectionSnapshot {
        CorrectionSnapshot(state: CorrectionState(recording), speakerVoices: recording.speakerVoices,
                           voicesVersion: recording.voicesVersion, vocabularyPending: recording.vocabularyPending,
                           people: people.snapshot(of: recording))
    }

    private func record(_ kind: UndoableCorrection.Kind, before: CorrectionSnapshot, in recording: Recording) {
        lastCorrection = UndoableCorrection(recordingID: recording.id, kind: kind, before: before,
                                            after: CorrectionState(recording))
    }

    /// Something other than a correction changed these transcripts (nil: all of them): their Undo goes.
    func invalidateCorrection(of ids: Set<UUID>?) {
        guard let correction = lastCorrection, ids?.contains(correction.recordingID) ?? true else { return }
        lastCorrection = nil
    }

    /// Takes the last correction back, if it was `recording`'s and the transcript is still as the correction left it:
    /// words, paragraphs, turns, names, links, and (with recognition on) voices and the people's samples from it as
    /// they were; a vocabulary pass that was still due is queued again. A voice job still running for the correction
    /// drops its result (refreshVoices(of:) compares `editCount`). Returns whether it undid anything.
    @discardableResult
    func undoLastCorrection(of recording: Recording) -> Bool {
        // Not while its vocabulary pass runs: the pass would drop its result over the restored words, and the transcript
        // would miss its Your Words terms (the Undo stays: it works once the pass is over, or goes if it wrote words).
        guard let undo = lastCorrection, undo.recordingID == recording.id, !isGone(recording),
              recording.speakerStatus == .done, !vocabularyRunning.contains(recording.id) else { return false }
        lastCorrection = nil
        guard CorrectionState(recording) == undo.after else { return false }   // changed since: undoing would lose it
        let before = undo.before
        recording.words = before.state.words
        recording.segments = before.state.segments
        recording.speakerTurns = before.state.speakerTurns
        recording.speakerNames = before.state.speakerNames
        recording.speakerPeople = before.state.speakerPeople
        // Voices only while recognition is on: turned off meanwhile, the profiles were deleted on purpose.
        let recognizes = PeopleDirectory.isRecognitionEnabled
        recording.speakerVoices = recognizes ? before.speakerVoices : [:]
        recording.voicesVersion = before.voicesVersion
        recording.speakerPeople = people.restore(before.people, of: recording, withSamples: recognizes)
        recording.vocabularyPending = before.vocabularyPending
        recording.editCount += 1                              // search and Spotlight read it again
        try? modelContext.save()
        if before.vocabularyPending { enqueueBackgroundPass(recording, fresh: true) }
        return true
    }

    /// Edit Text started on `recording` (RecordingDetailView): its vocabulary pass waits.
    func beginEditingText(_ recording: Recording) {
        editingText.insert(recording.id)
    }

    /// Edit Text ended (Done, Cancel, the card closed): a vocabulary pass that waited goes now.
    func endEditingText(_ recording: Recording) {
        guard editingText.remove(recording.id) != nil, !isGone(recording), recording.vocabularyPending,
              recording.speakerStatus == .done else { return }
        enqueueBackgroundPass(recording, fresh: true)
    }

    /// The index a new speaker gets: past every speaker the transcript knows (paragraphs, turns, names, links).
    private func nextSpeakerIndex(of recording: Recording) -> Int {
        let used = recording.segments.compactMap(\.speakerIndex) + recording.speakerTurns.map(\.speakerIndex)
            + Array(recording.speakerNames.keys) + Array(recording.speakerPeople.keys)
        return (used.max() ?? -1) + 1
    }

    /// The paragraphs `segments` (one stretch of the transcript) go to `speaker`, or to a new speaker (nil): the name
    /// row's "Assign This Part To".
    func assign(_ segments: [TranscriptSegment], to speaker: Int?, in recording: Recording) {
        guard canCorrectSpeakers(of: recording), let first = segments.first, let last = segments.last else { return }
        let before = snapshot(of: recording)
        let target = speaker ?? nextSpeakerIndex(of: recording)
        correct(recording, words: nil, stretches: [(first.start, last.end, target)])
        record(.assign, before: before, in: recording)
    }

    /// Everything `from` said becomes `into`'s: the name row's "Merge Into". `into` keeps its name; an unnamed `into`
    /// takes `from`'s name and person.
    func merge(_ from: Int, into: Int, in recording: Recording) {
        guard canCorrectSpeakers(of: recording), from != into else { return }
        let before = snapshot(of: recording)
        if recording.speakerNames[into] == nil, let name = recording.speakerNames[from] {
            recording.speakerNames[into] = name
            recording.speakerPeople[into] = recording.speakerPeople[from]
            // The person's voice sample from this transcript goes along: the compaction drops `from`'s, and the voice
            // job only gives a linked speaker a sample when it had no voice (`into` has one), so a person named once
            // lost their only sample and was never recognized again.
            people.moveSamples(of: recording, from: from, to: into)
        }
        recording.speakerTurns = SpeakerCorrection.merging(recording.correctableTurns, from, into: into)
        recording.realignSegments()
        finishCorrection(of: recording, speakersMoved: true)
        record(.merge, before: before, in: recording)
    }

    /// Edit Text's Done: the paragraphs' new text into the words, and the paragraphs whose speaker chip changed to
    /// their new speakers (`speakers`: segment id → speaker index; an index past the transcript's speakers is a new
    /// one, the same index for several paragraphs the same new speaker). One correction for Undo. Each choice and each
    /// edited paragraph is a stretch of time taken from the paragraphs as they were when editing started, so the
    /// re-folding of the edited text can't move a choice to another paragraph or drop it; an edited paragraph keeps
    /// all its words with its (chosen) speaker. Returns the words typed in place of others (for Your Words) and
    /// whether anything changed.
    func applyEdits(text: [UUID: String], speakers: [UUID: Int], in recording: Recording)
        -> (replacements: [String], changed: Bool) {
        guard canCorrectSpeakers(of: recording) else { return ([], false) }
        let segments = recording.segments
        let ranges = recording.wordRanges()
        var words = recording.words
        var replacements: [String] = []
        var stretches: [(start: TimeInterval, end: TimeInterval, speaker: Int)] = []
        let newIndex = nextSpeakerIndex(of: recording)
        // New speakers from the chips: their indices past the known speakers, in the order the chips chose them.
        let added = Set(speakers.values).subtracting(Set(segments.compactMap(\.speakerIndex))).sorted()
        let renumbered = Dictionary(uniqueKeysWithValues: added.enumerated().map { ($1, newIndex + $0) })
        // From the end, so the earlier ranges stay valid while later ones change length.
        for segment in segments.reversed() {
            let chosen = speakers[segment.id].map { renumbered[$0] ?? $0 }
            let target = chosen ?? segment.speakerIndex
            if let draft = text[segment.id], draft != segment.text, let range = ranges[segment.id] {
                let result = TextCorrection.words(Array(words[range]), editedTo: draft, start: segment.start, end: segment.end)
                words.replaceSubrange(range, with: result.words)
                replacements = result.replacements + replacements
                if let target, let first = result.words.first, let last = result.words.last {
                    stretches.append((first.start, last.end, target))
                }
            } else if let chosen, chosen != segment.speakerIndex {
                stretches.append((segment.start, segment.end, chosen))
            }
        }
        let moved = segments.contains { segment in
            speakers[segment.id].map { renumbered[$0] ?? $0 } .map { $0 != segment.speakerIndex } ?? false
        }
        guard words != recording.words || moved else { return (replacements, false) }
        let before = snapshot(of: recording)
        correct(recording, words: words, stretches: stretches)
        record(.edit, before: before, in: recording)
        return (replacements, true)
    }

    /// New words (nil: the same) and stretches of time given to speakers: the turns are cut for each stretch
    /// (SpeakerCorrection.assigning, in turn time), and a word outside the stretches keeps the speaker it had (a short
    /// turn pins it where the cut would otherwise move it, e.g. a word in a pause whose nearest turn is now a sliver of
    /// the cut turn).
    private func correct(_ recording: Recording, words newWords: [TranscriptWord]?,
                         stretches: [(start: TimeInterval, end: TimeInterval, speaker: Int)]) {
        let offset = recording.alignmentOffset
        let oldWords = recording.words
        let oldTurns = recording.correctableTurns
        let oldLabels = TranscriptAligner.finalSpeakers(words: oldWords, turns: oldTurns, offset: offset)
        var labelOf: [TranscriptWord: Int] = [:]
        for (word, label) in zip(oldWords, oldLabels) { if let label { labelOf[word] = label } }
        var turns = oldTurns
        for stretch in stretches {
            turns = SpeakerCorrection.assigning(turns, start: stretch.start - offset, end: stretch.end - offset,
                                                to: stretch.speaker)
        }
        let words = newWords ?? oldWords
        let newLabels = TranscriptAligner.finalSpeakers(words: words, turns: turns, offset: offset)
        var pins: [SpeakerTurn] = []
        for (word, label) in zip(words, newLabels) {
            guard let old = labelOf[word], old != label,
                  !stretches.contains(where: { word.end > $0.start && word.start < $0.end || word.start == $0.start })
            else { continue }
            pins.append(SpeakerTurn(speakerIndex: old, start: word.start - offset,
                                    end: max(word.end, word.start + 0.01) - offset))
        }
        recording.words = words
        recording.speakerTurns = (turns + pins).sorted { $0.start < $1.start }
        recording.realignSegments()
        finishCorrection(of: recording, speakersMoved: !stretches.isEmpty)
    }

    /// After a correction: the speaker numbers close their gaps (names, people, voices and voice samples follow), the
    /// transcript is saved, and with speakers moved and recognition on the voices are computed again from the
    /// corrected labels (they are what naming a speaker stores as a sample).
    private func finishCorrection(of recording: Recording, speakersMoved: Bool) {
        let turns = recording.speakerTurns
        let mapping = SpeakerCorrection.compaction(used: Set(recording.segments.compactMap(\.speakerIndex)))
        let known = Set(turns.map(\.speakerIndex)).union(recording.speakerNames.keys).union(recording.speakerPeople.keys)
        if mapping.contains(where: { $0.key != $0.value }) || known.count != mapping.count {
            recording.speakerTurns = turns.compactMap { turn in
                mapping[turn.speakerIndex].map { SpeakerTurn(speakerIndex: $0, start: turn.start, end: turn.end) }
            }
            recording.segments = recording.segments.map { segment in
                var segment = segment
                segment.speakerIndex = segment.speakerIndex.flatMap { mapping[$0] }
                return segment
            }
            people.renumberSpeakers(of: recording, mapping)
        }
        recording.editCount += 1
        let recognizes = PeopleDirectory.isRecognitionEnabled && speakersMoved
        if recognizes { recording.voicesVersion = 0 }
        try? modelContext.save()
        guard recognizes else { return }
        enqueueJob(for: recording) {
            guard await self.prepareModel() else { return }
            await self.refreshVoices(of: recording)
        }
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
            // An import has no live words to fall back on: a pass that failed (offline while the language's speech
            // model must download, a language it doesn't know) leaves it to Try Again, not an empty transcript marked
            // done that says no speech was found and is never transcribed again.
            if transcript == nil, recording.words.isEmpty {
                recording.speakerStatus = .failed
                try? modelContext.save()
                progress[id] = nil
                return
            }
            if let transcript, !transcript.words.isEmpty {
                let changes = WordChange.changes(from: recording.words, to: transcript.words, vocabulary: false)
                let hadWords = !recording.words.isEmpty
                recording.words = transcript.words
                recording.alignmentOffset = transcript.alignmentOffset
                recording.segments = TranscriptAligner.keepingIDsByOverlap(   // the same rows, new words: nothing flies in
                    of: recording.segments, in: TranscriptAligner.segments(words: transcript.words, turns: liveTurns))
                if hadWords { flash(changes, in: id) }       // an import's first words aren't changes
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
        if recording.speakerStatus == .done, recording.vocabularyPending || recording.summaryVersion < summaryVersion
            || recording.actionItemsVersion < ActionItemExtractor.version {
            enqueueBackgroundPass(recording, fresh: true)
        } else if recording.speakerStatus == .done {
            track(id) { $0.drop(.vocabulary); $0.drop(.summary); $0.drop(.actions) }
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
        let edits = recording.editCount
        let labels = TranscriptAligner.speakers(words: words, turns: TranscriptAligner.turns(from: recording.segments),
                                                smoothing: false)
        // Dropped when the transcript was corrected or a correction undone meanwhile: the voices belong to labels
        // that are gone (the next job, if any, computes them again).
        guard let voices = try? await diarizer.voices(fileURL: url, windows: VoiceWindows.windows(words: words, speakers: labels)),
              !isGone(recording), recording.speakerStatus == .done, recording.editCount == edits else { return }
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
            if let index = sweepPasses.firstIndex(where: { $0.id == id }) {
                // Queued: only a sweep entry moves up ("Speakers: n" on an older transcript still waiting).
                guard fresh else { return }
                sweepPasses.remove(at: index)
            } else {
                // Running right now (it stays in backgroundQueued until it is described): once more after it, from
                // the transcript as it is then. Dropped here, an Undo's or Edit Text's pass was lost for good.
                if !freshPasses.contains(where: { $0.id == id }) { passAgain.insert(id) }
                return
            }
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
                await findActionItems(pass.recording)         // the same words, Gemma still loaded
                backgroundQueued.remove(pass.id)
                if passAgain.remove(pass.id) != nil, !isGone(pass.recording) {
                    enqueueBackgroundPass(pass.recording, fresh: true)
                }
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
        guard recording.vocabularyPending, !editingText.contains(id) else {   // in Edit Text: when it ends
            track(id) { $0.drop(.vocabulary) }
            return
        }
        track(id) { $0.begin(.vocabulary) }
        vocabularyRunning.insert(id)
        defer { vocabularyRunning.remove(id) }
        let words = recording.words
        let improved = await fileTranscriber.applyVocabulary(to: words, fileURL: recording.audioURL,
                                                             locale: Locale(identifier: recording.localeIdentifier))
        guard !isGone(recording) else { progress[id] = nil; return }
        guard recording.words == words else {
            // Something else wrote the words meanwhile: the result is dropped, and the pass runs again on the new words.
            passAgain.insert(id)
            track(id) { $0.finish(.vocabulary) }
            return
        }
        if improved != words {
            invalidateCorrection(of: [id])                    // the words change: an Undo would take them back
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
        // The action items come next in this pass. On a transcript without a summary (the sweep's older ones) the
        // status line takes a new place: listed now, their place is held in that same move rather than inserted when
        // they begin. Under a summary the line only covers it, and they follow quietly (findActionItems).
        let actionsFollow = recording.actionItemsVersion < ActionItemExtractor.version && (recording.summary ?? "").isEmpty
        track(id) { progress in
            progress.begin(.summary)
            if actionsFollow { progress.expect(.actions) }
        }
        defer {
            if case .running = progress[id]?.state(of: .summary) {   // not now: waiting for Stop, or given up
                let waits = waitingForGemma.contains { $0.id == id }
                track(id) { waits ? $0.expect(.summary, again: true) : $0.drop(.summary) }
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
                try await titler.describe(paragraphs: paragraphs, locale: locale, writer: model)
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

    /// The action items (ActionItemExtractor), right after the summary: once per transcript (`actionItemsVersion`), by
    /// Gemma only, the same rules as `describe` (nothing without Gemma; while recording, right after Stop; stopped
    /// because the app left the foreground, the next return tries again). A new extraction keeps what the user did with
    /// the items found before (`ActionItem.merged`: added, removed).
    private func findActionItems(_ recording: Recording) async {
        let target = ActionItemExtractor.version
        guard !isGone(recording) else { return }
        let id = recording.id
        guard recording.speakerStatus == .done, recording.actionItemsVersion < target else {
            track(id) { $0.drop(.actions) }
            return
        }
        // On the card only when the step was listed ahead (after Stop, a re-run, or behind the summary it follows): the
        // sweep's pass over an older transcript whose summary is current only adds items, quietly. Shown, the status
        // line covered that summary for Gemma's whole run and the held place moved the open transcript down; now the
        // row appears when items are found.
        let shown = progress[id]?.state(of: .actions) != nil
        if shown { track(id) { $0.begin(.actions) } }
        defer {
            if shown, case .running = progress[id]?.state(of: .actions) {   // not now: waiting for Stop, or given up
                let waits = waitingForGemma.contains { $0.id == id }
                track(id) { waits ? $0.expect(.actions, again: true) : $0.drop(.actions) }
            }
        }
        let recordedAt = recording.createdAt
        let paragraphs = recording.segments.map { segment in
            TranscriptTitler.paragraph(segment.text, speaker: segment.speakerIndex.map(recording.speakerName))
        }
        guard betterSummaries.activeModel != nil else { return }
        guard !isRecording else {                                   // Gemma never runs while recording: after Stop
            waitForGemma(recording, id: id)
            return
        }
        let found: [ActionItem]
        do {
            let extractor = actionItemExtractor
            found = try await betterSummaries.run { model in
                try await extractor.extract(paragraphs: paragraphs, recordedAt: recordedAt, writer: model)
            }
        } catch {
            // As in describe: RetryLater stores nothing (again later, or right after the recording that stopped it);
            // LocalModelFailed: once Gemma is downloaded again.
            if isRecording, !isGone(recording) { waitForGemma(recording, id: id) }
            return
        }
        guard !isGone(recording) else { return }
        recording.actionItems = ActionItem.merged(found, keepingFlagsOf: recording.actionItems)
        recording.actionItemsVersion = max(recording.actionItemsVersion, target)
        try? modelContext.save()
        if shown { track(id) { $0.finish(.actions) } }
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
