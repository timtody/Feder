#if LITERT
import Foundation
import Observation
import UIKit
import os

/// Feder Lab (FED-150, FED-152; the FederLab target only): Gemma 4 E2B and E4B on Google's LiteRT-LM next to the app's
/// E2B on MLX, on the iPhone with the user's own transcripts. Downloads the LiteRT model files (pinned Hugging Face
/// revisions, a background session over Wi-Fi like Gemma's), chooses the model that writes summaries and answers in Ask
/// (`BetterSummaries.labWriter`), and runs the bench: every chosen model on every chosen transcript through the app's
/// own `TranscriptTitler`, with the time, the first words' time, the peak `phys_footprint` (what iOS's memory limit
/// counts) and the least memory left before that limit (`os_proc_available_memory`), the thermal state, and optionally
/// a battery run (summaries per 1 % of battery). The report stays on the iPhone (Caches/FederLab) until copied.
@MainActor @Observable
final class ModelLab {
    static let shared = ModelLab()

    nonisolated enum Model: String, CaseIterable, Identifiable, Sendable, Codable {
        case mlxE2B, litertE2B, litertE4B

        var id: String { rawValue }
        var name: String {
            switch self {
            case .mlxE2B: "E2B · MLX"
            case .litertE2B: "E2B · LiteRT"
            case .litertE4B: "E4B · LiteRT"
            }
        }
        /// The file on Hugging Face (litert-community, the full files Google's iPhone figures are for); nil for MLX,
        /// which BetterSummaries downloads.
        var file: (repository: String, revision: String, name: String, bytes: Int64)? {
            switch self {
            case .mlxE2B: nil
            case .litertE2B: ("litert-community/gemma-4-E2B-it-litert-lm", "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1",
                              "gemma-4-E2B-it.litertlm", 2_588_147_712)
            case .litertE4B: ("litert-community/gemma-4-E4B-it-litert-lm", "2eee7ac325f20eb8c9ac1d0e972f7c84663062da",
                              "gemma-4-E4B-it.litertlm", 3_659_530_240)
            }
        }
        var sizeText: String {
            switch self {
            case .mlxE2B: "3.6 GB"
            case .litertE2B: "2.6 GB"
            case .litertE4B: "3.7 GB"
            }
        }
        /// Where the file lives: Application Support/Models/<repository>/<revision>/<file> (Models is excluded from
        /// backups, as Gemma's).
        var location: URL? {
            file.map {
                URL.applicationSupportDirectory.appending(path: "Models/\($0.repository.split(separator: "/").last!)")
                    .appending(path: $0.revision).appending(path: $0.name)
            }
        }
    }

    // MARK: Models

    private(set) var states: [Model: ModelDownloadState] = [:]
    /// The model that writes summaries and answers in Ask (UserDefaults, kept across launches).
    var writer: Model = Model(rawValue: UserDefaults.standard.string(forKey: "labWriter") ?? "") ?? .mlxE2B {
        didSet {
            UserDefaults.standard.set(writer.rawValue, forKey: "labWriter")
            apply(sweep: true)
        }
    }
    /// LiteRT-LM's multi-token prediction for the Lab's LiteRT models (read when an engine is created).
    var speculativeDecoding: Bool = UserDefaults.standard.bool(forKey: "labSpeculativeDecoding") {
        didSet {
            UserDefaults.standard.set(speculativeDecoding, forKey: "labSpeculativeDecoding")
            apply(sweep: false)
        }
    }
    @ObservationIgnored private weak var better: BetterSummaries?
    @ObservationIgnored private weak var parakeet: ParakeetModel?
    @ObservationIgnored private weak var identifier: SpeakerIdentifier?

    private init() {
        for model in Model.allCases where model.file != nil {
            states[model] = Self.isDownloaded(model) ? .ready : .notDownloaded
        }
        LabDownload.shared.setHandler { event in
            Task { @MainActor in ModelLab.shared.handle(event) }
        }
        LabDownload.shared.reattach()
    }

    /// AppServices, at launch: the chosen LiteRT model writes from now on; Parakeet's download state and the pipeline's
    /// queue are for the pipeline bench.
    func attach(_ better: BetterSummaries, parakeet: ParakeetModel, identifier: SpeakerIdentifier) {
        self.better = better
        self.parakeet = parakeet
        self.identifier = identifier
        apply(sweep: false)                                      // the launch sweep runs anyway
    }

    nonisolated static func isDownloaded(_ model: Model) -> Bool {
        guard let location = model.location else { return false }
        return FileManager.default.fileExists(atPath: location.path(percentEncoded: false))
    }

    /// Hands BetterSummaries the chosen writer: a LiteRT model once downloaded, E2B on MLX otherwise. `sweep`: the
    /// transcripts still without a summary get one from the new writer.
    private func apply(sweep: Bool) {
        guard let better else { return }
        let old = better.labWriter
        Task { await old?.unload() }
        if writer != .mlxE2B, states[writer] == .ready {
            better.labWriter = makeWriter(writer)
        } else {
            better.labWriter = nil
        }
        if sweep { better.onBecameActive?() }
    }

    private func makeWriter(_ model: Model) -> any TextWriter {
        #if targetEnvironment(simulator)
        if model == .mlxE2B { return FakeTextWriter() }         // no MLX GPU: `-fakeGemma`'s writer, for the flow
        #endif
        if let location = model.location {
            return LiteRTLanguageModel(file: location, speculativeDecoding: speculativeDecoding)
        }
        return LocalLanguageModel(variant: .e2b, directory: BetterSummaries.modelDirectory(.e2b))
    }

