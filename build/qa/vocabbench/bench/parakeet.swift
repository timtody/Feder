import Foundation
import FluidAudio

// The Parakeet base pass of the vocabulary bench (FED-56, run.sh --parakeet): what SpeechFileTranscriber.transcribe
// returns when the user chose Parakeet Ultra, per clip, as out/base-parakeet/<id>.json (the bench's Pass format:
// words with times and confidences). ParakeetTranscriber.words(from:) is cut from the app's source by run.sh; the
// calls below are ParakeetTranscriber.transcribe's, except that the models load once instead of per file. The word
// times stay as Parakeet gives them (about 0.12 s early, ParakeetTranscriber.alignmentOffset): the app merges the
// vocabulary into exactly these words, with no shift.
//
//   parakeet <manifest.json> <out dir> [--fresh]

struct Clip: Codable { var id: String; var wav: String }
struct Manifest: Codable { var clips: [Clip] }
struct Pass: Codable { var words: [TranscriptWord]; var confidences: [Double] }

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { print("usage: parakeet <manifest.json> <out dir> [--fresh]"); exit(2) }
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let dir = URL(fileURLWithPath: arguments[2]).appending(path: "base-parakeet")
let fresh = arguments.contains("--fresh")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let todo = manifest.clips.filter { fresh || !FileManager.default.fileExists(atPath: dir.appending(path: $0.id + ".json").path) }
guard !todo.isEmpty else { print("parakeet: \(manifest.clips.count) clips cached"); exit(0) }

// Never downloads: loadFromCache fails when the model is not in Application Support/FluidAudio/Models.
guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra) else {
    print("Parakeet Ultra is not downloaded on this Mac (FluidAudio's model cache)"); exit(2)
}
let models = try await AsrModels.loadFromCache(version: .ultra)
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
let clock = ContinuousClock.now
for clip in todo {
    var state = try TdtDecoderState()
    let result = try await manager.transcribe(URL(fileURLWithPath: clip.wav), decoderState: &state,
                                              language: Language(rawValue: "de"))
    let parsed = ParakeetTranscriber.words(from: result.tokenTimings ?? [])
    try JSONEncoder().encode(Pass(words: parsed.words, confidences: parsed.confidences))
        .write(to: dir.appending(path: clip.id + ".json"))
}
print("parakeet: \(todo.count) clips transcribed [\(ContinuousClock.now - clock)]")
