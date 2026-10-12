import Foundation
import AVFoundation
import Synchronization

// sfbench <lseend|sortformer> <clean|noise dBFS, e.g. -55> [speed (x real time, default 5)] [meeting name filter]
//
// Streams each DiarBench meeting (16 kHz Int16 mono WAV, 12 three-minute German meetings of real MLS voices) the way
// the app does: 0.1 s pieces of the analyzer-format audio through ONE persistent AVAudioConverter to mono Float32 at
// the diarizer's rate (MicrophoneCapture's CaptureTap), into the app's own LiveDiarizer class. The snapshots are
// aligned with the exact word times of the ground truth by the app's TranscriptAligner (with island smoothing, as the
// live labels are). Pieces are fed at `speed` x real time; each snapshot is stamped with the audio fed when it
// arrived, which stands for when the label would appear on screen.
// SEED=<n> (environment) seeds the noise (default 55). Every snapshot is dumped to snap-<model>-<cond>-<meeting>.json in
// the working directory, so a run can be re-scored or diagnosed afterwards.

let lead = 0.12      // truth word times are Parakeet-like (audio - 0.12 s, compose.py); +lead = where they are spoken
let meetDir = URL(fileURLWithPath: "/Users/julius.taylor/projects/recorder/build/qa/diarbench/meet")

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: sfbench <lseend|sortformer> <clean|dBFS> [speed] [filter]")
    exit(2)
}
let modelName = arguments[1]
let noiseDB = arguments[2] == "clean" ? nil : Double(arguments[2])
let speed = arguments.count > 3 ? Double(arguments[3]) ?? 5 : 5
let filter = arguments.count > 4 ? arguments[4] : ""

struct Truth: Decodable {
    let text: String
    let start: Double
    let end: Double
    let speaker: String
    let turn: Int
    let interjection: Bool
}

/// The audio fed so far (seconds), read by the snapshot collector.
nonisolated final class FedClock: Sendable {
    private let seconds = Mutex<Double>(0)
    func set(_ value: Double) { seconds.withLock { $0 = value } }
    var value: Double { seconds.withLock { $0 } }
}

nonisolated struct Arrival: Sendable {
    let snapshot: LiveSpeakerTurns
    let fed: Double
}

/// SplitMix64 + Box-Muller: the same noise for both models.
struct Noise {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func gaussian() -> Double {
        let u1 = max(Double(next() >> 11) / Double(1 << 53), 1e-300)
        let u2 = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

/// MicrophoneCapture's CaptureTap.convert, verbatim: one-shot conversion with a persistent converter.
nonisolated func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
    let format = converter.outputFormat
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
    guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, outStatus in
        if consumed { outStatus.pointee = .noDataNow; return nil }
        consumed = true
        outStatus.pointee = .haveData
        return buffer
    }
    guard status != .error, converted.frameLength > 0 else { return nil }
    return converted
}

/// The meeting as analyzer-format pieces of 0.1 s (Int16, 16 kHz, mono), with the noise added.
func pieces(of url: URL, noise dB: Double?) throws -> (format: AVAudioFormat, pieces: [AVAudioPCMBuffer], seconds: Double) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
    let format = file.processingFormat
    let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: all)
    let n = Int(all.frameLength)
    let source = all.int16ChannelData![0]
    if let dB {
        var rng = Noise(state: UInt64(ProcessInfo.processInfo.environment["SEED"] ?? "55") ?? 55)
        let sigma = 32_768 * pow(10, dB / 20)
        for i in 0..<n {
            let value = Double(source[i]) + (rng.gaussian() * sigma).rounded()
            source[i] = Int16(max(-32_768, min(32_767, value)))
        }
    }
    var result: [AVAudioPCMBuffer] = []
    var offset = 0
    let step = Int(format.sampleRate / 10)
    while offset < n {
        let count = min(step, n - offset)
        let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        piece.frameLength = AVAudioFrameCount(count)
        piece.int16ChannelData![0].update(from: source + offset, count: count)
        result.append(piece)
        offset += count
    }
    return (format, result, Double(n) / format.sampleRate)
}

