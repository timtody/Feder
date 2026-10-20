#if DEBUG
import Charts
import SwiftData
import SwiftUI

/// Settings › About › Pipeline Trace (Debug builds, FED-195): the recent transcripts' pipelines after Stop. English only
/// (`verbatim`): Debug-only, so its strings stay out of the catalog.
struct PipelineTraceList: View {
    private let trace = PipelineTrace.shared
    @State private var opened: UUID?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        AppForm {
            Section {
                if trace.traces.isEmpty {
                    Text(verbatim: "No pipeline yet. Record or import something; the steps after Stop appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(trace.traces) { item in
                    NavigationLink {
                        PipelineTraceView(id: item.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.name.isEmpty ? "Transcript" : item.name)
                            Text(verbatim: TraceAnalysis.summaryLine(item))
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in offsets.map { trace.traces[$0].id }.forEach(trace.delete) }
            } footer: {
                Text(verbatim: "Each transcript's steps after Stop with the memory, CPU, GPU and energy Feder used meanwhile, sampled every 250 ms. The last 20 are kept (Caches/PipelineTraces).")
            }
        }
        .navigationTitle(Text(verbatim: "Pipeline Trace"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { PipelineTraceView(id: $0) }
        .task {
            // The transcripts' names now: a trace keeps the one from when its pipeline began ("Neues Transkript 108"),
            // before Gemma's title or a rename. A Debug screen's one small fetch of at most 20 rows.
            let ids = trace.traces.map(\.id)
            let found = (try? modelContext.fetch(FetchDescriptor<Recording>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            for recording in found { trace.rename(recording.id, to: recording.name) }
            // `-openLatestTrace` (with `-showPipelineTrace`): screenshots.
            if ProcessInfo.processInfo.arguments.contains("-openLatestTrace") { opened = trace.traces.first?.id }
        }
    }
}

/// One transcript's pipeline on one time axis: the steps as bars (who), and under them what was used (memory, CPU
/// cores, power, GPU), each step's stretch tinted in every chart (when). Then a table per step.
struct PipelineTraceView: View {
    let id: UUID
    private let trace = PipelineTrace.shared
    @State private var analysis: TraceAnalysis?

    private var item: PipelineTrace.Trace? { trace.traces.first { $0.id == id } }

    var body: some View {
        AppForm {
            if let analysis {
                Section {
                    LabeledContent { Text(verbatim: analysis.header) } label: { Text(verbatim: "Total") }
                    if let battery = analysis.batteryText {
                        LabeledContent { Text(verbatim: battery) } label: { Text(verbatim: "Battery") }
                    }
                    LabeledContent { Text(verbatim: analysis.thermalText) } label: { Text(verbatim: "Thermal") }
                }
                Section {
                    stepsChart(analysis)
                } header: {
                    Text(verbatim: "Steps")
                }
                Section {
                    memoryChart(analysis)
                } header: {
                    Text(verbatim: "Memory")
                } footer: {
                    Text(verbatim: "Footprint: what iOS's memory limit counts (GPU buffers included). Dashed: the limit (footprint + memory left). Neural Engine: Feder's memory there.")
                }
                Section {
                    cpuChart(analysis)
                } header: {
                    Text(verbatim: "CPU: Cores Busy")
                } footer: {
                    Text(verbatim: "CPU time per second of wall time: 1 = one core fully busy. Light line: the share on performance cores.")
                }
                Section {
                    powerChart(analysis)
                } header: {
                    Text(verbatim: "Power")
                } footer: {
                    Text(verbatim: analysis.hasGPU
                         ? "Watts from the energy iOS attributes to Feder; GPU: busy share. Billed: also work daemons did for Feder."
                         : "Watts from the energy iOS attributes to Feder: its CPU work. This iPhone reports no GPU time for Feder, so Gemma's GPU work and the Neural Engine's are not in these watts. For them: Instruments › Power Profiler, whose timeline shows these steps (signposts \"de.timtody.feder\" / Pipeline).")
                }
                Section {
                    ForEach(analysis.steps) { step in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Circle().fill(TraceAnalysis.color(step.span.step)).frame(width: 8, height: 8)
                                Text(verbatim: step.title).font(.headline)
                            }
                            Text(verbatim: step.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(verbatim: "Per Step")
                } footer: {
                    Text(verbatim: "Energy: what iOS attributed to Feder's own process, mostly its CPU work, and each step's share of it. Not included: Apple's speech recognition (Words with Apple, Vocabulary), which runs in a system process, and GPU or Neural Engine work unless the iPhone reports it. For the whole iPhone's power per component: Instruments › Power Profiler, whose timeline shows these steps (signposts \"de.timtody.feder\" / Pipeline). Steps that overlap share what was used meanwhile.")
                }
                if let item {
                    Section {
                        ShareLink(item: PipelineTrace.file(item)) { Text(verbatim: "Share Trace (JSON)…") }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text(verbatim: item?.name.isEmpty == false ? item!.name : "Pipeline"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item?.spans.count) {
            // While a step runs: refreshed every second from the sampler's samples so far.
            while !Task.isCancelled {
                guard var current = item else { return }
                if current.isRunning || current.samples.isEmpty { current.samples = trace.liveSamples() }
                analysis = TraceAnalysis(current)
                guard current.isRunning else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Charts (one x axis: seconds since the first step began)

    private func stepsChart(_ a: TraceAnalysis) -> some View {
        Chart {
            ForEach(a.steps) { step in
                BarMark(xStart: .value("Start", step.from), xEnd: .value("End", step.to),
                        y: .value("Step", step.span.step.title))
                    .foregroundStyle(TraceAnalysis.color(step.span.step).opacity(step.span.failed ? 0.4 : 1))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(verbatim: step.span.model ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            ForEach(a.marks) { mark in
                RuleMark(x: .value("Mark", mark.time))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(verbatim: mark.label).font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: 0...a.duration)
        .chartXAxisLabel { Text(verbatim: "seconds") }
        .frame(height: CGFloat(max(2, a.lanes)) * 34 + 40)
    }

    private func bands(_ a: TraceAnalysis) -> some ChartContent {
        ForEach(a.steps) { step in
            RectangleMark(xStart: .value("Start", step.from), xEnd: .value("End", step.to))
                .foregroundStyle(TraceAnalysis.color(step.span.step).opacity(0.10))
        }
    }

    private func memoryChart(_ a: TraceAnalysis) -> some View {
        Chart {
            bands(a)
            ForEach(a.points) { point in
                LineMark(x: .value("Time", point.time), y: .value("GB", point.footprint),
                         series: .value("Series", "Footprint"))
                    .foregroundStyle(.blue)
                LineMark(x: .value("Time", point.time), y: .value("GB", point.neural),
                         series: .value("Series", "Neural Engine"))
                    .foregroundStyle(.purple)
            }
            if let limit = a.limit {
                RuleMark(y: .value("Limit", limit))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(verbatim: String(format: "limit %.1f GB", limit)).font(.caption2).foregroundStyle(.red)
                    }
            }
        }
        .chartXScale(domain: 0...a.duration)
        .chartYAxisLabel { Text(verbatim: "GB") }
        .chartForegroundStyleScale(["Footprint": Color.blue, "Neural Engine": Color.purple])
        .frame(height: 160)
    }

    private func cpuChart(_ a: TraceAnalysis) -> some View {
        Chart {
            bands(a)
            ForEach(a.points) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Cores", point.cores))
                    .foregroundStyle(.orange.opacity(0.5))
                LineMark(x: .value("Time", point.time), y: .value("Cores", point.performanceCores))
                    .foregroundStyle(.orange)
            }
        }
        .chartXScale(domain: 0...a.duration)
        .chartYAxisLabel { Text(verbatim: "cores") }
        .frame(height: 140)
    }

    private func powerChart(_ a: TraceAnalysis) -> some View {
        Chart {
            bands(a)
            ForEach(a.points) { point in
                AreaMark(x: .value("Time", point.time), y: .value("W", point.watts))
                    .foregroundStyle(.green.opacity(0.5))
                if a.hasBilled {
                    LineMark(x: .value("Time", point.time), y: .value("W", point.billedWatts),
                             series: .value("Series", "Billed"))
                        .foregroundStyle(.teal)
                }
                if a.hasGPU {
                    LineMark(x: .value("Time", point.time), y: .value("W", point.gpu * a.maxWatts),
                             series: .value("Series", "GPU busy"))
                        .foregroundStyle(.pink)
                }
            }
        }
        .chartXScale(domain: 0...a.duration)
        .chartYAxisLabel { Text(verbatim: "W") }
        .frame(height: 140)
    }
}

/// A trace turned into chart points and per-step figures (pure).
nonisolated struct TraceAnalysis: Sendable {
    nonisolated struct Point: Identifiable, Sendable {
        var id: Double { time }
        var time: Double                    // seconds since the first step began
        var footprint: Double               // GB
        var neural: Double                  // GB
        var cores: Double
        var performanceCores: Double
        var watts: Double
        var billedWatts: Double
        var gpu: Double                     // 0…1 busy
    }

    nonisolated struct StepFigures: Identifiable, Sendable {
        var id: UUID { span.id }
        var span: PipelineTrace.Span
        var from: Double, to: Double
        var title: String
        var detail: String
    }

    nonisolated struct MarkPoint: Identifiable, Sendable {
        var id: UUID
        var time: Double
        var label: String
    }

    var points: [Point] = []
    var steps: [StepFigures] = []
    var marks: [MarkPoint] = []
    var duration: Double = 1
    var lanes = 1
    var limit: Double?
    var hasGPU = false
    var hasBilled = false
    var maxWatts: Double = 1
    var header = ""
    var batteryText: String?
    var thermalText = ""

    init(_ trace: PipelineTrace.Trace) {
        let origin = trace.start
        let samples = trace.samples.sorted { $0.uptime < $1.uptime }
        duration = max(1, max(trace.end, samples.last?.uptime ?? trace.end) - origin)
        lanes = Set(trace.spans.map(\.step)).count
        for (previous, sample) in zip(samples, samples.dropFirst()) {
            let dt = max(0.001, sample.uptime - previous.uptime)
            points.append(Point(time: sample.uptime - origin,
                                footprint: Double(sample.footprint) / 1_073_741_824,
                                neural: Double(sample.neuralFootprint) / 1_073_741_824,
                                cores: Double(sample.cpuNanoseconds &- previous.cpuNanoseconds) / 1e9 / dt,
                                performanceCores: Double(sample.performanceNanoseconds &- previous.performanceNanoseconds) / 1e9 / dt,
                                watts: Double(sample.energyNanojoules &- previous.energyNanojoules) / 1e9 / dt,
                                billedWatts: Double(sample.billedEnergyNanojoules &- previous.billedEnergyNanojoules) / 1e9 / dt,
                                gpu: min(1, Double(sample.gpuNanoseconds &- previous.gpuNanoseconds) / 1e9 / dt)))
        }
        hasGPU = points.contains { $0.gpu > 0 }
        hasBilled = points.contains { $0.billedWatts > 0 }
        maxWatts = max(1, points.map(\.watts).max() ?? 1)
        if let first = samples.first(where: { $0.available > 0 }) {
            limit = Double(first.footprint + first.available) / 1_073_741_824
        }
        let total = Self.delta(samples, from: trace.start, to: trace.end)
        for span in trace.spans.sorted(by: { $0.start < $1.start }) {
            let end = span.end ?? (samples.last?.uptime ?? span.start)
            let d = Self.delta(samples, from: span.start, to: end)
            let wall = end - span.start
            let inside = samples.filter { $0.uptime >= span.start && $0.uptime <= end }
            let peak = Double(inside.map(\.footprint).max() ?? 0) / 1_073_741_824
            let overlaps = trace.spans.filter { $0.id != span.id && $0.start < end && ($0.end ?? .infinity) > span.start }
            var parts = [String(format: "%.1f s", wall)]
            parts.append(String(format: "CPU %.1f s (%.1f cores)", d.cpu, d.cpu / max(0.001, wall)))
            if hasGPU { parts.append(String(format: "GPU %.1f s", d.gpu)) }
            parts.append(String(format: "%.1f J, %.1f W", d.energy, d.energy / max(0.001, wall)))
            if total.energy > 0 { parts.append(String(format: "%.0f %% of the energy", d.energy / total.energy * 100)) }
            parts.append(String(format: "peak %.2f GB", peak))
            if !overlaps.isEmpty { parts.append("overlaps " + overlaps.map(\.step.title).joined(separator: ", ")) }
            if span.failed { parts.append("failed") }
            if span.end == nil { parts.append("running") }
            steps.append(StepFigures(span: span, from: span.start - origin, to: end - origin,
                                     title: span.step.title + (span.model.map { " · \($0)" } ?? ""),
                                     detail: parts.joined(separator: " · ")))
        }
        // Marks within half a second share one label ("turns, voices"), so they don't print over each other.
        for mark in trace.marks.sorted(by: { $0.time < $1.time }) {
            if let last = marks.last, mark.time - origin - last.time < 0.5 {
                marks[marks.count - 1].label += ", " + mark.label
            } else {
                marks.append(MarkPoint(id: mark.id, time: mark.time - origin, label: mark.label))
            }
        }
        let wall = trace.end - trace.start
        header = String(format: "%.1f s · CPU %.1f s · Feder's energy %.1f J (%.2f mWh)", wall, total.cpu, total.energy,
                        total.energy / 3.6) + (trace.audioSeconds.map { String(format: " · %.1f min of audio", $0 / 60) } ?? "")
        let startLevel = trace.spans.map(\.batteryStart).first { $0 >= 0 }
        let endLevel = trace.spans.compactMap(\.batteryEnd).last { $0 >= 0 }
        if let startLevel, let endLevel {
            batteryText = String(format: "%.0f %% → %.0f %%", startLevel * 100, endLevel * 100) + " (1 % steps)"
        }
        let worst = samples.map(\.thermal).max() ?? 0
        thermalText = ["nominal", "fair", "serious", "critical"][min(3, max(0, worst))] + " at worst"
    }

    /// The counters' change between the samples nearest `from` and `to`.
    static func delta(_ samples: [ResourceCounters], from: Double, to: Double) -> (cpu: Double, gpu: Double, energy: Double) {
        guard let a = samples.last(where: { $0.uptime <= from + 0.125 }) ?? samples.first,
              let b = samples.first(where: { $0.uptime >= to - 0.125 }) ?? samples.last, b.uptime >= a.uptime else {
            return (0, 0, 0)
        }
        return (Double(b.cpuNanoseconds &- a.cpuNanoseconds) / 1e9, Double(b.gpuNanoseconds &- a.gpuNanoseconds) / 1e9,
                Double(b.energyNanojoules &- a.energyNanojoules) / 1e9)
    }

    static func summaryLine(_ trace: PipelineTrace.Trace) -> String {
        let analysis = TraceAnalysis(trace)
        return trace.started.formatted(date: .abbreviated, time: .shortened) + " · " + analysis.header
            + (trace.isRunning ? " · running" : "")
    }

    static func color(_ step: PipelineTrace.Step) -> Color {
        switch step {
        case .words: .blue
        case .speakers: .orange
        case .vocabulary: .purple
        case .summary: .green
        case .actionItems: .pink
        }
    }
}
#endif
