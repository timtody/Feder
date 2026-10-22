import AVFoundation
import Foundation
import Speech

// Vocabulary bench (FED-56): the app's post-stop vocabulary chain on the Mac, per clip:
//   base   = SpeechTranscriber, no context (SpeechFileTranscriber.transcribe, Apple's default words pass), or with
//            --parakeet Parakeet Ultra's words (the same function when the user chose Parakeet; bench/parakeet.swift
//            writes them, run.sh --parakeet runs it)
//   hinted = DictationTranscriber .timeIndexedLongDictation with the vocabulary as contextual strings (applyVocabulary)
//   merged = VocabularyMerge.apply(vocabulary:hinted:to: base), the app's own source compiled in (run.sh)
// The two recognizer passes are cached per clip (out/base, out/hinted-<vocabulary>), so a change to VocabularyMerge
// (FED-53/54) re-scores in seconds; --fresh re-runs them. Base words keep their confidences for FED-53's gate.
//
//   vocabbench <manifest.json> <out dir> [--names] [--short] [--parakeet] [--fresh]

struct Clip: Codable {
    var id: String; var wav: String; var text: String; var kind: String; var voice: String
    var near: String?; var lure: String?                   // controls: a near-miss word and the term it resembles
}
struct Manifest: Codable { var names: [String]; var short: [String]; var clips: [Clip] }
struct Pass: Codable { var words: [TranscriptWord]; var confidences: [Double] }

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: vocabbench <manifest.json> <out dir> [--names] [--short] [--parakeet] [--fresh]"); exit(2)
}
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let outDir = URL(fileURLWithPath: arguments[2])
let withNames = arguments.contains("--names"), short = arguments.contains("--short")
let parakeet = arguments.contains("--parakeet"), fresh = arguments.contains("--fresh")

// What the app would send with the built-in list switched on (Vocabulary.current caps at maximumCount and dedups;
// the built-in list is under the cap), or with --short a user's own short list (the shipping app sends only the
// user's words: Vocabulary.current). --names appends the people's names, as FED-55 proposes.
var vocabulary = short ? manifest.short : Vocabulary.builtIn
if withNames { vocabulary += manifest.names }
var seen = Set<String>()
vocabulary = Array(vocabulary.filter { seen.insert($0.lowercased()).inserted }.prefix(Vocabulary.maximumCount))
let variant = (short ? "short" : "builtin") + (withNames ? "+names" : "")

// MARK: - Recognizers (as SpeechFileTranscriber runs them)

let requested = Locale(identifier: "de-DE")
guard let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requested),
      let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
    print("de-DE is not supported by SpeechTranscriber/DictationTranscriber on this Mac"); exit(2)
}

func analyze<Module: SpeechModule, Results: AsyncSequence, Output: Sendable>(
    _ fileURL: URL, with module: Module, context: AnalysisContext?,
    collect: @escaping @MainActor (Results) async throws -> Output
) async throws -> Output where Results == Module.Results {
    // The bench never downloads: install the assets once by running the app's pass, or fail loudly.
    if try await AssetInventory.assetInstallationRequest(supporting: [module]) != nil {
        print("speech assets for \(module) are not installed on this Mac"); exit(2)
    }
    let analyzer = SpeechAnalyzer(modules: [module],
                                  options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
    // As the app (SpeechFileTranscriber): a refused context is not an error, the pass runs without it; the bench
    // counts it, since such a pass measures DictationTranscriber without the vocabulary.
    if let context {
        do { try await analyzer.setContext(context) }
        catch { contextRefused.append("\(fileURL.lastPathComponent)\t\(error.localizedDescription)") }
    }
    let results = Task { try await collect(module.results) }
    let file = try AVAudioFile(forReading: fileURL)
    if let end = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: end)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await results.value
}

var contextRefused: [String] = []

