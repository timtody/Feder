import Foundation

// Pure search core for the Transcripts screen. Foundation only, no SwiftUI, no SwiftData: `TranscriptSearchModel`
// snapshots each Recording into a `SearchDocument.Source` (on the main actor), folds it into a `SearchDocument` and runs
// `TranscriptSearch` off the main actor. Matching is case-, diacritic- and width-insensitive ("muller" finds "Müller", "strasse" finds
// "Straße"), substring-based (German compounds: "vertrag" finds "Arbeitsvertrag") with word-start hits preferred.

// MARK: - Folding

nonisolated enum SearchFolding {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Locale-independent fold. Can change the length ("ß" -> "ss", "ﬁ" -> "fi"), so folded offsets are never used to
    /// index the original string: highlights are found again in the original with `range(of:options:)`.
    static func fold(_ s: String) -> String { s.folding(options: options, locale: nil) }

    static func equal(_ a: String, _ b: String) -> Bool { fold(a) == fold(b) }

    /// All non-overlapping occurrences of `needle` in `haystack` (original indices), at most `limit`.
    static func ranges(of needle: String, in haystack: String, limit: Int = 64) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var from = haystack.startIndex
        while result.count < limit, from < haystack.endIndex,
              let r = haystack.range(of: needle, options: options, range: from..<haystack.endIndex) {
            result.append(r)
            from = r.isEmpty ? haystack.index(after: r.lowerBound) : r.upperBound
        }
        return result
    }

    /// The range starts a word: nothing or a non-letter/non-digit before it.
    static func startsWord(_ r: Range<String.Index>, in s: String) -> Bool {
        guard r.lowerBound > s.startIndex else { return true }
        let before = s[s.index(before: r.lowerBound)]
        return !(before.isLetter || before.isNumber)
    }
}

// MARK: - Tokens and query

nonisolated struct SearchToken: Hashable, Identifiable, Sendable {
    enum Kind: Int, Hashable, Sendable { case person, tag }   // raw order = suggestion order (people first)
    var kind: Kind
    var value: String                                          // display form: "Anna Schmidt", "budget"
    var id: String { "\(kind.rawValue):\(SearchFolding.fold(value))" }
}

nonisolated struct SearchQuery: Sendable, Equatable {
    var people: [String] = []        // person tokens: a named speaker must equal one (folded)
    var tags: [String] = []          // tag tokens: a tag must equal one (folded)
    var tagTerms: [String] = []      // "#bud" typed as text: some tag contains it
    var terms: [String] = []         // free text, AND: each term must be found in title, place, tag, speaker or text

    init(text: String, tokens: [SearchToken] = []) {
        for token in tokens {
            switch token.kind {
            case .person: people.append(token.value)
            case .tag: tags.append(token.value)
            }
        }
        for word in text.split(whereSeparator: \.isWhitespace) {
            if word.hasPrefix("#") {
                let t = String(word.dropFirst())
                if !t.isEmpty { tagTerms.append(t) }
            } else {
                terms.append(String(word))
            }
        }
    }

    var isEmpty: Bool { people.isEmpty && tags.isEmpty && tagTerms.isEmpty && terms.isEmpty }
    /// What the detail transcript highlights when opened from this search (matched speakers are passed separately).
    var highlightTerms: [String] { terms }
}

// MARK: - Documents (immutable snapshot of one Recording)

