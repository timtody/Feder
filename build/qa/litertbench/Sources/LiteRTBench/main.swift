import Darwin
import Foundation
import LiteRTLM

// FED-142: Gemma 4 E4B on LiteRT-LM against the app's Gemma 4 E2B on MLX, through the app's TranscriptTitler
// (requests, map-reduce, parsing). Prints the load time, each description's time and requests, the raw answer, the
// stored title and summary, and the process's peak phys_footprint and resident size. Neither is the model's memory:
// LiteRT's GPU reads the weights from the memory-mapped file, which phys_footprint leaves out, and resident_size misses
// GPU memory. Compare models on the whole Mac's used memory during a run (README › Better Summaries).
//
// usage: LiteRTBench mlx <modelDir>            <en|de|both> <repeat> <text.txt>…
//        LiteRTBench litert <file.litertlm> <gpu|cpu> <en|de|both> <repeat> <text.txt>…
// A text is one "Name: text" paragraph per line; <repeat> joins it that many times (the long-transcript case).

/// Peak phys_footprint, sampled every 20 ms on its own thread.
nonisolated final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakBytes: UInt64 = 0
    private var peakResident: UInt64 = 0

    static func current() -> UInt64 { info().phys_footprint }

    /// Resident pages, file-backed ones included (a memory-mapped model's weights, which phys_footprint leaves out).
    static func resident() -> UInt64 { info().resident_size }

    static func info() -> task_vm_info_data_t {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : task_vm_info_data_t()
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let now = Self.current()
                let resident = Self.resident()
                lock.withLock { peakBytes = max(peakBytes, now); peakResident = max(peakResident, resident) }
                usleep(20_000)
            }
        }
    }

    /// The peak since the last reset, then starts again from the current footprint.
    func takePeak() -> String {
        lock.withLock {
            let peak = max(peakBytes, Self.current()), resident = max(peakResident, Self.resident())
            peakBytes = Self.current()
            peakResident = Self.resident()
            return String(format: "%.2f GB (resident %.2f GB)", Double(peak) / 1_073_741_824,
                          Double(resident) / 1_073_741_824)
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

// `LiteRTBench parse`: TranscriptTitler.parseLabelled on the answers that failed in FED-142/153 and on its traps,
// no model; exits 1 on a failed check.
if args.count > 1, args[1] == "parse" {
    var failures = 0
    func check(_ answer: String, title: String?, summary: String?, topics: Int? = nil, _ what: String) {
        let parsed = TranscriptTitler.parseLabelled(answer)
        // Trimmed, as the app uses them (cleanTitle, plainSentences).
        let ok = parsed?.title.trimmingCharacters(in: .whitespaces) == title
            && parsed?.summary.trimmingCharacters(in: .whitespaces) == summary
            && (topics == nil || parsed?.topics.count == topics)
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(what): title \(parsed?.title ?? "nil") | summary \(parsed?.summary.prefix(60) ?? "nil") | topics \(parsed?.topics ?? [])")
    }
    check("Topics: budget; travel\nSummary: Anna moves the licence budget to travel.\nTitle: Budget Review",
          title: "Budget Review", summary: "Anna moves the licence budget to travel.", topics: 2, "three lines")
    check("Themen: Gletscher und Talformen; Moränen; Gletscherrückzug; Permafrost\nZusammenfassung: Ein Gletscher formt U-Täler durch Abschleifen. Die Teilnehmer lesen Kapitel 7.\nGletscherformen und Rückzug",
          title: "Gletscherformen und Rückzug", summary: "Ein Gletscher formt U-Täler durch Abschleifen. Die Teilnehmer lesen Kapitel 7.", topics: 4,
          "E4B on the Mac: the title without its label")
    check("Themen: Shell-Architektur; Frontend; Kanäle; Fachlichkeit; Zusammenfassung: Sophia erklärt die Architektur der Shell. Julius fragt nach Fragmenten. Titel: Shell-Architektur und Kanäle",
          title: "Shell-Architektur und Kanäle", summary: "Sophia erklärt die Architektur der Shell. Julius fragt nach Fragmenten.", topics: 4,
          "E4B on the iPhone: all on one line")
    check("Themen: Testphase Kreditprojektstand, Abnahme, Personalplanung, Budget; Zusammenfassung: Lena passt Erwartungswerte an, Jonas schickt Fehlerliste; Titel: Kreditprojekt: Testabnahmeplan",
          title: "Kreditprojekt: Testabnahmeplan", summary: "Lena passt Erwartungswerte an, Jonas schickt Fehlerliste", topics: 0,
          "E2B on LiteRT on the Mac: one line with semicolons")
    check("Themen: Budget\nZusammenfassung: Anna nennt drei Themen: Budget, Reisen und Lizenzen.\nTitel: Budgetrunde",
          title: "Budgetrunde", summary: "Anna nennt drei Themen: Budget, Reisen und Lizenzen.", "a summary that says \"Themen:\"")
    check("Topics: budget\nSummary: Anna gave a short summary: the budget moves to travel.\nTitle: Budget Review",
          title: "Budget Review", summary: "Anna gave a short summary: the budget moves to travel.", "English prose with \"summary:\"")
    check("Topics: budget\nSummary: Anna moves the budget.", title: nil, summary: nil, "no title at all: nil, as before")
    check("**Title:** Budget Review\n**Summary:** Anna moves the budget.", title: "Budget Review", summary: "Anna moves the budget.",
          "Markdown labels")
    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}

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
print("load: \(format(Date().timeIntervalSince(loadStart))) s, peak \(sampler.takePeak())")

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
        let before = ResourceCounters.now()
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
        // FED-195: the counters PipelineTrace samples on the iPhone, checked against the wall time here.
        let after = ResourceCounters.now()
        print(String(format: "-- counters: wall %.1f s, cpu %.1f s (p %.1f s), gpu %.1f s, energy %.1f J (%.1f W), billed %.1f J, neural %.0f MB",
                     after.uptime - before.uptime, Double(after.cpuNanoseconds - before.cpuNanoseconds) / 1e9,
                     Double(after.performanceNanoseconds - before.performanceNanoseconds) / 1e9,
                     Double(after.gpuNanoseconds - before.gpuNanoseconds) / 1e9,
                     Double(after.energyNanojoules - before.energyNanojoules) / 1e9,
                     Double(after.energyNanojoules - before.energyNanojoules) / 1e9 / max(0.001, after.uptime - before.uptime),
                     Double(after.billedEnergyNanojoules - before.billedEnergyNanojoules) / 1e9,
                     Double(after.neuralFootprint) / 1_048_576))
        print("\n======== \(language) · \(format(seconds)) s · \(writer.requests.count) request(s) · peak " +
              "\(sampler.takePeak())")
        for (index, request) in writer.requests.enumerated() {
            print("-- request \(index + 1): \(format(request.seconds)) s, first chunk after " +
                  "\(request.firstChunk.map(format) ?? "-") s, \(request.answer.count) characters")
        }
        print("-- raw answer:\n\(writer.requests.last?.answer ?? "-")")
        print("-- stored: title \(description?.title ?? "-") · topics \(description?.topics ?? [])\n" +
              "\(description?.summary ?? "nil")")
    }
}
