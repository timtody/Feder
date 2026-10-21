import Foundation
import FluidAudio

// Parakeet Ultra's pass as the app runs it (AsrManager.transcribe, German), then, with --hotwords, FluidAudio's
// VocabularyBoostingSession.rescore over its text, token timings and the clip's 16 kHz samples, the way
// UnifiedAsrManager does it. The CTC spotter is NVIDIA's English Parakeet CTC (110M or 0.6B); terms are tokenized
// with its tokenizer. Models load from (or download once into) FluidAudio's cache on the Mac.

let vocabDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOCABBENCH"]
    ?? "/Users/julius.taylor/projects/recorder/.claude/worktrees/night-2026-10-18/build/qa/vocabbench")
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: parakeetvocab <run> mls|synth [--ctc 110m|06b] [--hotwords short|builtin] [--config recommended|norescue] [--minsim x]"); exit(2) }
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let run = args[1], set = args[2]
let variant: CtcModelVariant = option("--ctc") == "06b" ? .ctc06b : .ctc110m
let hotwords = option("--hotwords")

let data = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabDir.appending(path: "clips/\(set).json"))) as! [String: Any]
let clips = data["clips"] as! [[String: Any]]
// The lists live in synth.json; on the MLS clips (none of the terms said) they measure false replacements.
let lists = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabDir.appending(path: "clips/synth.json"))) as! [String: Any]
let terms: [String] = try hotwords.map { name in
    name.hasSuffix(".json") ? try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: name)))
        : lists[name] as! [String]
} ?? []

let models = try await AsrModels.loadFromCache(version: .ultra)
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
var boosting: VocabularyBoostingSession?
if !terms.isEmpty {
    let ctc = try await CtcModels.downloadAndLoad(variant: variant)
    // --config recommended: FluidAudio's documented short-vocabulary settings (CustomVocabulary.md); norescue: those
    // without the spotter-anchored rescue pass. --minsim: the vocabulary's similarity gate (FluidAudio's default 0.52).
    let recommended = VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, spotterRescueMinSimilarity: 0.30,
                                                spotterRescueMultiWordMinSimilarity: 0.50)
    let config: VocabularyRescorer.Config? = switch option("--config") {
    case "recommended": recommended
    case "norescue": VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, spotterRescueMinSimilarity: 0.30,
                                               spotterRescueMultiWordMinSimilarity: 0.50, spotterRescueEnabled: false)
    default: nil
    }
    let vocabulary = option("--minsim").flatMap(Float.init).map {
        CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }, minSimilarity: $0)
    } ?? CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
    boosting = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctc, config: config)
}
let converter = AudioConverter()

var results: [[String: Any]] = []
var audio = 0.0, wall = 0.0, replaced = 0
for clip in clips {
    var wav = URL(fileURLWithPath: clip["wav"] as! String)
    if set == "synth" { wav = vocabDir.appending(path: "clips/synth/\(clip["voice"] as! String)/\(wav.lastPathComponent)") }
    let samples = try converter.resampleAudioFile(wav)
    let started = Date()
    var state = try TdtDecoderState()
    let result = try await manager.transcribe(wav, decoderState: &state, language: Language(rawValue: "de"))
    var text = result.text
    if let boosting, let rescored = await boosting.rescore(text: text, tokenTimings: result.tokenTimings ?? [],
                                                           audioSamples: samples) {
        if rescored.wasModified { replaced += rescored.replacements.count }
        text = rescored.text
    }
    let took = Date().timeIntervalSince(started)
    let seconds = Double(samples.count) / 16_000
    audio += seconds; wall += took
    results.append(["id": clip["id"]!, "voice": clip["voice"] ?? NSNull(), "kind": clip["kind"] ?? NSNull(),
                    "ref": clip["text"]!, "hyp": text, "audio": seconds, "wall": took])
}
let out: [String: Any] = ["run": run, "model": "parakeet-ultra" + (terms.isEmpty ? "" : "+ctc-\(variant.rawValue)"),
                          "set": set, "hotwords": terms.isEmpty ? NSNull() : terms, "audio_s": audio, "wall_s": wall,
                          "replacements": replaced, "clips": results]
let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../out")
try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]).write(to: dir.appending(path: "\(run).json"))
print(String(format: "%@: %d clips, %.1f min audio, %.1f× real time, %d replacements", run, results.count, audio / 60,
             audio / wall, replaced))