func basePass(_ url: URL) async throws -> Pass {
    let transcriber = SpeechTranscriber(locale: speechLocale, transcriptionOptions: [], reportingOptions: [],
                                        attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    return try await analyze(url, with: transcriber, context: nil) { results in
        var pass = Pass(words: [], confidences: [])
        for try await result in results where result.isFinal {
            let parsed = SpeechTranscriberEngine.wordsAndConfidences(from: result.text, fallbackRange: result.range)
            pass.words += parsed.words
            pass.confidences += parsed.confidences
        }
        return pass
    }
}

func hintedPass(_ url: URL) async throws -> Pass {
    let dictation = DictationTranscriber(locale: dictationLocale, preset: .timeIndexedLongDictation)
    let context = AnalysisContext()
    context.contextualStrings[.general] = vocabulary
    return try await analyze(url, with: dictation, context: context) { results in
        var pass = Pass(words: [], confidences: [])
        for try await result in results where result.isFinal {
            let words = SpeechTranscriberEngine.words(from: result.text, fallbackRange: result.range)
            pass.words += words
            pass.confidences += Array(repeating: 1, count: words.count)
        }
        return pass
    }
}

// The hinted passes depend on the vocabulary sent, not only on the variant's name: a change to Vocabulary.builtIn or to
// gen.py's SHORT or NAMES would otherwise re-use passes made with the old contextual strings. Each hinted folder keeps
// the list it was made with; a different list empties it. (The base passes depend only on the audio, and gen.py drops
// a clip's cached passes when it makes the clip anew.)
let hintedFolder = "hinted-" + variant
do {
    let dir = outDir.appending(path: hintedFolder), stamp = dir.appending(path: "vocabulary.json")
    let current = try JSONEncoder().encode(vocabulary)
    if (try? Data(contentsOf: stamp)) != current {
        if FileManager.default.fileExists(atPath: dir.path) {
            print("vocabulary changed since \(hintedFolder) was made: its cached passes are dropped")
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try current.write(to: stamp)
    }
}

struct NotCached: LocalizedError { var errorDescription: String? { "no cached Parakeet pass (run.sh --parakeet)" } }

func cached(_ folder: String, _ clip: Clip, _ run: (URL) async throws -> Pass) async throws -> Pass {
    let dir = outDir.appending(path: folder)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: clip.id + ".json")
    if !fresh, let data = try? Data(contentsOf: file), let pass = try? JSONDecoder().decode(Pass.self, from: data) {
        return pass
    }
    let pass: Pass
    do { pass = try await run(URL(fileURLWithPath: clip.wav)) }
    catch { pass = try await run(URL(fileURLWithPath: clip.wav)) }    // once more: the Mac may have been busy
    try JSONEncoder().encode(pass).write(to: file)
    return pass
}

// MARK: - Scoring

/// A word without the punctuation around it, case kept: what the user sees ("Kick-off," -> "Kick-off").
func core(_ word: String) -> String { word.trimmingCharacters(in: .punctuationCharacters) }

/// Words split at spaces: the merge writes a multi-word term as one TranscriptWord ("Jour fixe", "Cofinpro AG").
func spaced(_ words: [String]) -> [String] { words.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) } }

/// Occurrences of each term in `words` (exact spelling, word by word), longest term first and without overlaps, as
/// VocabularyMerge looks for them: "Cofinpro AG" is one occurrence of "Cofinpro AG", not also one of "Cofinpro".
/// `folded` compares VocabularyMerge.normalized forms instead, for references without case (MLS: "die sparkasse").
func occurrences(of terms: [String], in words: [String], folded: Bool = false) -> [String: Int] {
    func form(_ word: String) -> String { folded ? VocabularyMerge.normalized(word) : core(word) }
    let tokenized = terms.map { (term: $0, tokens: $0.split(separator: " ").map { form(String($0)) }) }
        .sorted { $0.tokens.count > $1.tokens.count }
    let cores = spaced(words).map(form).filter { !$0.isEmpty }
    var counts: [String: Int] = [:]
    var i = 0
    while i < cores.count {
        if let match = tokenized.first(where: { i + $0.tokens.count <= cores.count
            && Array(cores[i..<(i + $0.tokens.count)]) == $0.tokens }) {
            counts[match.term, default: 0] += 1
            i += match.tokens.count
        } else {
            i += 1
        }
    }
    return counts
}

