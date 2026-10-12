import Foundation

/// Bookmarks (FED-14): moments the user marks while recording, with the card's bookmark button, the Live Activity's,
/// or the Action Button (any start from outside the app) pressed while a recording runs. Stored as seconds from the
/// recording's start (`Recording.bookmarks`, the words' scale). The transcript shows each above the paragraph it falls
/// in, the exports write the same line, and Gemma is told which paragraphs they are, so the summary covers them.
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

    /// "Bookmark · 3:21", "Bookmarks · 3:21, 7:05": the line above a paragraph, in the card and the exports.
    static func line(_ times: [TimeInterval]) -> String {
        let clocks = times.map(TranscriptExport.clock).joined(separator: ", ")
        return times.count == 1 ? String(localized: "Bookmark · \(clocks)") : String(localized: "Bookmarks · \(clocks)")
    }
}
