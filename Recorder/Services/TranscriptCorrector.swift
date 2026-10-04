import Foundation
import FoundationModels
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Third step of the full-accuracy pass: Apple's on-device language model (Foundation Models, Apple Intelligence)
/// decides from context whether suspicious words were misheard. The work is split by strength:
/// - code finds the suspects: low recognition confidence or not a correctly spelled word (system spell checker),
///   and offers sound-alike vocabulary terms for them ("Sporing" -> Scoring?, "Plattenmigration" -> Datenmigration?);
/// - the model reads the paragraph with these hints and the vocabulary and proposes fixes;
/// - code applies a fix only when the misheard words appear exactly like that, include a suspect, the fix sounds like
///   them (edit distance, as in VocabularyMerge) and the paragraph's changes stay small.
/// So it cannot rephrase, add or drop content, or touch words recognized with confidence, and every word keeps its
/// timestamps. Unavailable model (older iPhone, Apple Intelligence off) or the setting off = no change.
///
/// Off by default: on 80 real German clips (bank calls, audiobooks) it did not lower the word error rate (11.0 % ->
/// 11.2 %); it pushed vocabulary terms into ordinary sentences ("Es" -> "ESG", "rollen" -> "Rollout"). Its gains on
/// synthetic test voices came from their garbled non-words.
@MainActor
final class TranscriptCorrector {
    static let settingKey = "smartCorrections"           // Bool, absent means OFF (Settings screen, experimental)
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? false }

    static let chunkWords = 120                          // context per request, far below the model's window
    static let maxChangedShare = 0.2
    static let maxDistance = 0.5                         // for applying a fix
    static let candidateDistance = 0.45                  // for offering a vocabulary term as a hint
    static let suspiciousConfidence = 0.7

    var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    func correct(_ words: [TranscriptWord], confidences: [Double], vocabulary: [String], locale: Locale) async -> [TranscriptWord] {
        guard Self.isEnabled, isAvailable, !words.isEmpty, confidences.count == words.count else { return words }
        let known = Set(vocabulary.map { VocabularyMerge.normalized($0) })
        let language = locale.language.languageCode?.identifier ?? "de"
        let suspicious = words.indices.map { i in
            let core = words[i].text.trimmingCharacters(in: .punctuationCharacters)
            guard core.count > 1, !known.contains(VocabularyMerge.normalized(core)) else { return false }
            return confidences[i] < Self.suspiciousConfidence || Self.isMisspelled(core, language: language)
        }
        var output: [TranscriptWord] = []
        var start = 0
        while start < words.count {
            var end = min(words.count, start + Self.chunkWords)
            // End chunks at a sentence end when there is one in the last third, so the model sees whole sentences.
            if end < words.count,
               let cut = (start + Self.chunkWords * 2 / 3..<end).last(where: { Self.endsSentence(words[$0]) }) {
                end = cut + 1
            }
            output += await correctChunk(Array(words[start..<end]), suspicious: Array(suspicious[start..<end]),
                                         vocabulary: vocabulary, locale: locale)
            start = end
        }
        return output
    }

    private func correctChunk(_ chunk: [TranscriptWord], suspicious: [Bool], vocabulary: [String],
                              locale: Locale) async -> [TranscriptWord] {
        guard suspicious.contains(true) else { return chunk }
        let hints = chunk.indices.filter { suspicious[$0] }.map { i -> String in
            let word = chunk[i].text.trimmingCharacters(in: .punctuationCharacters)
            let terms = Self.soundAlikes(at: i, in: chunk, vocabulary: vocabulary)
            return terms.isEmpty ? word : "\(word) (sounds like: \(terms.joined(separator: " or ")))"
        }
        let prompt = """
        Vocabulary (terms that often occur in these conversations): \(vocabulary.joined(separator: ", "))

        Possibly misheard words: \(hints.joined(separator: "; "))

        Transcript:
        \(chunk.map(\.text).joined(separator: " "))
        """
        let session = LanguageModelSession(instructions: Self.instructions(locale: locale))
        guard let response = try? await session.respond(to: prompt, generating: Corrections.self,
                                                        options: GenerationOptions(samplingMode: .greedy)) else { return chunk }
        var words = chunk
        var flags = suspicious
        var changed = 0
        for fix in response.content.corrections {
            guard let replaced = Self.apply(fix, to: &words, suspicious: &flags) else { continue }
            changed += replaced
            if Double(changed) > Double(chunk.count) * Self.maxChangedShare { return chunk }   // too much: reject all
        }
        #if DEBUG
        if words.map(\.text) != chunk.map(\.text) {
            print("[Scribe] corrections: \(response.content.corrections.map { "\($0.heard) -> \($0.meant)" })")
        }
        #endif
        return words
    }

    /// Vocabulary terms that sound like the word at `index`, alone or together with its neighbour (best first, max 2).
    static func soundAlikes(at index: Int, in words: [TranscriptWord], vocabulary: [String]) -> [String] {
        let spans = [index...index, index...min(index + 1, words.count - 1), max(index - 1, 0)...index]
        var scored: [(term: String, score: Double)] = []
        for term in vocabulary {
            let t = VocabularyMerge.normalized(term.replacingOccurrences(of: " ", with: ""))
            guard t.count >= 3 else { continue }
            for span in Set(spans) {
                let heard = words[span].map { VocabularyMerge.normalized($0.text) }.joined()
                let d = Double(VocabularyMerge.distance(heard, t)) / Double(max(heard.count, t.count))
                if d > 0, d <= candidateDistance { scored.append((term, d)) }
            }
        }
        var seen = Set<String>()
        return scored.sorted { $0.score < $1.score }.map(\.term).filter { seen.insert($0).inserted }.prefix(2).map { $0 }
    }

    /// Applies one checked fix in place; returns how many words it replaced, or nil when it was rejected.
    static func apply(_ fix: Correction, to words: inout [TranscriptWord], suspicious: inout [Bool]) -> Int? {
        let heard = fix.heard.split(separator: " ").map { VocabularyMerge.normalized(String($0)) }
        let meant = fix.meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...3).contains(heard.count), !heard.contains(""), !meant.isEmpty, meant.split(separator: " ").count <= 3,
              heard.count <= words.count else { return nil }
        let tokens = words.map { VocabularyMerge.normalized($0.text) }
        guard let first = (0...(tokens.count - heard.count)).first(where: {
            Array(tokens[$0..<($0 + heard.count)]) == heard && suspicious[$0..<($0 + heard.count)].contains(true)
        }) else { return nil }
        let last = first + heard.count - 1
        let a = heard.joined(), b = VocabularyMerge.normalized(meant.replacingOccurrences(of: " ", with: ""))
        guard a != b || words[first...last].map(\.text).joined(separator: " ") != meant,
              VocabularyMerge.distance(a, b) <= Int(Double(max(a.count, b.count)) * maxDistance),
              !isInflection(a, b) else { return nil }
        let trailing = String(words[last].text.reversed().prefix { $0.isPunctuation }.reversed())
        let text = meant.hasSuffix(trailing) ? meant : meant + trailing
        words.replaceSubrange(first...last, with: [TranscriptWord(text: text, start: words[first].start, end: words[last].end)])
        suspicious.replaceSubrange(first...last, with: [false])
        return heard.count
    }

    /// "Schnittstellen" vs "Schnittstelle": the same word with a different ending is grammar, not a misheard word.
    static func isInflection(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.hasPrefix(short) && long.count - short.count <= 2
    }

    static func isMisspelled(_ word: String, language: String) -> Bool {
        #if canImport(UIKit)
        let checker = UITextChecker()
        let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                                  startingAt: 0, wrap: false, language: language)
        return range.location != NSNotFound
        #else
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                   inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
        #endif
    }

    private static func endsSentence(_ word: TranscriptWord) -> Bool {
        word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!")
    }

    private static func instructions(locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? "de"
        let language = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "German"
        return """
        You fix speech recognition errors in a \(language) transcript of a business conversation (consulting, banking, \
        finance). You get the transcript, words that may be misheard, and for some of them sound-alike vocabulary terms. \
        For each possibly misheard word decide from the context of the sentence what was actually said: often the \
        sound-alike vocabulary term, sometimes another real word that sounds similar and fits the sentence, and often \
        the word is already right. Only correct words that make no sense where they are. Never rephrase, never fix \
        grammar, style or punctuation, never add or remove content. Copy the misheard words exactly as they appear in \
        the transcript. If nothing was misheard, return no corrections.
        """
    }
}

@Generable
nonisolated struct Correction {
    @Guide(description: "The misheard words exactly as they appear in the transcript, one to three words")
    var heard: String
    @Guide(description: "The words that were actually said")
    var meant: String
}

@Generable
nonisolated struct Corrections {
    @Guide(description: "Corrections for clearly misheard words; empty if there are none", .maximumCount(12))
    var corrections: [Correction]
}
