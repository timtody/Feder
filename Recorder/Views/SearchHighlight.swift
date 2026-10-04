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
/// the result's snippet paragraph to start at.
struct TranscriptSearchContext: Equatable {
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
}
