import Foundation

/// What a person's page shows of one transcript: their longest turn there, as the start of its first paragraph (≤ 120
/// characters, `Snippets.excerpt`), the id of that turn's first paragraph (where the card opens: `TranscriptSearchContext`
/// steps through turn starts only) and how many turns they have there.
nonisolated struct PersonQuote: Sendable, Equatable {
    var text: String
    var turnStart: UUID
    var turns: Int
}

/// Pure helpers of the person page (PersonPageModel reads the transcripts on the main actor, these run off it): a
/// turn is consecutive paragraphs of one of the person's speakers (usually one speaker per transcript, two when they
/// were split); their longest by words is quoted, the earliest on a tie.
/// The page's recurring topics (NLTagger over Gemma's Topics lines, ranked by lift) were removed in FED-12; the
/// algorithm is in the commit before "FED-12: Person pages no longer show topics" (README › People).
nonisolated enum PersonDigest {
    /// One transcript's segments and the person's speakers there, read on the main actor.
    struct QuoteSource: Sendable {
        var id: UUID
        var speakers: Set<Int>
        var segments: [SearchDocument.Segment]
    }

    // MARK: Quotes

    static func quote(_ segments: [SearchDocument.Segment], speakers: Set<Int>) -> PersonQuote? {
        var best: (text: String, words: Int, start: UUID)?
        var turns = 0
        var i = 0
        while i < segments.count {
            guard let speaker = segments[i].speakerIndex, speakers.contains(speaker) else { i += 1; continue }
            let start = segments[i].id
            var parts: [String] = []
            while i < segments.count, segments[i].speakerIndex == speaker {
                parts.append(segments[i].text)
                i += 1
            }
            turns += 1
            let text = parts.joined(separator: " ")
            let words = text.split(whereSeparator: \.isWhitespace).count
            if words > (best?.words ?? 0) { best = (text, words, start) }
        }
        guard let best else { return nil }
        return PersonQuote(text: Snippets.excerpt(of: best.text, around: nil), turnStart: best.start, turns: turns)
    }

    /// Off the main actor: under NonisolatedNonsendingByDefault a plain `nonisolated async` function would run on the
    /// caller's actor (the main actor), so `@concurrent` is what moves the work to the global executor.
    @concurrent static func quotesInBackground(_ sources: [QuoteSource]) async -> [(id: UUID, quote: PersonQuote?)] {
        sources.map { ($0.id, quote($0.segments, speakers: $0.speakers)) }
    }
}
