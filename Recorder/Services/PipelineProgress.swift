import Foundation

/// What happens to a transcript after Stop, as the card shows it (PipelineStatusLine): one step each for the words
/// (Parakeet or Apple's recognizer), the speakers (Nemotron or pyannote, voices, recognition), the vocabulary pass and
/// the title and summary. A step is listed only when it applies to the transcript (an older transcript described by
/// the title sweep has only the summary step). SpeakerIdentifier keeps one per transcript in flight and drops it a
/// moment after the last step, so the row goes away by itself.
nonisolated struct PipelineProgress: Equatable, Sendable {
    enum Step: Int, CaseIterable, Sendable {
        case words, speakers, vocabulary, summary

        var title: String {
            switch self {
            case .words: "Words"
            case .speakers: "Speakers"
            case .vocabulary: "Vocabulary"
            case .summary: "Summary"
            }
        }

        var symbol: String {
            switch self {
            case .words: "text.word.spacing"
            case .speakers: "person.2.wave.2"
            case .vocabulary: "character.book.closed"
            case .summary: "apple.intelligence"
            }
        }
    }

    enum State: Equatable, Sendable {
        case waiting
        case running(since: Date)
        case done(seconds: TimeInterval)
        case failed
    }

    private(set) var states: [Step: State] = [:]

    /// The steps that apply, in order.
    var steps: [Step] { Step.allCases.filter { states[$0] != nil } }

    func state(of step: Step) -> State? { states[step] }

    /// Every listed step has ended (done or failed).
    var isComplete: Bool {
        !states.isEmpty && states.values.allSatisfy {
            switch $0 {
            case .done, .failed: true
            case .waiting, .running: false
            }
        }
    }

    /// Lists `step` as still to come (unless it has begun already; `again`: also after it ran).
    mutating func expect(_ step: Step, again: Bool = false) {
        if states[step] == nil || again { states[step] = .waiting }
    }

    mutating func begin(_ step: Step) {
        states[step] = .running(since: .now)
    }

    /// Ends `step`; the time shown is the time it ran (0 when it never ran, e.g. nothing to do).
    mutating func finish(_ step: Step, failed: Bool = false) {
        guard !failed else { states[step] = .failed; return }
        if case .running(let since) = states[step] {
            states[step] = .done(seconds: Date.now.timeIntervalSince(since))
        } else {
            states[step] = .done(seconds: 0)
        }
    }

    /// Takes `step` off the list (it turned out not to apply).
    mutating func drop(_ step: Step) {
        states[step] = nil
    }
}

/// A stretch of a transcript whose words the pipeline just replaced (the full-accuracy pass, or the vocabulary pass),
/// so the card can show the change for a moment (TranscriptView's flash).
nonisolated struct WordChange: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var vocabulary: Bool                 // a vocabulary term: underlined as well
    var at: Date

    /// The stretches of `new` that read differently from `old` at the same time: words with no old word of the same
    /// text overlapping them (the two passes time words a little differently, so overlap, not equality).
    static func changes(from old: [TranscriptWord], to new: [TranscriptWord], vocabulary: Bool, at: Date = .now) -> [WordChange] {
        guard !old.isEmpty else { return [] }
        var changes: [WordChange] = []
        var j = 0
        for word in new {
            while j < old.count, old[j].end < word.start - 0.3 { j += 1 }
            var same = false
            var k = j
            while k < old.count, old[k].start <= word.end + 0.3 {
                if old[k].end >= word.start - 0.3, VocabularyMerge.normalized(old[k].text) == VocabularyMerge.normalized(word.text) {
                    same = true; break
                }
                k += 1
            }
            guard !same else { continue }
            if let last = changes.last, word.start - last.end < 0.25 {   // the next word, not one in between
                changes[changes.count - 1].end = word.end
            } else {
                changes.append(WordChange(start: word.start, end: word.end, vocabulary: vocabulary, at: at))
            }
        }
        return changes
    }
}
