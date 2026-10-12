import Foundation

/// Bookmarks (FED-14): moments the user marks while recording, with the card's bookmark button, the Live Activity's,
/// or the Action Button (any start from outside the app) pressed while a recording runs. Stored as seconds from the
/// recording's start (`Recording.bookmarks`, the words' scale). The transcript highlights each one's sentence (`places`)
/// and lists them in a folded Bookmarks row; the exports write a line above the paragraph; Gemma is told which
/// paragraphs they are, so the summary covers them. (Gemma also titled each one until October 2026; the titles didn't
/// work, FED-77.)
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

    /// A bookmarked sentence: the one being spoken at the press, in its paragraph (`segmentID`), as character offsets
    /// into that paragraph's text (`range`), and its text (the Bookmarks row's snippet).
    struct Place: Sendable, Equatable, Identifiable {
        var time: TimeInterval          // the first bookmark on the sentence
        /// Every bookmark on the sentence, in time order: a long one pressed twice is one place (FED-73).
        var marks: [TimeInterval]
        var segmentID: UUID
        var range: Range<Int>?          // nil: the sentence wasn't found in the paragraph's text (no highlight)
        var sentence: String
        /// Where the sentence starts in its paragraph, 0...1 (the Bookmarks row scrolls a long paragraph that far).
        var position: Double
        var id: TimeInterval { time }
    }

    /// A press within this of a new sentence's first word marks the sentence that just ended: people press after
    /// hearing what matters, and the next sentence has barely begun.
    static let justEnded: TimeInterval = 1.5

    /// The bookmarked sentences (`Place`), in time order, each once: two bookmarks on one sentence (a long one, pressed
    /// twice) are one place at the first one's time; the list showed the same sentence twice (FED-73). A sentence ends
    /// at a word ending in ".", "?", "!" or "…", or at its paragraph's end (it never spans two speakers); a bookmark
    /// takes the sentence whose words were being said (the last word starting at or before it), or the one before when
    /// the press came within `justEnded` of that sentence's start (also across a speaker change). Paragraphs are their
    /// words joined by single spaces (TranscriptAligner.fold), so a sentence's offsets are its words' (a short one said
    /// twice in a paragraph, "Okay.", is the bookmarked one, not the first); when Edit Text or a pass left the text and
    /// the words apart, the sentence is searched for, and without a match there is no highlight; the list still shows it.
    static func places(_ marks: [TimeInterval], words: [TranscriptWord], segments: [TranscriptSegment]) -> [Place] {
        guard !marks.isEmpty, !words.isEmpty, !segments.isEmpty else { return [] }
        // Each word's paragraph, walking both in time order (as the exports do), and its offset in the paragraph's text.
        var paragraphOf: [Int] = []
        var offsetOf: [Int] = []
        var segment = 0, offset = 0
        for word in words {
            let before = segment
            while segment + 1 < segments.count, word.start >= segments[segment + 1].start - 0.001 { segment += 1 }
            if segment != before { offset = 0 }
            paragraphOf.append(segment)
            offsetOf.append(offset)
            offset += word.text.count + 1
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
        func joined(_ span: ClosedRange<Int>) -> String {
            words[span].map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        var places: [Place] = []
        var placeOf: [Int: Int] = [:]                       // sentence index → its place
        for mark in marks.sorted() {
            let word = words.lastIndex { $0.start <= mark } ?? 0
            var sentence = sentences.firstIndex { $0.contains(word) } ?? 0
            if sentence > 0, mark - words[sentences[sentence].lowerBound].start < justEnded { sentence -= 1 }
            if let index = placeOf[sentence] {
                places[index].marks.append(mark)
                continue
            }
            let span = sentences[sentence]
            let paragraph = segments[paragraphOf[span.lowerBound]]
            let text = joined(span)
            let range = Self.range(of: text, in: paragraph.text, at: offsetOf[span.lowerBound])
            let position = range.map { Double($0.lowerBound) / Double(max(1, paragraph.text.count)) } ?? 0
            placeOf[sentence] = places.count
            places.append(Place(time: mark, marks: [mark], segmentID: paragraph.id, range: range, sentence: text,
                                position: position))
        }
        return places
    }

    /// `sentence` in `paragraph` as character offsets: at its words' offset when it is there, else the first match.
    private static func range(of sentence: String, in paragraph: String, at offset: Int) -> Range<Int>? {
        if offset + sentence.count <= paragraph.count {
            let start = paragraph.index(paragraph.startIndex, offsetBy: offset)
            let end = paragraph.index(start, offsetBy: sentence.count)
            if paragraph[start..<end] == sentence { return offset..<offset + sentence.count }
        }
        guard let found = paragraph.range(of: sentence) else { return nil }
        let lower = paragraph.distance(from: paragraph.startIndex, to: found.lowerBound)
        return lower..<lower + paragraph.distance(from: found.lowerBound, to: found.upperBound)
    }

    /// The paragraphs the bookmarks' sentences are found in are final: the full-accuracy words pass has run and the
    /// speakers are final. Before that each step after Stop rewrites them, and the highlights jumped from the live
    /// words to each pass's (FED-73). The vocabulary pass after them only swaps words in place: the sentences are found
    /// again by time, the same ones, and their highlight stays through it (RecordingDetailView.bookmarkRanges,
    /// ChangeFlashText); afterwards only the user's own corrections rewrite the text.
    @MainActor
    static func paragraphsAreFinal(_ recording: Recording) -> Bool {
        recording.wordsRefined && recording.speakerStatus == .done
    }

    /// "Bookmark · 3:21", "Bookmarks · 3:21, 7:05": the line above a paragraph, in the exports.
    static func line(_ times: [TimeInterval]) -> String {
        let clocks = times.map(TranscriptExport.clock).joined(separator: ", ")
        return times.count == 1 ? String(localized: "Bookmark · \(clocks)") : String(localized: "Bookmarks · \(clocks)")
    }
}