nonisolated struct SearchDocument: Sendable {
    struct Segment: Sendable {
        var id: UUID
        var text: String
        var start: TimeInterval
        var speakerIndex: Int?
    }

    /// What is read from a Recording on the main actor; the folding happens off it.
    struct Source: Sendable {
        var id: UUID
        var title: String
        var place: String?
        var summary: String?
        var tags: [String]
        var speakerNames: [Int: String]
        var segments: [Segment]
        var key: Int
    }

    let id: UUID
    let title: String
    let place: String?
    let summary: String?                     // the automatic 1-2 sentence summary (TranscriptTitler)
    let tags: [String]
    let speakerNames: [Int: String]          // only names the user gave or recognition set (not "Speaker N")
    let segments: [Segment]
    /// The change key of the Recording it was made from: rebuilt only when that differs.
    let key: Int

    // Precomputed folds.
    fileprivate let foldedTitle: String
    fileprivate let foldedPlace: String
    fileprivate let foldedSummary: String
    fileprivate let foldedTags: [String]
    fileprivate let foldedSpeakers: [(index: Int, folded: String)]
    fileprivate let body: [UInt8]            // folded segment texts, UTF-8, each followed by "\n"
    fileprivate let segmentOffsets: [Int]    // byte offset of each segment in `body`

    init(_ source: Source) {
        self.init(id: source.id, title: source.title, place: source.place, summary: source.summary, tags: source.tags,
                  speakerNames: source.speakerNames, segments: source.segments, key: source.key)
    }

    init(id: UUID, title: String, place: String?, summary: String? = nil, tags: [String], speakerNames: [Int: String],
         segments: [Segment], key: Int) {
        self.id = id
        self.title = title
        self.place = place
        self.summary = summary
        self.tags = tags
        self.speakerNames = speakerNames
        self.segments = segments
        self.key = key
        foldedTitle = SearchFolding.fold(title)
        foldedPlace = place.map(SearchFolding.fold) ?? ""
        foldedSummary = summary.map(SearchFolding.fold) ?? ""
        foldedTags = tags.map(SearchFolding.fold)
        foldedSpeakers = speakerNames.sorted { $0.key < $1.key }.map { ($0.key, SearchFolding.fold($0.value)) }
        var body: [UInt8] = []
        var offsets: [Int] = []
        offsets.reserveCapacity(segments.count)
        for segment in segments {
            offsets.append(body.count)
            body.append(contentsOf: SearchFolding.fold(segment.text).utf8)
            body.append(0x0A)
        }
        self.body = body
        self.segmentOffsets = offsets
    }

    /// Byte offsets of `needle` (already folded, UTF-8) in the folded body, at most `limit`.
    fileprivate func bodyHits(_ needle: [UInt8], limit: Int, wordStartsOnly: Bool = false) -> [Int] {
        guard !needle.isEmpty, body.count >= needle.count else { return [] }
        var hits: [Int] = []
        body.withUnsafeBytes { hay in
            needle.withUnsafeBytes { nee in
                var start = 0
                while hits.count < limit, start <= hay.count - nee.count,
                      let p = memmem(hay.baseAddress! + start, hay.count - start, nee.baseAddress!, nee.count) {
                    let offset = hay.baseAddress!.distance(to: UnsafeRawPointer(p))
                    if !wordStartsOnly || bodyHitStartsWord(offset) { hits.append(offset) }
                    start = offset + nee.count
                }
            }
        }
        return hits
    }

    /// The folded segment `index` contains `needle` (folded UTF-8).
    fileprivate func segment(_ index: Int, contains needle: [UInt8]) -> Bool {
        let lo = segmentOffsets[index]
        let hi = index + 1 < segmentOffsets.count ? segmentOffsets[index + 1] : body.count
        guard !needle.isEmpty, hi - lo >= needle.count else { return false }
        return body.withUnsafeBytes { hay in
            needle.withUnsafeBytes { nee in
                memmem(hay.baseAddress! + lo, hi - lo, nee.baseAddress!, nee.count) != nil
            }
        }
    }

    /// Segment containing body byte `offset` (binary search).
    fileprivate func segmentIndex(atByte offset: Int) -> Int {
        var lo = 0, hi = segmentOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segmentOffsets[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// A body hit starts a word: the folded byte before it is not an ASCII letter/digit and not part of a
    /// multi-byte (non-ASCII) letter.
    fileprivate func bodyHitStartsWord(_ offset: Int) -> Bool {
        guard offset > 0 else { return true }
        let b = body[offset - 1]
        if b < 0x80 { return !((b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)) }
        var lead = offset - 1                                   // non-ASCII: decode the scalar before the hit
        while lead > 0, body[lead] & 0xC0 == 0x80 { lead -= 1 }
        let scalar = String(decoding: body[lead..<offset], as: UTF8.self).unicodeScalars.last
        return !(scalar.map { $0.properties.isAlphabetic || $0.properties.numericType != nil } ?? false)
    }
}

// MARK: - Results

nonisolated struct Snippet: Sendable, Equatable {
    var text: String                          // one paragraph excerpt, with "…" where cut
    var highlights: [Range<String.Index>]     // ranges in `text`
    var segmentID: UUID
    var segmentIndex: Int
    var start: TimeInterval
    var speakerIndex: Int?
}

nonisolated struct SearchResult: Sendable, Identifiable {
    var id: UUID
    var title: String                                 // the document title `titleHighlights` index into
    var titleHighlights: [Range<String.Index>] = []
    var matchedSpeakers: [Int] = []                   // speaker indices whose name matched a token or term
    var matchedTags: [String] = []                    // tags (original spelling) that matched a token or term
    var placeMatched = false
    var snippet: Snippet?
    var summaryExcerpt: String?                       // when only the summary matched a term: an excerpt of it
    var summaryHighlights: [Range<String.Index>] = [] // ranges in `summaryExcerpt`
    var textHitCount = 0                              // occurrences of the snippet's term in the transcript (capped)
    var score = 0                                     // for optional relevance ordering; the list keeps date order
}

// MARK: - Search

nonisolated enum TranscriptSearch {
    static let maxHitsCounted = 99
    /// Terms shorter than this match only at word starts ("an" finds "Anna", "an", not "Stand"); longer terms match
    /// anywhere (German compounds).
    static let substringMinLength = 3

    /// nil = the document does not match. Every token and every term must match (AND).
    static func match(_ doc: SearchDocument, _ query: SearchQuery) -> SearchResult? {
        guard !query.isEmpty else { return SearchResult(id: doc.id, title: doc.title) }
        var result = SearchResult(id: doc.id, title: doc.title)
        var summaryAnchor: Range<String.Index>?

        // Tokens: exact (folded) equality.
        for person in query.people {
            let f = SearchFolding.fold(person)
            let hits = doc.foldedSpeakers.filter { $0.folded == f }.map(\.index)
            guard !hits.isEmpty else { return nil }
            result.matchedSpeakers.append(contentsOf: hits)
            result.score += 50
        }
        for tag in query.tags {
            let f = SearchFolding.fold(tag)
            guard let i = doc.foldedTags.firstIndex(of: f) else { return nil }
            result.matchedTags.append(doc.tags[i])
            result.score += 50
        }
        for t in query.tagTerms {
            let f = SearchFolding.fold(t)
            let hits = doc.foldedTags.indices.filter { doc.foldedTags[$0].contains(f) }
            guard !hits.isEmpty else { return nil }
            result.matchedTags.append(contentsOf: hits.map { doc.tags[$0] })
            result.score += 30
        }

        // Free-text terms: each must be found somewhere.
        var bodyTerms: [(term: String, hits: [Int])] = []
        for term in query.terms {
            let f = SearchFolding.fold(term)
            var found = false
            let wordStartsOnly = term.count < substringMinLength
            func hit(_ original: String) -> [Range<String.Index>] {
                let r = SearchFolding.ranges(of: term, in: original)
                return wordStartsOnly ? r.filter { SearchFolding.startsWord($0, in: original) } : r
            }
            let titleRanges = hit(doc.title)
            if !titleRanges.isEmpty {
                found = true
                result.titleHighlights.append(contentsOf: titleRanges)
                result.score += titleRanges.contains { SearchFolding.startsWord($0, in: doc.title) } ? 40 : 20
            }
            if let place = doc.place, doc.foldedPlace.contains(f), !hit(place).isEmpty {
                found = true; result.placeMatched = true; result.score += 10
            }
            if let summary = doc.summary, doc.foldedSummary.contains(f), let first = hit(summary).first {
                found = true; result.score += 10
                if summaryAnchor == nil { summaryAnchor = first }
            }
            for (i, ft) in doc.foldedTags.enumerated() where ft.contains(f) && !hit(doc.tags[i]).isEmpty {
                found = true
                result.matchedTags.append(doc.tags[i])
                result.score += 30
            }
            for s in doc.foldedSpeakers where s.folded.contains(f) && !hit(doc.speakerNames[s.index] ?? "").isEmpty {
                found = true
                result.matchedSpeakers.append(s.index)
                result.score += 30
            }
            let hits = doc.bodyHits(Array(f.utf8), limit: maxHitsCounted, wordStartsOnly: wordStartsOnly)
            if !hits.isEmpty {
                found = true
                bodyTerms.append((term, hits))
                result.score += hits.contains(where: doc.bodyHitStartsWord) ? 20 : 10
            }
            guard found else { return nil }
        }
        result.matchedSpeakers = Array(Set(result.matchedSpeakers)).sorted()
        result.matchedTags = unique(result.matchedTags)

        if !bodyTerms.isEmpty {
            result.snippet = snippet(doc, bodyTerms: bodyTerms, allTerms: query.terms)
            result.textHitCount = bodyTerms.map(\.hits.count).max() ?? 0
        } else if let speaker = result.matchedSpeakers.first,
                  let i = doc.segments.firstIndex(where: { $0.speakerIndex == speaker }) {
            // Person only: show the first thing that person said.
            let seg = doc.segments[i]
            let text = Snippets.excerpt(of: seg.text, around: nil)
            result.snippet = Snippet(text: text, highlights: [], segmentID: seg.id, segmentIndex: i,
                                     start: seg.start, speakerIndex: seg.speakerIndex)
        } else if let summary = doc.summary, let summaryAnchor {
            // Found in the summary only: show that part of it.
            let text = Snippets.excerpt(of: summary, around: summaryAnchor)
            result.summaryExcerpt = text
            result.summaryHighlights = Snippets.highlightRanges(terms: query.terms, in: text)
        }
        return result
    }

    /// Runs over all documents in order, checking cancellation every 32 documents.
    static func search(_ docs: [SearchDocument], _ query: SearchQuery) -> [SearchResult]? {
        var results: [SearchResult] = []
        for (n, doc) in docs.enumerated() {
            if n % 32 == 0, Task.isCancelled { return nil }
            if let r = match(doc, query) { results.append(r) }
        }
        return results
    }

    // Off the main actor: under NonisolatedNonsendingByDefault a plain `nonisolated async` function would run on the
    // caller's actor (the main actor), so `@concurrent` is what moves the work to the global executor.

    @concurrent static func searchInBackground(_ docs: [SearchDocument], _ query: SearchQuery) async -> [SearchResult]? {
        search(docs, query)
    }

    /// Folds the documents (0.5 ms per 10,000-word transcript on an M5 Mac).
    @concurrent static func documentsInBackground(_ sources: [SearchDocument.Source]) async -> [SearchDocument] {
        sources.map(SearchDocument.init)
    }

    /// Picks the paragraph that contains the most distinct terms (first such, preferring a word-start hit of the
    /// rarest term), then cuts an excerpt around the first hit there and highlights every term in it.
    private static func snippet(_ doc: SearchDocument, bodyTerms: [(term: String, hits: [Int])],
                                allTerms: [String]) -> Snippet? {
        let rarest = bodyTerms.min { $0.hits.count < $1.hits.count }!
        let ordered = rarest.hits.filter(doc.bodyHitStartsWord) + rarest.hits.filter { !doc.bodyHitStartsWord($0) }
        var bestSegment = doc.segmentIndex(atByte: ordered[0])
        if bodyTerms.count > 1 {
            var bestCount = 0
            let needles = bodyTerms.map { Array(SearchFolding.fold($0.term).utf8) }
            for offset in ordered.prefix(40) {
                let si = doc.segmentIndex(atByte: offset)
                let count = needles.filter { doc.segment(si, contains: $0) }.count
                if count > bestCount { bestCount = count; bestSegment = si }
                if count == bodyTerms.count { break }
            }
        }
        let seg = doc.segments[bestSegment]
        let candidates = SearchFolding.ranges(of: rarest.term, in: seg.text)
        let anchor = candidates.first { SearchFolding.startsWord($0, in: seg.text) } ?? candidates.first
        let text = Snippets.excerpt(of: seg.text, around: anchor)
        let highlights = Snippets.highlightRanges(terms: allTerms, in: text)
        return Snippet(text: text, highlights: highlights, segmentID: seg.id, segmentIndex: bestSegment,
                       start: seg.start, speakerIndex: seg.speakerIndex)
    }

    private static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert(SearchFolding.fold($0)).inserted }
    }
}

