import SwiftUI

/// Highlighted text for search results and the transcript opened from one: hits in the tint colour, semibold
/// (size-preserving: the run keeps the surrounding `.font`, unlike setting the `font` attribute), on a light tint
/// background. Built as one AttributedString: `Text + Text` is deprecated in iOS 26.
enum SearchHighlight {
    static func attributed(_ text: String, _ ranges: [Range<String.Index>]) -> AttributedString {
        let tint = Color.accentColor
        var result = AttributedString(text)
        for range in ranges {
            // Character offsets map String ranges onto the AttributedString built from the same text.
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let start = result.characters.index(result.startIndex, offsetBy: lower)
            let end = result.characters.index(start, offsetBy: length)
            result[start..<end].inlinePresentationIntent = .stronglyEmphasized
            result[start..<end].foregroundColor = tint
            result[start..<end].backgroundColor = tint.opacity(0.16)
        }
        return result
    }

    /// `Text` with highlighted ranges; plain `Text(verbatim:)` without any.
    static func text(_ string: String, _ ranges: [Range<String.Index>]) -> Text {
        ranges.isEmpty ? Text(verbatim: string) : Text(attributed(string, ranges))
    }

    /// Only the matched part bold (suggestion rows).
    static func bold(_ string: String, _ range: Range<String.Index>?) -> Text {
        guard let range else { return Text(verbatim: string) }
        var result = AttributedString(string)
        let start = result.characters.index(result.startIndex, offsetBy: string.distance(from: string.startIndex, to: range.lowerBound))
        let end = result.characters.index(start, offsetBy: string.distance(from: range.lowerBound, to: range.upperBound))
        result[start..<end].inlinePresentationIntent = .stronglyEmphasized
        return Text(result)
    }
}

/// What a transcript opened from a search result highlights: the typed words, the speakers whose names matched, and
/// the result's snippet paragraph to start at. Also what the card's Find highlights (its words alone). Nonisolated: the
/// paragraphs with hits are found off the main actor (`find`).
nonisolated struct TranscriptSearchContext: Equatable, Sendable {
    var terms: [String]
    var speakers: Set<Int>
    var firstHit: UUID?

    func highlights(in text: String) -> [Range<String.Index>] {
        terms.isEmpty ? [] : Snippets.highlightRanges(terms: terms, in: text)
    }

    /// The paragraphs "n of m" steps through: those containing a term; with no terms (a person token alone), the
    /// turns of the matched speakers.
    func hits(in segments: [TranscriptSegment]) -> [UUID] {
        if !terms.isEmpty {
            return segments.filter { !highlights(in: $0.text).isEmpty }.map(\.id)
        }
        return segments.indices.filter { i in
            guard let speaker = segments[i].speakerIndex, speakers.contains(speaker) else { return false }
            return i == 0 || segments[i - 1].speakerIndex != speaker
        }
        .map { segments[$0].id }
    }

    /// The hits and which of them is current: `keep` while it is still a hit, else the result's paragraph
    /// (`firstHit`), else, like Safari's Find on Page, the first hit at or below the top of what is on screen (`visible`:
    /// the paragraphs on screen), else the first. Off the main actor: every paragraph's text is folded and searched,
    /// which on a long transcript is more than a keystroke's frame.
    @concurrent
    func find(in segments: [TranscriptSegment], keep: UUID?, visible: Set<UUID>) async -> (hits: [UUID], index: Int) {
        let hits = hits(in: segments)
        if let keep, let index = hits.firstIndex(of: keep) { return (hits, index) }
        if let firstHit, let index = hits.firstIndex(of: firstHit) { return (hits, index) }
        guard !visible.isEmpty, let top = segments.firstIndex(where: { visible.contains($0.id) }) else { return (hits, 0) }
        let below = Set(segments[top...].map(\.id))
        return (hits, hits.firstIndex(where: { below.contains($0) }) ?? 0)
    }
}
