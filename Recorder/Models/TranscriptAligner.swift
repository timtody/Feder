import Foundation

/// Pure functions: words + speaker turns -> displayable segments. No dependencies, unit-testable.
nonisolated enum TranscriptAligner {
    /// Silence between two consecutive words that starts a new paragraph even for the same speaker.
    static let paragraphGap: TimeInterval = 2.0

    /// A live paragraph this long ends at its next sentence end, so the rows redrawn on every live update stay short.
    static let paragraphWords = 60

    /// Ends at a sentence and has at least `paragraphWords` words (`wordCount` when the caller keeps count).
    static func isFull(_ text: String, wordCount: Int? = nil) -> Bool {
        guard let last = text.last, ".?!".contains(last) else { return false }
        return (wordCount ?? text.split(separator: " ").count) >= paragraphWords
    }

    /// Entry point. With no turns every segment has `speakerIndex == nil` (live labels off, undiarized recordings).
    /// Words ending after `labelledUntil` (audio the live diarizer has not processed yet) stay unlabelled instead of
    /// borrowing the nearest turn. With island smoothing (see `speakers`): the live labels, and the live labels
    /// re-applied to the full-accuracy words.
    static func segments(words: [TranscriptWord], turns: [SpeakerTurn], labelledUntil: TimeInterval = .infinity) -> [TranscriptSegment] {
        fold(words: words, speakers: speakers(words: words, turns: turns, labelledUntil: labelledUntil))
    }

    /// One speaker per word (what `segments` folds): nil for every word without turns, and for words ending after
    /// `labelledUntil`. `smoothing` flips one-word islands between two agreeing neighbours (`smoothed`): neutral on live
    /// labels, harmful on the final ones (see `finalSpeakers`).
    static func speakers(words: [TranscriptWord], turns: [SpeakerTurn], labelledUntil: TimeInterval = .infinity,
                         smoothing: Bool = true) -> [Int?] {
        let labelled = turns.isEmpty ? 0 : (words.firstIndex { $0.end > labelledUntil } ?? words.count)
        let labels = assign(words: Array(words[..<labelled]), turns: turns)
        return (smoothing ? smoothed(labels) : labels).map { Optional($0) }
            + Array(repeating: nil, count: words.count - labelled)
    }

    /// The final speakers after Stop: the diarizer's `turns` moved by `offset` (the words' FileTranscript
    /// alignmentOffset, e.g. -0.12 s for Parakeet's words), without island smoothing. Measured on DiarBench (Nemotron
    /// turns, Parakeet words): smoothing erased real one-word turns (2.43 -> 2.22 % wrong words without it; in turns of
    /// at most 3 words 15.3 -> 10.5 %), and the offset took 2.22 -> 1.77 %.
    static func finalSpeakers(words: [TranscriptWord], turns: [SpeakerTurn], offset: TimeInterval) -> [Int?] {
        speakers(words: words, turns: shifted(turns, by: offset), smoothing: false)
    }

    /// `finalSpeakers` folded into paragraphs, keeping the ids of `previous` by time (`keepingIDsByOverlap`).
    static func finalSegments(words: [TranscriptWord], turns: [SpeakerTurn], offset: TimeInterval,
                              keepingIDsOf previous: [TranscriptSegment] = []) -> [TranscriptSegment] {
        keepingIDsByOverlap(of: previous,
                            in: fold(words: words, speakers: finalSpeakers(words: words, turns: turns, offset: offset)))
    }

    /// `turns` with `offset` seconds added to their times.
    static func shifted(_ turns: [SpeakerTurn], by offset: TimeInterval) -> [SpeakerTurn] {
        guard offset != 0 else { return turns }
        return turns.map { SpeakerTurn(speakerIndex: $0.speakerIndex, start: $0.start + offset, end: $0.end + offset) }
    }

    /// Labelled segments as speaker turns, e.g. to carry live labels over to re-transcribed words.
    static func turns(from segments: [TranscriptSegment]) -> [SpeakerTurn] {
        segments.compactMap { segment in
            segment.speakerIndex.map { SpeakerTurn(speakerIndex: $0, start: segment.start, end: segment.end) }
        }
    }

    /// Each segment takes the id of the `previous` segment that started at the same time; every id is used once.
    static func keepingIDs(of previous: [TranscriptSegment], in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !previous.isEmpty else { return segments }
        var idByStart: [TimeInterval: UUID] = [:]
        for segment in previous where idByStart[segment.start] == nil { idByStart[segment.start] = segment.id }
        var used = Set<UUID>()
        return segments.map { segment in
            var segment = segment
            if let id = idByStart[segment.start], used.insert(id).inserted { segment.id = id }
            return segment
        }
    }

    /// After Stop: segments take the ids of the `previous` segments they overlap (or start with), each id used once,
    /// the largest overlaps first, so a paragraph a pass rewrites stays the same view. The passes after Stop
    /// gave every paragraph a new id, and the card removed every row and inserted new ones: with the speakers' re-split
    /// the whole text faded out and flew in again from the bottom. Exact starts (`keepingIDs`) don't survive Parakeet,
    /// which re-times every word. A split keeps the id on its larger part; only real new paragraphs get a new one.
    static func keepingIDsByOverlap(of previous: [TranscriptSegment],
                                    in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !previous.isEmpty, !segments.isEmpty else { return segments }
        let old = previous.sorted { $0.start < $1.start }
        // Every overlapping pair (old segments sorted by start, so each new one only looks at its neighbours), then
        // the largest overlaps first: a split keeps the id on its larger part.
        var pairs: [(new: Int, old: Int, overlap: TimeInterval)] = []
        var first = 0
        for (n, segment) in segments.enumerated() {
            while first < old.count, old[first].end < segment.start { first += 1 }
            var o = first
            while o < old.count, old[o].start <= segment.end {
                let overlap = min(old[o].end, segment.end) - max(old[o].start, segment.start)
                if overlap > 0 || old[o].start == segment.start { pairs.append((n, o, max(overlap, 0))) }
                o += 1
            }
        }
        pairs.sort { $0.overlap > $1.overlap || ($0.overlap == $1.overlap && $0.new < $1.new) }
        var result = segments
        var takenNew = Set<Int>(), takenOld = Set<Int>()
        for pair in pairs where !takenNew.contains(pair.new) && !takenOld.contains(pair.old) {
            result[pair.new].id = old[pair.old].id
            takenNew.insert(pair.new)
            takenOld.insert(pair.old)
        }
        return result
    }

    static func overlap(_ word: TranscriptWord, _ turn: SpeakerTurn) -> TimeInterval {
        max(0, min(word.end, turn.end) - max(word.start, turn.start))
    }

    /// Majority overlap: the turn with the largest intersection wins; a word touching no turn (silence gap,
    /// before the first turn, after the last) takes the turn whose midpoint is nearest to its own midpoint (`TurnIndex`).
    static func assign(words: [TranscriptWord], turns: [SpeakerTurn]) -> [Int] {
        let index = TurnIndex(turns)
        guard !index.isEmpty else { return words.map { _ in 0 } }
        return words.map { index.assignment(of: $0).speaker }
    }

    /// Binary search: the first index whose element satisfies `predicate`, for an array partitioned false...true.
    static func firstIndex<T>(in array: [T], where predicate: (T) -> Bool) -> Int {
        var low = 0, high = array.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(array[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// A single word attributed to X but surrounded on both sides by Y becomes Y (removes one-word flips).
    static func smoothed(_ speakers: [Int]) -> [Int] {
        guard speakers.count >= 3 else { return speakers }
        var result = speakers
        for i in 1..<(speakers.count - 1) where speakers[i - 1] == speakers[i + 1] && speakers[i] != speakers[i - 1] {
            result[i] = speakers[i - 1]
        }
        return result
    }

    /// Folds consecutive words with the same speaker into one segment; also breaks at silences > paragraphGap.
    static func fold(words: [TranscriptWord], speakers: [Int?]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for (word, speaker) in zip(words, speakers) {
            if let last = out.last, last.speakerIndex == speaker, word.start - last.end <= paragraphGap {
                out[out.count - 1].text += " " + word.text
                out[out.count - 1].end = max(last.end, word.end)
            } else {
                out.append(TranscriptSegment(speakerIndex: speaker, text: word.text, start: word.start, end: word.end))
            }
        }
        return out
    }
}

/// Speaker turns prepared for assigning words to them, built once per set of turns: live labelling assigns words several
/// times per second on the main actor, so each word only looks at the turns near it (binary searches) instead of
/// scanning from the first turn: O((W + T) log T), not O(W * T). The result is identical to a full scan, including ties
/// (earliest turn by start wins), for overlapping turns too.
nonisolated struct TurnIndex {
    let sorted: [SpeakerTurn]                     // by start
    private let maxEnd: [TimeInterval]            // maxEnd[i] = latest end among sorted[0...i]
    private let mids: [TimeInterval]
    private let byMid: [Int]                      // indices into `sorted` by midpoint (ties: earlier turn first)

    init(_ turns: [SpeakerTurn]) {
        sorted = turns.sorted { $0.start < $1.start }
        // maxEnd is non-decreasing even when turns overlap (ends aren't), so every turn before the first i with
        // maxEnd[i] > word.start ends at or before the word and cannot overlap it.
        var maxEnd: [TimeInterval] = []
        maxEnd.reserveCapacity(sorted.count)
        for turn in sorted { maxEnd.append(max(maxEnd.last ?? -.infinity, turn.end)) }
        self.maxEnd = maxEnd
        let mids = sorted.map { ($0.start + $0.end) / 2 }
        self.mids = mids
        byMid = sorted.indices.sorted { mids[$0] != mids[$1] ? mids[$0] < mids[$1] : $0 < $1 }
    }

    var isEmpty: Bool { sorted.isEmpty }

    /// The word's speaker (the index must not be empty) and, when no turn overlaps the word, how far the midpoint of the
    /// turn it took is from its own (nil when a turn overlaps it). LiveSpeakers uses that distance to tell which words a
    /// changed turn can reach.
    func assignment(of word: TranscriptWord) -> (speaker: Int, nearest: TimeInterval?) {
        var best: SpeakerTurn?
        var bestOverlap: TimeInterval = 0
        for turn in sorted[TranscriptAligner.firstIndex(in: maxEnd, where: { $0 > word.start })...] {
            if turn.start >= word.end { break }          // sorted by start: nothing later can overlap
            let o = TranscriptAligner.overlap(word, turn)
            if o > bestOverlap { best = turn; bestOverlap = o }
        }
        if let best { return (best.speakerIndex, nil) }
        let mid = (word.start + word.end) / 2
        // Nearest midpoints are the last one below `mid` and the first one at or above it; of equal midpoints the
        // earliest turn is taken, as `sorted.min` would.
        let above = TranscriptAligner.firstIndex(in: byMid, where: { mids[$0] >= mid })
        var candidates: [Int] = []
        if above > 0 {
            let belowMid = mids[byMid[above - 1]]
            candidates.append(byMid[TranscriptAligner.firstIndex(in: byMid, where: { mids[$0] >= belowMid })])
        }
        if above < byMid.count { candidates.append(byMid[above]) }
        let nearest = candidates.min { a, b in
            let da = abs(mids[a] - mid), db = abs(mids[b] - mid)
            return da != db ? da < db : a < b
        }
        guard let nearest else { return (0, nil) }        // unreachable: the index is not empty
        return (sorted[nearest].speakerIndex, abs(mids[nearest] - mid))
    }
}