func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
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

func werTokens(_ words: [String]) -> [String] { spaced(words).map(VocabularyMerge.normalized).filter { !$0.isEmpty } }

/// What the merge changed: each merged word that is not a base word, with the base words it took the place of.
/// VocabularyMerge replaces a run of words by one word spanning their times, and case fixes keep the times.
struct Edit { var from: String; var to: String; var caseOnly: Bool }
func edits(base: [TranscriptWord], merged: [TranscriptWord]) -> [Edit] {
    var result: [Edit] = []
    var i = 0
    for word in merged {
        guard i < base.count else { break }
        if base[i] == word { i += 1; continue }
        var k = i
        while k + 1 < base.count && base[k].end < word.end { k += 1 }
        let from = base[i...k].map(\.text).joined(separator: " ")
        result.append(Edit(from: from, to: word.text,
                           caseOnly: k == i && from.lowercased() == word.text.lowercased()))
        i = k + 1
    }
    return result
}

struct Tally { var ref = 0, base = 0, hinted = 0, merged = 0, falseEdits = 0, lost = 0, hintedExtra = 0, caseRight = 0,
             baseFolded = 0 }
func + (a: Tally, b: Tally) -> Tally {
    Tally(ref: a.ref + b.ref, base: a.base + b.base, hinted: a.hinted + b.hinted, merged: a.merged + b.merged,
          falseEdits: a.falseEdits + b.falseEdits, lost: a.lost + b.lost, hintedExtra: a.hintedExtra + b.hintedExtra,
          caseRight: a.caseRight + b.caseRight, baseFolded: a.baseFolded + b.baseFolded)
}

/// The base words of a cached pass that only another tool writes (Parakeet: bench/parakeet.swift).
func stored(_ folder: String, _ clip: Clip) throws -> Pass {
    let file = outDir.appending(path: folder).appending(path: clip.id + ".json")
    guard let data = try? Data(contentsOf: file) else { throw NotCached() }
    return try JSONDecoder().decode(Pass.self, from: data)
}

/// Why the merge did not take over a term the dictation pass heard, in VocabularyMerge's own steps (its tolerance,
/// its window, its distance limit), so FED-54's loosening can be aimed: one hinted word (a multi-word term that came
/// back as one word, which the merge never finds), no base words in the window, a gap in them, or the distance.
func whyMissed(_ term: String, hinted: [TranscriptWord], base: [TranscriptWord]) -> String {
    let tokens = term.split(separator: " ").map { VocabularyMerge.normalized(String($0)) }
    let hintedTokens = hinted.map { VocabularyMerge.normalized($0.text) }
    let joined = VocabularyMerge.normalized(term.replacingOccurrences(of: " ", with: ""))
    guard let at = hinted.indices.first(where: { $0 + tokens.count <= hinted.count
        && Array(hintedTokens[$0..<($0 + tokens.count)]) == tokens }) else {
        return tokens.count > 1 && hintedTokens.contains(joined) ? "one hinted word" : "not found in the hinted words"
    }
    let lower = hinted[at].start - VocabularyMerge.tolerance, upper = hinted[at + tokens.count - 1].end + VocabularyMerge.tolerance
    let span = base.indices.filter { (base[$0].start + base[$0].end) / 2 >= lower && (base[$0].start + base[$0].end) / 2 <= upper }
    guard let first = span.first, let last = span.last else { return "no base word in its time window" }
    guard span.count == last - first + 1 else { return "gap in the window" }
    var best: (heard: String, distance: Int, limit: Int)?
    for start in first...last {
        for end in start...min(last, start + tokens.count) {
            let heard = base[start...end].map { VocabularyMerge.normalized($0.text) }.joined()
            let d = VocabularyMerge.distance(heard, joined)
            let limit = Int(Double(max(heard.count, joined.count)) * VocabularyMerge.maxDistance)
            if best == nil || d - limit < best!.distance - best!.limit { best = (heard, d, limit) }
        }
    }
    let window = base[first...last].map(\.text).joined(separator: " ")
    guard let best, best.distance > best.limit else { return "? (window: \(window))" }
    return "distance \(best.distance) > \(best.limit) (closest: \"\(best.heard)\" in window \"\(window)\", "
        + "at most \(tokens.count + 1) words)"
}

