import Foundation

/// Bookmarks (FED-14): moments the user marks while recording, with the card's bookmark button, the Live Activity's,
/// or the Action Button (any start from outside the app) pressed while a recording runs. Stored as seconds from the
/// recording's start (`Recording.bookmarks`, the words' scale). The transcript highlights each one's sentence (`places`)
/// and lists them in a folded Bookmarks row; the exports write a line above the paragraph; Gemma is told which
/// paragraphs they are, so the summary covers them, and titles each (BookmarkTitler).
nonisolated enum Bookmarks {
    /// Presses closer than this are one bookmark: a double press, or the card's and the Live Activity's at once.
    static let minimumGap: TimeInterval = 1

    /// `marks` with `time` added, sorted; nil when one is already within `minimumGap` of it.
    static func adding(_ time: TimeInterval, to marks: [TimeInterval]) -> [TimeInterval]? {
        guard !marks.contains(where: { abs($0 - time) < minimumGap }) else { return nil }
        return (marks + [time]).sorted()
    }

    /// The bookmarks by paragraph (segment id), each paragraph's sorted. A bookmark falls in the last paragraph that
    /// starts at or before it: the words being said when it was pressed, or the pause after them. One before the
    /// first paragraph (pressed before anyone spoke) goes to the first.
    static func byParagraph(_ marks: [TimeInterval], in segments: [TranscriptSegment]) -> [UUID: [TimeInterval]] {
        guard let first = segments.first else { return [:] }
        var result: [UUID: [TimeInterval]] = [:]
        for mark in marks.sorted() {
            let segment = segments.last { $0.start <= mark } ?? first
            result[segment.id, default: []].append(mark)
        }
        return result
    }

    /// A bookmark's sentence: the one being spoken at the press, in its paragraph (`segmentID`), as character offsets
    /// into that paragraph's text (`range`), and its text (the Bookmarks row's snippet, Gemma's title's source).
    struct Place: Sendable, Equatable, Identifiable {
        var time: TimeInterval
        var segmentID: UUID
        var range: Range<Int>?          // nil: the sentence wasn't found in the paragraph's text (no highlight)
        var sentence: String
        /// The sentence before it (also across a speaker change), "" for the first: context for Gemma's title.
        var before: String = ""
        /// Where the sentence starts in its paragraph, 0...1 (the Bookmarks row scrolls a long paragraph that far).
        var position: Double
        var id: TimeInterval { time }
    }

    /// A press within this of a new sentence's first word marks the sentence that just ended: people press after
    /// hearing what matters, and the next sentence has barely begun.
    static let justEnded: TimeInterval = 1.5

    /// Each bookmark's sentence (`Place`), in time order. A sentence ends at a word ending in ".", "?", "!" or "…", or
    /// at its paragraph's end (it never spans two speakers); the bookmark takes the sentence whose words were being
    /// said (the last word starting at or before it), or the one before when the press came within `justEnded` of
    /// that sentence's start (also across a speaker change). Paragraphs are their words joined by single spaces
    /// (TranscriptAligner.fold), so a sentence is found in its paragraph's text by its words; when Edit Text or a pass
    /// left them apart, there is no highlight, and the list still shows the sentence.
    static func places(_ marks: [TimeInterval], words: [TranscriptWord], segments: [TranscriptSegment]) -> [Place] {
        guard !marks.isEmpty, !words.isEmpty, !segments.isEmpty else { return [] }
        // Each word's paragraph, walking both in time order (as the exports do).
        var paragraphOf: [Int] = []
        var segment = 0
        for word in words {
            while segment + 1 < segments.count, word.start >= segments[segment + 1].start - 0.001 { segment += 1 }
            paragraphOf.append(segment)
        }
        // Sentences as word index ranges.
        var sentences: [ClosedRange<Int>] = []
        var start = 0
        for index in words.indices {
            let last = index == words.count - 1 || paragraphOf[index + 1] != paragraphOf[index]
            let text = words[index].text.trimmingCharacters(in: .whitespaces)
            if last || text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") || text.hasSuffix("…") {
                sentences.append(start...index)
                start = index + 1
            }
        }
        return marks.sorted().map { mark in
            let word = words.lastIndex { $0.start <= mark } ?? 0
            var sentence = sentences.firstIndex { $0.contains(word) } ?? 0
            if sentence > 0, mark - words[sentences[sentence].lowerBound].start < justEnded { sentence -= 1 }
            func text(_ span: ClosedRange<Int>) -> String {
                words[span].map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            let span = sentences[sentence]
            let paragraph = segments[paragraphOf[span.lowerBound]]
            let before = sentence > 0 ? text(sentences[sentence - 1]) : ""
            let text = text(span)
            let found = paragraph.text.range(of: text)
            let range = found.map { paragraph.text.distance(from: paragraph.text.startIndex, to: $0.lowerBound)
                ..< paragraph.text.distance(from: paragraph.text.startIndex, to: $0.upperBound) }
            let position = range.map { Double($0.lowerBound) / Double(max(1, paragraph.text.count)) } ?? 0
            return Place(time: mark, segmentID: paragraph.id, range: range, sentence: text, before: before,
                         position: position)
        }
    }

    /// The text the bookmarks' sentences are found in is final: the full-accuracy words pass has run, the speakers are
    /// final, and the vocabulary pass is done. Before that each step after Stop rewrites the paragraphs; afterwards
    /// only the user's own corrections do (FED-73).
    @MainActor
    static func textIsFinal(_ recording: Recording) -> Bool {
        recording.wordsRefined && recording.speakerStatus == .done && !recording.vocabularyPending
    }

    /// "Bookmark · 3:21", "Bookmarks · 3:21, 7:05": the line above a paragraph, in the exports.
    static func line(_ times: [TimeInterval]) -> String {
        let clocks = times.map(TranscriptExport.clock).joined(separator: ", ")
        return times.count == 1 ? String(localized: "Bookmark · \(clocks)") : String(localized: "Bookmarks · \(clocks)")
    }
}
