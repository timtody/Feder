import Foundation

/// `TranscriptAligner.speakers(words:turns:labelledUntil:)` (live: with smoothing) for the growing live transcript, kept
/// up to date incrementally. Live labelling runs several times per second on the main actor, and the full pass grows with
/// the transcript (2.6 ms per call at 30 minutes on an M5 Mac). A new snapshot of live turns only re-assigns the words it
/// can reach: words ending after the earliest change (usually the ongoing turn growing at the end) and words in silence
/// gaps whose nearest turn midpoint could now be a changed turn. The labels are identical to the full pass, always
/// (randomized equivalence test in the live latency harness). Words only ever grow at the end.
nonisolated struct LiveSpeakers {
    /// Per word: what TranscriptAligner.speakers returns for the words of the last update (nil = not labelled yet).
    private(set) var labels: [Int?] = []

    private var turns: [SpeakerTurn] = []
    private var index = TurnIndex([])
    private var labelledUntil: TimeInterval = -.infinity
    private var raw: [Int] = []                   // assignment of the labelled words (the first raw.count), unsmoothed
    private var maxEnd: [TimeInterval] = []       // running maximum of the labelled words' ends
    private var maxReach: [TimeInterval] = []     // running maximum over gap words of midpoint + nearest-turn distance

    /// Updates `labels` for `words` (those of the last update plus any appended) and returns the first index whose label
    /// changed or is new (`words.count` when none).
    mutating func update(words: [TranscriptWord], turns: [SpeakerTurn], labelledUntil until: TimeInterval) -> Int {
        let grows = until >= labelledUntil
        var from = 0                                   // first labelled word to assign again (0: all)
        if turns != self.turns {
            let next = TurnIndex(turns)
            if grows, !index.isEmpty, !next.isEmpty {
                let change = Self.change(from: index.sorted, to: next.sorted)
                from = min(TranscriptAligner.firstIndex(in: maxEnd) { $0 >= change.overlap },
                           TranscriptAligner.firstIndex(in: maxReach) { $0 >= change.midpoint })
            }
            self.turns = turns
            index = next
        } else if grows {
            from = raw.count
        }
        // Words ending after `until`, and all words after the first of them, stay unlabelled (as in the full pass). The
        // labelled words of the last update ended before the old, lower bound.
        let labelled = index.isEmpty ? 0 : (words[(grows ? raw.count : 0)...].firstIndex { $0.end > until } ?? words.count)
        labelledUntil = until
        from = min(from, raw.count, labelled)
        raw.removeSubrange(from...)
        maxEnd.removeSubrange(from...)
        maxReach.removeSubrange(from...)
        for word in words[from..<labelled] {
            let (speaker, nearest) = index.assignment(of: word)
            raw.append(speaker)
            maxEnd.append(max(maxEnd.last ?? -.infinity, word.end))
            // + 1 µs: midpoint + distance can round a few ulps below the nearest turn's own midpoint.
            let reach = nearest.map { (word.start + word.end) / 2 + $0 + 1e-6 } ?? -.infinity
            maxReach.append(max(maxReach.last ?? -.infinity, reach))
        }
        // Smoothing looks at both neighbours, and the old last labelled word may have become an inner one.
        let smoothFrom = max(0, from - 1)
        let old = Array(labels[smoothFrom...])
        labels.removeSubrange(smoothFrom...)
        for i in smoothFrom..<labelled { labels.append(smoothed(at: i)) }
        labels += repeatElement(nil, count: words.count - labelled)
        for (k, label) in labels[smoothFrom...].enumerated() where k >= old.count || label != old[k] { return smoothFrom + k }
        return words.count
    }

    /// The labels the full pass gives `more` when it follows the words of the last update (the provisional words after
    /// the finalized ones), without changing anything here.
    func labels(continuing more: [TranscriptWord]) -> [Int?] {
        var out = [Int?](repeating: nil, count: more.count)
        // A finalized word beyond `labelledUntil` leaves everything after it unlabelled.
        guard !index.isEmpty, raw.count == labels.count else { return out }
        let labelled = more.firstIndex { $0.end > labelledUntil } ?? more.count
        let assigned = more[..<labelled].map { index.assignment(of: $0).speaker }
        for j in assigned.indices {
            let left = j > 0 ? assigned[j - 1] : raw.last           // the neighbours in words + more
            let inner = left != nil && j + 1 < assigned.count
            out[j] = inner && left == assigned[j + 1] && assigned[j] != left ? left : assigned[j]
        }
        return out
    }

    /// TranscriptAligner.smoothed for the labelled word `i`, from the assignments.
    private func smoothed(at i: Int) -> Int {
        guard i > 0, i + 1 < raw.count, raw[i - 1] == raw[i + 1], raw[i] != raw[i - 1] else { return raw[i] }
        return raw[i - 1]
    }

    /// Where two turn lists (sorted by start) differ, compared position by position: `overlap` is the earliest time from
    /// which a word's overlaps with them can differ (a turn that only changed its end, usually the ongoing one, counts
    /// from the earlier of its two ends; any other difference from its start), `midpoint` the earliest midpoint of a turn
    /// that differs (it may now be, or no longer be, the nearest turn of a word in a silence gap). A word ending before
    /// `overlap` keeps its speaker if a turn overlaps it, and also if none does but its nearest turn's distance reaches
    /// only to before `midpoint`: every turn that differs is then strictly farther away or doesn't touch it.
    private static func change(from old: [SpeakerTurn], to new: [SpeakerTurn]) -> (overlap: TimeInterval, midpoint: TimeInterval) {
        var overlap = TimeInterval.infinity, midpoint = TimeInterval.infinity
        for p in 0..<max(old.count, new.count) {
            let a = p < old.count ? old[p] : nil
            let b = p < new.count ? new[p] : nil
            guard a != b else { continue }
            if let a, let b, a.start == b.start, a.speakerIndex == b.speakerIndex {
                overlap = min(overlap, a.end, b.end)
            } else {
                overlap = min(overlap, a?.start ?? .infinity, b?.start ?? .infinity)
            }
            for turn in [a, b] {
                if let turn { midpoint = min(midpoint, (turn.start + turn.end) / 2) }
            }
        }
        return (overlap, midpoint)
    }
}
