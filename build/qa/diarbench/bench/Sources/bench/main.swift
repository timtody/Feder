import Foundation
import AVFoundation
import FluidAudio

struct OutWord: Codable { var text: String; var start: Double; var end: Double }
struct OutTurn: Codable { var speaker: Int; var start: Double; var end: Double }
struct RunOut: Codable { var words: [OutWord]; var turns: [OutTurn]; var labels: [Int?]; var embeddings: [[Float]] }

func asr() async throws -> AsrManager {
    let models = try await AsrModels.loadFromCache(version: .ultra)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    return manager
}
func transcribe(_ m: AsrManager, _ url: URL) async throws -> [TranscriptWord] {
    var state = try TdtDecoderState()
    let r = try await m.transcribe(url, decoderState: &state, language: Language(rawValue: "de"))
    return ParakeetWords.words(from: r.tokenTimings ?? []).words
}
func nemotron(_ url: URL) async throws -> [SpeakerTurn] {
    let config = Nemotron3Config.preset(named: NemotronTurns.presetName)!
    let models = try await Nemotron3Models.loadFromHuggingFace(config: config, progressHandler: nil)
    let diarizer = Nemotron3Diarizer(config: config, models: models)
    diarizer.reset()
    let file = try AVAudioFile(forReading: url)
    let converter = AudioConverter(sampleRate: 16_000)
    let block = AVAudioFrameCount(file.processingFormat.sampleRate * 10)
    var p: [Float] = []; var frames = 0
    func collect(_ rs: [Nemotron3ChunkResult]) { for r in rs { p += r.probabilities; frames += r.frameCount } }
    while file.framePosition < file.length {
        let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block)!
        try file.read(into: b, frameCount: block)
        guard b.frameLength > 0 else { break }
        diarizer.appendAudio(try converter.resampleBuffer(b))
        collect(try diarizer.processBufferedAudio())
    }
    collect(try diarizer.finishStream())
    return NemotronTurns.turns(probabilities: p, frames: frames, slots: config.numSpeakers, frameSeconds: Double(config.outputFrameSeconds))
}

let args = CommandLine.arguments
switch args[1] {
case "words":                     // bench words <wav>... : <wav>.words.json per file
    let m = try await asr()
    for path in args.dropFirst(2) {
        let w = try await transcribe(m, URL(fileURLWithPath: path))
        try JSONEncoder().encode(w.map { OutWord(text: $0.text, start: $0.start, end: $0.end) }).write(to: URL(fileURLWithPath: path + ".words.json"))
    }
    print("words done", args.count - 2)
case "run":                       // bench run <meeting.wav>... : <wav>.run.json per file
    let m = try await asr()
    let embedder = VoiceEmbedder(models: try await OfflineDiarizerModels.load())
    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let words = try await transcribe(m, url)
        let turns = try await nemotron(url)
        let labels = TranscriptAligner.finalSpeakers(words: words, turns: turns, offset: ParakeetWords.alignmentOffset)
        let spans = words.map { VoiceWindows.Span(start: $0.start, end: max($0.end, $0.start + 0.05)) }
        let embeddings = try embedder.embeddings(fileURL: url, spans: spans)
        let out = RunOut(words: words.map { OutWord(text: $0.text, start: $0.start, end: $0.end) },
                         turns: turns.map { OutTurn(speaker: $0.speakerIndex, start: $0.start, end: $0.end) },
                         labels: labels, embeddings: embeddings)
        try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: path + ".run.json"))
        print("run", (path as NSString).lastPathComponent, words.count, "words", turns.count, "turns")
    }
default: print("usage")
}