/// The lure test's hinted words: the base words with `lure` over the near miss, as if the dictation pass had heard
/// the term there; nil when the base pass did not hear the near miss as written.
func lured(_ base: [TranscriptWord], near: String, lure: String) -> [TranscriptWord]? {
    let nearTokens = near.split(separator: " ").map { VocabularyMerge.normalized(String($0)) }
    let baseTokens = base.map { VocabularyMerge.normalized($0.text) }
    guard base.count >= nearTokens.count, let at = (0...(base.count - nearTokens.count))
        .first(where: { Array(baseTokens[$0..<($0 + nearTokens.count)]) == nearTokens }) else { return nil }
    let start = base[at].start, end = base[at + nearTokens.count - 1].end
    let lureWords = lure.split(separator: " ").map(String.init)
    let step = (end - start) / Double(lureWords.count)
    var hinted = base
    hinted.replaceSubrange(at..<(at + nearTokens.count), with: lureWords.enumerated().map { index, word in
        TranscriptWord(text: word, start: start + Double(index) * step, end: start + Double(index + 1) * step)
    })
    return hinted
}

// Terms reported: the vocabulary plus the names (counted even when they are not in the vocabulary, for FED-55).
let scoredTerms = vocabulary + manifest.names.filter { !vocabulary.contains($0) }

var perTerm: [String: [String: Tally]] = [:]                // voice -> term -> tally, over clips whose reference has it
var caseList: [String] = []                                 // real clips: case fixes, not judged
var perGroup: [String: Tally] = [:]                         // "<voice> <kind>"
var falseList: [String] = []
var missedList: [String] = []
var failedList: [String] = []
var lureList: [String] = []
var lureCount: [String: (placed: Int, taken: Int, unplaced: Int, caseFix: Int)] = [:]   // voice -> lure test
var editCount: [String: (all: Int, caseOnly: Int)] = [:]
var wer: [String: (base: Int, hinted: Int, merged: Int, ref: Int)] = [:]   // "<voice> <kind>"
let clock = ContinuousClock.now

