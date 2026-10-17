#if LITERT
import SwiftData
import SwiftUI

/// Settings › Feder Lab (FederLab target only, FED-150): the LiteRT models' downloads, the model that writes summaries and
/// answers in Ask, and the bench on the user's own transcripts with its report. English only (`verbatim`): the Lab never
/// ships, so its strings stay out of the catalog.
struct ModelLabView: View {
    @Environment(AppServices.self) private var services
    @Query(Self.recent) private var recordings: [Recording]
    @State private var chosen: Set<UUID>?
    @State private var models: Set<ModelLab.Model>?
    @State private var batteryMinutes = 0
    @State private var copied = false
    private let lab = ModelLab.shared

    static var recent: FetchDescriptor<Recording> {
        var descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 40
        return descriptor
    }

    private var transcripts: [Recording] { recordings.filter { $0.speakerStatus == .done && !$0.segments.isEmpty } }
    private var ready: [ModelLab.Model] { ModelLab.Model.allCases.filter(isReady) }
    /// The 3 newest transcripts and every downloaded model, until the user picks.
    private var chosenIDs: Set<UUID> { chosen ?? Set(transcripts.prefix(3).map(\.id)) }
    private var chosenModels: Set<ModelLab.Model> { models ?? Set(ready) }

    var body: some View {
        @Bindable var lab = lab
        AppForm {
            Section {
                ForEach(ModelLab.Model.allCases) { model in
                    modelRow(model)
                }
            } header: {
                Text(verbatim: "Models")
            } footer: {
                Text(verbatim: "LiteRT files from Hugging Face (litert-community, pinned), over Wi-Fi in the background. E2B · MLX is the app's own model: Settings › Summaries.")
            }

            Section {
                Picker(selection: $lab.writer) {
                    ForEach(ModelLab.Model.allCases.filter { isReady($0) || $0 == .mlxE2B || $0 == lab.writer }) {
                        Text(verbatim: $0.name).tag($0)
                    }
                } label: {
                    Text(verbatim: "Model")
                }
                Toggle(isOn: $lab.speculativeDecoding) { Text(verbatim: "Speculative Decoding (LiteRT)") }
            } header: {
                Text(verbatim: "Writes Summaries and Answers")
            } footer: {
                Text(verbatim: "New transcripts, those still without a summary, and the Ask tab use this model.")
            }

            Section {
                ForEach(ready) { model in
                    Toggle(isOn: Binding(get: { chosenModels.contains(model) },
                                         set: { _ in models = chosenModels.symmetricDifference([model]) })) {
                        Text(verbatim: model.name)
                    }
                }
                Picker(selection: $batteryMinutes) {
                    Text(verbatim: "Off").tag(0)
                    ForEach([10, 20, 30], id: \.self) { Text(verbatim: "\($0) min per model").tag($0) }
                } label: {
                    Text(verbatim: "Battery Run")
                }
                if lab.isRunning {
                    LabeledContent { ProgressView() } label: { Text(verbatim: lab.status) }
                    Button(role: .destructive) { lab.stop() } label: { Text(verbatim: "Stop") }
                } else {
                    Button { start() } label: {
                        Text(verbatim: "Run Bench (\(chosenIDs.count) transcripts × \(chosenModels.count) models)")
                    }
                    .disabled(chosenIDs.isEmpty || chosenModels.isEmpty)
                    if !lab.status.isEmpty { Text(verbatim: lab.status).foregroundStyle(.secondary) }
                }
            } header: {
                Text(verbatim: "Bench")
            } footer: {
                Text(verbatim: "Each model summarizes each chosen transcript as the app does, one model in memory at a time; background summaries wait. Keep Feder open: the screen stays on. A battery run needs the iPhone unplugged\(UIDevice.current.batteryState == .unplugged ? "" : " (it is charging now)").")
            }

            Section {
                ForEach(transcripts) { recording in
                    Button {
                        chosen = chosenIDs.symmetricDifference([recording.id])
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: recording.name).foregroundStyle(.primary)
                                Text(verbatim: Duration.seconds(recording.duration)
                                    .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if chosenIDs.contains(recording.id) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text(verbatim: "Transcripts (\(chosenIDs.count) chosen)")
            }

            if !lab.runs.isEmpty || !lab.batteryRuns.isEmpty {
                results
            }
        }
        .navigationTitle(Text(verbatim: "Feder Lab"))
        .navigationBarTitleDisplayMode(.inline)
        .task {                     // `-runLabBench`: the default bench starts once the transcripts are there (QA)
            guard ProcessInfo.processInfo.arguments.contains("-runLabBench"), !lab.isRunning, lab.runs.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
            start()
        }
    }

    private func isReady(_ model: ModelLab.Model) -> Bool {
        model == .mlxE2B ? services.betterSummaries.state == .ready : lab.states[model] == .ready
    }

    @ViewBuilder
    private func modelRow(_ model: ModelLab.Model) -> some View {
        if model == .mlxE2B {
            LabeledContent {
                Text(verbatim: isReady(model) ? "Downloaded" : "Settings › Summaries")
            } label: {
                Text(verbatim: model.name)
            }
        } else if lab.states[model] == .ready {
            LabeledContent {
                Button(role: .destructive) { lab.delete(model) } label: { Text(verbatim: "Delete") }
            } label: {
                Text(verbatim: "\(model.name) (\(model.sizeText))")
            }
        } else {
            ModelDownloadRow(name: model.name, state: lab.states[model] ?? .notDownloaded, size: model.sizeText) {
                lab.download(model)
            }
        }
    }

    private func start() {
        let inputs = transcripts.filter { chosenIDs.contains($0.id) }.map(ModelLab.input)
        lab.run(models: ModelLab.Model.allCases.filter(chosenModels.contains), inputs: inputs,
                batteryMinutes: batteryMinutes > 0 ? batteryMinutes : nil)
    }

    @ViewBuilder
    private var results: some View {
        ForEach(ModelLab.unique(lab.runs.map(\.transcript)), id: \.self) { transcript in
            Section {
                ForEach(lab.runs.filter { $0.transcript == transcript }) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: run.model.name).font(.headline)
                        Text(verbatim: stats(run)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if let title = run.title { Text(verbatim: title).bold() }
                        Text(verbatim: run.error.map { "Error: \($0)" } ?? run.summary ?? "")
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(verbatim: transcript)
            }
        }
        if !lab.batteryRuns.isEmpty {
            Section {
                ForEach(lab.batteryRuns) { run in
                    LabeledContent {
                        Text(verbatim: run.batteryUsed > 0
                             ? String(format: "%.1f per 1 %%", Double(run.summaries) / run.batteryUsed) : "< 1 % used")
                    } label: {
                        Text(verbatim: run.model.name)
                        Text(verbatim: String(format: "%d summaries, %.0f %% in %.0f min, %@", run.summaries,
                                              run.batteryUsed, run.minutes, run.thermal))
                    }
                }
            } header: {
                Text(verbatim: "Battery: Summaries per 1 %")
            }
        }
        Section {
            Button { UIPasteboard.general.string = lab.report; copied = true } label: {
                Text(verbatim: copied ? "Copied" : "Copy Report")
            }
            ShareLink(item: lab.report) { Text(verbatim: "Share Report…") }
        } footer: {
            if let file = lab.reportFile { Text(verbatim: "Also saved in the app's Caches: FederLab/\(file.lastPathComponent)") }
        }
    }

    private func stats(_ run: ModelLab.Run) -> String {
        var parts = [ModelLab.seconds(run.seconds)]
        if let first = run.firstWords { parts.append("first words " + ModelLab.seconds(first)) }
        if run.requests > 1 { parts.append("\(run.requests) requests") }
        if let load = run.loadSeconds { parts.append("load " + ModelLab.seconds(load)) }
        parts.append(String(format: "peak %.2f GB, least left %.2f GB", run.peakFootprint, run.leastAvailable))
        parts.append(run.thermal)
        return parts.joined(separator: " · ")
    }
}
#endif
