import Foundation

/// What the live screen shows (RecordingSession -> LiveTranscriptView).
nonisolated struct LiveText: Equatable, Sendable {
    /// The finalized words in paragraphs (SteadyLabels); speakerIndex = confirmed live label, nil = none yet.
    var segments: [TranscriptSegment] = []
    /// The speaker the last finalized word is shown under, which its paragraph may not have confirmed yet.
    var speaker: Int?
    /// The provisional words after them, each with its own estimated time and live label.
    var provisional: [ProvisionalWord] = []

    var isEmpty: Bool { segments.isEmpty && provisional.isEmpty }
}

/// A provisional word with its live label: `speaker` is the newest one (nil: not diarized yet, it goes with the word
/// before), `steady` the label once it held for SteadyLabels.hold (then its paragraph may show the speaker).
nonisolated struct ProvisionalWord: Hashable, Sendable {
    var word: TranscriptWord
    var speaker: Int?
    var steady: Int?
}

/// The live transcript while recording (pure, so the live latency harness runs exactly this): finalized words,
/// provisional words and live speaker turns in, `text` (what the screen shows) out. RecordingSession feeds it every
/// transcription result and live-label snapshot, and calls refresh(now:) when `nextChange` comes due.
///
/// SpeechTranscriber finalizes only about every 15 s of speech; its provisional text is one run spanning everything not
/// final yet (measured: no per-word times). Labelling only the final words left a new speaker's first words under the
/// previous speaker for p50 5.5 s, p90 16.9 s. So the provisional text is split into words with estimated times
/// (VolatileTimer) and each word is shown under the newest live label for its time: the right speaker now shows p50
/// 2.2 s, p90 3.1 s after a change (24 replayed conversations, LS-EEND snapshots every 0.5 s).
nonisolated struct LiveTranscript {
    private(set) var words: [TranscriptWord] = []         // finalized, in order
    private(set) var turns = LiveSpeakerTurns()
    private(set) var text = LiveText()

    private var tail: [TranscriptWord] = []               // the transcriber's provisional words, as they came
    private var tailIsRun = false                         // they came as one untimed run (SpeechTranscriber)
    private var timedTail: [TranscriptWord] = []          // the same, split into words with estimated times
    private var speakers = LiveSpeakers()
    private var steady = SteadyLabels()
    private var timer = VolatileTimer()
    private var frames = FrameSteady()

    /// When a pending label comes due: call refresh(now:) then (nil: nothing pending).
    var nextChange: ContinuousClock.Instant? {
        [steady.nextChange, frames.nextChange].compactMap { $0 }.min()
    }

    /// The provisional words as shown, each with its estimated time.
    var provisionalWords: [TranscriptWord] { timedTail }

    /// A volatile result: the new provisional tail, replacing the last one.
    mutating func revise(_ provisional: [TranscriptWord], now: ContinuousClock.Instant = .now) {
        tail = provisional
        tailIsRun = provisional.count == 1
        timedTail = timer.words(for: tail)
        placeTail(now: now)
    }

    /// A final result. Provisional words after the finalized ones stay until the next volatile result, so they don't
    /// blink out. The finalized words take over the label holds of the provisional words they replace (SteadyLabels.
    /// carry), so a name that had held stays.
    mutating func finalize(_ newWords: [TranscriptWord], now: ContinuousClock.Instant = .now) {
        let end = newWords.last?.end ?? .infinity
        let matched = matches(for: newWords)
        steady.carry(matched.map { $0.map { frames.hold(of: timedTail[$0]) } ?? nil }, from: words.count)
        words += newWords
        if tailIsRun {
            // SpeechTranscriber's provisional text is one run over everything not final yet, starting before `end`:
            // removed whole, it took the next speaker's words (and their paragraph and name) off the screen until the
            // next volatile result, up to a second later (also after a second final in a row). Its words after the
            // finalized ones stay, and the timer goes on from them when the next run starts at the final's end.
            // Consumed: as many as were finalized, moved by where the last match was (words the final reads
            // differently go too, instead of staying after it as a stale second reading).
            let last = matched.indices.last { matched[$0] != nil }
            let offset = last.map { matched[$0]! - $0 } ?? 0
            let consumed = min(max(newWords.count + offset, 0), timedTail.count)
            timedTail.removeFirst(consumed)
            // Estimated times can lie before the final's end, inside the finalized speaker's speech, which would keep
            // a new speaker's first word under the one before until it is final: the kept words move to start at
            // `end`, and their holds move with them (a label that changes there starts over).
            let shift = max(0, end - (timedTail.first?.start ?? end))
            if shift > 0 {
                let moved = timedTail.map { TranscriptWord(text: $0.text, start: $0.start + shift, end: $0.end + shift) }
                frames.move(from: timedTail, to: moved)
                timedTail = moved
            }
            timer.dropFirst(consumed, shiftedBy: shift)
            tail = []
        } else {
            tail.removeAll { $0.start < end }                 // words timed one by one (FakeTranscriber)
            timedTail = timer.words(for: tail)
        }
        if let last = words.last { frames.forget(before: last.start) }
        realign(now: now)
        placeTail(now: now)
    }

    /// A live-label snapshot (the full state so far).
    mutating func apply(_ snapshot: LiveSpeakerTurns, now: ContinuousClock.Instant = .now) {
        turns = snapshot
        realign(now: now)
        placeTail(now: now)
    }

    /// Pending labels came due (`nextChange`).
    mutating func refresh(now: ContinuousClock.Instant = .now) {
        realign(now: now)
        placeTail(now: now)
    }

    /// The provisional word each finalized word replaces (its index in `timedTail`): matched in order like the live
    /// screen's fade-in (LiveTranscriptModel), the same word ignoring case and punctuation, up to three words further
    /// on after a revision dropped some, and not under another live label (a final "you" matched the next speaker's
    /// "you" two words on, removed that speaker's words and gave the finalized one their hold); nil when none matches
    /// (that word's hold starts when it is finalized).
    private func matches(for newWords: [TranscriptWord]) -> [Int?] {
        let labels = speakers.labels(continuing: newWords)   // as the aligner will label the finalized words
        var next = 0
        return newWords.indices.map { j in
            guard let match = (next..<min(next + 4, timedTail.count)).first(where: { m in
                let shown = m < text.provisional.count ? text.provisional[m].speaker : nil
                return VolatileTimer.isSame(timedTail[m].text, newWords[j].text)
                    && (labels[j] == nil || shown == nil || labels[j] == shown)
            }) else { return nil }
            next = match + 1
            return match
        }
    }

    private mutating func realign(now: ContinuousClock.Instant) {
        let changed = speakers.update(words: words, turns: turns.turns, labelledUntil: turns.processedUntil)
        steady.update(words: words, labels: speakers.labels, changedFrom: changed, now: now)
        text.segments = steady.segments
        text.speaker = steady.lastShown
    }

    /// The provisional words' labels from the newest live turns, as if they followed the finalized words.
    private mutating func placeTail(now: ContinuousClock.Instant) {
        let labels = speakers.labels(continuing: timedTail)
        let held = frames.steady(words: timedTail, labels: labels, now: now)
        text.provisional = timedTail.indices.map {
            ProvisionalWord(word: timedTail[$0], speaker: labels[$0], steady: held[$0])
        }
    }
}

