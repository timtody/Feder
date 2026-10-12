import Foundation
import AVFoundation
import CoreMedia
import Speech
import FluidAudio

// Streams a 16 kHz mono WAV in real time (0.1 s chunks, like the microphone tap) into SpeechAnalyzer +
// SpeechTranscriber (.timeIndexedProgressiveTranscription, as the app) and FluidAudio's LS-EEND (dihard3, 500 ms step,
// minFramesOn 3 / minFramesOff 5, as LSEENDLiveDiarizer), and logs every result and snapshot with its wall time.

struct Word: Codable { var text: String; var start: Double; var end: Double }
struct Turn: Codable { var speaker: Int; var start: Double; var end: Double }
struct Event: Codable { var t: Double; var kind: String; var words: [Word]?; var turns: [Turn]?; var until: Double? }

func words(from text: AttributedString, fallback: CMTimeRange) -> [Word] {     // SpeechTranscriberEngine.words(from:)
    var out: [Word] = []; var prefix = ""
    for run in text.runs {
        let token = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { continue }
        let punct = token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
        if let r = run.audioTimeRange, !punct { out.append(Word(text: prefix + token, start: r.start.seconds, end: r.end.seconds)); prefix = "" }
        else if out.isEmpty { prefix += token } else { out[out.count - 1].text += token }
    }
    if out.isEmpty, !prefix.isEmpty { out.append(Word(text: prefix, start: fallback.start.seconds, end: fallback.end.seconds)) }
    return out
}

actor Log { var events: [Event] = []; func add(_ e: Event) { events.append(e) } }

let path = CommandLine.arguments[1], outPath = CommandLine.arguments[2]
let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let fmt16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let total = AVAudioFrameCount(file.length)
let all = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: total)!
try file.read(into: all)
let samples = Array(UnsafeBufferPointer(start: all.floatChannelData![0], count: Int(all.frameLength)))

let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de-DE"))!
let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await req.downloadAndInstall() }
let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])!
let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
try await analyzer.prepareToAnalyze(in: format)
let converter = AVAudioConverter(from: fmt16, to: format)!
print("format \(format)")

let model = try await LSEENDModel.loadFromHuggingFace(variant: .dihard3, stepSize: .step500ms)
let diarizer = try LSEENDDiarizer(model: model, timelineConfig: DiarizerTimelineConfig(minFramesOn: 3, minFramesOff: 5))
let frameHz = diarizer.modelFrameHz ?? 10

let log = Log()
let start = ContinuousClock.now
func wall() -> Double { let d = ContinuousClock.now - start; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

let (input, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
let results = Task {
    for try await r in transcriber.results {
        await log.add(Event(t: wall(), kind: r.isFinal ? "final" : "volatile", words: words(from: r.text, fallback: r.range), turns: nil, until: nil))
    }
}
try await analyzer.start(inputSequence: input)

var numbering: [Int: Int] = [:]
func snapshot(until: Double) -> [Turn] {
    let segs = diarizer.timeline.speakers.values.flatMap { $0.finalizedSegments + $0.tentativeSegments }
        .sorted { ($0.startFrame, $0.speakerIndex) < ($1.startFrame, $1.speakerIndex) }
    return segs.map { s in
        let i = numbering[s.speakerIndex] ?? { let n = numbering.count; numbering[s.speakerIndex] = n; return n }()
        return Turn(speaker: i, start: Double(s.startTime), end: Double(s.endTime))
    }
}
var publishedAt = 0.0
let chunk = 1600                                            // 0.1 s at 16 kHz
var offset = 0
while offset < samples.count {
    let piece = Array(samples[offset..<min(offset + chunk, samples.count)])
    let due = Double(offset) / 16000
    let now = wall(); if due > now { try await Task.sleep(for: .seconds(due - now)) }
    // ASR
    let b = AVAudioPCMBuffer(pcmFormat: fmt16, frameCapacity: AVAudioFrameCount(piece.count))!
    b.frameLength = AVAudioFrameCount(piece.count)
    piece.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: piece.count) }
    let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(piece.count) * format.sampleRate / 16000) + 16)!
    var fed = false
    var err: NSError?
    converter.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true; status.pointee = .haveData; return b
    }
    inputCont.yield(AnalyzerInput(buffer: outBuf))
    // LS-EEND at 8 kHz (pairs averaged)
    let eight = stride(from: 0, to: piece.count - 1, by: 2).map { (piece[$0] + piece[$0 + 1]) / 2 }
    if try diarizer.process(samples: eight) != nil {
        let processed = Double(diarizer.numFramesProcessed) / frameHz
        if processed - publishedAt >= 0.5 {
            publishedAt = processed
            await log.add(Event(t: wall(), kind: "snapshot", words: nil, turns: snapshot(until: processed), until: processed))
        }
    }
    offset += chunk
}
inputCont.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
_ = try? diarizer.finalizeSession()
await log.add(Event(t: wall(), kind: "snapshot", words: nil, turns: snapshot(until: 1e9), until: 1e9))
_ = try? await results.value
let events = await log.events
try JSONEncoder().encode(events).write(to: URL(fileURLWithPath: outPath))
print("events \(events.count): volatile \(events.filter { $0.kind == "volatile" }.count), final \(events.filter { $0.kind == "final" }.count), snapshots \(events.filter { $0.kind == "snapshot" }.count)")
