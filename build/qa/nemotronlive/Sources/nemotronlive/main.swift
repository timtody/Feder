import AVFoundation
import FluidAudio
import Foundation

// FED-196's Mac check of Feder's NemotronLiveTranscriber logic. The variant and revision are the app's
// (NemotronLiveModel, AppServices.modelRevisions). Word errors are counted like build/qa/vocabbench's: letters and
// digits only, case folded, so they compare with its Apple 7.3 % / Parakeet 5.0 % / Dictation 16.9 % on these clips.

let revision = "1a41b75758b0337ff67db7d5408280aaaf23074e"
ModelRegistry.revisionOverrides = ["FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML": revision]
let args = CommandLine.arguments
let chunkMs = Int(ProcessInfo.processInfo.environment["CHUNK_MS"] ?? "") ?? 1120

/// ParakeetTranscriber.words(from:) from the app, copied (the app's enum is main-actor and pulls in its model state).
func words(from tokens: [TokenTiming]) -> [(text: String, start: Double, end: Double)] {
    var words: [(text: String, start: Double, end: Double)] = []
    var pendingBoundary = false
    for token in tokens where !token.token.isEmpty && token.token != "<blank>" && token.token != "<pad>" {
        let marked = token.token.hasPrefix("▁") || token.token.hasPrefix(" ")
        let piece = marked ? String(token.token.drop { $0 == "▁" || $0 == " " }) : token.token
        guard !piece.isEmpty else { pendingBoundary = true; continue }
        let startsWord = marked || pendingBoundary
        pendingBoundary = false
        let punctuationOnly = piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
        if words.isEmpty || (startsWord && !punctuationOnly) {
            words.append((piece, token.startTime, token.endTime))
        } else {
            words[words.count - 1].text += piece
            words[words.count - 1].end = max(words[words.count - 1].end, token.endTime)
        }
    }
    return words
}

func normalized(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { $0.isWhitespace })
        .map { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }
        .filter { !$0.isEmpty }
}

func edits(_ a: [String], _ b: [String]) -> Int {
    var row = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var previous = row[0]; row[0] = i + 1
        for (j, y) in b.enumerated() {
            let current = row[j + 1]
            row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (x == y ? 0 : 1))
            previous = current
        }
    }
    return row[b.count]
}

struct Streamed { var text: String; var ownText = ""; var lags: [Double]; var audioSeconds: Double; var wall: Double }

/// One file through a fresh manager, 100 ms at a time; `lags`: per finalized word, audio fed so far minus its end.
func stream(_ url: URL, shared: SharedNemotronMultilingualModels, vocabulary: [String]) async throws -> Streamed {
    let manager = StreamingNemotronMultilingualAsrManager()
    try await manager.loadFromShared(shared)
    await manager.setLanguage("de-DE")
    if !vocabulary.isEmpty { await manager.setCustomVocabulary(vocabulary.map { CustomVocabularyTerm(text: $0) }) }
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    let format = file.processingFormat, step = AVAudioFrameCount(format.sampleRate / 10)
    var fed = 0.0, finalized = 0, lags: [Double] = []
    let started = Date()
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { break }
        try file.read(into: buffer, frameCount: step)
        fed += Double(buffer.frameLength) / format.sampleRate
        _ = try await manager.process(audioBuffer: buffer)
        let now = words(from: await manager.getTokenTimings())
        let complete = max(0, now.count - 1)
        if complete > finalized {
            for word in now[finalized..<complete] { lags.append(fed - word.end) }
            finalized = complete
        }
    }
    let (ownText, timings) = try await manager.finishWithTokenTimings()
    let all = words(from: timings)
    await manager.cleanup()
    return Streamed(text: all.map(\.text).joined(separator: " "), ownText: ownText, lags: lags, audioSeconds: fed,
                    wall: Date().timeIntervalSince(started))
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

