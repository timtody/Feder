import Foundation
import Observation
import UIKit

/// "Better Summaries" (Settings): Gemma 4 E2B (`LocalLanguageModel`) writes the titles and summaries instead of Apple's
/// model. Owns the model's one-time download (3.6 GB, only when the user taps it: pinned files from Hugging Face into
/// Application Support, excluded from backups), the on/off setting, deleting it, and running it: only while the app is
/// in the foreground, because iOS does not let apps use the GPU in the background (a request is stopped when the app
/// resigns active and tried again on the next return, see `run`). The weights (about 3.7 GB of memory) are freed after a
/// minute without requests and when a recording starts.
@MainActor @Observable
final class BetterSummaries {
    /// UserDefaults key of the toggle; absent means on (once downloaded).
    nonisolated static let enabledKey = "betterSummaries"
    /// The simulator has no MLX GPU support: the feature is shown as unavailable there.
    nonisolated static let isSupported: Bool = {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }()

    /// The download state per build; `state` is the chosen build's.
    private(set) var states: [LocalLanguageModel.Variant: ModelDownloadState] = [:]
    var state: ModelDownloadState { states[variant] ?? .notDownloaded }
    /// The model of the chosen build, once downloaded.
    private(set) var model: LocalLanguageModel?
    /// The local model: Gemma 4 E2B, the only one (see `LocalLanguageModel.Variant`).
    var variant: LocalLanguageModel.Variant { .e2b }
    /// The transcript being described with Gemma right now (Settings shows it while it works).
    private(set) var isWorking = false
    /// SpeakerIdentifier.setRecording: Gemma does not run while recording (the GPU and memory belong to it); a request
    /// in flight when recording starts is stopped.
    @ObservationIgnored var isRecording = false {
        didSet { if isRecording { cancelRunning?() } }
    }
    /// Called when the model becomes usable (downloaded, or turned on): AppServices starts the re-describe sweep.
    @ObservationIgnored var onBecameActive: (() -> Void)?

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var cancelRunning: (() -> Void)?   // stops the request in flight
    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    nonisolated static func modelDirectory(_ variant: LocalLanguageModel.Variant) -> URL {
        URL.applicationSupportDirectory.appending(path: "Models/\(variant.repository.split(separator: "/").last!)")
            .appending(path: variant.revision)
    }