for clip in manifest.clips {
    // The app keeps the earlier words when a pass fails (SpeechFileTranscriber); the bench leaves such a clip out of
    // every number and lists it, since a missing pass is no measurement of the merge.
    let base: Pass, hinted: Pass
    do {
        base = parakeet ? try stored("base-parakeet", clip) : try await cached("base", clip, basePass)
        hinted = try await cached(hintedFolder, clip, hintedPass)
    } catch {
        failedList.append("\(clip.id)\t\(error.localizedDescription)")
        continue
    }
    let merged = VocabularyMerge.apply(vocabulary: vocabulary, hinted: hinted.words, to: base.words)
    let refWords = clip.text.split(whereSeparator: \.isWhitespace).map(String.init)
    let group = "\(clip.voice) \(clip.kind)"
    // A real clip's reference has no case or punctuation (MLS), so its terms are counted case-folded and its case
    // fixes are counted but not judged; the synthetic sentences are exact, so there case matters ("Dora" -> "DORA").
    let folded = clip.kind == "real"

    let refCounts = occurrences(of: scoredTerms, in: refWords, folded: folded)
    let baseCounts = occurrences(of: scoredTerms, in: base.words.map(\.text), folded: folded)
    let hintedCounts = occurrences(of: scoredTerms, in: hinted.words.map(\.text), folded: folded)
    let mergedCounts = occurrences(of: scoredTerms, in: merged.map(\.text), folded: folded)
    // The base pass with case ignored: how many terms it had apart from their spelling, so the merge's case fixes can
    // be told from the misheard words the vocabulary brings in.
    let baseFoldedCounts = occurrences(of: scoredTerms, in: base.words.map(\.text), folded: true)
    let refFoldedCounts = occurrences(of: scoredTerms, in: refWords, folded: true)
    var termCounts: [String: (merged: Int, ref: Int, base: Int)] = [:]
    for term in scoredTerms {
        let ref = refCounts[term, default: 0], b = baseCounts[term, default: 0]
        let h = hintedCounts[term, default: 0], m = mergedCounts[term, default: 0]
        termCounts[term] = (m, ref, b)
        guard ref + b + h + m > 0 else { continue }
        var t = Tally(ref: ref, base: min(b, ref), hinted: min(h, ref), merged: min(m, ref))
        t.hintedExtra = max(0, h - ref)
        t.baseFolded = min(baseFoldedCounts[term, default: 0], refFoldedCounts[term, default: 0], ref)
        t.lost = max(0, min(b, ref) - min(m, ref))
        if clip.kind != "control", ref > 0 {
            perTerm[clip.voice, default: [:]][term, default: Tally()] = perTerm[clip.voice, default: [:]][term, default: Tally()] + t
        }
        perGroup[group, default: Tally()] = perGroup[group, default: Tally()] + t
        // The dictation pass had it right but the merge did not take it over (what FED-54 loosens).
        if min(h, ref) > min(m, ref), vocabulary.contains(term) {
            missedList.append("\(clip.id)\t\(term): \(whyMissed(term, hinted: hinted.words, base: base.words))"
                              + "\n    base: \(base.words.map(\.text).joined(separator: " "))"
                              + "\n    hinted: \(hinted.words.map(\.text).joined(separator: " "))")
        }
    }

    // An edit that writes term T is right while it fills an occurrence of T the base pass missed, false otherwise.
    // Counted per clip, not by position: an edit that writes T in the wrong place of a clip whose reference has a T
    // the base pass missed counts as right. The synthetic clips are single sentences with one term each, where the two
    // agree; on long clips (MLS) or with a much wider merge window (FED-54) an alignment would be needed.
    let changes = edits(base: base.words, merged: merged)
    editCount[group, default: (0, 0)].all += changes.count
    editCount[group, default: (0, 0)].caseOnly += changes.filter(\.caseOnly).count
    var filled: [String: Int] = [:]
    for change in changes {
        if folded && change.caseOnly { caseList.append("\(clip.id)\t\"\(change.from)\" -> \"\(change.to)\""); continue }
        let term = core(change.to)
        let c = termCounts[term] ?? (0, 0, 0)
        if filled[term, default: 0] < max(0, c.ref - min(c.base, c.ref)) {
            filled[term, default: 0] += 1
            // A right edit that only changes case ("Kick-Off" -> "Kick-off"): the words pass had the word, only spelled
            // otherwise, so it is counted apart from the misheard words the vocabulary brought in. (VocabularyMerge's
            // fixingCase makes such an edit without a dictation hit, and its matching folds case too.)
            if change.caseOnly { perGroup[group, default: Tally()].caseRight += 1 }
        } else {
            perGroup[group, default: Tally()].falseEdits += 1
            if clip.kind != "control" { perTerm[clip.voice, default: [:]][term, default: Tally()].falseEdits += 1 }
            falseList.append("\(clip.id)\t\"\(change.from)\" -> \"\(change.to)\"\(change.caseOnly ? " (case)" : "")\t| \(clip.text)")
        }
    }

    // Lure test: does the merge write the lure over the near miss when the dictation pass hands it over there?
    if let near = clip.near, let lure = clip.lure, vocabulary.contains(lure) {
        let fake = lured(base.words, near: near, lure: lure)     // nil: the base pass did not hear the near miss
        if fake != nil, VocabularyMerge.normalized(near) == VocabularyMerge.normalized(lure) {
            // "Dora" / "DORA": the near miss, heard as written, is the term apart from case. VocabularyMerge.fixingCase
            // rewrites it before any matching, with or without a dictation hit, so the distance gate never decides it.
            // Counted apart (it shows up as a false replacement above), not as a near miss the gate let through.
            lureCount[clip.voice, default: (0, 0, 0, 0)].caseFix += 1
            lureList.append("\(clip.id)\tcase fix\t\(near) / \(lure)\t(not a gate test: fixingCase runs before the matching)")
        } else if let fake {
            let result = VocabularyMerge.apply(vocabulary: vocabulary, hinted: fake, to: base.words)
            // Against the merge with no hinted words (only its case fixes), so a case fix elsewhere in the sentence
            // is not counted as the lure passing the gate.
            let caseFixed = VocabularyMerge.apply(vocabulary: vocabulary, hinted: [], to: base.words)
            let before = occurrences(of: [lure], in: caseFixed.map(\.text))[lure, default: 0]
            let taken = occurrences(of: [lure], in: result.map(\.text))[lure, default: 0] > before
            lureCount[clip.voice, default: (0, 0, 0, 0)].placed += 1
            if taken { lureCount[clip.voice, default: (0, 0, 0, 0)].taken += 1 }
            let change = edits(base: caseFixed, merged: result).map { "\"\($0.from)\" -> \"\($0.to)\"" }
            lureList.append("\(clip.id)\t\(taken ? "taken   " : "rejected")\t\(near) / \(lure)"
                            + (change.isEmpty ? "" : "\t\(change.joined(separator: ", "))"))
        } else {
            lureCount[clip.voice, default: (0, 0, 0, 0)].unplaced += 1
            lureList.append("\(clip.id)\tnot placed\t\(near) / \(lure)\t| base: \(base.words.map(\.text).joined(separator: " "))")
        }
    }

    // Word errors for every group, the synthetic ones too: judging terms per clip would not see an edit that writes the
    // right term but also eats a correct neighbour, which a wider merge window (FED-54) could do.
    do {
        let r = werTokens(refWords)
        var w = wer[group, default: (0, 0, 0, 0)]
        w.base += editDistance(werTokens(base.words.map(\.text)), r)
        w.hinted += editDistance(werTokens(hinted.words.map(\.text)), r)
        w.merged += editDistance(werTokens(merged.map(\.text)), r)
        w.ref += r.count
        wer[group] = w
    }
}

