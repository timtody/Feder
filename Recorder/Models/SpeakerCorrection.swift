import Foundation

/// Hand corrections of a transcript's speakers (the name row's menu and Edit Text's speaker chips): a stretch of the
/// transcript to another speaker (an existing one or a new one: splitting a speaker that is two people), or one speaker
/// merged into another. They change the speaker turns, never the segments directly: the segments are rebuilt from the
/// words and the turns (TranscriptAligner.finalSegments), like after diarization, so a later re-alignment (the
/// vocabulary pass) keeps the correction. Pure functions, unit-testable.
nonisolated enum SpeakerCorrection {
    /// `turns` with the stretch `start..<end` (turn time) given to `speaker`: overlapping turns are cut at its edges.
    /// Every word inside the stretch then overlaps the new turn most; the words outside don't touch it.
    static func assigning(_ turns: [SpeakerTurn], start: TimeInterval, end: TimeInterval, to speaker: Int) -> [SpeakerTurn] {
        var out: [SpeakerTurn] = []
        for turn in turns {
            guard turn.end > start, turn.start < end else { out.append(turn); continue }
            if turn.start < start { out.append(SpeakerTurn(speakerIndex: turn.speakerIndex, start: turn.start, end: start)) }
            if turn.end > end { out.append(SpeakerTurn(speakerIndex: turn.speakerIndex, start: end, end: turn.end)) }
        }
        out.append(SpeakerTurn(speakerIndex: speaker, start: start, end: end))
        return out.sorted { $0.start < $1.start }
    }

    /// Every turn of `from` becomes `into`'s.
    static func merging(_ turns: [SpeakerTurn], _ from: Int, into: Int) -> [SpeakerTurn] {
        turns.map { $0.speakerIndex == from ? SpeakerTurn(speakerIndex: into, start: $0.start, end: $0.end) : $0 }
    }

    /// Old index → new one for the speakers still `used`, closing the gaps in their order (after a merge "Speaker 3"
    /// becomes "Speaker 2", as if it had been found that way). Speakers not used are missing from the map.
    static func compaction(used: Set<Int>) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: used.sorted().enumerated().map { ($1, $0) })
    }

    /// `values` re-keyed by `mapping`, entries of speakers gone dropped.
    static func remapped<Value>(_ values: [Int: Value], _ mapping: [Int: Int]) -> [Int: Value] {
        var out: [Int: Value] = [:]
        for (index, value) in values { if let new = mapping[index] { out[new] = value } }
        return out
    }
}

extension Recording {
    /// The turns a correction starts from: the final diarization's, or, for a transcript diarized before they were
    /// kept, its paragraphs as turns (in the turns' time, i.e. without the words' alignment offset).
    var correctableTurns: [SpeakerTurn] {
        speakerTurns.isEmpty
            ? TranscriptAligner.shifted(TranscriptAligner.turns(from: segments), by: -alignmentOffset)
            : speakerTurns
    }

    /// The segments from the words and the speaker turns, paragraphs keeping their ids (SpeakerIdentifier's final
    /// alignment).
    func realignSegments() {
        segments = TranscriptAligner.finalSegments(words: words, turns: speakerTurns, offset: alignmentOffset,
                                                   keepingIDsOf: segments)
    }

    /// The paragraphs from `id` to the next speaker change: a name row's turn.
    func turnSegments(startingAt id: UUID) -> [TranscriptSegment] {
        let segments = self.segments
        guard let first = segments.firstIndex(where: { $0.id == id }) else { return [] }
        var last = first
        while last + 1 < segments.count, segments[last + 1].speakerIndex == segments[first].speakerIndex { last += 1 }
        return Array(segments[first...last])
    }
}

