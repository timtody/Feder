import Foundation
import Observation
import UIKit

/// Gemma 4 E2B (`LocalLanguageModel`), the only writer of titles and summaries (TranscriptTitler). Owns the model's
/// one-time download (3.6 GB, only when the user asks for it in the onboarding sheet or Settings: pinned files from
/// Hugging Face into Application Support, excluded from backups; a background transfer over Wi-Fi, see GemmaDownload),
/// the on/off setting, deleting it, and running it: only while the app is in the foreground, because iOS does not let
/// apps use the GPU in the background (a request is stopped when the app resigns active and tried again on the next
/// return, see `run`). The weights (about 3.7 GB of memory) are freed after a minute without requests and when a
/// recording starts.
@MainActor @Observable
final class BetterSummaries {
    /// UserDefaults key of the toggle; absent means on (once downloaded).
    nonisolated static let enabledKey = "betterSummaries"
    /// Whether this iPhone can run Gemma: 8 GB of memory or more (it needs about 3.7 GB; on a 6 GB iPhone it would be
    /// killed mid-summary), not the simulator (no MLX GPU there). Smaller iPhones are never offered it and get no
    /// automatic titles and summaries. DEBUG on the simulator: `-fakeGemma` (downloaded) and `-fakeGemmaDownload`
    /// (not yet) stand in with `FakeTextWriter`.
    nonisolated static let isSupported: Bool = {
        #if targetEnvironment(simulator)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-fakeGemma") || arguments.contains("-fakeGemmaDownload")
        #else
        return false
        #endif
        #else
        return ProcessInfo.processInfo.physicalMemory >= 7_000_000_000   // the iPhone 17's 8 GB report as about 7.5 GB
        #endif
    }()

    /// The download state per build; `state` is the chosen build's.
    private(set) var states: [LocalLanguageModel.Variant: ModelDownloadState] = [:]
    var state: ModelDownloadState { states[variant] ?? .notDownloaded }
    /// The model of the chosen build, once downloaded.
    private(set) var model: (any TextWriter)?
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

    /// Bytes of the download so far (also while it waits for Wi-Fi, so the bar resumes where it was).
    private(set) var downloadedFraction: Double = 0
    @ObservationIgnored private let network: NetworkPath
    #if DEBUG
    @ObservationIgnored private var fakeDownload: Task<Void, Never>?
    #endif
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
    var activeModel: (any TextWriter)? {
        guard Self.isSupported, isEnabled, state == .ready else { return nil }
        return model
    }