// MARK: - Report

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.1f %%", 100 * Double(a) / Double(b)) }
func row(_ cells: [String], _ widths: [Int]) -> String {
    zip(cells, widths).map { $0.0.padding(toLength: max($0.1, $0.0.count), withPad: " ", startingAt: 0) }.joined(separator: " ")
}

print("Vocabulary bench: \(manifest.clips.count) clips, vocabulary \(variant) (\(vocabulary.count) terms), base "
      + (parakeet ? "Parakeet Ultra" : "SpeechTranscriber \(speechLocale.identifier)")
      + ", DictationTranscriber \(dictationLocale.identifier)")
print(manifest.clips.contains { $0.kind == "real" }
      ? "Counts: occurrences, case-folded (the real clips' reference has no case or punctuation); case fixes not judged."
      : "Counts: occurrences of the exact spelling (case and spaces matter; punctuation around a word does not).")
print("base = \(parakeet ? "Parakeet Ultra" : "SpeechTranscriber"), hinted = DictationTranscriber with contextual "
      + "strings, merged = VocabularyMerge. A term inside a longer one (Cofinpro in Cofinpro AG) is not counted again.")

let widths = [22, 5, 8, 8, 8, 6, 6]
for (voice, terms) in perTerm.sorted(by: { $0.key < $1.key }) {
    print("\nPer term, \(voice) (clips whose reference has the term): correct occurrences of ref")
    print(row(["term", "ref", "base", "hinted", "merged", "false", "lost"], widths))
    for term in scoredTerms where terms[term] != nil {
        let t = terms[term]!
        print(row([term + (vocabulary.contains(term) ? "" : " *"), "\(t.ref)", "\(t.base)", "\(t.hinted)", "\(t.merged)",
                   "\(t.falseEdits)", "\(t.lost)"], widths))
    }
    if terms.keys.contains(where: { !vocabulary.contains($0) }) { print("* not in the vocabulary (a name; --names adds them)") }
}