/// Best one-to-one mapping live label -> truth speaker (most matching words).
func bestMapping(labels: [Int?], refs: [String]) -> [Int: String] {
    var counts: [Int: [String: Int]] = [:]
    for (label, ref) in zip(labels, refs) { if let label { counts[label, default: [:]][ref, default: 0] += 1 } }
    let hyps = counts.keys.sorted()
    let speakers = Array(Set(refs)).sorted()
    var best: [Int: String] = [:]
    var bestScore = -1
    var current: [Int: String] = [:]
    func search(_ r: Int, used: Set<Int>, score: Int) {
        if r == speakers.count {
            if score > bestScore { bestScore = score; best = current }
            return
        }
        search(r + 1, used: used, score: score)              // this speaker gets no label
        for h in hyps where !used.contains(h) {
            current[h] = speakers[r]
            search(r + 1, used: used.union([h]), score: score + (counts[h]?[speakers[r]] ?? 0))
            current[h] = nil
        }
    }
    search(0, used: [], score: 0)
    return best
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = p * Double(sorted.count - 1)
    let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
    return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
}

struct MeetingResult: Codable {
    let meeting: String
    let words: Int
    let speakers: Int
    let liveSpeakers: Int
    let finalCorrect: Int
    let liveCorrect: Int
    let speaker1Words: Int
    let firstSpeakerWords: Int
    let delays: [Double]            // new speakers that got a correct label
    let missed: Int
    let audioSeconds: Double
    let cpuSeconds: Double
    let wallSeconds: Double
    let snapshots: Int
    let gaps: Int                   // snapshots missing in the sequence (should be 0)
    let lagP50: Double              // audio fed when a snapshot arrived minus its processedUntil
}

// MARK: - Run

let diarizer: any LiveDiarizer = modelName == "sortformer" ? SortformerLiveDiarizer() : LSEENDLiveDiarizer()
let step = modelName == "sortformer" ? SortformerLiveDiarizer.publishInterval : LSEENDLiveDiarizer.publishInterval
let loadStart = Date()
try await diarizer.prepare()
print("model \(modelName) loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s; noise \(noiseDB.map { "\($0) dBFS" } ?? "none"); \(speed)x real time; \(diarizer.sampleRate) Hz")

let meetings = try FileManager.default.contentsOfDirectory(atPath: meetDir.path)
    .filter { $0.hasSuffix(".wav") && (filter.isEmpty || $0.contains(filter)) }.sorted()
