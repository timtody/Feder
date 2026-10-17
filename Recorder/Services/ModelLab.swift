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

    nonisolated enum Model: String, CaseIterable, Identifiable, Sendable {
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

    private init() {
        for model in Model.allCases where model.file != nil {
            states[model] = Self.isDownloaded(model) ? .ready : .notDownloaded
        }
        LabDownload.shared.setHandler { event in
            Task { @MainActor in ModelLab.shared.handle(event) }
        }
        LabDownload.shared.reattach()
    }

    /// AppServices, at launch: the chosen LiteRT model writes from now on.
    func attach(_ better: BetterSummaries) {
        self.better = better
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

    // MARK: Bench

    struct Run: Identifiable, Sendable {
        let id = UUID()
        var transcript: String
        var characters: Int
        var model: Model
        var loadSeconds: Double?            // the first transcript's run carries the model's load
        var seconds: Double = 0
        var firstWords: Double?             // until the final request's first chunk (the card shows the summary then)
        var requests = 0
        var peakFootprint: Double = 0       // GB
        var leastAvailable: Double = 0      // GB left before iOS's memory limit, at the tightest moment
        var thermal = ""
        var title: String?
        var summary: String?
        var error: String?
    }

    struct BatteryRun: Identifiable, Sendable {
        let id = UUID()
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
    private(set) var reportFile: URL?
    @ObservationIgnored private var benchTask: Task<Void, Never>?

    /// A transcript as Gemma reads it, built as SpeakerIdentifier.describe does (speaker names, bookmark markers).
    struct Input: Sendable {
        var name: String
        var paragraphs: [String]
        var bookmarked: Bool
    }

    static func input(_ recording: Recording) -> Input {
        let segments = recording.segments
        let bookmarked = Set(Bookmarks.byParagraph(recording.bookmarks, in: segments).keys)
        let paragraphs = segments.map { segment in
            TranscriptTitler.paragraph(segment.text, speaker: segment.speakerIndex.map(recording.speakerName),
                                       bookmarked: bookmarked.contains(segment.id))
        }
        return Input(name: recording.name, paragraphs: paragraphs, bookmarked: !bookmarked.isEmpty)
    }

    /// Runs `models` on `inputs`; with `batteryMinutes`, afterwards each model summarizes the inputs over and over for
    /// that long (unplugged), for summaries per 1 % of battery. Background summaries wait meanwhile (`runAhead`); the
    /// screen stays on, since leaving the app stops Gemma.
    func run(models: [Model], inputs: [Input], batteryMinutes: Int?) {
        guard !isRunning, let better, !inputs.isEmpty, !models.isEmpty else { return }
        isRunning = true
        runs = []
        batteryRuns = []
        reportFile = nil
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        benchTask = Task {
            defer {
                isRunning = false
                UIApplication.shared.isIdleTimerDisabled = false
                writeReport()
            }
            do {
                try await better.runAhead { [self] in
                    // The app's own models off the GPU first (not `better.unload()`: it would stop this very run).
                    await better.model?.unload()
                    await better.labWriter?.unload()
                    for model in models {
                        try await bench(model, inputs: inputs)
                    }
                    if let batteryMinutes {
                        for model in models {
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

    private func bench(_ model: Model, inputs: [Input]) async throws {
        let writer = makeWriter(model)
        defer { Task { await writer.unload() } }
        let sampler = MemorySampler()
        defer { sampler.stop() }
        status = "\(model.name): loading"
        let loadStart = Date.now
        if let local = writer as? LocalLanguageModel {
            try await local.load()
        } else if let litert = writer as? LiteRTLanguageModel {
            try await litert.load()
        }
        var loadSeconds: Double? = Date.now.timeIntervalSince(loadStart)
        let titler = TranscriptTitler()
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            status = "\(model.name): \(index + 1) of \(inputs.count)"
            let measuring = MeasuringWriter(writer)
            sampler.reset()
            let start = Date.now
            var run = Run(transcript: input.name, characters: input.paragraphs.joined(separator: "\n").count, model: model,
                          loadSeconds: loadSeconds)
            loadSeconds = nil
            do {
                let description = try await titler.describe(paragraphs: input.paragraphs, locale: .current,
                                                            writer: measuring, bookmarked: input.bookmarked)
                run.title = description?.title
                run.summary = description?.summary ?? "(no usable answer) " + (measuring.lastAnswer ?? "")
            } catch is TranscriptTitler.RetryLater {
                throw CancellationError()
            } catch {
                run.error = String(describing: error)
            }
            run.seconds = Date.now.timeIntervalSince(start)
            run.firstWords = measuring.lastFirstChunk
            run.requests = measuring.requests
            (run.peakFootprint, run.leastAvailable) = sampler.peak()
            run.thermal = Self.thermal
            runs.append(run)
        }
        await writer.unload()
        try await Task.sleep(for: .seconds(2))                  // memory settles before the next model loads
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

    // MARK: Report

    /// The runs as Markdown: a table per transcript, then every summary.
    var report: String {
        let device = "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion), " +
            String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
        var lines = ["# Feder Lab bench, \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                     "\(device); speculative decoding \(speculativeDecoding ? "on" : "off")", ""]
        for transcript in Self.unique(runs.map(\.transcript)) {
            let rows = runs.filter { $0.transcript == transcript }
            lines.append("## \(transcript) (\(rows.first?.characters ?? 0) characters)")
            lines.append("| model | time | first words | requests | load | peak footprint | least left | thermal |")
            lines.append("|---|---|---|---|---|---|---|---|")
            for run in rows {
                lines.append("| \(run.model.name) | \(Self.seconds(run.seconds)) | \(run.firstWords.map(Self.seconds) ?? "-") | " +
                             "\(run.requests) | \(run.loadSeconds.map(Self.seconds) ?? "") | " +
                             String(format: "%.2f GB | %.2f GB", run.peakFootprint, run.leastAvailable) + " | \(run.thermal) |")
            }
            for run in rows {
                lines.append("")
                lines.append("**\(run.model.name)**: \(run.title ?? "(no title)")")
                lines.append(run.error.map { "Error: \($0)" } ?? run.summary ?? "")
            }
            lines.append("")
        }
        if !batteryRuns.isEmpty {
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

    private func writeReport() {
        guard !runs.isEmpty || !batteryRuns.isEmpty else { return }
        let text = report
        let directory = URL.cachesDirectory.appending(path: "FederLab")
        let file = directory.appending(path: "bench-\(Int(Date.now.timeIntervalSince1970)).md")
        Task.detached {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        reportFile = file
    }

    nonisolated static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    nonisolated static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
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