guard args.count >= 3 else {
    print("usage: nemotronlive wer <clips.json> [limit] | nemotronlive stream <file.wav>…   (CHUNK_MS=560|1120|2240)")
    exit(1)
}
print("downloading/loading latin/\(chunkMs)ms at \(revision.prefix(7)) …")
let loadStart = Date()
let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(languageCode: "de-DE", chunkMs: chunkMs)
print(String(format: "ready in %.1f s", Date().timeIntervalSince(loadStart)))

if args[1] == "glue" {
    // Our parser's words against FluidAudio's own text for the same decode: does the gluing come from us?
    struct Clips: Decodable { struct Clip: Decodable { var id: String; var wav: String; var text: String }; var clips: [Clip] }
    let clips = try JSONDecoder().decode(Clips.self, from: Data(contentsOf: URL(fileURLWithPath: args[2]))).clips
    let limit = args.count > 3 ? Int(args[3]) ?? clips.count : clips.count
    var oursE = 0, ownE = 0, total = 0, differ = 0, oursWords = 0, ownWords = 0
    for clip in clips.prefix(limit) {
        let r = try await stream(URL(fileURLWithPath: clip.wav), shared: shared, vocabulary: [])
        let ref = normalized(clip.text), ours = normalized(r.text), own = normalized(r.ownText)
        oursE += edits(ref, ours); ownE += edits(ref, own); total += ref.count
        oursWords += ours.count; ownWords += own.count
        if ours != own {
            differ += 1
            if differ <= 5 { print("-- ours: \(r.text)\n   own:  \(r.ownText)") }
        }
    }
    print(String(format: "%d clips: ours WER %.1f %% (%d words), FluidAudio's text WER %.1f %% (%d words), reference %d words; %d clips differ",
                 min(limit, clips.count), Double(oursE) / Double(total) * 100, oursWords, Double(ownE) / Double(total) * 100, ownWords, total, differ))
} else if args[1] == "wer" {
    struct Clips: Decodable { struct Clip: Decodable { var id: String; var wav: String; var text: String }; var clips: [Clip] }
    let clips = try JSONDecoder().decode(Clips.self, from: Data(contentsOf: URL(fileURLWithPath: args[2]))).clips
    let limit = args.count > 3 ? Int(args[3]) ?? clips.count : clips.count
    var errors = 0, total = 0, lags: [Double] = [], audio = 0.0, wall = 0.0, worst: [(Double, String, String)] = []
    for clip in clips.prefix(limit) {
        let result = try await stream(URL(fileURLWithPath: clip.wav), shared: shared, vocabulary: [])
        let reference = normalized(clip.text), heard = normalized(result.text)
        let e = edits(reference, heard)
        errors += e; total += reference.count; lags += result.lags; audio += result.audioSeconds; wall += result.wall
        worst.append((Double(e) / Double(max(1, reference.count)), clip.text, result.text))
    }
    print(String(format: "%d clips, %.1f min of audio: WER %.1f %% (%d errors / %d words); final after p50 %.2f s, p90 %.2f s; %.1f× real time",
                 min(limit, clips.count), audio / 60, Double(errors) / Double(total) * 100, errors, total,
                 percentile(lags, 0.5), percentile(lags, 0.9), audio / wall))
    for (rate, reference, heard) in worst.sorted(by: { $0.0 > $1.0 }).prefix(6) {
        print(String(format: "-- %.0f %%\n   ref:   %@\n   heard: %@", rate * 100, reference, heard))
    }
} else {
    for path in args.dropFirst(2) {
        let result = try await stream(URL(fileURLWithPath: path), shared: shared, vocabulary: [])
        print(String(format: "== %@: %.1f s audio, final after p50 %.2f s, p90 %.2f s, %.1f× real time",
                     (path as NSString).lastPathComponent, result.audioSeconds, percentile(result.lags, 0.5),
                     percentile(result.lags, 0.9), result.audioSeconds / result.wall))
        print(result.text.prefix(600))
    }
}