var results: [MeetingResult] = []
for name in meetings {
    let base = String(name.dropLast(4))
    let truth = try JSONDecoder().decode([Truth].self, from: Data(contentsOf: meetDir.appending(path: base + ".truth.json")))
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    let words = truth.map { TranscriptWord(text: $0.text, start: $0.start + lead, end: $0.end + lead) }
    let refs = truth.map(\.speaker)
    let audio = try pieces(of: meetDir.appending(path: name), noise: noiseDB)
    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: diarizer.sampleRate, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: audio.format, to: mono)!
    converter.primeMethod = .none

    let (samples, continuation) = AsyncStream<[Float]>.makeStream()
    let snapshots = diarizer.start(samples: samples)
    let clock = FedClock()
    let collector = Task.detached { () -> [Arrival] in
        var arrivals: [Arrival] = []
        for await snapshot in snapshots { arrivals.append(Arrival(snapshot: snapshot, fed: clock.value)) }
        return arrivals
    }
    let cpu0 = cpuSeconds()
    let wall0 = Date()
    var fedFrames = 0
    let pause = Duration.seconds(0.1 / speed)
    var next = ContinuousClock.now
    for piece in audio.pieces {
        if let out = convert(piece, with: converter), let channel = out.floatChannelData {
            continuation.yield(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
        }
        fedFrames += Int(piece.frameLength)
        clock.set(Double(fedFrames) / audio.format.sampleRate)
        next = next.advanced(by: pause)
        try await Task.sleep(until: next)
    }
    continuation.finish()
    let arrivals = await collector.value
    let cpu = cpuSeconds() - cpu0
    let wall = Date().timeIntervalSince(wall0)

    guard let final = arrivals.last, final.snapshot.processedUntil == .infinity else {
        print("\(base): no final snapshot (\(arrivals.count) snapshots)")
        continue
    }
    do {   // every snapshot, for re-scoring (processedUntil -1 = the final one)
        let dump: [[String: Any]] = arrivals.map { a in
            ["processedUntil": a.snapshot.processedUntil.isFinite ? a.snapshot.processedUntil : -1, "fed": a.fed,
             "turns": a.snapshot.turns.map { [Double($0.speakerIndex), $0.start, $0.end] }]
        }
        let data = try JSONSerialization.data(withJSONObject: ["meeting": base, "audioSeconds": audio.seconds,
                                                               "wallSeconds": wall, "snapshots": dump])
        try data.write(to: URL(fileURLWithPath: "snap-\(modelName)-\(noiseDB.map { "\(Int($0))" } ?? "clean")-\(base).json"))
    }
    let finalLabels = TranscriptAligner.speakers(words: words, turns: final.snapshot.turns)
    let mapping = bestMapping(labels: finalLabels, refs: refs)
    let liveSnapshots = arrivals.dropLast()
    var gaps = 0
    var previous = 0.0
    for arrival in liveSnapshots {
        gaps += max(0, Int(((arrival.snapshot.processedUntil - previous) / step).rounded()) - 1)
        previous = arrival.snapshot.processedUntil
    }

    // The label each word first showed, and when each speaker first showed correctly.
    var firstShown = [Int?](repeating: nil, count: words.count)
    var firstCorrect: [String: Double] = [:]
    for arrival in liveSnapshots + [final] {
        let labels = TranscriptAligner.speakers(words: words, turns: arrival.snapshot.turns,
                                                labelledUntil: arrival.snapshot.processedUntil)
        let shownAt = arrival.snapshot.processedUntil == .infinity ? audio.seconds : arrival.fed
        for (i, label) in labels.enumerated() {
            guard let label else { continue }
            if firstShown[i] == nil { firstShown[i] = label }
            if firstCorrect[refs[i]] == nil, mapping[label] == refs[i] { firstCorrect[refs[i]] = shownAt }
        }
    }
    var order: [String] = []
    for ref in refs where !order.contains(ref) { order.append(ref) }
    var delays: [Double] = []
    var missed = 0
    for speaker in order.dropFirst() {
        let firstWord = words[refs.firstIndex(of: speaker)!].start
        if let shown = firstCorrect[speaker] { delays.append(shown - firstWord) } else { missed += 1 }
    }
    let finalCorrect = zip(finalLabels, refs).filter { label, ref in label.flatMap { mapping[$0] } == ref }.count
    let liveCorrect = zip(firstShown, refs).filter { label, ref in label.flatMap { mapping[$0] } == ref }.count
    let lags = liveSnapshots.map { $0.fed - $0.snapshot.processedUntil }
    let result = MeetingResult(
        meeting: base, words: words.count, speakers: order.count,
        liveSpeakers: Set(final.snapshot.turns.map(\.speakerIndex)).count,
        finalCorrect: finalCorrect, liveCorrect: liveCorrect,
        speaker1Words: finalLabels.filter { $0 == 0 }.count, firstSpeakerWords: refs.filter { $0 == order[0] }.count,
        delays: delays, missed: missed, audioSeconds: audio.seconds, cpuSeconds: cpu, wallSeconds: wall,
        snapshots: arrivals.count, gaps: gaps, lagP50: percentile(lags, 0.5))
    results.append(result)
    print(String(format: "%@  final %5.1f %%  live %5.1f %%  spk1 %4.1f %% (truth %4.1f %%)  speakers %d/%d  new: %@ missed %d  cpu %.3f s/s  lag %.2f s  snaps %d gaps %d",
                 base.padding(toLength: 16, withPad: " ", startingAt: 0),
                 100 * Double(finalCorrect) / Double(words.count), 100 * Double(liveCorrect) / Double(words.count),
                 100 * Double(result.speaker1Words) / Double(words.count),
                 100 * Double(result.firstSpeakerWords) / Double(words.count),
                 result.liveSpeakers, result.speakers,
                 delays.map { String(format: "%.1f", $0) }.joined(separator: ","), missed,
                 cpu / audio.seconds, result.lagP50, arrivals.count, gaps))
}

let words = results.reduce(0) { $0 + $1.words }
let delays = results.flatMap(\.delays)
print(String(format: "ALL %@ %@: final %.1f %%  live %.1f %%  spk1 %.1f %% (truth %.1f %%)  new speaker p50 %.1f s p90 %.1f s (n %d) missed %d  cpu %.3f s per s of audio  lag p50 %.2f s",
             modelName, noiseDB.map { "\($0)" } ?? "clean",
             100 * Double(results.reduce(0) { $0 + $1.finalCorrect }) / Double(words),
             100 * Double(results.reduce(0) { $0 + $1.liveCorrect }) / Double(words),
             100 * Double(results.reduce(0) { $0 + $1.speaker1Words }) / Double(words),
             100 * Double(results.reduce(0) { $0 + $1.firstSpeakerWords }) / Double(words),
             percentile(delays, 0.5), percentile(delays, 0.9), delays.count, results.reduce(0) { $0 + $1.missed },
             results.reduce(0) { $0 + $1.cpuSeconds } / results.reduce(0) { $0 + $1.audioSeconds },
             percentile(results.map(\.lagP50), 0.5)))
let out = URL(fileURLWithPath: "results-\(modelName)-\(noiseDB.map { "\(Int($0))" } ?? "clean").json")
let encoder = JSONEncoder()
encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
try encoder.encode(results).write(to: out)
