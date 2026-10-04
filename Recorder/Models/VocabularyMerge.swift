import Foundation

/// Merges vocabulary terms from a vocabulary-aware pass (DictationTranscriber with contextual strings) into the words of
/// the more accurate pass (SpeechTranscriber, which ignores contextual strings). A term is taken over only where the
/// vocabulary-aware pass actually recognized it, at the same time, replacing words that look similar to it
/// ("Bufin" -> "BaFin", "KoFin Pro" -> "Cofinpro"). Everything else stays exactly as the accurate pass heard it.
nonisolated enum VocabularyMerge {
    /// Seconds a term's time range is widened by when looking for the words it replaces.
    static let tolerance: TimeInterval = 0.15
    /// Maximum edit distance between the replaced words and the term, relative to the longer of the two.
    static let maxDistance = 0.5

    static func apply(vocabulary: [String], hinted: [TranscriptWord], to base: [TranscriptWord]) -> [TranscriptWord] {
        let terms = vocabulary
            .map { (text: $0, tokens: $0.split(separator: " ").map { normalized(String($0)) }) }
            .filter { !$0.tokens.isEmpty && $0.tokens.allSatisfy { !$0.isEmpty } }
            .sorted { $0.tokens.count > $1.tokens.count }        // "Product Owner" before "Owner"
        guard !terms.isEmpty, !base.isEmpty else { return base }
        let base = fixingCase(of: base, terms: terms.filter { $0.tokens.count == 1 }.map(\.text))
        guard !hinted.isEmpty else { return base }
        let hintedTokens = hinted.map { normalized($0.text) }

        // Where the vocabulary-aware pass heard a term.
        var found: [(term: String, start: TimeInterval, end: TimeInterval)] = []
        var i = 0
        while i < hinted.count {
            if let term = terms.first(where: { i + $0.tokens.count <= hinted.count
                && Array(hintedTokens[i..<(i + $0.tokens.count)]) == $0.tokens }) {
                found.append((term.text, hinted[i].start, hinted[i + term.tokens.count - 1].end))
                i += term.tokens.count
            } else {
                i += 1
            }
        }

        var words = base
        for occurrence in found.reversed() {                     // back to front: indices stay valid
            let lower = occurrence.start - tolerance, upper = occurrence.end + tolerance
            let span = words.indices.filter { index in
                let middle = (words[index].start + words[index].end) / 2
                return middle >= lower && middle <= upper
            }
            guard let first = span.first, let last = span.last, span.count == last - first + 1 else { continue }
            // The contiguous run of words inside the window that is closest to the term (fewest words on a tie):
            // "der Sparkasse" -> just "Sparkasse", "Im Jurixe" -> just "Jurixe". Neighbours are never touched.
            let term = normalized(occurrence.term.replacingOccurrences(of: " ", with: ""))
            let maxWords = occurrence.term.split(separator: " ").count + 1
            var best: (range: ClosedRange<Int>, distance: Int)?
            for start in first...last {
                for end in start...min(last, start + maxWords - 1) {
                    let heard = words[start...end].map { normalized($0.text) }.joined()
                    let d = distance(heard, term)
                    guard d <= Int(Double(max(heard.count, term.count)) * maxDistance) else { continue }
                    if best == nil || d < best!.distance
                        || (d == best!.distance && end - start < best!.range.count - 1) {
                        best = (start...end, d)
                    }
                }
            }
            guard let best else { continue }
            let replaced = words[best.range]
            let original = replaced.map(\.text).joined(separator: " ")
            let trailing = String(replaced.last!.text.reversed().prefix { $0.isPunctuation }.reversed())
            guard original != occurrence.term + trailing else { continue }   // already right
            words.replaceSubrange(best.range, with: [TranscriptWord(text: occurrence.term + trailing,
                                                                    start: replaced.first!.start, end: replaced.last!.end)])
        }
        return words
    }

    /// A word that equals a single-word term apart from case gets the term's spelling: "Marisk" -> "MaRisk",
    /// "bafin" -> "BaFin". Punctuation around the word is kept.
    static func fixingCase(of words: [TranscriptWord], terms: [String]) -> [TranscriptWord] {
        var spelling: [String: String] = [:]
        for term in terms { spelling[term.lowercased()] = term }
        return words.map { word in
            let core = word.text.trimmingCharacters(in: .punctuationCharacters)
            guard let term = spelling[core.lowercased()], term != core, let range = word.text.range(of: core) else { return word }
            var fixed = word
            fixed.text.replaceSubrange(range, with: term)
            return fixed
        }
    }

    /// Lowercased letters and digits only, diacritics folded: "MaRisk," -> "marisk", "Aufwands-" -> "aufwands".
    static func normalized(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Levenshtein distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