/// Hand corrections of the words (Edit Text): a paragraph's new text becomes words again. The words are the source of
/// truth (the paragraphs are rebuilt from them and the speaker turns), so an edit lands in `Recording.words`: the
/// tokens the user kept keep their times, new ones share the time between their kept neighbours.
nonisolated enum TextCorrection {
    struct Result: Sendable {
        var words: [TranscriptWord]
        /// Words typed in place of others ("Kofinpro" → "Cofinpro"): offered for Your Words.
        var replacements: [String]
    }

    /// `old` (a paragraph's words) edited into `text`. Kept tokens keep their times; new ones share the time between
    /// their kept neighbours. Where there is none (a word typed right before or after a kept one, or at the paragraph's
    /// start or end), they share that kept word's own time: zero-length words were placed by the nearest turn's
    /// midpoint and could land with the neighbouring speaker.
    static func words(_ old: [TranscriptWord], editedTo text: String, start: TimeInterval, end: TimeInterval) -> Result {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = lcs(old.map(\.text), tokens)                   // pairs (old index, new index), increasing
        var times = [(start: TimeInterval, end: TimeInterval)?](repeating: nil, count: tokens.count)
        for (o, n) in kept { times[n] = (old[o].start, old[o].end) }
        var replacements: [String] = []
        var previous: (o: Int, n: Int)? = nil
        for (o, n) in kept + [(old.count, tokens.count)] {
            let fresh = (previous.map { $0.n + 1 } ?? 0)..<n
            let replaced = (previous.map { $0.o + 1 } ?? 0) < o
            if !fresh.isEmpty {
                var from = previous.flatMap { times[$0.n]?.end } ?? (old.first?.start ?? start)
                var to = o < old.count ? (times[n]?.start ?? old[o].start) : (old.last?.end ?? end)
                let minimum = 0.02 * Double(fresh.count)
                if to - from < minimum {
                    if let previous, let word = times[previous.n] {
                        // After a kept word: its time is shared, the kept word keeps the first part.
                        let piece = max(word.end - word.start, minimum) / Double(fresh.count + 1)
                        times[previous.n] = (word.start, word.start + piece)
                        from = word.start + piece
                        to = max(to, word.start + piece * Double(fresh.count + 1))
                    } else if n < tokens.count, let word = times[n] {
                        // Before the paragraph's first kept word: the kept word keeps the last part.
                        let piece = max(word.end - word.start, minimum) / Double(fresh.count + 1)
                        from = word.start
                        to = word.start + piece * Double(fresh.count)
                        times[n] = (to, max(word.end, to + piece))
                    } else {
                        to = from + minimum
                    }
                }
                let step = (to - from) / Double(fresh.count)
                for (k, index) in fresh.enumerated() {
                    times[index] = (from + step * Double(k), from + step * Double(k + 1))
                }
                if replaced { replacements += fresh.map { tokens[$0] } }
            }
            previous = (o, n)
        }
        let words = tokens.indices.map { index in
            TranscriptWord(text: tokens[index], start: times[index]?.start ?? start, end: times[index]?.end ?? end)
        }
        return Result(words: words, replacements: replacements)
    }

    /// The longest common subsequence of two token lists, as index pairs.
    static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    /// A replacement worth offering for Your Words: letters left after trimming punctuation, at least 3 of them.
    static func vocabularyCandidates(_ replacements: [String], known: [String]) -> [String] {
        var seen = Set(known.map { $0.lowercased() })
        return replacements.compactMap { word in
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard trimmed.count >= 3, trimmed.contains(where: \.isLetter), seen.insert(trimmed.lowercased()).inserted
            else { return nil }
            return trimmed
        }
    }
}

extension Recording {
    /// The words of each paragraph: the paragraphs are folds of consecutive words, so a paragraph's words are those
    /// from its start up to the next paragraph's start.
    func wordRanges() -> [UUID: Range<Int>] {
        Self.wordRanges(words: words, segments: segments)
    }

    /// `wordRanges()` of words and paragraphs already read (off the main actor too).
    nonisolated static func wordRanges(words: [TranscriptWord], segments: [TranscriptSegment]) -> [UUID: Range<Int>] {
        var ranges: [UUID: Range<Int>] = [:]
        var index = 0
        for (s, segment) in segments.enumerated() {
            let next = s + 1 < segments.count ? segments[s + 1].start : .infinity
            while index < words.count, words[index].start < segment.start - 0.001 { index += 1 }
            let first = index
            while index < words.count, words[index].start < next - 0.001 { index += 1 }
            ranges[segment.id] = first..<index
        }
        return ranges
    }
}
