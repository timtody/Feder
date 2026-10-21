import AppKit
import Foundation

// The app's TranscriptWord (Recorder/Models/Recording.swift), so VocabularySpelling compiles as it is.
struct TranscriptWord: Codable, Hashable, Sendable { var text: String; var start: TimeInterval; var end: TimeInterval }

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: spellfix <in.json> <out.json> <terms.json>"); exit(2) }
var result = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let terms = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
let checker = NSSpellChecker.shared
checker.automaticallyIdentifiesLanguages = false
func isWord(_ word: String) -> Bool {
    checker.checkSpelling(of: word, startingAt: 0, language: "de", wrap: false, inSpellDocumentWithTag: 0,
                          wordCount: nil).location == NSNotFound
}
var clips = result["clips"] as! [[String: Any]]
let started = Date()
var words = 0
var searchTime = 0.0
for i in clips.indices {
    let texts = (clips[i]["hyp"] as! String).split(separator: " ").map(String.init)
    words += texts.count
    let searchStart = Date()
    let found = VocabularySpelling.candidates(texts, terms: terms)
    searchTime += Date().timeIntervalSince(searchStart)
    let unknown = Set(found.values.flatMap { $0.flatMap(\.unknown) })
    let nonWords = unknown.filter { !isWord($0) }
    let fake = texts.enumerated().map { TranscriptWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 1) }
    let fixed = VocabularySpelling.applying(found, to: fake, confidences: [], nonWords: nonWords).words
    clips[i]["hyp"] = fixed.map(\.text).joined(separator: " ")
}
result["clips"] = clips
try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: args[2]))
print(String(format: "%d clips, %d words in %.0f ms (search %.0f ms)", clips.count, words,
             Date().timeIntervalSince(started) * 1000, searchTime * 1000))
// One transcript of an hour: all clips' words in one call, as the app makes it.
let all = clips.flatMap { ($0["hyp"] as! String).split(separator: " ").map(String.init) }
let oneStart = Date()
let found = VocabularySpelling.candidates(all, terms: terms)
print(String(format: "as one transcript: %d words, search %.0f ms, %d candidates", all.count,
             Date().timeIntervalSince(oneStart) * 1000, found.values.map(\.count).reduce(0, +)))
// withinOneEdit against Python's Levenshtein on random strings (scratch check; EDITCASES=<file>).
if let path = ProcessInfo.processInfo.environment["EDITCASES"] {
    let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[Any]]
    let wrong = cases.filter { c in
        VocabularySpelling.distance(Array((c[0] as! String).unicodeScalars), Array((c[1] as! String).unicodeScalars),
                                    limit: 1) != (c[2] as! Bool)
    }
    print("withinOneEdit: \(wrong.count) wrong of \(cases.count)", wrong.prefix(5))
}