/// Times for the provisional words. A volatile SpeechTranscriber result is one run spanning the whole unfinalized range,
/// which arrives as ONE TranscriptWord; this splits it into its words. Words kept from the previous result (same text,
/// ignoring case and punctuation) keep their times; new words are spread over [end of the last kept word,
/// max(that + 0.12 s per word, range end - `lag`)] in proportion to their letters + 2. Measured on 24 conversations: off
/// by p50 0.31 s, p90 0.88 s; the newest recognized word trails the range end by p50 0.59 s. Results that already come
/// timed per word (FakeTranscriber) pass unchanged.
nonisolated struct VolatileTimer {
    static let lag: TimeInterval = 0.6

    private var regionStart = -TimeInterval.infinity
    private var tokens: [String] = []
    private var times: [(start: TimeInterval, end: TimeInterval)] = []
    private var continues = false                 // dropFirst: the next run's new start goes on from the words kept

    /// The first `count` words were finalized (LiveTranscript.finalize): the rest keep their times, and the next run,
    /// which starts at the final's end, continues them instead of timing every word again from its new start (that
    /// moved them to other 0.1 s frames, so their held labels started over, and words placed in the silence before a
    /// new speaker went to the previous one).
    /// `shift`: the kept words moved later by that much (LiveTranscript.finalize, so they start at the final's end).
    mutating func dropFirst(_ count: Int, shiftedBy shift: TimeInterval = 0) {
        tokens.removeFirst(min(count, tokens.count))
        times.removeFirst(min(count, times.count))
        if shift > 0 { times = times.map { ($0.start + shift, $0.end + shift) } }
        continues = true
    }

    mutating func words(for provisional: [TranscriptWord]) -> [TranscriptWord] {
        guard let run = provisional.first else { return [] }
        guard provisional.count == 1 else { return provisional }
        let next = run.text.split(separator: " ").map(String.init)
        if run.start != regionStart {
            if !continues { tokens = []; times = [] }
            regionStart = run.start
        }
        continues = false
        // Kept: the same words at the same places. A single word read differently (the recognizer revising it) keeps
        // its place too when the word after it is the same, so the words after it don't all move.
        var kept = 0
        while kept < min(tokens.count, next.count),
              Self.isSame(tokens[kept], next[kept])
                || (kept + 1 < min(tokens.count, next.count) && Self.isSame(tokens[kept + 1], next[kept + 1])) {
            kept += 1
        }
        times.removeSubrange(kept...)
        if next.count > kept {
            let from = times.last?.end ?? run.start
            let to = max(from + 0.12 * Double(next.count - kept), run.end - Self.lag)
            let weights = next[kept...].map { Double($0.count) + 2 }
            let total = weights.reduce(0, +)
            var t = from
            for weight in weights {
                let duration = (to - from) * weight / total
                times.append((t, t + duration))
                t += duration
            }
        }
        tokens = next
        return zip(next, times).map { TranscriptWord(text: $0, start: $1.start, end: $1.end) }
    }

    /// The same word as far as its time goes, and for the live screen's fade-in (LiveTranscriptModel): equal ignoring
    /// case and punctuation ("hello" firming up as "Hello,").
    static func isSame(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
        a == b || a.lowercased().filter { $0.isLetter || $0.isNumber } == b.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
