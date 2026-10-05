import Foundation

/// What the live screen shows (RecordingSession -> LiveTranscriptView).
nonisolated struct LiveText: Equatable, Sendable {
    /// The finalized words in paragraphs (SteadyLabels); speakerIndex = confirmed live label, nil = none yet.
    var segments: [TranscriptSegment] = []
    /// The speaker the last finalized word is shown under, which its paragraph may not have confirmed yet.
    var speaker: Int?
    /// The provisional words after them, each with its own estimated time and live label.
    var provisional: [ProvisionalWord] = []
    /// Per segment: the id of its first word (the same id it had while provisional) and the speaker its words are shown
    /// under: LiveNames' key.
    var segmentKeys: [LiveNames.Key?] = []

    var isEmpty: Bool { segments.isEmpty && provisional.isEmpty }
}

/// A provisional word with its live label: `speaker` is the newest one (nil: not diarized yet, it goes with the word
/// before), `steady` the label once it held for SteadyLabels.hold (then its paragraph may show the speaker). `id`: the
/// word across volatile results and into its final version (VolatileTimer, LiveTranscript.finalize).
nonisolated struct ProvisionalWord: Hashable, Sendable {
    var word: TranscriptWord
    var speaker: Int?
    var steady: Int?
    var id = 0
}