print("\nPer voice and kind")
let gw = [16, 6, 9, 11, 9, 9, 8, 7, 11, 6, 7, 13]
print(row(["group", "ref", "base", "base no case", "hinted", "merged", "edits", "case", "case right", "false", "lost",
           "hinted extra"], gw))
for group in Set(perGroup.keys).union(editCount.keys).sorted() {
    let t = perGroup[group] ?? Tally(), e = editCount[group] ?? (0, 0)
    print(row([group, "\(t.ref)", pct(t.base, t.ref), pct(t.baseFolded, t.ref), pct(t.hinted, t.ref),
               pct(t.merged, t.ref), "\(e.all)",
               "\(e.caseOnly)", "\(t.caseRight)", "\(t.falseEdits)", "\(t.lost)", "\(t.hintedExtra)"], gw))
}
print("base no case = the base pass's terms with case (and punctuation inside a word) ignored;")
print("edits = words the merge changed (case = case fixes only; case right = case fixes that made a term right: the base")
print("pass had the word in another case); false = edits that wrote a term more often than the clip's reference has it")
print("beyond what the base pass had (counted per clip, not by position); lost = correct terms the merge removed;")
print("hinted extra = terms the dictation pass heard that the reference lacks.")

print("\nWER per voice and kind (letters and digits only, case-folded)")
for (group, w) in wer.sorted(by: { $0.key < $1.key }) {
    print("  \(group) (\(w.ref) reference words): base \(pct(w.base, w.ref)), hinted \(pct(w.hinted, w.ref)), "
          + "merged \(pct(w.merged, w.ref))")
}

print("\nFalse replacements (\(falseList.count))")
for line in falseList { print("  " + line) }
if !caseList.isEmpty {
    print("\nCase fixes on real clips, not judged: the reference has no case (\(caseList.count))")
    for line in caseList { print("  " + line) }
}
if !lureList.isEmpty {
    print("\nLure test: the lure (a vocabulary term) put into the hinted words over a control's near miss, as if the")
    print("dictation pass had heard the term there; taken = the merge wrote it over the near miss (a false replacement")
    print("the merge's gate let through). Not placed = the base pass did not hear the near miss as written.")
    for (voice, c) in lureCount.sorted(by: { $0.key < $1.key }) {
        print("  \(voice): \(c.taken) of \(c.placed) taken (\(pct(c.taken, c.placed))), \(c.unplaced) not placed, "
              + "\(c.caseFix) case fixes (the term apart from case: no gate)")
    }
    for line in lureList { print("  " + line) }
}
print("\nMissed merges: the dictation pass had the term, the merged words do not (\(missedList.count))")
for line in missedList { print("  " + line) }
if !contextRefused.isEmpty {
    print("\nContextual strings refused, the pass ran without them as in the app (\(contextRefused.count))")
    for line in contextRefused { print("  " + line) }
}
print("\nClips left out, a recognizer pass failed twice (\(failedList.count))")
for line in failedList { print("  " + line) }
print("\n[\(ContinuousClock.now - clock)]")
