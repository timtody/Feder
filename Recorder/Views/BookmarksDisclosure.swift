import SwiftUI

/// The transcript's bookmarks (FED-14) folded into one "Bookmarks" row under the Summary row, in its style (the system's
/// `DisclosureGroup`, subheadline, the count in secondary); only with bookmarks. Opened, a row per bookmark: its time,
/// Gemma's short title when there is one (BookmarkTitler, an experiment), and the bookmarked sentence under it, at
/// most two lines. A tap scrolls to the sentence, which the transcript highlights (BookmarkHighlight); nothing plays.
struct BookmarksDisclosure: View {
    let places: [Bookmarks.Place]
    /// Gemma's titles in the bookmarks' order ([] or "": none).
    let titles: [String]
    let onSelect: (Bookmarks.Place) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    row(place, title: index < titles.count ? titles[index] : "", index: index)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Bookmarks").fontWeight(.semibold)
                Text(verbatim: "\(places.count)").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Bookmarks")
            .accessibilityValue(Text(verbatim: "\(places.count)"))
            .accessibilityIdentifier("Bookmarks")
        }
        .font(.subheadline)
    }

    private func row(_ place: Bookmarks.Place, title: String, index: Int) -> some View {
        Button {
            onSelect(place)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: TranscriptExport.clock(place.time))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    if !title.isEmpty {
                        Text(verbatim: title)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                    }
                    Text(verbatim: place.sentence)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("BookmarkRow.\(index)")
    }
}

/// A bookmarked sentence in the transcript's text: a soft tint behind it and a small bookmark at its start, so a long
/// paragraph (a lecture) shows *what* was bookmarked. Unlike a search hit, neither bold nor coloured text, so the two
/// stay apart in a card opened from a search. Ranges are character offsets into the paragraph (Bookmarks.places).
enum BookmarkHighlight {
    static let tint = Color.accentColor.opacity(0.12)

    /// The paragraph with its search hits (SearchHighlight) and its bookmarked sentences.
    static func text(_ string: String, search: [Range<String.Index>], marks: [Range<Int>]) -> Text {
        let marks = merged(marks, length: string.count)
        guard !marks.isEmpty else { return SearchHighlight.text(string, search) }
        var attributed = SearchHighlight.attributed(string, search)
        for mark in marks { tintBackground(&attributed, mark) }
        // The bookmark in front of each sentence: the text cut there, the symbol between the pieces (VoiceOver reads
        // it as "Bookmark", where it is).
        var pieces: [Text] = []
        var cursor = 0
        for mark in marks {
            pieces.append(Text(slice(attributed, cursor..<mark.lowerBound)))
            let symbol = Text(Image(systemName: "bookmark.fill")).foregroundStyle(.tint)
            pieces.append(Text("\(symbol)\(Text(verbatim: "\u{2009}"))"))
            cursor = mark.lowerBound
        }
        pieces.append(Text(slice(attributed, cursor..<string.count)))
        return pieces.dropFirst().reduce(pieces[0]) { Text("\($0)\($1)") }
    }

    /// The tint behind `range`, except where a search hit's tint already is.
    static func tintBackground(_ attributed: inout AttributedString, _ range: Range<Int>) {
        let start = attributed.characters.index(attributed.startIndex, offsetBy: range.lowerBound)
        let end = attributed.characters.index(start, offsetBy: range.count)
        for run in attributed[start..<end].runs where run.backgroundColor == nil {
            attributed[run.range].backgroundColor = tint
        }
    }

    /// Sorted, overlapping ones joined, clamped to the text; one past its end dropped (a pass rewrote the paragraph
    /// before the places were found again: a shorter text trapped building the clamped range).
    static func merged(_ ranges: [Range<Int>], length: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = max(0, range.lowerBound), upper = min(length, range.upperBound)
            guard lower < upper else { continue }
            let clamped = lower..<upper
            if let last = result.last, clamped.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, clamped.upperBound)
            } else {
                result.append(clamped)
            }
        }
        return result
    }

    private static func slice(_ attributed: AttributedString, _ range: Range<Int>) -> AttributedString {
        let start = attributed.characters.index(attributed.startIndex, offsetBy: range.lowerBound)
        let end = attributed.characters.index(start, offsetBy: range.count)
        return AttributedString(attributed[start..<end])
    }
}
