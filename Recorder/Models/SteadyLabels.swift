import Foundation

/// Live speaker labels as the live screen shows them. LS-EEND labels can still switch while someone talks, so a word's
/// label is confirmed only once the aligner has given it the same label for `hold`. Meanwhile the word is already shown
/// under its newest label (`shown = latest ?? steady ?? previous`: a different speaker starts a new paragraph at once),
/// but a paragraph gets its speaker (the coloured name) only from a word whose confirmed label is the one it is shown
/// under. Once shown, the name stays while the paragraph keeps its first word and speaker (LiveNames). Words never labelled follow the word before. Measured on 24 replayed conversations: with the provisional words
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
    /// Per paragraph: the index of its first word, and the speaker its words are shown under (LiveNames' keys).
    var firstWords: [Int] { firstWord }
    var shownSpeakers: [Int?] { shown }

    private var latest: [Int?] = []                       // per word: the aligner's label at the last update
    private var since: [ContinuousClock.Instant] = []     // per word: when `latest` was first seen
    private var steady: [Int?] = []                       // per word: the last label that held for `hold`
    private var firstPending: Int?                        // first word whose latest label has not held yet
    private var firstWord: [Int] = []                     // per paragraph: its first word
    private var tokens: [Int] = []                        // per paragraph: its words (space-separated tokens)
    private var shown: [Int?] = []                        // per paragraph: the speaker its words are shown under
    private var carried: [Int: LabelHold] = [:]           // per word index not added yet: its provisional word's hold

    /// The holds the next words (from index `start` on) take over from the provisional words they finalize
    /// (LiveTranscript.finalize). Without them a finalized word started its hold again: the name of a paragraph whose
    /// label had held while its words were provisional went away for `hold` when they were finalized (after a pause,
    /// or a new speaker's first words: 370 of 412 speaker changes in a replay of 40 synthetic conversations).
    mutating func carry(_ holds: [LabelHold?], from start: Int) {
        for (offset, hold) in holds.enumerated() { if let hold { carried[start + offset] = hold } }
    }

    /// Takes the aligner's labels for `words` (nil = not labelled yet) and `changedFrom`, the first word whose label may
    /// differ from the last update (LiveSpeakers.update), and updates `segments` and `nextChange`.
    mutating func update(words: [TranscriptWord], labels: [Int?], changedFrom: Int, now: ContinuousClock.Instant = .now) {
        let known = latest.count
        for i in known..<max(known, words.count) {
            // A carried hold goes on from when it began, and a label that held already is steady at once (it stays the
            // word's speaker while the aligner hasn't labelled the finalized word yet).
            // Not when the finalized word's own label says otherwise: its time is exact, the provisional word's was an
            // estimate (keeping the held label there kept words under the wrong speaker for `hold`).
            var hold = carried.removeValue(forKey: i)
            if let carried = hold, let label = labels[i], label != (carried.held ?? carried.label) { hold = nil }
            latest.append(hold?.label)
            since.append(hold?.since ?? now)
            steady.append(hold.flatMap { $0.since + Self.hold <= now ? $0.label : $0.held })
        }
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
            // The newest label places the word. (Keeping a held label until another one held too was tried against
            // names going away: with LS-EEND's labels changing back and forth it kept words under the speaker before.)
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

/// A word's live label: the newest one, when it was first seen (SteadyLabels.hold runs from `since`), and the last
/// one that held (`held`, its speaker meanwhile).
nonisolated struct LabelHold: Equatable {
    var label: Int
    var since: ContinuousClock.Instant
    var held: Int?
}

/// The hold for provisional words, per word (VolatileTimer's ids), so it follows the word through new estimated times,
/// a final before it and the next run. It was kept per 0.1 s frame of the word's estimated midpoint: every re-timing
/// (a revised or inserted word before it, the run starting anew after a final) put words on frames without a hold, and
/// their paragraph's name went away for `SteadyLabels.hold`.
nonisolated struct WordSteady {
    private var state: [Int: LabelHold] = [:]
    /// When the earliest pending label becomes steady (nil: nothing pending).
    private(set) var nextChange: ContinuousClock.Instant?

    /// Per word (`ids` parallel to `labels`, the newest labels; nil: not labelled there yet): the speaker it is shown
    /// under (the newest label) and that label once it held. Words no longer among `ids` are forgotten.
    mutating func update(ids: [Int], labels: [Int?], now: ContinuousClock.Instant = .now) -> [(speaker: Int?, steady: Int?)] {
        nextChange = nil
        var next: [Int: LabelHold] = [:]
        let out = zip(ids, labels).map { id, label -> (speaker: Int?, steady: Int?) in
            var hold = state[id]
            if let label {
                if hold == nil { hold = LabelHold(label: label, since: now) }
                else if hold!.label != label { hold!.label = label; hold!.since = now }
                if hold!.held != label {
                    let due = hold!.since + SteadyLabels.hold
                    if due <= now { hold!.held = label } else { nextChange = min(nextChange ?? due, due) }
                }
            }
            if let hold { next[id] = hold }
            return (label, label != nil && hold?.held == label ? label : nil)
        }
        state = next
        return out
    }

    /// The word's hold (nil: no label seen for it), for the finalized word that replaces it (SteadyLabels.carry).
    func hold(of id: Int) -> LabelHold? { state[id] }
}
