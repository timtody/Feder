import AVFoundation
import NaturalLanguage
import Speech

/// The first `seconds` of `url` into a 16 kHz mono WAV (what the app's imports are).
func excerpt(_ url: URL, seconds: Double, skip: Double = 0) throws -> URL {
    let input = try AVAudioFile(forReading: url)
    let out = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.processingFormat.sampleRate, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: mono, to: format)!
    let file = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    input.framePosition = AVAudioFramePosition(skip * input.processingFormat.sampleRate)
    let total = AVAudioFrameCount(min(Double(input.length - input.framePosition), seconds * input.processingFormat.sampleRate))
    let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: total)!
    try input.read(into: buffer, frameCount: total)
    let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: total)!
    m.frameLength = buffer.frameLength
    for i in 0..<Int(buffer.frameLength) {
        var s: Float = 0
        for c in 0..<Int(buffer.format.channelCount) { s += buffer.floatChannelData![c][i] }
        m.floatChannelData![0][i] = s / Float(buffer.format.channelCount)
    }
    let o = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(total) * 16_000 / mono.sampleRate) + 1024)!
    var fed = false
    _ = converter.convert(to: o, error: nil) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return m
    }
    try file.write(from: o)
    return out
}

struct Probe { var confidence: Double; var words: Int; var text: String }

func probe(_ url: URL, _ id: String) async throws -> Probe {
    let t = SpeechTranscriber(locale: Locale(identifier: id), transcriptionOptions: [], reportingOptions: [],
                              attributeOptions: [.transcriptionConfidence])
    let analyzer = SpeechAnalyzer(modules: [t])
    let results = Task { () -> (Double, Int, String) in
        var sum = 0.0, n = 0, text = ""
        for try await r in t.results where r.isFinal {
            text += String(r.text.characters) + " "
            for run in r.text.runs {
                if let c = run.transcriptionConfidence {
                    let chars = r.text[run.range].characters.filter { !$0.isWhitespace }.count
                    sum += c * Double(chars); n += chars
                }
            }
        }
        return (n > 0 ? sum / Double(n) : 0, text.split(separator: " ").count, text)
    }
    let file = try AVAudioFile(forReading: url)
    if let end = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: end) }
    else { await analyzer.cancelAndFinishNow() }
    let (c, w, x) = try await results.value
    return Probe(confidence: c, words: w, text: x)
}

let seconds = Double(CommandLine.arguments[1])!
let skip = Double(CommandLine.arguments[2])!
for path in CommandLine.arguments.dropFirst(3) {
    let url = URL(fileURLWithPath: path)
    let clock = ContinuousClock.now
    let ex = try excerpt(url, seconds: seconds, skip: skip)
    let de = try await probe(ex, "de_DE"), en = try await probe(ex, "en_US")
    let nl = NLLanguageRecognizer(); nl.processString(de.text)
    let nlDE = nl.languageHypotheses(withMaximum: 2)
    nl.reset(); nl.processString(en.text)
    let nlEN = nl.languageHypotheses(withMaximum: 2)
    let deOwn = (nlDE[.german] ?? 0) > 0.8, enOwn = (nlEN[.english] ?? 0) > 0.8
    var pick: String
    if deOwn && enOwn { pick = de.confidence >= en.confidence ? "de" : "en" }
    else if deOwn { pick = "de" } else if enOwn { pick = "en" }
    else { let best = de.confidence >= en.confidence ? nlDE : nlEN; pick = "NL:" + (best.max { $0.value < $1.value }?.key.rawValue ?? "?") }
    func f(_ h: [NLLanguage: Double]) -> String { h.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \(String(format: "%.2f", $0.value))" }.joined(separator: ",") }
    print("\(url.lastPathComponent)\tde \(String(format: "%.3f", de.confidence)) (\(de.words)w; NL \(f(nlDE)))\ten \(String(format: "%.3f", en.confidence)) (\(en.words)w; NL \(f(nlEN)))\t→ \(pick)  [\(ContinuousClock.now - clock)]")
    try? FileManager.default.removeItem(at: ex)
}