    func download(_ model: Model) {
        guard model.file != nil else { return }
        switch states[model] {
        case .ready, .downloading, .waitingForWiFi: return
        default: break
        }
        states[model] = .downloading(0)
        LabDownload.shared.start(model)
    }

    func delete(_ model: Model) {
        LabDownload.shared.cancel(model)
        if writer == model { writer = .mlxE2B }
        if let location = model.location {
            try? FileManager.default.removeItem(at: location.deletingLastPathComponent().deletingLastPathComponent())
        }
        states[model] = .notDownloaded
    }

    private func handle(_ event: LabDownload.Event) {
        switch event {
        case .progress(let model, let fraction):
            if let next = (states[model] ?? .downloading(0)).advanced(to: fraction) { states[model] = next }
        case .finished(let model):
            states[model] = .ready
            if writer == model { apply(sweep: true) }
        case .failed(let model, let reason):
            states[model] = .failed(reason)
        }
    }

    // MARK: Pipeline steps

    /// The steps after Stop (PIPELINE.md §4), each benched with every model that can do it (FED-166).
    nonisolated enum Step: String, CaseIterable, Codable, Sendable, Identifiable {
        case words, speakers, alignment, voices, people, vocabulary, summary, actionItems

        var id: String { rawValue }
        var name: String {
            switch self {
            case .words: "1 · Words"
            case .speakers: "2 · Speakers"
            case .alignment: "3 · Alignment"
            case .voices: "4 · Voices"
            case .people: "5 · People"
            case .vocabulary: "6 · Vocabulary"
            case .summary: "7 · Title and Summary"
            case .actionItems: "8 · Action Items"
            }
        }
        /// Needs one of the user's recordings (its audio, words, turns or voices); the bench texts have none and only
        /// feed the summary and the action items.
        var needsRecording: Bool { self != .summary && self != .actionItems }
        /// Measured per minute of audio (the step reads the whole file); the others per 1,000 characters of transcript.
        var perAudioMinute: Bool { [.words, .speakers, .voices, .vocabulary].contains(self) }
        var unitName: String { perAudioMinute ? "min of audio" : "1,000 characters" }
    }

    /// What does a step: the app's alternatives per step, and the three Gemma builds for the last two. The Gemma cases
    /// share Model's raw values, so the report's JSON reads the same for them as before.
    nonisolated enum Engine: String, CaseIterable, Codable, Sendable {
        case apple, parakeet, nemotron, pyannote, aligner, wespeaker, voiceMatch, dictation, mlxE2B, litertE2B, litertE4B

        init(_ model: Model) { self = Engine(rawValue: model.rawValue)! }
        var model: Model? { Model(rawValue: rawValue) }
        var name: String {
            switch self {
            case .apple: "Apple"
            case .parakeet: "Parakeet Ultra"
            case .nemotron: "Nemotron 3"
            case .pyannote: "pyannote"
            case .aligner: "TranscriptAligner"
            case .wespeaker: "WeSpeaker"
            case .voiceMatch: "VoiceMatch"
            case .dictation: "Apple Dictation"
            case .mlxE2B, .litertE2B, .litertE4B: model!.name
            }
        }
    }

    /// The models available for `step` on this iPhone now: Parakeet once downloaded, Nemotron once downloaded, the
    /// vocabulary pass only with a vocabulary, the chosen Gemma builds for the last two.
    func engines(for step: Step, gemma: [Model]) -> [Engine] {
        switch step {
        case .words: [.apple] + (parakeet?.isReady == true ? [.parakeet] : [])
        case .speakers: (NemotronDiarizer.isDownloaded ? [.nemotron] : []) + [.pyannote]
        case .alignment: [.aligner]
        case .voices: [.wespeaker]
        case .people: [.voiceMatch]
        case .vocabulary: Vocabulary.current.isEmpty ? [] : [.dictation]
        case .summary, .actionItems: gemma.map(Engine.init)
        }
    }

    /// Why a step has fewer models than it could, for the Lab's footer.
    func missingEngines(for step: Step) -> String? {
        switch step {
        case .words where parakeet?.isReady != true: "Parakeet isn't downloaded (Settings › Transcription)"
        case .speakers where !NemotronDiarizer.isDownloaded: "Nemotron isn't downloaded (Settings › Speakers)"
        case .vocabulary where Vocabulary.current.isEmpty: "no vocabulary yet (Settings › Your Words)"
        default: nil
        }
    }

    /// Whether the pipeline is working on a recording: the bench waits, so the two never share the hardware.
    var pipelineIsBusy: Bool { !(identifier?.progress.isEmpty ?? true) }

    // MARK: Bench

    /// What a step reads from one of the user's recordings, copied when the bench starts (never written back).
    nonisolated struct Audio: Sendable {
        var url: URL
        var duration: TimeInterval
        var locale: String
        var words: [TranscriptWord]
        var turns: [SpeakerTurn]            // the stored final diarization (empty before it)
        var alignmentOffset: TimeInterval
        var speakers: SpeakerCount
        var diarizer: DiarizerKind?
        var voices: [Int: [Float]]
        var recordedAt: Date
    }

