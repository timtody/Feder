import Foundation

/// The vocabulary on Parakeet's words without a second recognizer (FED-204): a word or a few words that are a term
/// apart from its spelling get the term's spelling, in four rules:
/// - case: "Sepa" -> "SEPA", "bafin" -> "BaFin"
/// - hyphens and spaces: "Kickoff" -> "Kick-off", "Jourfixe" -> "Jour fixe"
/// - spoken numbers: "Basel vier" -> "Basel IV", "IFRS neun" -> "IFRS 9"
/// - one letter off (two from 12 letters on), only for terms of 5+ letters and only where every heard word the fix
///   would change is not a word in the recording's language (the spell checker): "Jur fixe" -> "Jour fixe", never
///   "Marisa" -> "MaRisk", "digitalisieren" -> "Digitalisierung" or "springt" -> "Sprint"
/// Measured on Parakeet Ultra's words (FederLab's vocabset, the hint list Feder's 112 built-in terms, 77 of them never
/// said): one speaker's real recordings 74 % -> 93 % of the terms right; the synthetic sentences 51 % -> 68 % (Parakeet
/// + Dictation + VocabularyMerge: 67 %); no term written that wasn't said, apart from a name that is also a term
/// ("Tante Dora" -> "DORA", as the old merge's case fix did too); 62 minutes of real speech without terms: no new false term.
/// Without the spell check it wrote six false terms on the synthetic sentences; with two letters allowed from 9 letters
/// on, "Volksmann" became "Volksbank".
///
/// Two steps, so the search stays off the main actor and only the spell check (UITextChecker, main actor) runs on it:
/// `candidates` finds every possible fix, `applying` takes them left to right, a near miss only if its heard words
/// are among `nonWords`.
nonisolated enum VocabularySpelling {
    /// words[range] may become `text`. `unknown`: the heard words a near miss would change (empty for the exact rules).
    struct Candidate: Sendable, Equatable {
        var range: Range<Int>
        var text: String
        var unknown: [String]
    }

    static let minNearLength = 5
    static let longTermLength = 12

    /// Every fix, by the position it starts at; at one position in the order to try (longer terms first).
    @concurrent static func candidates(in words: [TranscriptWord], terms: [String]) async -> [Int: [Candidate]] {
        candidates(words.map(\.text), terms: terms)
    }

    static func candidates(_ texts: [String], terms: [String]) -> [Int: [Candidate]] {
        let prepared = terms
            .map { term -> (text: String, count: Int, widths: [Int], key: [Unicode.Scalar], words: Set<String>) in
                let count = term.split(separator: " ").count
                return (term, count, Set([count, count + 1, max(1, count - 1)]).sorted(),   // "Kickoff" is one word
                        Array(fold(term).unicodeScalars), Set(term.lowercased().split(separator: " ").map(String.init)))
            }
            .filter { !$0.key.isEmpty }
            .enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }   // stable
            .map(\.element)
        guard let widest = prepared.map(\.count).max() else { return [:] }
        // Only terms whose folded length is within two of a chunk's can match it: indexed by that length.
        var byLength: [Int: [Int]] = [:]
        for (index, term) in prepared.enumerated() { byLength[term.key.count, default: []].append(index) }
        // fold(a chunk) is its words' folds joined, so each word is folded once (an hour is ~10,000 words).
        let folds = texts.map { Array(fold($0).unicodeScalars) }
        var found: [Int: [Candidate]] = [:]
        for start in texts.indices {
            var hits: [(term: Int, order: Int, candidate: Candidate)] = []
            var heard: [Unicode.Scalar] = []
            for width in 1...min(widest + 1, texts.count - start) {
                heard += folds[start + width - 1]
                for length in max(1, heard.count - 2)...(heard.count + 2) {
                    for index in byLength[length] ?? [] {
                        let term = prepared[index]
                        guard let order = term.widths.firstIndex(of: width) else { continue }
                        let exact = heard == term.key
                        if !exact {
                            guard term.key.count >= minNearLength,
                                  distance(heard, term.key, limit: term.key.count >= longTermLength ? 2 : 1) else { continue }
                        }
                        let chunk = texts[start..<(start + width)]
                        guard chunk.joined(separator: " ").trimmingCharacters(in: edge) != term.text else { continue }
                        let unknown = exact ? [] : chunk.map { $0.trimmingCharacters(in: edge) }
                            .filter { !$0.isEmpty && !term.words.contains($0.lowercased()) }
                        guard exact || !unknown.isEmpty else { continue }
                        let last = chunk[chunk.endIndex - 1]
                        let trailing = String(last[last.index(last.startIndex, offsetBy: trimmedLength(last))...])
                        hits.append((index, order, Candidate(range: start..<(start + width), text: term.text + trailing,
                                                             unknown: unknown)))
                    }
                }
            }
            // In the order to try: longer terms first (the list's order among equals), each term's widths ascending.
            if !hits.isEmpty { found[start] = hits.sorted { ($0.term, $0.order) < ($1.term, $1.order) }.map(\.candidate) }
        }
        return found
    }

    /// The words with the fixes taken: left to right, at each position the first candidate that is exact or whose
    /// heard words are all `nonWords`. A fix over several words keeps the first one's start, the last one's end and
    /// the lowest confidence.
    static func applying(_ candidates: [Int: [Candidate]], to words: [TranscriptWord], confidences: [Double],
                         nonWords: Set<String>) -> (words: [TranscriptWord], confidences: [Double]) {
        guard !candidates.isEmpty else { return (words, confidences) }
        var outWords: [TranscriptWord] = [], outConfidences: [Double] = []
        var index = 0
        while index < words.count {
            if let fix = candidates[index]?.first(where: { $0.unknown.allSatisfy(nonWords.contains) }) {
                let span = words[fix.range]
                outWords.append(TranscriptWord(text: fix.text, start: span.first!.start, end: span.last!.end))
                let spanConfidences = fix.range.compactMap { $0 < confidences.count ? confidences[$0] : nil }
                if !confidences.isEmpty { outConfidences.append(spanConfidences.min() ?? 1) }
                index = fix.range.upperBound
            } else {
                outWords.append(words[index])
                if index < confidences.count { outConfidences.append(confidences[index]) }
                index += 1
            }
        }
        return (outWords, outConfidences)
    }

    // MARK: Matching

    /// Punctuation around a word or chunk (kept on the fixed word, not compared).
    private static let edge = CharacterSet(charactersIn: ".,;:!?\"")

    private static func trimmedLength(_ word: String) -> Int {
        var end = word.endIndex
        while end > word.startIndex, let scalar = word[word.index(before: end)].unicodeScalars.first,
              edge.contains(scalar) {
            end = word.index(before: end)
        }
        return word.distance(from: word.startIndex, to: end)
    }

    /// Spoken numbers (German and English) and Roman numerals as digits, so "vier", "IV" and "4" compare equal.
    private static let numbers: [String: String] = [
        "null": "0", "eins": "1", "ein": "1", "zwei": "2", "drei": "3", "vier": "4", "fünf": "5", "sechs": "6",
        "sieben": "7", "acht": "8", "neun": "9", "zehn": "10", "elf": "11", "zwölf": "12",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "ix": "9", "x": "10",
    ]

    /// Lowercased letters and digits, words joined, numbers as digits: "Kick-off" -> "kickoff", "Basel IV" ->
    /// "basel4". Diacritics stay ("Bafög" is not "Bafog").
    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: " ").split(whereSeparator: \.isWhitespace)
            .map { word -> String in
                let kept = String(word.filter { $0.isLetter || $0.isNumber })
                return numbers[kept] ?? kept
            }
            .joined()
    }

    /// Whether the Levenshtein distance of `a` and `b` is at most `limit` (most pairs differ in length by more).
    static func distance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Bool {
        guard abs(a.count - b.count) <= limit else { return false }
        if limit == 1 { return withinOneEdit(a, b) }
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count] <= limit
    }

    /// One substitution, insertion or deletion at most, in one walk (the search makes ~10^5 of these per hour of
    /// speech; the full table allocated per pair took ~0.4 s for an hour on an M5).
    private static func withinOneEdit(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        var i = 0, j = 0, edited = false
        while i < short.count && j < long.count {
            if short[i] == long[j] { i += 1; j += 1; continue }
            if edited { return false }
            edited = true
            if short.count == long.count { i += 1 }            // substitution; else skip one in the longer
            j += 1
        }
        let left = (short.count - i) + (long.count - j)      // what one walk didn't reach: a trailing extra letter
        return edited ? left == 0 : left <= 1
    }
}
