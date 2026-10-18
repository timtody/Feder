#if LITERT
import SwiftData
import SwiftUI

/// Settings › Feder Lab (FederLab target only, FED-150, FED-153): the LiteRT models' downloads, the model that writes
/// summaries and answers in Ask, and the bench on the Lab's bench texts and the user's own transcripts, repeated with
/// the model order rotating, with its report. English only (`verbatim`): the Lab never ships, so its strings stay out of
/// the catalog.
struct ModelLabView: View {
    @Environment(AppServices.self) private var services
    @Query(Self.recent) private var recordings: [Recording]
    @State private var benchTexts: [ModelLab.Input] = []
    @State private var chosenTexts: Set<String>?
    @State private var chosenTranscripts: Set<UUID> = []
    @State private var models: Set<ModelLab.Model>?
    @State private var repetitions = 5
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
    /// Every bench text and every downloaded model until the user picks; the user's own transcripts only when picked.
    private var textIDs: Set<String> { chosenTexts ?? Set(benchTexts.map(\.id)) }
    private var chosenModels: Set<ModelLab.Model> { models ?? Set(ready) }
    private var inputCount: Int { textIDs.count + chosenTranscripts.count }

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
                Stepper(value: $repetitions, in: 1...10) {
                    LabeledContent { Text(verbatim: "\(repetitions)") } label: { Text(verbatim: "Repetitions") }
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
                        Text(verbatim: "Run Bench (\(inputCount) inputs × \(chosenModels.count) models × \(repetitions))")
                    }
                    .disabled(inputCount == 0 || chosenModels.isEmpty)
                    if !lab.status.isEmpty { Text(verbatim: lab.status).foregroundStyle(.secondary) }
                }
            } header: {
                Text(verbatim: "Bench")
            } footer: {
                Text(verbatim: "Each model summarizes each chosen input as the app does, one model in memory at a time, the model order rotating with every repetition; background summaries wait. Keep Feder open: the screen stays on. A battery run needs the iPhone unplugged\(UIDevice.current.batteryState == .unplugged ? "" : " (it is charging now)").")
            }

            Section {
                ForEach(benchTexts) { text in
                    choiceRow(text.name, detail: "\(text.characters.formatted()) characters", chosen: textIDs.contains(text.id)) {
                        chosenTexts = textIDs.symmetricDifference([text.id])
                    }
                }
            } header: {
                Text(verbatim: "Bench Texts (\(textIDs.count) chosen)")
            } footer: {
                Text(verbatim: "Synthetic meetings and a lecture in German and English, written for the bench. They are part of Feder Lab and never appear among your transcripts.")
            }

            Section {
                ForEach(transcripts) { recording in
                    choiceRow(recording.name,
                              detail: Duration.seconds(recording.duration)
                                  .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)),
                              chosen: chosenTranscripts.contains(recording.id)) {
                        chosenTranscripts = chosenTranscripts.symmetricDifference([recording.id])
                    }
                }
            } header: {
                Text(verbatim: "Your Transcripts (\(chosenTranscripts.count) chosen)")
            } footer: {
                Text(verbatim: "The report's JSON file carries the text of every chosen transcript, so they can be judged against it. It only leaves the iPhone when you share it.")
            }

            if !lab.runs.isEmpty || !lab.batteryRuns.isEmpty {
                results
            }
        }
        .navigationTitle(Text(verbatim: "Feder Lab"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if benchTexts.isEmpty { benchTexts = await ModelLab.benchTexts() }
            // `-runLabBench`: the default bench starts once the texts are there (QA; `-labRepetitions <n>`).
            guard ProcessInfo.processInfo.arguments.contains("-runLabBench"), !lab.isRunning, lab.runs.isEmpty else { return }
            let count = UserDefaults.standard.integer(forKey: "labRepetitions")
            if count > 0 { repetitions = count }
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

    private func choiceRow(_ name: String, detail: String, chosen: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                VStack(alignment: .leading) {
                    Text(verbatim: name).foregroundStyle(.primary)
                    Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private func start() {
        let own = transcripts.filter { chosenTranscripts.contains($0.id) }.map(ModelLab.input)
        let inputs = benchTexts.filter { textIDs.contains($0.id) } + own
        lab.run(models: ModelLab.Model.allCases.filter(chosenModels.contains), inputs: inputs, repetitions: repetitions,
                batteryMinutes: batteryMinutes > 0 ? batteryMinutes : nil)
    }

    @ViewBuilder
    private var results: some View {
        let rows = lab.rows
        ForEach(lab.inputs) { input in
            let mine = rows.filter { $0.input == input.id }
            if !mine.isEmpty {
                Section {
                    ForEach(mine) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: row.model.name).font(.headline)
                            Text(verbatim: stats(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let title = row.title { Text(verbatim: title).bold() }
                            Text(verbatim: row.summary ?? "No usable answer").textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text(verbatim: "\(input.name) · \(input.characters.formatted()) characters")
                }
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
            if !lab.reportFiles.isEmpty {
                ShareLink(items: lab.reportFiles) { Text(verbatim: "Share Report and Data…") }
            }
        } footer: {
            Text(verbatim: "The Markdown report has the means; the JSON file has every run, the raw answers and the inputs' text for the judge. Both are also in the app's Caches/FederLab.")
        }
    }

    private func stats(_ row: ModelLab.Row) -> String {
        var parts = [row.seconds.text("s")]
        if let first = row.firstWords { parts.append("first words " + first.text("s")) }
        parts.append("peak " + row.peak.text("GB", digits: 2))
        parts.append("least left " + row.least.text("GB", digits: 2))
        parts.append(ModelLab.thermalText(row.thermal))
        if row.failures > 0 { parts.append("no summary \(row.failures) of \(row.seconds.n)") }
        if row.distinctSummaries > 1 { parts.append("\(row.distinctSummaries) different summaries") }
        return parts.joined(separator: " · ")
    }
}
#endif
