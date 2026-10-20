#if LITERT
import SwiftData
import SwiftUI

/// Settings › Feder Lab (FederLab target only, FED-150, FED-153, FED-166): the LiteRT models' downloads, the model that
/// writes summaries and answers in Ask, and the bench: every step after Stop with each model that can do it, on the
/// user's recordings (and, for the summary and the action items, the Lab's bench texts), repeated with each step's model
/// order rotating, with its report. English only (`verbatim`): the Lab never ships, so its strings stay out of the
/// catalog.
struct ModelLabView: View {
    @Environment(AppServices.self) private var services
    @Query(Self.recent) private var recordings: [Recording]
    @Query private var people: [Person]
    @State private var benchTexts: [ModelLab.Input] = []
    @State private var chosenSteps: Set<ModelLab.Step> = Set(ModelLab.Step.allCases)
    @State private var chosenTexts: Set<String>?
    @State private var chosenTranscripts: Set<UUID>?
    @State private var models: Set<ModelLab.Model>?
    @State private var repetitions = 5
    @State private var batteryMinutes = 0
    @State private var copied = false
    private let lab = ModelLab.shared

    static var recent: FetchDescriptor<Recording> {
        var descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 60
        return descriptor
    }

    private var transcripts: [Recording] { recordings.filter { $0.speakerStatus == .done && !$0.segments.isEmpty } }
    private var ready: [ModelLab.Model] { ModelLab.Model.allCases.filter(isReady) }
    private var gemma: [ModelLab.Model] { ModelLab.Model.allCases.filter(chosenModels.contains) }
    private var steps: [ModelLab.Step] { ModelLab.Step.allCases.filter(chosenSteps.contains) }
    private var textIDs: Set<String> { chosenTexts ?? Set(benchTexts.map(\.id)) }
    private var chosenModels: Set<ModelLab.Model> { models ?? Set(ready) }
    /// Until the user picks: five recordings spread over the lengths (shortest, longest and three between), so the
    /// line through time and length has points along it.
    private var transcriptIDs: Set<UUID> { chosenTranscripts ?? Self.spread(transcripts, count: 5) }

    nonisolated static func spread(_ recordings: [Recording], count: Int) -> Set<UUID> {
        let sorted = recordings.sorted { $0.duration < $1.duration }
        guard sorted.count > count else { return Set(sorted.map(\.id)) }
        return Set((0..<count).map { sorted[Int((Double($0) / Double(count - 1) * Double(sorted.count - 1)).rounded())].id })
    }

    /// How many runs the bench will make: per step, its models × the inputs it applies to × the repetitions.
    private var runCount: Int {
        let withAudio = transcriptIDs.count, all = withAudio + textIDs.count
        return steps.map { step in
            lab.engines(for: step, gemma: gemma).count * (step.needsRecording ? withAudio : all)
        }.reduce(0, +) * repetitions
    }

