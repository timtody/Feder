#if DEBUG
import Foundation
import Observation
import os
import UIKit

/// Debug builds: a resource timeline of the steps after Stop (FED-195). SpeakerIdentifier reports each step's start and
/// end per transcript (`track`), the model that did it, and marks inside the speakers step; meanwhile a sampler reads
/// the process's counters (ResourceCounters) every 250 ms. Settings › About › Pipeline Trace draws them on one time
/// axis: which step ran when, and what memory, CPU, GPU and energy it took. Each step is also an os_signpost interval
/// (subsystem de.timtody.feder, category Pipeline), so Instruments' Power Profiler on the iPhone shows the GPU and
/// Neural Engine power the app's own counters don't see, under the same step names.
@MainActor @Observable
final class PipelineTrace {
    static let shared = PipelineTrace()

    nonisolated enum Step: String, Codable, Sendable, CaseIterable {
        case words, speakers, vocabulary, summary, actionItems

        var title: String {
            switch self {
            case .words: "Words"
            case .speakers: "Speakers"
            case .vocabulary: "Vocabulary"
            case .summary: "Summary"
            case .actionItems: "Action Items"
            }
        }

        init(_ step: PipelineProgress.Step) {
            switch step {
            case .words: self = .words
            case .speakers: self = .speakers
            case .vocabulary: self = .vocabulary
            case .summary: self = .summary
            }
        }
    }

    nonisolated struct Span: Codable, Sendable, Identifiable {
        var id = UUID()
        var step: Step
        var start: Double                   // uptime, seconds
        var end: Double?
        var model: String?                  // "Parakeet", "nemotron", "Gemma 4 E2B"…
        var failed = false
        var batteryStart: Float
        var batteryEnd: Float?
    }

    nonisolated struct Mark: Codable, Sendable, Identifiable {
        var id = UUID()
        var time: Double
        var label: String
    }

    /// One transcript's pipeline: its steps, the marks inside them, and the samples while it ran.
    nonisolated struct Trace: Codable, Sendable, Identifiable {
        var id: UUID                        // the recording's
        var name: String
        var audioSeconds: Double?
        var started: Date
        var spans: [Span] = []
        var marks: [Mark] = []
        var samples: [ResourceCounters] = []
        var deviceMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

        var start: Double { spans.map(\.start).min() ?? 0 }
        var end: Double { spans.compactMap(\.end).max() ?? (samples.last?.uptime ?? start) }
        var isRunning: Bool { spans.contains { $0.end == nil } }
    }

