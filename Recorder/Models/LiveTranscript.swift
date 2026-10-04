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
        timedTail = timer.words(for: tail)
        placeTail(now: now)
    }

    /// A final result. Provisional words after the finalized ones stay until the next volatile result, so they don't
    /// blink out.
    mutating func finalize(_ newWords: [TranscriptWord], now: ContinuousClock.Instant = .now) {
        words += newWords
        let end = newWords.last?.end ?? .infinity
        tail.removeAll { $0.start < end }
        timedTail = timer.words(for: tail)
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

    mutating func words(for provisional: [TranscriptWord]) -> [TranscriptWord] {
        guard let run = provisional.first else { return [] }
        guard provisional.count == 1 else { return provisional }
        let next = run.text.split(separator: " ").map(String.init)
        if run.start != regionStart { regionStart = run.start; tokens = []; times = [] }
        var kept = 0
        while kept < min(tokens.count, next.count), Self.isSame(tokens[kept], next[kept]) { kept += 1 }
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