    var body: some View {
        @Bindable var lab = lab
        AppForm {
            Section {
                ForEach(ModelLab.Model.allCases) { model in
                    modelRow(model)
                }
            } header: {
                Text(verbatim: "Gemma Models")
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
                ForEach(ModelLab.Step.allCases) { step in
                    Toggle(isOn: Binding(get: { chosenSteps.contains(step) },
                                         set: { _ in chosenSteps = chosenSteps.symmetricDifference([step]) })) {
                        Text(verbatim: step.name)
                        Text(verbatim: stepDetail(step))
                    }
                }
            } header: {
                Text(verbatim: "Steps")
            } footer: {
                Text(verbatim: "Each step runs with every model that can do it, on copies of your recordings' audio, words and voices: nothing is written back. Steps 1–6 need your recordings; the bench texts only feed 7 and 8.")
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
                    Button { start() } label: { Text(verbatim: "Run Bench (\(runCount) runs)") }
                        .disabled(runCount == 0 || lab.pipelineIsBusy)
                    if lab.pipelineIsBusy {
                        Text(verbatim: "Feder is still working on a recording; the bench starts when it's done.")
                            .foregroundStyle(.secondary)
                    } else if !lab.status.isEmpty {
                        Text(verbatim: lab.status).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(verbatim: "Bench")
            } footer: {
                Text(verbatim: "Gemma steps use the models switched on here. One model in memory at a time; each step's model order rotates with every repetition; background summaries wait. Keep Feder open: the screen stays on. A battery run (summaries only) needs the iPhone unplugged\(UIDevice.current.batteryState == .unplugged ? "" : " (it is charging now)").")
            }

            Section {
                Button { chosenTranscripts = Self.spread(transcripts, count: 5) } label: {
                    Text(verbatim: "Choose 5 of Different Lengths")
                }
                ForEach(transcripts) { recording in
                    choiceRow(recording.name,
                              detail: Duration.seconds(recording.duration)
                                  .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)),
                              chosen: transcriptIDs.contains(recording.id)) {
                        chosenTranscripts = transcriptIDs.symmetricDifference([recording.id])
                    }
                }
            } header: {
                Text(verbatim: "Your Recordings (\(transcriptIDs.count) chosen)")
            } footer: {
                Text(verbatim: "The report's JSON file carries the text of every chosen recording, so its summaries can be judged against it. It only leaves the iPhone when you share it.")
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
                Text(verbatim: "Synthetic meetings and a lecture in German and English, written for the bench, for steps 7 and 8. They are part of Feder Lab and never appear among your transcripts.")
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

    /// The step's models now, and what is missing.
    private func stepDetail(_ step: ModelLab.Step) -> String {
        let engines = lab.engines(for: step, gemma: gemma).map(\.name)
        let models = engines.isEmpty ? "no model" : engines.joined(separator: ", ")
        return [models, lab.missingEngines(for: step)].compactMap { $0 }.joined(separator: " · ")
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
        let own = transcripts.filter { transcriptIDs.contains($0.id) }.map(ModelLab.input)
        let texts = chosenSteps.contains(.summary) || chosenSteps.contains(.actionItems)
            ? benchTexts.filter { textIDs.contains($0.id) } : []
        let fingerprints = Dictionary(uniqueKeysWithValues: people.filter { !$0.fingerprint.isEmpty }
                                                                  .map { ($0.id, $0.fingerprint) })
        lab.run(steps: steps, gemma: gemma, inputs: own + texts, fingerprints: fingerprints, repetitions: repetitions,
                batteryMinutes: batteryMinutes > 0 ? batteryMinutes : nil)
    }

    @ViewBuilder
    private var results: some View {
        Section {
            ForEach(lab.stepRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(row.step.name) · \(row.model.name)").font(.headline)
                    Text(verbatim: stepStats(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(verbatim: "Pipeline: Time per Step")
        } footer: {
            Text(verbatim: "Per unit: total time over total length, in seconds per minute of audio (steps reading the file) or per 1,000 characters. Line: fixed cost + cost per unit, fitted through the inputs. Times count only runs with a result.\(lab.skipped.isEmpty ? "" : " Skipped: " + lab.skipped.joined(separator: "; ") + ".")")
        }
        let rows = lab.rows
        ForEach(lab.inputs) { input in
            let mine = rows.filter { $0.input == input.id }
            if !mine.isEmpty {
                Section {
                    ForEach(mine) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "\(row.step.name) · \(row.model.name)").font(.headline)
                            Text(verbatim: stats(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if row.step == .summary {
                                if let title = row.title { Text(verbatim: title).bold() }
                                Text(verbatim: row.summary ?? "No usable answer").textSelection(.enabled)
                            } else if let output = row.output {
                                Text(verbatim: output)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text(verbatim: inputHeader(input))
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
            Text(verbatim: "The Markdown report has the means and lines; the JSON file has every run, the raw answers and the inputs' text for the judge. Both are also in the app's Caches/FederLab.")
        }
    }

    private func inputHeader(_ input: ModelLab.Input) -> String {
        let audio = input.audio.map {
            Duration.seconds($0.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) + " · "
        } ?? ""
        // The transcript's name now (Gemma's title or the user's may have come since the bench started), the one at
        // the start in brackets, and its date, so it can be found in the list.
        let current = transcripts.first { "transcript:\($0.id)" == input.id }
        let name = current.map { $0.name == input.name ? $0.name : "\($0.name) (was \(input.name))" } ?? input.name
        let date = input.audio.map { $0.recordedAt.formatted(date: .abbreviated, time: .shortened) + " · " } ?? ""
        return "\(name) · \(date)\(audio)\(input.characters.formatted()) characters"
    }

    private func stepStats(_ row: ModelLab.StepRow) -> String {
        let unit = row.step.perAudioMinute ? "min" : "1K chars"
        var parts = ["\(row.inputs) inputs", "per input " + row.perInput.text("s")]
        if let rate = row.rate { parts.append(String(format: "%.2f s/%@", rate, unit)) }
        if let fit = row.fit { parts.append(fit.text(unit)) }
        parts.append(String(format: "peak %.2f GB", row.peak))
        if row.failures > 0 { parts.append("no result \(row.failures) of \(row.runs)") }
        return parts.joined(separator: " · ")
    }

    private func stats(_ row: ModelLab.Row) -> String {
        let unit = row.step.perAudioMinute ? "min" : "1K chars"
        var parts = [row.seconds.text("s")]
        if let perUnit = row.perUnit { parts.append(perUnit.text("s/\(unit)", digits: 2)) }
        if let first = row.firstWords { parts.append("first words " + first.text("s")) }
        parts.append("peak " + row.peak.text("GB", digits: 2))
        parts.append("least left " + row.least.text("GB", digits: 2))
        parts.append(ModelLab.thermalText(row.thermal))
        if row.failures > 0 { parts.append("no result \(row.failures) of \(row.seconds.n)") }
        if row.distinctSummaries > 1 { parts.append("\(row.distinctSummaries) different summaries") }
        return parts.joined(separator: " · ")
    }
}
#endif