    /// A transcript as Gemma reads it: one of the user's, built as SpeakerIdentifier.describe does (speaker names,
    /// bookmark markers), with its audio for the steps before; or one of the Lab's bench texts (synthetic, in the
    /// FederLab bundle, never in the store), only for the summary and the action items.
    nonisolated struct Input: Sendable, Identifiable {
        var id: String                      // "bench:<file>" or "transcript:<uuid>"
        var name: String
        var paragraphs: [String]
        var bookmarked = false
        var isBenchText = false
        var audio: Audio?
        var characters: Int { paragraphs.joined(separator: "\n").count }
        /// The steps' length: minutes of audio, or thousands of characters.
        func units(for step: Step) -> Double {
            step.perAudioMinute ? (audio?.duration ?? 0) / 60 : Double(characters) / 1000
        }
    }

    static func input(_ recording: Recording) -> Input {
        let segments = recording.segments
        let bookmarked = Set(Bookmarks.byParagraph(recording.bookmarks, in: segments).keys)
        let paragraphs = segments.map { segment in
            TranscriptTitler.paragraph(segment.text, speaker: segment.speakerIndex.map(recording.speakerName),
                                       bookmarked: bookmarked.contains(segment.id))
        }
        let audio = Audio(url: recording.audioURL, duration: recording.duration, locale: recording.localeIdentifier,
                          words: recording.words, turns: recording.speakerTurns, alignmentOffset: recording.alignmentOffset,
                          speakers: recording.speakerCountOverride.map { .exactly($0) } ?? .automatic,
                          diarizer: recording.diarizer, voices: recording.speakerVoices,
                          recordedAt: recording.originalDate ?? recording.createdAt)
        return Input(id: "transcript:\(recording.id)", name: recording.name, paragraphs: paragraphs,
                     bookmarked: !bookmarked.isEmpty, audio: audio)
    }