    nonisolated static func isDownloaded(_ variant: LocalLanguageModel.Variant) -> Bool {
        variant.files.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory(variant).appending(path: $0).path(percentEncoded: false))
        }
    }

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.isEnabled) { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
            if newValue { onBecameActive?() } else { Task { await unload() } }
        }
    }

    /// The model to write with: downloaded, turned on, supported. nil = Apple's model.
    var activeModel: LocalLanguageModel? {
        guard Self.isSupported, isEnabled, state == .ready else { return nil }
        return model
    }

    init() {
        for build in LocalLanguageModel.Variant.allCases where Self.isSupported && Self.isDownloaded(build) {
            states[build] = .ready
        }
        if state == .ready { model = LocalLanguageModel(variant: variant, directory: Self.modelDirectory(variant)) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRunning?() }     // stop before the GPU is taken away
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.unload() } }   // a suspended app keeps no 3.7 GB
        })
    }

    // MARK: Running

    /// Runs `work` with Gemma while the app is active: throws RetryLater when it is not, or when it resigns active
    /// meanwhile (the request is cancelled). One request at a time (the background worker is serial anyway).
    func run<T: Sendable>(_ work: @escaping @MainActor (LocalLanguageModel) async throws -> T) async throws -> T {
        guard let model = activeModel else { throw TranscriptTitler.LocalModelFailed(underlying: "not available") }
        guard UIApplication.shared.applicationState == .active, !isRecording else { throw TranscriptTitler.RetryLater() }
        unloadTask?.cancel()
        isWorking = true
        defer {
            isWorking = false
            scheduleUnload()
        }
        let task = Task { try await work(model) }
        cancelRunning = { task.cancel() }
        defer { cancelRunning = nil }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch let error as TranscriptTitler.LocalModelFailed {
            // Gemma doesn't run (damaged files): off until downloaded again, so not every launch tries and falls back.
            #if DEBUG
            print("[Scribe] Gemma failed: \(error.underlying)")
            #endif
            let failed = variant
            await delete()
            states[failed] = .failed("Gemma could not be loaded. Download it again.")
            throw error
        }
    }

    /// Frees the weights (a recording is about to start, or a minute passed without requests).
    func unload() async {
        unloadTask?.cancel()
        cancelRunning?()
        await model?.unload()
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.model?.unload()
        }
    }

    // MARK: Download

    /// "Download Gemma 4 E2B": the pinned files, one after another, each into a temporary file first; a
    /// file already complete from an earlier, interrupted download is kept.
    func download() {
        guard Self.isSupported, downloadTask == nil else { return }
        let build = variant
        switch state {
        case .ready, .downloading: return
        case .notDownloaded, .waitingForWiFi, .failed: break
        }
        states[build] = .downloading(0)
        UIApplication.shared.isIdleTimerDisabled = true      // auto-lock would suspend the app and fail the gigabytes
        downloadTask = Task {
            do {
                try await Self.fetchFiles(build) { fraction in
                    Task { @MainActor in
                        if let next = self.states[build]?.advanced(to: fraction) { self.states[build] = next }
                    }
                }
                states[build] = .ready
                if build == variant {
                    model = LocalLanguageModel(variant: build, directory: Self.modelDirectory(build))
                    if isEnabled { onBecameActive?() }
                }
            } catch let error as URLError where error.code == .cancelled {
                states[build] = .notDownloaded
            } catch is CancellationError {
                states[build] = .notDownloaded
            } catch {
                states[build] = .failed(error.localizedDescription)
            }
            downloadTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Removes the chosen build's files (all revisions) and frees the memory. Summaries it wrote stay.
    func delete() async {
        downloadTask?.cancel()
        await unload()
        model = nil
        try? FileManager.default.removeItem(at: Self.modelDirectory(variant).deletingLastPathComponent())
        states[variant] = .notDownloaded
    }

    private nonisolated static func fetchFiles(_ variant: LocalLanguageModel.Variant,
                                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = modelDirectory(variant)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var models = directory.deletingLastPathComponent().deletingLastPathComponent()   // …/Models: no iCloud backup
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? models.setResourceValues(values)

        let total = Double(variant.downloadBytes)
        var done: Int64 = 0
        for name in variant.files {
            let target = directory.appending(path: name)
            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                done += (try? fileManager.attributesOfItem(atPath: target.path(percentEncoded: false))[.size] as? Int64) ?? 0
                continue
            }
            let url = URL(string: "https://huggingface.co/\(variant.repository)/resolve/\(variant.revision)/\(name)")!
            let before = done
            let temporary = try await FileDownload.run(url) { written in progress(min(1, Double(before + written) / total)) }
            try fileManager.moveItem(at: temporary, to: target)
            done += (try? fileManager.attributesOfItem(atPath: target.path(percentEncoded: false))[.size] as? Int64) ?? 0
            progress(min(1, Double(done) / total))
        }
    }

    /// One file, with progress: a session whose delegate gets `didWriteData` (the async `download(from:delegate:)` does
    /// not report progress to a task delegate). Cancelling the Swift task cancels the download.
    nonisolated private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let report: @Sendable (Int64) -> Void
        private var continuation: CheckedContinuation<URL, any Error>?
        private let lock = NSLock()

        private init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

        static func run(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
            let download = FileDownload(report: progress)
            let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: url)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    download.lock.withLock { download.continuation = continuation }
                    task.resume()
                }
            } onCancel: { task.cancel() }
        }

        private func finish(_ result: Result<URL, any Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<URL, any Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                finish(.failure(URLError(.badServerResponse)))
                return
            }
            // The file at `location` is deleted when this returns: move it somewhere of ours first.
            let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                finish(.success(kept))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error { finish(.failure(error)) }
        }
    }
}