/// The names the live screen keeps. A paragraph's name (its speaker, coloured, above it) comes from a word whose label
/// held there; it used to go away whenever no word of the paragraph was confirmed for a moment (its words finalized,
/// re-timed, revised, LS-EEND correcting itself) and come back half a second later. Now a name once shown stays while
/// the paragraph is still there with the same first word shown under the same speaker; it goes when that changes (the
/// words really moved to another speaker). Pure, so the live replays run exactly this; LiveTranscriptModel applies it.
nonisolated struct LiveNames {
    /// A paragraph: the id of its first word and the speaker its words are shown under.
    struct Key: Hashable, Sendable {
        var word: Int
        var speaker: Int
    }

    private var named: Set<Key> = []

    /// The labels to show for paragraphs in order (`labels`: their confirmed ones), and remembers the named ones.
    mutating func labels(_ labels: [Int?], keys: [Key?]) -> [Int?] {
        var next: Set<Key> = []
        let out = zip(labels, keys).map { label, key -> Int? in
            guard let key else { return label }
            let shown = label ?? (named.contains(key) ? key.speaker : nil)
            if shown == key.speaker { next.insert(key) }
            return shown
        }
        named = next
        return out
    }
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
    private var tailIDs: [Int] = []                       // per timed word: who it is across results (VolatileTimer)
    private var wordIDs: [Int] = []                       // per finalized word: the id it had while provisional
    private var speakers = LiveSpeakers()
    private var steady = SteadyLabels()
    private var timer = VolatileTimer()
    private var holds = WordSteady()

    /// When a pending label comes due: call refresh(now:) then (nil: nothing pending).
    var nextChange: ContinuousClock.Instant? {
        [steady.nextChange, holds.nextChange].compactMap { $0 }.min()
    }

    /// The provisional words as shown, each with its estimated time.
    var provisionalWords: [TranscriptWord] { timedTail }

    /// A volatile result: the new provisional tail, replacing the last one.
    mutating func revise(_ provisional: [TranscriptWord], now: ContinuousClock.Instant = .now) {
        tail = provisional
        tailIsRun = provisional.count == 1
        timedTail = timer.words(for: tail)
        tailIDs = timer.ids
        placeTail(now: now)
    }

    /// A final result. Provisional words after the finalized ones stay until the next volatile result, so they don't
    /// blink out. The finalized words take over the label holds of the provisional words they replace (SteadyLabels.
    /// carry), so a name that had held stays.
    mutating func finalize(_ newWords: [TranscriptWord], now: ContinuousClock.Instant = .now) {
        let end = newWords.last?.end ?? .infinity
        let matched = matches(for: newWords)
        steady.carry(matched.map { $0.map { holds.hold(of: tailIDs[$0]) } ?? nil }, from: words.count)
        wordIDs += matched.map { $0.map { tailIDs[$0] } ?? timer.freshID() }
        words += newWords
        if tailIsRun {
            // SpeechTranscriber's provisional text is one run over everything not final yet, starting before `end`:
            // removed whole, it took the next speaker's words (and their paragraph and name) off the screen until the
            // next volatile result, up to a second later (also after a second final in a row). Its words after the
            // finalized ones stay until the next volatile result, and keep their ids into it (VolatileTimer.dropFirst).
            // Consumed: as many as were finalized, moved by where the last match was (words the final reads
            // differently go too, instead of staying after it as a stale second reading).
            let last = matched.indices.last { matched[$0] != nil }
            let offset = last.map { matched[$0]! - $0 } ?? 0
            let consumed = min(max(newWords.count + offset, 0), timedTail.count)
            timedTail.removeFirst(consumed)
            tailIDs.removeFirst(consumed)
            // Estimated times can lie before the final's end, inside the finalized speaker's speech, which would keep
            // a new speaker's first word under the one before: until the next run times them again, the kept words
            // move to start at `end` (their holds go with the words, not the times).
            let shift = max(0, end - (timedTail.first?.start ?? end))
            if shift > 0 {
                timedTail = timedTail.map { TranscriptWord(text: $0.text, start: $0.start + shift, end: $0.end + shift) }
            }
            timer.dropFirst(consumed)
            tail = []
        } else {
            tail.removeAll { $0.start < end }                 // words timed one by one (FakeTranscriber)
            timedTail = timer.words(for: tail)
            tailIDs = timer.ids
        }
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
    /// screen's fade-in (LiveTranscriptModel), the same word ignoring case and punctuation, at its place or up to three
    /// words further on after a revision dropped some; nil when none matches (that word's hold starts when it is
    /// finalized). A match further on must not be under another live label (a final "you" matched the next speaker's
    /// "you" two words on, removed that speaker's words and gave the finalized one their hold). At its place it is the
    /// same word whatever its label: requiring the labels to agree there too left the match behind at one wrongly placed
    /// word, and every word after it lost its hold. (Whether the hold is taken over is SteadyLabels.carry's decision.)
    private func matches(for newWords: [TranscriptWord]) -> [Int?] {
        let labels = speakers.labels(continuing: newWords)   // as the aligner will label the finalized words
        var next = 0
        return newWords.indices.map { j in
            guard let match = (next..<min(next + 4, timedTail.count)).first(where: { m in
                let shown = m < text.provisional.count ? text.provisional[m].speaker : nil
                return VolatileTimer.isSame(timedTail[m].text, newWords[j].text)
                    && (m == next || labels[j] == nil || shown == nil || labels[j] == shown)
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
        text.segmentKeys = zip(steady.firstWords, steady.shownSpeakers).map { first, shown in
            shown.map { LiveNames.Key(word: wordIDs[first], speaker: $0) }
        }
    }

    /// The provisional words' labels from the newest live turns, as if they followed the finalized words.
    private mutating func placeTail(now: ContinuousClock.Instant) {
        let labels = speakers.labels(continuing: timedTail)
        let shown = holds.update(ids: tailIDs, labels: labels, now: now)
        text.provisional = timedTail.indices.map {
            ProvisionalWord(word: timedTail[$0], speaker: shown[$0].speaker, steady: shown[$0].steady, id: tailIDs[$0])
        }
    }
}

/// Times for the provisional words. A volatile SpeechTranscriber result is one run spanning the whole unfinalized range,
/// which arrives as ONE TranscriptWord; this splits it into its words. Words kept from the previous result (same text,
/// ignoring case and punctuation) keep their times; new words are spread over [end of the last kept word,
/// max(that + 0.12 s per word, range end - `lag`)] in proportion to their letters + 2. Measured on 24 conversations: off
/// by p50 0.31 s, p90 0.88 s; the newest recognized word trails the range end by p50 0.59 s. Results that already come
/// timed per word (FakeTranscriber) pass unchanged.
/// Each word also gets an id that stays the same while it is the same word (`ids`, parallel to the words returned),
/// so its label's hold follows the word, not its estimated time (WordSteady).
nonisolated struct VolatileTimer {
    static let lag: TimeInterval = 0.6

    private var regionStart = -TimeInterval.infinity
    private var tokens: [String] = []
    private var times: [(start: TimeInterval, end: TimeInterval)] = []
    private var tokenIDs: [Int] = []              // per token
    private var timedIDs: [String: Int] = [:]     // words timed one by one: by text and start
    private var nextID = 0
    /// Per word of the last result: its id.
    private(set) var ids: [Int] = []

    /// The first `count` words were finalized (LiveTranscript.finalize): the rest keep their ids into the next run.
    /// (Their times don't carry over: the next run starts where speech resumed, and its words are timed from there.
    /// Carrying the times placed them in the pause before, under the speaker before.)
    mutating func dropFirst(_ count: Int) {
        tokens.removeFirst(min(count, tokens.count))
        times.removeFirst(min(count, times.count))
        tokenIDs.removeFirst(min(count, tokenIDs.count))
    }

    /// An id no word has had (for a finalized word that matched no provisional one).
    mutating func freshID() -> Int { newID() }

    mutating func words(for provisional: [TranscriptWord]) -> [TranscriptWord] {
        guard let run = provisional.first else { ids = []; return [] }
        guard provisional.count == 1 else {
            var seen: [String: Int] = [:]
            ids = provisional.map { word in
                let key = word.text.lowercased().filter { $0.isLetter || $0.isNumber } + "@\(word.start)"
                let id = timedIDs[key] ?? newID()
                seen[key] = id
                return id
            }
            timedIDs = seen
            return provisional
        }
        let next = run.text.split(separator: " ").map(String.init)
        // A new run (after a final) is timed from its own start; its words keep their ids from the last one.
        let newRegion = run.start != regionStart
        regionStart = run.start
        // Each word of the new result keeps the id and the time of the word it replaces in the last one: aligned by
        // edit distance (same word, or one read differently at its place; words inserted or dropped around them).
        // Keeping only the unchanged prefix gave every word after the first revision a new id and a new time, so their
        // held labels started over and the paragraph's name went away for SteadyLabels.hold; revisions come in
        // clusters (one reverting while the next is revised).
        let pairs = Self.align(tokens, next)
        var newTimes: [(start: TimeInterval, end: TimeInterval)?] = Array(repeating: nil, count: next.count)
        var newIDs: [Int?] = Array(repeating: nil, count: next.count)
        for (old, new) in pairs {
            newIDs[new] = tokenIDs[old]
            if !newRegion { newTimes[new] = times[old] }
        }
        // Words after the last one kept are new: spread over the rest of the run as before.
        let lastKept = newTimes.lastIndex { $0 != nil }
        let firstNew = lastKept.map { $0 + 1 } ?? 0
        if next.count > firstNew {
            let from = lastKept.flatMap { newTimes[$0]?.end } ?? run.start
            let to = max(from + 0.12 * Double(next.count - firstNew), run.end - Self.lag)
            let weights = next[firstNew...].map { Double($0.count) + 2 }
            let total = weights.reduce(0, +)
            var t = from
            for (k, weight) in weights.enumerated() {
                let duration = (to - from) * weight / total
                newTimes[firstNew + k] = (t, t + duration)
                t += duration
            }
        }
        // Words inserted between kept ones share the second half of the word before them (or the gap after it).
        var j = 0
        while j < firstNew {
            guard newTimes[j] == nil else { j += 1; continue }
            var k = j
            while k < firstNew, newTimes[k] == nil { k += 1 }
            let before = j > 0 ? newTimes[j - 1]! : (start: run.start, end: run.start)
            let after = newTimes[k]!.start
            let from = after > before.end ? before.end : (before.start + before.end) / 2
            if j > 0, after <= before.end { newTimes[j - 1] = (before.start, from) }
            let step = (max(after, from) - from) / Double(k - j)
            for m in j..<k { newTimes[m] = (from + step * Double(m - j), from + step * Double(m - j + 1)) }
            j = k
        }
        times = newTimes.map { $0! }
        tokenIDs = newIDs.map { $0 ?? newID() }
        tokens = next
        ids = tokenIDs
        return zip(next, times).map { TranscriptWord(text: $0, start: $1.start, end: $1.end) }
    }

    /// The words of `new` that take the place of a word of `old` (the same word, or one read differently there), in
    /// order: the diagonal steps of a minimal edit (substitute, insert and drop cost 1, the same word 0; ties go to
    /// the diagonal). About 40 words per side between finals, once a second.
    static func align(_ old: [String], _ new: [String]) -> [(old: Int, new: Int)] {
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return [] }
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let diagonal = cost[i - 1][j - 1] + (isSame(old[i - 1], new[j - 1]) ? 0 : 1)
                cost[i][j] = min(diagonal, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }
        var pairs: [(old: Int, new: Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            let same = isSame(old[i - 1], new[j - 1])
            if cost[i][j] == cost[i - 1][j - 1] + (same ? 0 : 1) {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if cost[i][j] == cost[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    private mutating func newID() -> Int {
        nextID += 1
        return nextID
    }

    /// The same word as far as its time goes, and for the live screen's fade-in (LiveTranscriptModel): equal ignoring
    /// case and punctuation ("hello" firming up as "Hello,").
    static func isSame(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
        a == b || a.lowercased().filter { $0.isLetter || $0.isNumber } == b.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
