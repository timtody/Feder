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
