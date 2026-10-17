import Darwin
import Foundation
import LiteRTLM

// FED-142: Gemma 4 E4B on LiteRT-LM against the app's Gemma 4 E2B on MLX, through the app's TranscriptTitler
// (requests, map-reduce, parsing). Prints the load time, each description's time and requests, the raw answer, the
// stored title and summary, and the process's peak memory (phys_footprint, what iOS's memory limit counts; GPU
// buffers included).
//
// usage: LiteRTBench mlx <modelDir>            <en|de|both> <repeat> <text.txt>…
//        LiteRTBench litert <file.litertlm> <gpu|cpu> <en|de|both> <repeat> <text.txt>…
// A text is one "Name: text" paragraph per line; <repeat> joins it that many times (the long-transcript case).

/// Peak phys_footprint, sampled every 20 ms on its own thread.
nonisolated final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakBytes: UInt64 = 0

    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let now = Self.current()
                lock.withLock { peakBytes = max(peakBytes, now) }
                usleep(20_000)
            }
        }
    }

    /// The peak since the last reset, then starts again from the current footprint.
    func takePeak() -> Double {
        lock.withLock {
            let peak = max(peakBytes, Self.current())
            peakBytes = Self.current()
            return Double(peak) / 1_073_741_824
        }
    }
}

/// Forwards to the model and keeps each request's time and answer.
nonisolated final class MeasuringWriter: TextWriter, @unchecked Sendable {
    let model: any TextWriter
    var requests: [(answer: String, seconds: Double, firstChunk: Double?)] = []

    init(model: any TextWriter) { self.model = model }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String {
        let start = Date()
        let first = FirstChunk()
        let answer = try await model.respond(instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                                             temperature: temperature) { _ in first.mark(start) }
        requests.append((answer, Date().timeIntervalSince(start), first.seconds))
        return answer
    }

    func chat(instructions: String, turns: [ChatTurn], maxTokens: Int, temperature: Float,
              partial: (@Sendable (String) -> Void)?) async throws -> String {
        try await model.chat(instructions: instructions, turns: turns, maxTokens: maxTokens, temperature: temperature,
                             partial: partial)
    }

    func unload() async { await model.unload() }
}

nonisolated final class FirstChunk: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func mark(_ start: Date) { lock.withLock { if value == nil { value = Date().timeIntervalSince(start) } } }
    var seconds: Double? { lock.withLock { value } }
}

func format(_ value: Double) -> String { String(format: "%.1f", value) }

let args = CommandLine.arguments
guard args.count > 5, args[1] == "mlx" || (args[1] == "litert" && args.count > 6) else {
    print("usage: LiteRTBench mlx <modelDir> <en|de|both> <repeat> <text.txt>…\n" +
          "       LiteRTBench litert <file.litertlm> <gpu|cpu> <en|de|both> <repeat> <text.txt>…")
    exit(1)
}
let sampler = FootprintSampler()
sampler.start()
let model: any TextWriter
let rest: ArraySlice<String>
let loadStart = Date()
if args[1] == "mlx" {
    let local = LocalLanguageModel(variant: .e2b, directory: URL(fileURLWithPath: args[2]))
    try await local.load()
    model = local
    rest = args[3...]
} else {
    let litert = LiteRTLanguageModel(file: URL(fileURLWithPath: args[2]), backend: args[3] == "cpu" ? .cpu() : .gpu)
    try await litert.load()
    model = litert
    rest = args[4...]
}
print("load: \(format(Date().timeIntervalSince(loadStart))) s, peak \(String(format: "%.2f", sampler.takePeak())) GB")

let languages = rest[rest.startIndex] == "both" ? ["en", "de"] : [rest[rest.startIndex]]
let repeatCount = Int(rest[rest.startIndex + 1]) ?? 1
let titler = TranscriptTitler()
for path in rest.dropFirst(2) {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let paragraphs = Array(repeating: lines, count: repeatCount).flatMap { $0 }
    print("\n######## \((path as NSString).lastPathComponent) ×\(repeatCount): \(paragraphs.joined(separator: "\n").count) characters")
    for language in languages {
        let writer = MeasuringWriter(model: model)
        _ = sampler.takePeak()
        let start = Date()
        let description: TranscriptTitler.Description?
        do {
            description = try await titler.describe(paragraphs, locale: Locale(identifier: language), writer: writer,
                                                    bookmarked: false,
                                                    limit: TranscriptTitler.chunkCharacters(
                                                        contextSize: LocalLanguageModel.contextTokens),
                                                    partial: nil)
        } catch {
            print("== \(language): error \(error)")
            continue
        }
        let seconds = Date().timeIntervalSince(start)
        print("\n======== \(language) · \(format(seconds)) s · \(writer.requests.count) request(s) · peak " +
              "\(String(format: "%.2f", sampler.takePeak())) GB")
        for (index, request) in writer.requests.enumerated() {
            print("-- request \(index + 1): \(format(request.seconds)) s, first chunk after " +
                  "\(request.firstChunk.map(format) ?? "-") s, \(request.answer.count) characters")
        }
        print("-- raw answer:\n\(writer.requests.last?.answer ?? "-")")
        print("-- stored: title \(description?.title ?? "-") · topics \(description?.topics ?? [])\n" +
              "\(description?.summary ?? "nil")")
    }
}