// MARK: - Snippets and highlight ranges

nonisolated enum Snippets {
    static let ellipsis = "…"

    /// An excerpt of `text` around `hit`: about `before` characters of context before the hit, snapped forward to a
    /// word start, and at most `maxLength` characters in all, snapped back to a word end. "…" marks each cut. Without a
    /// hit it is the paragraph's start. Whitespace runs collapse to one space.
    static func excerpt(of text: String, around hit: Range<String.Index>?, before: Int = 24, maxLength: Int = 120) -> String {
        let hitStart = hit?.lowerBound ?? text.startIndex
        let hitEnd = hit?.upperBound ?? text.startIndex

        // Start: `before` characters back, then forward to the next word start (unless at the paragraph start).
        var start = text.index(hitStart, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        // A hit close to the paragraph start (within the budget plus a few characters): keep the start, no "…".
        if text.distance(from: text.startIndex, to: hitStart) <= before + 8 { start = text.startIndex }
        if start > text.startIndex {
            let previous = text[text.index(before: start)]
            if !previous.isWhitespace {        // mid-word: skip to after the next whitespace, never past the hit
                if let ws = text[start..<hitStart].firstIndex(where: \.isWhitespace) {
                    start = text.index(after: ws)
                } else {
                    start = hitStart
                }
            }
            while start < hitStart, text[start].isWhitespace { start = text.index(after: start) }
        }

        // End: `maxLength` characters from start (at least to the hit's end), then back to a word end.
        let budgetEnd = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
        var end = max(budgetEnd, hitEnd)
        if end < text.endIndex, !text[end].isWhitespace {
            if let ws = text[hitEnd..<end].lastIndex(where: \.isWhitespace) { end = ws }
        }
        while end > hitEnd, end > start, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }

        var body = String(text[start..<end])
        body = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let head = start > text.startIndex ? ellipsis : ""
        let tail = end < text.endIndex ? ellipsis : ""
        return head + body + tail
    }

    /// Ranges of every term in `text`, merged where they overlap, in order.
    static func highlightRanges(terms: [String], in text: String) -> [Range<String.Index>] {
        let all = terms.flatMap { term in
            let r = SearchFolding.ranges(of: term, in: text)
            return term.count < TranscriptSearch.substringMinLength ? r.filter { SearchFolding.startsWord($0, in: text) } : r
        }
        .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in all {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}

// MARK: - Suggestions (people and tags as the user types)

nonisolated struct SuggestionCandidate: Sendable, Hashable {
    var kind: SearchToken.Kind
    var name: String
    var count: Int                  // transcripts that use it: popularity tie-break
}

nonisolated struct Suggestion: Sendable, Identifiable, Equatable {
    var token: SearchToken
    var matched: Range<String.Index>?   // in token.value, for bolding; nil for the empty-field list
    var replacing: String               // the typed fragment this token replaces in the search text ("" when empty)
    var tier: Int
    var count = 0                       // transcripts that use it (the candidate's count)
    var id: String { token.id }
}

nonisolated enum SearchSuggestions {
    /// Up to `limit` people/tags for what is being typed. Fragments tried: the whole text (multi-word names) and the
    /// last word. Tiers: 0 equal, 1 prefix of the name, 2 prefix of a later word in the name, 3 substring (fragment of
    /// at least 3 characters). Order: tier, people before tags, more transcripts, shorter, alphabetical.
    /// "#…" suggests only tags, "@…" only people. An empty text lists the most used people and tags, half of each
    /// (the rest from the other kind when one has fewer), so tags show even when people are used more.
    static func suggest(text: String, candidates: [SuggestionCandidate], excluding tokens: [SearchToken] = [],
                        limit: Int = 5) -> [Suggestion] {
        let taken = Set(tokens.map(\.id))
        let pool = candidates.filter { !taken.contains(SearchToken(kind: $0.kind, value: $0.name).id) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            func top(_ kind: SearchToken.Kind) -> [SuggestionCandidate] {
                pool.filter { $0.kind == kind }.sorted {
                    $0.count != $1.count ? $0.count > $1.count
                                         : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            let people = top(.person), tags = top(.tag)
            let tagShare = min(tags.count, max(limit / 2, limit - people.count))
            let chosen = Array(people.prefix(limit - tagShare)) + Array(tags.prefix(tagShare))
            return chosen.map { Suggestion(token: SearchToken(kind: $0.kind, value: $0.name), matched: nil, replacing: "",
                                           tier: 9, count: $0.count) }
        }

        var fragments: [String] = [trimmed]
        if let last = trimmed.split(whereSeparator: \.isWhitespace).last, String(last) != trimmed {
            fragments.append(String(last))
        }
        var best: [String: Suggestion] = [:]
        var meta: [String: SuggestionCandidate] = [:]
        for raw in fragments {
            var fragment = raw
            var kinds: Set<SearchToken.Kind> = [.person, .tag]
            if fragment.hasPrefix("#") { fragment.removeFirst(); kinds = [.tag] }
            else if fragment.hasPrefix("@") { fragment.removeFirst(); kinds = [.person] }
            guard !fragment.isEmpty else {           // just "#" or "@": the most used of that kind
                for c in pool where kinds.contains(c.kind) {
                    let token = SearchToken(kind: c.kind, value: c.name)
                    if best[token.id] == nil {
                        best[token.id] = Suggestion(token: token, matched: nil, replacing: raw, tier: 8, count: c.count)
                        meta[token.id] = c
                    }
                }
                continue
            }
            for c in pool where kinds.contains(c.kind) {
                guard let (tier, range) = tier(of: fragment, in: c.name) else { continue }
                let token = SearchToken(kind: c.kind, value: c.name)
                if let existing = best[token.id], existing.tier <= tier { continue }
                best[token.id] = Suggestion(token: token, matched: range, replacing: raw, tier: tier, count: c.count)
                meta[token.id] = c
            }
        }
        return best.values.sorted { a, b in
            let ca = meta[a.id]!, cb = meta[b.id]!
            if a.tier != b.tier { return a.tier < b.tier }
            if ca.kind != cb.kind { return ca.kind.rawValue < cb.kind.rawValue }
            if ca.count != cb.count { return ca.count > cb.count }
            if ca.name.count != cb.name.count { return ca.name.count < cb.name.count }
            return ca.name.localizedStandardCompare(cb.name) == .orderedAscending
        }
        .prefix(limit).map { $0 }
    }

    static func tier(of fragment: String, in name: String) -> (Int, Range<String.Index>)? {
        let ranges = SearchFolding.ranges(of: fragment, in: name, limit: 8)
        guard let first = ranges.first else { return nil }
        if first.lowerBound == name.startIndex && first.upperBound == name.endIndex { return (0, first) }
        if first.lowerBound == name.startIndex { return (1, first) }
        if let wordStart = ranges.first(where: { SearchFolding.startsWord($0, in: name) }) { return (2, wordStart) }
        return fragment.count >= 3 ? (3, first) : nil
    }

    /// Accepting a suggestion: the token is added and the fragment it completes is removed from the text.
    static func accept(_ s: Suggestion, text: String, tokens: [SearchToken]) -> (text: String, tokens: [SearchToken]) {
        var newText = text
        if !s.replacing.isEmpty, let r = newText.range(of: s.replacing, options: .backwards) {
            newText.removeSubrange(r)
        }
        newText = newText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var newTokens = tokens
        if !newTokens.contains(where: { $0.id == s.token.id }) { newTokens.append(s.token) }
        return (newText, newTokens)
    }

    /// Candidates from all transcripts (named speakers and tags, counted per transcript) plus people without
    /// transcripts. Spelling: the most frequent one.
    static func candidates(speakerNamesPerDoc: [[String]], tagsPerDoc: [[String]], people: [String]) -> [SuggestionCandidate] {
        func tally(_ lists: [[String]], kind: SearchToken.Kind, extra: [String]) -> [SuggestionCandidate] {
            var counts: [String: (spellings: [String: Int], docs: Int)] = [:]
            for list in lists {
                var seen = Set<String>()
                for name in list {
                    let key = SearchFolding.fold(name.trimmingCharacters(in: .whitespaces))
                    guard !key.isEmpty, seen.insert(key).inserted else { continue }
                    counts[key, default: ([:], 0)].docs += 1
                    counts[key]!.spellings[name, default: 0] += 1
                }
            }
            for name in extra {
                let key = SearchFolding.fold(name)
                if counts[key] == nil { counts[key] = ([name: 1], 0) }
            }
            return counts.values.map { entry in
                let spelling = entry.spellings.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
                return SuggestionCandidate(kind: kind, name: spelling, count: entry.docs)
            }
        }
        return tally(speakerNamesPerDoc, kind: .person, extra: people) + tally(tagsPerDoc, kind: .tag, extra: [])
    }
}
