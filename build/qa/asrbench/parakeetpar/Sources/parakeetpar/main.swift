import AVFoundation
import CoreML
import FluidAudio
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let audioSeconds = Double(try AVAudioFile(forReading: url).length) / 16_000

func now() -> Double { Date().timeIntervalSince1970 }
func text(_ r: ASRResult) -> String { r.text.trimmingCharacters(in: .whitespaces) }

/// One load, as the app does per job.
func loaded(_ units: MLComputeUnits? = nil, concurrency: Int = 4) async throws -> (AsrManager, Double) {
    let t = now()
    let models = try await AsrModels.loadFromCache(version: .ultra, encoderComputeUnits: units)
    let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: concurrency))
    try await manager.loadModels(models)
    return (manager, now() - t)
}

func run(_ manager: AsrManager, _ file: URL) async throws -> (ASRResult, Double) {
    var state = try TdtDecoderState()
    let t = now()
    let r = try await manager.transcribe(file, decoderState: &state, language: .german)
    return (r, now() - t)
}

print(String(format: "audio %.0f s", audioSeconds))
// Warm-up: the first load after a build compiles for the Neural Engine.
let (_, firstLoad) = try await loaded()
print(String(format: "first load %.2f s", firstLoad))
var reference: String?
for concurrency in [1, 2, 4, 8, 4] {
    let (manager, load) = try await loaded(concurrency: concurrency)
    let (r, seconds) = try await run(manager, url)
    let same = reference.map { $0 == text(r) } ?? true
    if concurrency == 4, reference == nil { reference = text(r) }
    print(String(format: "concurrency %d: load %.2f s, transcribe %.2f s (%.0fx real time), %d words%@",
                 concurrency, load, seconds, audioSeconds / seconds, text(r).split(separator: " ").count,
                 same ? "" : " (text differs from concurrency 4)"))
}

// Two separately loaded copies, each on half the file, at the same time: Neural Engine + GPU, and Neural Engine twice.
let file = try AVAudioFile(forReading: url)
let half = AVAudioFrameCount(file.length / 2)
func write(_ from: AVAudioFramePosition, _ count: AVAudioFrameCount, _ name: String) throws -> URL {
    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
    file.framePosition = from
    try file.read(into: buffer, frameCount: count)
    let target = try AVAudioFile(forWriting: out, settings: file.fileFormat.settings)
    try target.write(from: buffer)
    return out
}
let first = try write(0, half, "half1.wav"), second = try write(AVAudioFramePosition(half), half, "half2.wav")
for (label, units) in [("ANE + GPU", MLComputeUnits.cpuAndGPU), ("ANE + ANE", MLComputeUnits.cpuAndNeuralEngine)] {
    let t = now()
    let (a, loadA) = try await loaded()
    let (b, loadB) = try await loaded(units)
    let loads = now() - t
    let t2 = now()
    async let x = run(a, first)
    async let y = run(b, second)
    let (ra, sa) = try await x, (rb, sb) = try await y
    let both = now() - t2
    print(String(format: "%@: loads %.2f s (%.2f + %.2f), halves %.2f s and %.2f s, wall %.2f s (%.0fx), %d words",
                 label, loads, loadA, loadB, sa, sb, both, audioSeconds / both,
                 (text(ra) + " " + text(rb)).split(separator: " ").count))
}