    init(network: NetworkPath) {
        self.network = network
        for build in LocalLanguageModel.Variant.allCases where Self.isSupported && Self.isDownloaded(build) {
            states[build] = .ready
        }
        if state == .ready { model = LocalLanguageModel(variant: variant, directory: Self.modelDirectory(variant)) }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-fakeGemma") {
            states[variant] = .ready
            model = FakeTextWriter()
        }
        #endif
        GemmaDownload.shared.setHandler { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Asked for earlier and not complete: the transfer goes on in the background (or is started again after a
        // force-quit, from its resume data); show it.
        if Self.isSupported, state != .ready, GemmaDownload.isWanted, !Self.usesFakeDownload {
            states[variant] = .downloading(0)
            GemmaDownload.shared.start()
            Task { [weak self, network] in self?.networkChanged(await network.current()) }
        }
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
    func run<T: Sendable>(_ work: @escaping @MainActor (any TextWriter) async throws -> T) async throws -> T {
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
            states[failed] = .failed(String(localized: "Gemma could not be loaded. Download it again."))
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

    /// Free space Gemma needs: its files plus room for the moment a finished file is moved in.
    nonisolated static let neededBytes: Int64 = 4_000_000_000

    /// "Download Gemma 4 E2B" (Settings, onboarding): starts the background transfer, which waits for Wi-Fi.
    func download() {
        guard Self.isSupported else { return }
        switch state {
        case .ready, .downloading, .waitingForWiFi: return
        case .notDownloaded, .failed: break
        }
        let free = (try? URL.applicationSupportDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        guard free >= Self.neededBytes else {
            states[variant] = .failed(String(localized: "Gemma needs 4 GB of free storage on this iPhone."))
            return
        }
        states[variant] = .downloading(downloadedFraction)
        #if DEBUG
        if Self.usesFakeDownload { return startFakeDownload() }
        #endif
        GemmaDownload.shared.start()
        Task { [weak self, network] in self?.networkChanged(await network.current()) }
    }

    /// Free storage for the onboarding page's check, off the main actor (a file-system call).
    @concurrent
    nonisolated static func freeBytes() async -> Int64? {
        try? URL.applicationSupportDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// GemmaDownload's events, on the main actor.
    private func handle(_ event: GemmaDownload.Event) {
        switch event {
        case .progress(let bytes):
            downloadedFraction = min(1, Double(bytes) / Double(variant.downloadBytes))
            if case .downloading(let shown) = state, downloadedFraction - shown >= 0.005 {
                states[variant] = .downloading(downloadedFraction)
            }
        case .finished:
            finishDownload()
        case .failed(let reason):
            guard state != .ready else { return }
            states[variant] = .failed(reason)
        }
    }

    private func finishDownload() {
        downloadedFraction = 1
        states[variant] = .ready
        #if DEBUG && targetEnvironment(simulator)
        model = FakeTextWriter()
        #else
        model = LocalLanguageModel(variant: variant, directory: Self.modelDirectory(variant))
        #endif
        if isEnabled { onBecameActive?() }
    }

    /// NetworkPath changed (AppServices forwards every change): "Waiting for Wi-Fi" while the path is not Wi-Fi without
    /// Low Data Mode, since the background session moves no byte there; back to the bar when it is. The views name the
    /// reason from NetworkPath.kind (no connection, cellular, Low Data Mode).
    func networkChanged(_ kind: NetworkPath.Kind) {
        let wifi = kind == .wifi
        switch state {
        case .downloading where !wifi: states[variant] = .waitingForWiFi
        case .waitingForWiFi where wifi:
            states[variant] = .downloading(downloadedFraction)
            #if DEBUG
            if Self.usesFakeDownload { startFakeDownload() }
            #endif
        default: break
        }
    }

    /// DEBUG on the simulator: `-fakeGemmaDownload` stands in for the transfer (`-fakeGemmaDownloadSeconds`, default
    /// 8, from 0 to 100 %); NetworkPath's fakes (`-fakeNoWiFi`, `-fakeOffline`, `-fakeWiFiAfter`) keep it waiting.
    private static var usesFakeDownload: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-fakeGemmaDownload")
        #else
        false
        #endif
    }

    #if DEBUG
    private func startFakeDownload() {
        guard network.kind == .wifi else {
            states[variant] = .waitingForWiFi
            return
        }
        guard fakeDownload == nil else { return }
        let seconds = UserDefaults.standard.double(forKey: "fakeGemmaDownloadSeconds")
        let duration = seconds > 0 ? seconds : 8
        fakeDownload = Task { [weak self] in
            for step in 1...100 {
                try? await Task.sleep(for: .seconds(duration / 100))
                guard let self, !Task.isCancelled else { return }
                self.handle(.progress(self.variant.downloadBytes * Int64(step) / 100))
            }
            self?.finishDownload()
        }
    }
    #endif

    /// Removes the chosen build's files (all revisions) and frees the memory. Summaries it wrote stay.
    func delete() async {
        GemmaDownload.shared.cancel()
        downloadedFraction = 0
        #if DEBUG
        fakeDownload?.cancel()
        fakeDownload = nil
        #endif
        await unload()
        model = nil
        try? FileManager.default.removeItem(at: Self.modelDirectory(variant).deletingLastPathComponent())
        states[variant] = .notDownloaded
    }
}
