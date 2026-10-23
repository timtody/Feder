import AVFoundation
import FluidAudio
import Foundation

let mode = CommandLine.arguments[1]
let url = URL(fileURLWithPath: CommandLine.arguments[2])
let audioSeconds = Double(try AVAudioFile(forReading: url).length) / 16_000
func now() -> Double { Date().timeIntervalSince1970 }

switch mode {
case "words":
    // As ParakeetTranscriber.transcribe: the model loaded per job, then the whole file.
    let t0 = now()
    let models = try await AsrModels.loadFromCache(version: .ultra)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    let load = now() - t0
    var state = try TdtDecoderState()
    let t1 = now()
    let result = try await manager.transcribe(url, decoderState: &state, language: .german)
    let words = result.text.split(separator: " ").count
    print("{\"mode\":\"words\",\"audio\":\(audioSeconds),\"load\":\(load),\"run\":\(now() - t1),\"words\":\(words)}")
case "speakers":
    // As NemotronDiarizer: loaded beforehand (prewarmed at launch in the app), the file streamed in 10 s blocks.
    let config = Nemotron3Config.preset(named: "c128-split-w8a8")!
    let models = try await Nemotron3Models.loadFromHuggingFace(config: config)
    let diarizer = Nemotron3Diarizer(config: config, models: models)
    let t1 = now()
    diarizer.reset()
    let file = try AVAudioFile(forReading: url)
    let converter = AudioConverter(sampleRate: 16_000)
    let block = AVAudioFrameCount(file.processingFormat.sampleRate * 10)
    var frames = 0
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block)!
        try file.read(into: buffer, frameCount: block)
        guard buffer.frameLength > 0 else { break }
        diarizer.appendAudio(try converter.resampleBuffer(buffer))
        frames += try diarizer.processBufferedAudio().reduce(0) { $0 + $1.frameCount }
    }
    frames += try diarizer.finishStream().reduce(0) { $0 + $1.frameCount }
    print("{\"mode\":\"speakers\",\"audio\":\(audioSeconds),\"run\":\(now() - t1),\"frames\":\(frames)}")
default:
    fatalError("words|speakers <file>")
}