    /// The Lab's bench texts (Lab/BenchTexts, FED-153): synthetic meetings of 2,000 to 90,000 characters in German and
    /// English, written for the bench with answer keys for the judge (build/qa/litertbench/judge/keys). Each file is
    /// "# <name>" and then one "Name: text" paragraph per line. Read off the main actor.
    @concurrent
    nonisolated static func benchTexts() async -> [Input] {
        let files = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "BenchTexts") ?? []
        return files.compactMap { file -> Input? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            guard let first = lines.first, first.hasPrefix("# ") else { return nil }
            lines.removeFirst()
            return Input(id: "bench:\(file.deletingPathExtension().lastPathComponent)", name: String(first.dropFirst(2)),
                         paragraphs: lines, isBenchText: true)
        }
        .sorted { $0.characters < $1.characters }
    }

    nonisolated struct Run: Identifiable, Sendable, Codable {
        var id = UUID()
        var input: String                   // Input.id
        var step: Step = .summary
        var repetition: Int                 // 1…
        var model: Engine
        var units: Double = 0               // the input's length for this step (Step.unitName)
        var loadSeconds: Double?            // the model's load, on its first input of a repetition
        var seconds: Double = 0
        var firstWords: Double?             // Gemma: until the final request's first chunk (the card shows it then)
        var requests = 0
        var peakFootprint: Double = 0       // GB
        var leastAvailable: Double = 0      // GB left before iOS's memory limit, at the tightest moment
        var thermal = ""
        var output: String?                 // what came out, briefly ("1,234 words", "3 speakers, 120 turns")
        var title: String?
        var summary: String?                // nil: no usable answer (or an error)
        var answer: String?                 // the final request's raw answer; the action items found
        var error: String?
    }

    nonisolated struct BatteryRun: Identifiable, Sendable, Codable {
        var id = UUID()
        var model: Model
        var minutes: Double
        var summaries: Int
        var characters: Int                 // written
        var batteryUsed: Double             // per cent
        var thermal: String
    }

    private(set) var isRunning = false
    private(set) var status = ""
    private(set) var runs: [Run] = []
    private(set) var batteryRuns: [BatteryRun] = []
    private(set) var inputs: [Input] = []
    private(set) var steps: [Step] = []
    /// Chosen steps that had nothing to run ("6 · Vocabulary: no vocabulary …"), for the report.
    private(set) var skipped: [String] = []
    /// Each repetition's model order per step ("2 · Speakers: Nemotron 3 → pyannote"): rotated by one each time, so no
    /// model always runs on a phone the one before has warmed (FED-153's first run: MLX first "nominal", LiteRT "fair").
    private(set) var orders: [[String]] = []
    private(set) var reportFiles: [URL] = []
    @ObservationIgnored private var benchTask: Task<Void, Never>?
    /// The Lab's own speaker models (not the app's: their state stays as it is), created for a bench.
    @ObservationIgnored private var pyannote: FluidAudioDiarizer?
    @ObservationIgnored private var nemotron: NemotronDiarizer?

    nonisolated static func rotated<T>(_ items: [T], by step: Int) -> [T] {
        guard !items.isEmpty else { return [] }
        let shift = step % items.count
        return Array(items[shift...] + items[..<shift])
    }

    /// Runs every chosen step with each of its models on the inputs it applies to, `repetitions` times, rotating each
    /// step's model order every time; with `batteryMinutes`, afterwards each Gemma model summarizes the inputs over and
    /// over for that long (unplugged), for summaries per 1 % of battery. Background summaries wait meanwhile
    /// (`runAhead`); the screen stays on, since leaving the app stops Gemma. Nothing is written to the recordings.
    func run(steps: [Step], gemma: [Model], inputs: [Input], fingerprints: [UUID: [Float]], repetitions: Int,
             batteryMinutes: Int?) {
        guard !isRunning, let better, !inputs.isEmpty, !steps.isEmpty else { return }
        guard !pipelineIsBusy else {
            status = "Feder is still working on a recording: try again when it's done."
            return
        }
        isRunning = true
        runs = []
        batteryRuns = []
        orders = []
        reportFiles = []
        self.inputs = inputs
        self.steps = steps
        skipped = steps.compactMap { step in
            if engines(for: step, gemma: gemma).isEmpty {
                return "\(step.name): " + (missingEngines(for: step) ?? "no model chosen")
            }
            if step.needsRecording, !inputs.contains(where: { $0.audio != nil }) { return "\(step.name): no recording chosen" }
            return nil
        }
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        benchTask = Task {
            defer {
                isRunning = false
                pyannote = nil
                nemotron = nil
                UIApplication.shared.isIdleTimerDisabled = false
                writeReport()
            }
            do {
                try await better.runAhead { [self] in
                    // The app's own models off the GPU first (not `better.unload()`: it would stop this very run).
                    await better.model?.unload()
                    await better.labWriter?.unload()
                    for repetition in 1...max(1, repetitions) {
                        var order: [String] = []
                        for step in steps {
                            let engines = Self.rotated(engines(for: step, gemma: gemma), by: repetition - 1)
                            let applicable = inputs.filter { !step.needsRecording || $0.audio != nil }
                            guard !engines.isEmpty, !applicable.isEmpty else { continue }
                            order.append("\(step.name): " + engines.map(\.name).joined(separator: " → "))
                            for engine in engines {
                                try await bench(step, engine, inputs: applicable, fingerprints: fingerprints,
                                                repetition: repetition, of: repetitions)
                            }
                        }
                        orders.append(order)
                    }
                    if let batteryMinutes, steps.contains(.summary) {
                        for model in gemma {
                            try await batteryRun(model, inputs: inputs, minutes: Double(batteryMinutes))
                        }
                    }
                }
                status = "Done"
            } catch is CancellationError {
                status = "Stopped"
            } catch {
                status = "Stopped: \(error)"
            }
        }
    }

    func stop() { benchTask?.cancel() }

    /// One step with one model on every input it applies to: the model is loaded first (timed), then each input runs
    /// alone, sampled for memory.
    private func bench(_ step: Step, _ engine: Engine, inputs: [Input], fingerprints: [UUID: [Float]],
                       repetition: Int, of repetitions: Int) async throws {
        let label = "Run \(repetition) of \(repetitions) · \(step.name) · \(engine.name)"
        status = label + ": loading"
        let sampler = MemorySampler()
        defer { sampler.stop() }
        let loadStart = Date.now
        var writer: (any TextWriter)?
        switch engine {
        case .mlxE2B, .litertE2B, .litertE4B:
            let made = makeWriter(engine.model!)
            if let local = made as? LocalLanguageModel { try await local.load() }
            if let litert = made as? LiteRTLanguageModel { try await litert.load() }
            writer = made
        case .pyannote, .nemotron, .wespeaker:
            if pyannote == nil { pyannote = FluidAudioDiarizer() }
            try await pyannote?.prepare()
            if engine == .nemotron, nemotron == nil { nemotron = NemotronDiarizer() }
        default:
            break                                               // loaded per job (Parakeet), or no model at all
        }
        var loadSeconds: Double? = Date.now.timeIntervalSince(loadStart)
        defer { if let writer { Task { await writer.unload() } } }
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            status = label + ": \(index + 1) of \(inputs.count)"
            sampler.reset()
            var run = Run(input: input.id, step: step, repetition: repetition, model: engine,
                          units: input.units(for: step), loadSeconds: loadSeconds)
            loadSeconds = nil
            let start = Date.now
            do {
                try await perform(step, engine, on: input, writer: writer, fingerprints: fingerprints, into: &run)
            } catch is TranscriptTitler.RetryLater {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                run.error = String(describing: error)
            }
            run.seconds = Date.now.timeIntervalSince(start)
            (run.peakFootprint, run.leastAvailable) = sampler.peak()
            run.thermal = Self.thermal
            runs.append(run)
        }
        if let writer { await writer.unload() }
        try await Task.sleep(for: .seconds(2))                  // memory settles before the next model loads
    }

    /// One input through one step, as SpeakerIdentifier runs it, on copies: the results go into the run, never into
    /// the recording.
    private func perform(_ step: Step, _ engine: Engine, on input: Input, writer: (any TextWriter)?,
                         fingerprints: [UUID: [Float]], into run: inout Run) async throws {
        let audio = input.audio
        switch (step, engine) {
        case (.words, .apple):
            guard let audio else { return }
            let transcript = try await SpeechFileTranscriber(parakeet: nil).transcribe(
                fileURL: audio.url, locale: Locale(identifier: audio.locale))
            run.output = "\(transcript.words.count) words"
        case (.words, .parakeet):
            guard let audio else { return }
            guard ParakeetTranscriber.supports(Locale(identifier: audio.locale)) else {
                run.error = "language not supported"
                return
            }
            let parsed = try await ParakeetTranscriber.transcribe(fileURL: audio.url, locale: Locale(identifier: audio.locale))
            run.output = "\(parsed.words.count) words"
        case (.speakers, .nemotron):
            guard let audio, let nemotron, let pyannote else { return }
            let diarization = try await DiarizerSelector(nemotron: nemotron, pyannote: pyannote)
                .diarization(fileURL: audio.url, speakers: audio.speakers)
            run.output = Self.describe(diarization.turns) + (diarization.diarizer == .pyannote ? " (fell back to pyannote)" : "")
        case (.speakers, .pyannote):
            guard let audio, let pyannote else { return }
            run.output = Self.describe(try await pyannote.diarize(fileURL: audio.url, speakers: audio.speakers))
        case (.alignment, .aligner):
            guard let audio, !audio.turns.isEmpty else { run.error = "no final speakers yet"; return }
            let labels = TranscriptAligner.finalSpeakers(words: audio.words, turns: audio.turns, offset: audio.alignmentOffset)
            run.output = "\(labels.count) words labelled"
        case (.voices, .wespeaker):
            guard let audio, let pyannote, !audio.turns.isEmpty else { run.error = "no final speakers yet"; return }
            let labels = TranscriptAligner.finalSpeakers(words: audio.words, turns: audio.turns, offset: audio.alignmentOffset)
            let voices = try await pyannote.voices(fileURL: audio.url,
                                                   windows: VoiceWindows.windows(words: audio.words, speakers: labels))
            run.output = "\(voices.count) voices"
        case (.people, .voiceMatch):
            guard let audio else { return }
            let found = VoiceMatch.assign(voices: audio.voices, fingerprints: fingerprints,
                                          threshold: VoiceMatch.threshold(for: audio.diarizer))
            run.output = "\(found.count) of \(audio.voices.count) voices recognized among \(fingerprints.count) people"
        case (.vocabulary, .dictation):
            guard let audio else { return }
            let merged = await SpeechFileTranscriber(parakeet: nil).applyVocabulary(
                to: audio.words, fileURL: audio.url, locale: Locale(identifier: audio.locale))
            let changed = zip(audio.words, merged).filter { $0.text != $1.text }.count + abs(audio.words.count - merged.count)
            run.output = "\(changed) words changed"
        case (.summary, _):
            guard let writer else { return }
            let measuring = MeasuringWriter(writer)
            let description = try await TranscriptTitler().describe(paragraphs: input.paragraphs, locale: .current,
                                                                    writer: measuring, bookmarked: input.bookmarked)
            run.title = description?.title
            run.summary = description?.summary
            run.answer = measuring.lastAnswer
            run.firstWords = measuring.lastFirstChunk
            run.requests = measuring.requests
            run.output = description == nil ? "no usable answer" : "\(description?.summary.count ?? 0) characters"
        case (.actionItems, _):
            guard let writer else { return }
            let measuring = MeasuringWriter(writer)
            // As SpeakerIdentifier.searchActionItems: no bookmark markers, deadlines from the recording's date.
            let paragraphs = input.paragraphs.map { $0.replacingOccurrences(of: TranscriptTitler.bookmarkMarker + " ", with: "") }
            let items = try await ActionItemExtractor().extract(paragraphs: paragraphs,
                                                                 recordedAt: audio?.recordedAt ?? .now, writer: measuring)
            run.firstWords = measuring.lastFirstChunk
            run.requests = measuring.requests
            run.output = "\(items.count) action items"
            run.answer = items.map { "\($0.task)\($0.owner.map { " (\($0))" } ?? "")\($0.duePhrase.map { ", \($0)" } ?? "")" }
                .joined(separator: "\n")
        default:
            run.error = "\(engine.name) can't do \(step.name)"
        }
    }

    nonisolated static func describe(_ turns: [SpeakerTurn]) -> String {
        let speakers = Set(turns.map(\.speakerIndex)).count
        return "\(speakers) speaker\(speakers == 1 ? "" : "s"), \(turns.count) turn\(turns.count == 1 ? "" : "s")"
    }

    private func batteryRun(_ model: Model, inputs: [Input], minutes: Double) async throws {
        let writer = makeWriter(model)
        defer { Task { await writer.unload() } }
        let titler = TranscriptTitler()
        let startLevel = UIDevice.current.batteryLevel
        let start = Date.now
        var summaries = 0, characters = 0
        while Date.now.timeIntervalSince(start) < minutes * 60 {
            for input in inputs where Date.now.timeIntervalSince(start) < minutes * 60 {
                try Task.checkCancellation()
                let left = Int(minutes * 60 - Date.now.timeIntervalSince(start))
                status = "Battery: \(model.name), \(left / 60):\(String(format: "%02d", left % 60)) left"
                let description = try? await titler.describe(paragraphs: input.paragraphs, locale: .current,
                                                             writer: writer, bookmarked: input.bookmarked)
                summaries += 1
                characters += description?.summary.count ?? 0
            }
        }
        let used = Double(startLevel - UIDevice.current.batteryLevel) * 100
        batteryRuns.append(BatteryRun(model: model, minutes: Date.now.timeIntervalSince(start) / 60,
                                      summaries: summaries, characters: characters, batteryUsed: used,
                                      thermal: Self.thermal))
        await writer.unload()
        try await Task.sleep(for: .seconds(2))
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "?"
        }
    }

    // MARK: Statistics

    /// Mean and sample standard deviation of n values.
    nonisolated struct Stat: Sendable {
        var mean: Double, sd: Double, n: Int

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let count = values.count, average = values.reduce(0, +) / Double(values.count)
            n = count
            mean = average
            sd = count > 1 ? (values.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(count - 1)).squareRoot() : 0
        }

        func text(_ unit: String, digits: Int = 1) -> String {
            let format = "%.\(digits)f"
            return String(format: format, mean) + " ± " + String(format: format, sd) + " " + unit
        }
    }

    /// time = fixed + perUnit × length, least squares over the inputs' mean times; r² how well a line explains them.
    nonisolated struct Fit: Sendable {
        var fixed: Double, perUnit: Double, r2: Double?

        init?(_ points: [(x: Double, y: Double)]) {
            let xs = points.map(\.x), ys = points.map(\.y)
            guard points.count >= 2, let meanX = Stat(xs)?.mean, let meanY = Stat(ys)?.mean else { return nil }
            let sxx = xs.map { ($0 - meanX) * ($0 - meanX) }.reduce(0, +)
            let syy = ys.map { ($0 - meanY) * ($0 - meanY) }.reduce(0, +)
            let sxy = zip(xs, ys).map { ($0 - meanX) * ($1 - meanY) }.reduce(0, +)
            guard sxx > 0 else { return nil }                   // every input the same length: no slope to fit
            perUnit = sxy / sxx
            fixed = meanY - perUnit * meanX
            r2 = points.count >= 3 && syy > 0 ? (sxy * sxy) / (sxx * syy) : nil
        }

        func text(_ unit: String) -> String {
            String(format: "%.2f s + %.2f s per %@", fixed, perUnit, unit) + (r2.map { String(format: " (R² %.2f)", $0) } ?? "")
        }
    }

    /// One step's model on one input over all repetitions.
    nonisolated struct Row: Identifiable, Sendable {
        var id: String { input + "|" + step.rawValue + "|" + model.rawValue }
        var input: String
        var step: Step
        var model: Engine
        var units: Double
        var seconds: Stat                   // from the runs without an error (all of them when every run failed)
        var timed: Int                      // runs without an error
        var perUnit: Stat?                  // seconds per Step.unitName
        var firstWords: Stat?
        var peak: Stat
        var least: Stat
        var thermal: [String: Int]
        var failures: Int                   // runs without a result (an error; for the summary: no usable answer)
        var output: String?
        var title: String?
        var summary: String?                // the first usable one
        var distinctSummaries: Int          // greedy decoding: 1 expected; more means the GPU's rounding changed it
    }

    var rows: [Row] {
        var result: [Row] = []
        for input in inputs {
            for step in Step.allCases {
                for engine in Engine.allCases {
                    let mine = runs.filter { $0.input == input.id && $0.step == step && $0.model == engine }
                    guard let first = mine.first, let allSeconds = Stat(mine.map(\.seconds)),
                          let peak = Stat(mine.map(\.peakFootprint)), let least = Stat(mine.map(\.leastAvailable))
                    else { continue }
                    let usable = mine.filter { $0.error == nil && (step != .summary || $0.summary != nil) }
                    // Times only from runs that got through: a step that fails at once (no file, no model) says nothing
                    // about its speed and would bend the line. The summary's "no usable answer" did the work: it counts.
                    let timed = mine.filter { $0.error == nil }
                    let seconds = Stat(timed.map(\.seconds)) ?? allSeconds
                    result.append(Row(input: input.id, step: step, model: engine, units: first.units, seconds: seconds,
                                      timed: timed.count,
                                      perUnit: first.units > 0 ? Stat(timed.map { $0.seconds / $0.units }) : nil,
                                      firstWords: Stat(mine.compactMap(\.firstWords)), peak: peak, least: least,
                                      thermal: Dictionary(mine.map { ($0.thermal, 1) }, uniquingKeysWith: +),
                                      failures: mine.count - usable.count,
                                      output: usable.first?.output ?? first.error ?? first.output,
                                      title: usable.first?.title, summary: usable.first?.summary,
                                      distinctSummaries: Set(usable.compactMap(\.summary)).count))
                }
            }
        }
        return result
    }

    /// One step's model over all inputs: time per input and per unit, the line through the inputs' means, peak memory.
    nonisolated struct StepRow: Identifiable, Sendable {
        var id: String { step.rawValue + "|" + model.rawValue }
        var step: Step
        var model: Engine
        var inputs: Int
        var perInput: Stat
        /// Total time ÷ total length over the runs with a result: seconds per Step.unitName. Not the mean of the
        /// ratios, which the short inputs' fixed cost would dominate (a 65-character transcript: 15 s per 1,000).
        var rate: Double?
        var fit: Fit?
        var peak: Double                    // the highest of all runs, GB
        var failures: Int
        var runs: Int
    }

    var stepRows: [StepRow] {
        let all = rows
        return Step.allCases.flatMap { step in
            Engine.allCases.compactMap { engine -> StepRow? in
                let mine = all.filter { $0.step == step && $0.model == engine }
                let timedRows = mine.filter { $0.timed > 0 }
                guard let perInput = Stat((timedRows.isEmpty ? mine : timedRows).map(\.seconds.mean)) else { return nil }
                let mineRuns = runs.filter { $0.step == step && $0.model == engine }
                let timedRuns = mineRuns.filter { $0.error == nil && $0.units > 0 }
                let totalUnits = timedRuns.map(\.units).reduce(0, +)
                return StepRow(step: step, model: engine, inputs: mine.count, perInput: perInput,
                               rate: totalUnits > 0 ? timedRuns.map(\.seconds).reduce(0, +) / totalUnits : nil,
                               fit: Fit(timedRows.map { (x: $0.units, y: $0.seconds.mean) }),
                               peak: mineRuns.map(\.peakFootprint).max() ?? 0,
                               failures: mine.map(\.failures).reduce(0, +), runs: mineRuns.count)
            }
        }
    }

    func loadStat(_ engine: Engine) -> Stat? { Stat(runs.filter { $0.model == engine }.compactMap(\.loadSeconds)) }

    nonisolated static func thermalText(_ counts: [String: Int]) -> String {
        ["nominal", "fair", "serious", "critical"].compactMap { state in counts[state].map { "\(state) \($0)" } }
            .joined(separator: ", ")
    }

    // MARK: Report

    private var deviceLine: String {
        "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion), " +
            String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824) +
            "; speculative decoding \(speculativeDecoding ? "on" : "off")"
    }

    /// The runs as Markdown: per step and model the time per input, per unit of length and the line through them; then
    /// per input every step's models; each summary side by side; the loads, the orders and the battery runs at the end.
    var report: String {
        let repetitions = orders.count
        var lines = ["# Feder Lab bench, \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                     "\(deviceLine); \(repetitions) repetition\(repetitions == 1 ? "" : "s"), mean ± standard deviation", ""]
        lines.append("## Pipeline: time per step")
        lines.append("Per input: the mean over inputs of each input's mean. Per unit: total time over total length " +
                     "(minutes of audio, or 1,000 characters). Line: least squares through the inputs' mean times, fixed " +
                     "cost + cost per unit. Times count only runs with a result.")
        lines.append("")
        lines.append("| step | model | inputs | per input | per unit | line | peak memory | no result |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for row in stepRows {
            let unit = row.step.perAudioMinute ? "min" : "1K chars"
            lines.append("| \(row.step.name) | \(row.model.name) | \(row.inputs) | \(row.perInput.text("s")) | " +
                         "\(row.rate.map { String(format: "%.2f s/%@", $0, unit) } ?? "-") | \(row.fit?.text(unit) ?? "-") | " +
                         String(format: "%.2f GB", row.peak) + " | \(row.failures) of \(row.runs) |")
        }
        if !skipped.isEmpty { lines.append("") }
        for line in skipped { lines.append("Skipped: \(line)") }
        lines.append("")
        let all = rows
        for input in inputs {
            let mine = all.filter { $0.input == input.id }
            guard !mine.isEmpty else { continue }
            let length = input.audio.map { String(format: "%.1f min of audio, ", $0.duration / 60) } ?? ""
            lines.append("## \(input.name) (\(length)\(input.characters) characters\(input.isBenchText ? ", bench text" : ""))")
            lines.append("| step | model | time | first words | result | peak footprint | least left | thermal | no result |")
            lines.append("|---|---|---|---|---|---|---|---|---|")
            for row in mine {
                lines.append("| \(row.step.name) | \(row.model.name) | \(row.seconds.text("s")) | " +
                             "\(row.firstWords?.text("s") ?? "-") | \(row.output ?? "-") | " +
                             "\(row.peak.text("GB", digits: 2)) | \(row.least.text("GB", digits: 2)) | " +
                             "\(Self.thermalText(row.thermal)) | \(row.failures) of \(row.seconds.n) |")
            }
            for row in mine where row.step == .summary {
                lines.append("")
                let varies = row.distinctSummaries > 1 ? " (\(row.distinctSummaries) different summaries over the runs)" : ""
                lines.append("**\(row.model.name)**: \(row.title ?? "(no title)")\(varies)")
                lines.append(row.summary ?? "(no usable answer)")
            }
            lines.append("")
        }
        lines.append("## Loads")
        for engine in Engine.allCases {
            if let load = loadStat(engine) { lines.append("- \(engine.name): \(load.text("s", digits: 2)) (n = \(load.n))") }
        }
        lines.append("")
        lines.append("## Model order per repetition")
        for (index, order) in orders.enumerated() {
            lines.append("\(index + 1). " + order.joined(separator: "; "))
        }
        if !batteryRuns.isEmpty {
            lines.append("")
            lines.append("## Battery")
            lines.append("| model | minutes | summaries | battery used | summaries per 1 % | thermal |")
            lines.append("|---|---|---|---|---|---|")
            for run in batteryRuns {
                let perPercent = run.batteryUsed > 0 ? String(format: "%.1f", Double(run.summaries) / run.batteryUsed) : "-"
                lines.append("| \(run.model.name) | \(String(format: "%.1f", run.minutes)) | \(run.summaries) | " +
                             "\(String(format: "%.0f", run.batteryUsed)) % | \(perPercent) | \(run.thermal) |")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Everything the judge needs (FED-153): the inputs' text, every run with its raw answer, the orders, the device.
    nonisolated struct ReportData: Codable {
        nonisolated struct InputData: Codable {
            var id: String, name: String, characters: Int, isBenchText: Bool, audioSeconds: Double?, text: String
        }
        var date: Date
        var device: String
        var speculativeDecoding: Bool
        var steps: [Step]
        var orders: [[String]]
        var inputs: [InputData]
        var runs: [Run]
        var battery: [BatteryRun]
    }

    private func writeReport() {
        guard !runs.isEmpty || !batteryRuns.isEmpty else { return }
        let markdown = report
        let data = ReportData(date: .now, device: deviceLine, speculativeDecoding: speculativeDecoding, steps: steps,
                              orders: orders,
                              inputs: inputs.map { .init(id: $0.id, name: $0.name, characters: $0.characters,
                                                         isBenchText: $0.isBenchText, audioSeconds: $0.audio?.duration,
                                                         text: $0.paragraphs.joined(separator: "\n")) },
                              runs: runs, battery: batteryRuns)
        let directory = URL.cachesDirectory.appending(path: "FederLab")
        let stamp = "bench-\(Int(Date.now.timeIntervalSince1970))"
        let files = [directory.appending(path: stamp + ".md"), directory.appending(path: stamp + ".json")]
        reportFiles = files
        Task.detached {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? markdown.write(to: files[0], atomically: true, encoding: .utf8)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(data).write(to: files[1], options: .atomic)
        }
    }

    nonisolated static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
}

/// Forwards to a model and keeps the final request's answer and the time to its first chunk.
private nonisolated final class MeasuringWriter: TextWriter, @unchecked Sendable {
    let model: any TextWriter
    private let lock = NSLock()
    private var count = 0
    private var firstChunk: Double?
    private var answer: String?

    init(_ model: any TextWriter) { self.model = model }

    var requests: Int { lock.withLock { count } }
    var lastFirstChunk: Double? { lock.withLock { firstChunk } }
    var lastAnswer: String? { lock.withLock { answer } }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String {
        let start = Date.now
        lock.withLock {
            count += 1
            firstChunk = nil
        }
        let text = try await model.respond(instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                                           temperature: temperature) { [self] text in
            lock.withLock { if firstChunk == nil { firstChunk = Date.now.timeIntervalSince(start) } }
            partial?(text)
        }
        lock.withLock { answer = text }
        return text
    }

    func chat(instructions: String, turns: [ChatTurn], maxTokens: Int, temperature: Float,
              partial: (@Sendable (String) -> Void)?) async throws -> String {
        try await model.chat(instructions: instructions, turns: turns, maxTokens: maxTokens, temperature: temperature,
                             partial: partial)
    }

    func unload() async { await model.unload() }
}

/// The peak phys_footprint (what iOS's memory limit counts) and the least memory left before that limit
/// (`os_proc_available_memory`), sampled every 50 ms on a thread of its own.
private nonisolated final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakFootprint: UInt64 = 0
    private var leastAvailable: UInt64 = .max
    private var running = true

    init() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let footprint = Self.footprint(), available = UInt64(os_proc_available_memory())
                lock.withLock {
                    peakFootprint = max(peakFootprint, footprint)
                    leastAvailable = min(leastAvailable, available)
                }
                usleep(50_000)
            }
        }
    }

    func stop() { lock.withLock { running = false } }

    func reset() {
        lock.withLock {
            peakFootprint = Self.footprint()
            leastAvailable = UInt64(os_proc_available_memory())
        }
    }

    /// GB: the peak footprint and the least available since `reset`.
    func peak() -> (Double, Double) {
        lock.withLock { (Double(peakFootprint) / 1_073_741_824, Double(leastAvailable) / 1_073_741_824) }
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// The Lab's model downloads: one background task per file over Wi-Fi (like GemmaDownload, without its retries: a
/// failure shows Try Again), moved into place when it finishes. The session is recreated at launch, which reattaches
/// transfers still running; AppDelegate hands over iOS's completion handler for `sessionIdentifier`.
nonisolated final class LabDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = LabDownload()
    static let sessionIdentifier = "de.timtody.feder.lab"

    enum Event: Sendable {
        case progress(ModelLab.Model, Double)
        case finished(ModelLab.Model)
        case failed(ModelLab.Model, String)
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var backgroundCompletion: (@Sendable () -> Void)?

    func setHandler(_ handler: @escaping @Sendable (Event) -> Void) { lock.withLock { onEvent = handler } }

    func reattach() { _ = backgroundSession() }

    func start(_ model: ModelLab.Model) {
        guard let file = model.file, let location = model.location else { return }
        try? FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var models = URL.applicationSupportDirectory.appending(path: "Models")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? models.setResourceValues(values)
        let url = URL(string: "https://huggingface.co/\(file.repository)/resolve/\(file.revision)/\(file.name)")!
        let task = backgroundSession().downloadTask(with: url)
        task.taskDescription = model.rawValue
        task.resume()
    }

    func cancel(_ model: ModelLab.Model) {
        backgroundSession().getAllTasks { tasks in
            tasks.filter { $0.taskDescription == model.rawValue }.forEach { $0.cancel() }
        }
    }

    func handleBackgroundEvents(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundCompletion = completion }
        reattach()
    }

    private func backgroundSession() -> URLSession {
        lock.withLock {
            if let session { return session }
            let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            configuration.allowsExpensiveNetworkAccess = false            // Wi-Fi only, as Gemma's download
            configuration.allowsConstrainedNetworkAccess = false
            configuration.sessionSendsLaunchEvents = true
            let made = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            session = made
            return made
        }
    }

    private func emit(_ event: Event) { lock.withLock { onEvent }?(event) }

    private func model(of task: URLSessionTask) -> ModelLab.Model? {
        task.taskDescription.flatMap(ModelLab.Model.init(rawValue:))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let model = model(of: downloadTask), let bytes = model.file?.bytes else { return }
        emit(.progress(model, min(1, Double(totalBytesWritten) / Double(bytes))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = model(of: downloadTask), let target = model.location else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return emit(.failed(model, "HTTP \(status)")) }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)   // before this callback returns
            emit(.finished(model))
        } catch {
            emit(.failed(model, error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let model = model(of: task) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        emit(.failed(model, error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        DispatchQueue.main.async { completion?() }
    }
}
#endif