    private(set) var traces: [Trace] = []            // newest first, the last 20
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "de.timtody.feder", category: "Pipeline")
    @ObservationIgnored private var intervals: [String: OSSignpostIntervalState] = [:]
    @ObservationIgnored private var idleSince: Date?

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        traces = Self.load()
    }

    private var battery: Float { UIDevice.current.batteryLevel }

    /// The transcript's name and length, when SpeakerIdentifier starts on it.
    func label(_ id: UUID, name: String, audioSeconds: Double) {
        let index = traceIndex(id)
        traces[index].name = name
        traces[index].audioSeconds = audioSeconds
    }

    /// SpeakerIdentifier.track: the progress before and after a change; every step that began or ended is recorded.
    func progressChanged(_ id: UUID, from old: PipelineProgress?, to new: PipelineProgress?) {
        for step in PipelineProgress.Step.allCases {
            let was = old?.state(of: step), now = new?.state(of: step)
            let wasRunning = if case .running = was { true } else { false }
            let isRunning = if case .running = now { true } else { false }
            if isRunning && !wasRunning { begin(id, Step(step)) }
            if wasRunning && !isRunning {
                let failed = if case .failed = now { true } else { false }
                end(id, Step(step), failed: failed)
            }
        }
    }

    func begin(_ id: UUID, _ step: Step) {
        let index = traceIndex(id)
        traces[index].spans.append(Span(step: step, start: ProcessInfo.processInfo.systemUptime, batteryStart: battery))
        intervals["\(id)|\(step.rawValue)"] = beginInterval(step)
        idleSince = nil
        sampler.start()
    }

    func end(_ id: UUID, _ step: Step, failed: Bool = false) {
        guard let index = traces.firstIndex(where: { $0.id == id }),
              let span = traces[index].spans.lastIndex(where: { $0.step == step && $0.end == nil }) else { return }
        traces[index].spans[span].end = ProcessInfo.processInfo.systemUptime
        traces[index].spans[span].failed = failed
        traces[index].spans[span].batteryEnd = battery
        if let state = intervals.removeValue(forKey: "\(id)|\(step.rawValue)") { endInterval(step, state) }
        if !traces.contains(where: \.isRunning) { scheduleStop() }
    }

    /// The model that did `step` (the last span of it).
    func model(_ id: UUID, _ step: Step, _ model: String) {
        guard let index = traces.firstIndex(where: { $0.id == id }),
              let span = traces[index].spans.lastIndex(where: { $0.step == step }) else { return }
        traces[index].spans[span].model = model
    }

    /// A moment inside a step ("model ready", "turns", "voices").
    func mark(_ id: UUID, _ label: String) {
        let index = traceIndex(id)
        traces[index].marks.append(Mark(time: ProcessInfo.processInfo.systemUptime, label: label))
        signposter.emitEvent("Mark", "\(label, privacy: .public)")
    }

    private func traceIndex(_ id: UUID) -> Int {
        if let index = traces.firstIndex(where: { $0.id == id }) { return index }
        traces.insert(Trace(id: id, name: "", started: .now), at: 0)
        if traces.count > 20 { traces.removeLast(traces.count - 20) }
        return 0
    }

    /// Nothing runs: the sampler goes on 3 s more (the tail after the last step), then the samples go into the
    /// traces they belong to and every finished trace is saved.
    private func scheduleStop() {
        idleSince = .now
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let idle = idleSince, Date.now.timeIntervalSince(idle) >= 2.9 else { return }
            let samples = sampler.stop()
            for index in traces.indices where !traces[index].isRunning {
                let from = traces[index].start - 1, to = traces[index].end + 3
                // Merged, not replaced: a transcript's vocabulary or summary can run minutes after its speakers,
                // with the sampler stopped in between.
                let known = Set(traces[index].samples.map(\.uptime))
                let mine = samples.filter { $0.uptime >= from && $0.uptime <= to && !known.contains($0.uptime) }
                if !mine.isEmpty { traces[index].samples = (traces[index].samples + mine).sorted { $0.uptime < $1.uptime } }
            }
            save()
        }
    }

    /// The transcript's current name (Gemma's title or the user's rename come after its pipeline began), saved into the
    /// trace's file so the Mac viewer shows it too.
    func rename(_ id: UUID, to name: String) {
        guard let index = traces.firstIndex(where: { $0.id == id }), traces[index].name != name else { return }
        traces[index].name = name
        if !traces[index].isRunning { save() }
    }

    func delete(_ id: UUID) {
        traces.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.directory.appending(path: "\(id).json"))
    }

    /// While a trace runs, its samples so far (the view's live update).
    func liveSamples() -> [ResourceCounters] { sampler.snapshot() }

    // MARK: Signposts (StaticString names, one per step)

    private func beginInterval(_ step: Step) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return switch step {
        case .words: signposter.beginInterval("Words", id: id)
        case .speakers: signposter.beginInterval("Speakers", id: id)
        case .vocabulary: signposter.beginInterval("Vocabulary", id: id)
        case .summary: signposter.beginInterval("Summary", id: id)
        case .actionItems: signposter.beginInterval("Action Items", id: id)
        }
    }

    private func endInterval(_ step: Step, _ state: OSSignpostIntervalState) {
        switch step {
        case .words: signposter.endInterval("Words", state)
        case .speakers: signposter.endInterval("Speakers", state)
        case .vocabulary: signposter.endInterval("Vocabulary", state)
        case .summary: signposter.endInterval("Summary", state)
        case .actionItems: signposter.endInterval("Action Items", state)
        }
    }

    // MARK: Files (Caches/PipelineTraces, one JSON per transcript)

    nonisolated static let directory = URL.cachesDirectory.appending(path: "PipelineTraces")

    nonisolated static func file(_ trace: Trace) -> URL { directory.appending(path: "\(trace.id).json") }

    private func save() {
        let finished = traces.filter { !$0.isRunning }
        Task.detached {
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for trace in finished {
                try? encoder.encode(trace).write(to: Self.file(trace), options: .atomic)
            }
        }
    }

    /// The traces saved before (Debug only, a few files: read once at launch).
    private static func load() -> [Trace] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? decoder.decode(Trace.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
            .prefix(20).map { $0 }
    }
}

/// Reads ResourceCounters every 250 ms on a thread of its own while a step runs.
private nonisolated final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var samples: [ResourceCounters] = []

    func start() {
        let starting: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            samples = []
            return true
        }
        guard starting else { return }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sample = ResourceCounters.now()
                lock.withLock { samples.append(sample) }
                usleep(250_000)
            }
        }
    }

    func stop() -> [ResourceCounters] {
        lock.withLock {
            running = false
            return samples
        }
    }

    func snapshot() -> [ResourceCounters] { lock.withLock { samples } }
}
#endif
