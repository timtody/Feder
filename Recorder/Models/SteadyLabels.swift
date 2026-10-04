import Foundation

/// Live speaker labels as the live screen shows them. LS-EEND labels can still switch while someone talks, so a word's
/// label is confirmed only once the aligner has given it the same label for `hold`. Meanwhile the word is already shown
/// under its newest label (`shown = latest ?? steady ?? previous`: a different speaker starts a new paragraph at once),
/// but a paragraph gets its speaker (the coloured name) only from a word whose confirmed label is the one it is shown
/// under. Words never labelled follow the word before. Measured on 24 replayed conversations: with the provisional words
/// labelled too (LiveTranscript), hold 0.5 s and this early split, the right speaker shows p50 2.2 s after a change
/// instead of 5.5 s, and 44 % instead of 59 % of words are ever shown under a wrong speaker.
///
/// Incremental: each update folds the words again only from the paragraph holding the first word whose label changed or
/// is still pending (usually the last one), so a long recording costs the same as a short one. Same paragraphs as
/// folding everything (randomized equivalence test in the live latency harness). Words only grow at the end, with
/// increasing start times.
nonisolated struct SteadyLabels {
    static let hold: Duration = .milliseconds(500)

    /// The words folded into display paragraphs: same shown speaker, no silence over `TranscriptAligner.paragraphGap`, and
    /// not `TranscriptAligner.isFull` yet. A paragraph keeps its id while its first word stays the same.
    private(set) var segments: [TranscriptSegment] = []
    /// When the earliest pending label becomes steady: update again then (nil: nothing pending).
    private(set) var nextChange: ContinuousClock.Instant?
    /// The speaker the last word is shown under (its paragraph may have no speaker yet).
    var lastShown: Int? { shown.last ?? nil }

    private var latest: [Int?] = []                       // per word: the aligner's label at the last update
    private var since: [ContinuousClock.Instant] = []     // per word: when `latest` was first seen
    private var steady: [Int?] = []                       // per word: the last label that held for `hold`
    private var firstPending: Int?                        // first word whose latest label has not held yet
    private var firstWord: [Int] = []                     // per paragraph: its first word
    private var tokens: [Int] = []                        // per paragraph: its words (space-separated tokens)
    private var shown: [Int?] = []                        // per paragraph: the speaker its words are shown under

    /// Takes the aligner's labels for `words` (nil = not labelled yet) and `changedFrom`, the first word whose label may
    /// differ from the last update (LiveSpeakers.update), and updates `segments` and `nextChange`.
    mutating func update(words: [TranscriptWord], labels: [Int?], changedFrom: Int, now: ContinuousClock.Instant = .now) {
        let known = latest.count
        let added = max(0, words.count - known)
        latest += repeatElement(nil, count: added)
        since += repeatElement(now, count: added)
        steady += repeatElement(nil, count: added)
        // Words before `first` keep their state and their paragraphs; fold again from the paragraph holding it.
        let first = min(changedFrom, known, firstPending ?? .max)
        guard first < words.count else { return }        // nothing new, changed or pending: nextChange stays nil
        var p = segments.count                            // first paragraph to rebuild
        if first < known { p = TranscriptAligner.firstIndex(in: firstWord) { $0 > first } - 1 }
        let start = p < segments.count ? firstWord[p] : known
        let replaced = Array(segments[p...])
        segments.removeSubrange(p...)
        firstWord.removeSubrange(p...)
        tokens.removeSubrange(p...)
        shown.removeSubrange(p...)
        nextChange = nil
        firstPending = nil
        var previous = shown.last ?? nil                  // shown speaker of the word before
        for i in start..<words.count {
            let word = words[i]
            if labels[i] != latest[i] { latest[i] = labels[i]; since[i] = now }
            if let label = latest[i], label != steady[i] {
                let due = since[i] + Self.hold
                if due <= now {
                    steady[i] = label
                } else {
                    nextChange = min(nextChange ?? due, due)
                    if firstPending == nil { firstPending = i }
                }
            }
            let speaker = latest[i] ?? steady[i] ?? previous
            let confirmed = steady[i] != nil && steady[i] == speaker
            let count = word.text.split(separator: " ").count
            let full = segments.last.map { TranscriptAligner.isFull($0.text, wordCount: tokens[tokens.count - 1]) } ?? false
            if let end = segments.last?.end,
               Self.continues(lastEnd: end, full: full, speaker: speaker, previous: previous, start: word.start) {
                let last = segments.count - 1                 // (no copy of the segment held: its text grows in place)
                segments[last].text += " " + word.text
                segments[last].end = max(end, word.end)
                if confirmed { segments[last].speakerIndex = speaker }
                tokens[last] += count
            } else {
                let label = Self.newLabel(speaker: speaker, previous: previous, confirmed: confirmed, full: full)
                segments.append(TranscriptSegment(speakerIndex: label, text: word.text, start: word.start, end: word.end))
                firstWord.append(i)
                tokens.append(count)
                shown.append(speaker)
            }
            previous = speaker
        }
        let rebuilt = TranscriptAligner.keepingIDs(of: replaced, in: Array(segments[p...]))
        segments.replaceSubrange(p..., with: rebuilt)
    }

    /// Whether a word shown under `speaker` continues the last paragraph (ending at `lastEnd`; nil: none yet): it is not
    /// full, the word before is shown under the same speaker, and no pause over `TranscriptAligner.paragraphGap` came
    /// first. The live screen places its provisional words by the same rule (LiveTranscriptModel).
    static func continues(lastEnd: TimeInterval?, full: Bool, speaker: Int?, previous: Int?, start: TimeInterval) -> Bool {
        guard let lastEnd else { return false }
        return !full && speaker == previous && start - lastEnd <= TranscriptAligner.paragraphGap
    }

    /// The label a new paragraph starts with: its first word's once confirmed; a full paragraph goes on with the same
    /// speaker.
    static func newLabel(speaker: Int?, previous: Int?, confirmed: Bool, full: Bool) -> Int? {
        confirmed || (full && speaker == previous) ? speaker : nil
    }
}

/// The hold for provisional words: their estimated times move a little between volatile results, so their labels are
/// kept per 0.1 s frame of audio (the frame of the word's midpoint) instead of per word.
nonisolated struct FrameSteady {
    private var state: [Int: (label: Int, since: ContinuousClock.Instant)] = [:]
    /// When the earliest pending label becomes steady (nil: nothing pending).
    private(set) var nextChange: ContinuousClock.Instant?

    /// Each word's label once it held for SteadyLabels.hold at its frame, else nil (also when unlabelled).
    mutating func steady(words: [TranscriptWord], labels: [Int?], now: ContinuousClock.Instant = .now) -> [Int?] {
        nextChange = nil
        return zip(words, labels).map { word, label in
            guard let label else { return nil }
            let frame = Self.frame(of: word)
            if state[frame]?.label != label { state[frame] = (label, now) }
            let due = (state[frame]?.since ?? now) + SteadyLabels.hold
            if due <= now { return label }
            nextChange = min(nextChange ?? due, due)
            return nil
        }
    }

    /// Drops the frames before `time`: provisional words only follow the finalized ones, so they never come back.
    mutating func forget(before time: TimeInterval) {
        let frame = Int((time * 10).rounded(.down))
        state = state.filter { $0.key >= frame }
    }

    private static func frame(of word: TranscriptWord) -> Int {
        Int(((word.start + word.end) / 2 * 10).rounded(.down))
    }
}
