#if DEBUG
import AVFoundation
import FluidAudio
import Foundation
import Observation
import Speech

/// Debug builds (FED-196): NVIDIA's Nemotron 3.5 ASR Streaming (multilingual 0.6B, Core ML via FluidAudio) as the
/// live words instead of Apple's SpeechTranscriber, chosen in Settings › About › Live Words Model, to compare the two
/// on the iPhone. The "latin" variant covers German and English; 1,120 ms chunks (FluidAudio: 560 ms thins out the
/// punctuation in long sessions, 2,240 ms is its recommendation, more delay). Downloaded on request at a pinned
/// revision (AppServices.modelRevisions); loaded once and kept, since a recording can't wait for a 0.6B model to load.
@MainActor @Observable
final class NemotronLiveModel {
    static let shared = NemotronLiveModel()

    nonisolated static let languageCode = "de-DE"        // any of en, es, fr, it, pt, de picks the "latin" folder
    nonisolated static let chunkMs = 1120
    nonisolated static let sizeText = "611 MB"

    private(set) var state: ModelDownloadState = .notDownloaded
    @ObservationIgnored private var shared: SharedNemotronMultilingualModels?
    @ObservationIgnored private var loading: Task<SharedNemotronMultilingualModels, Error>?

    private init() {
        if Self.isDownloaded { state = .ready }
    }

    /// Application Support/FluidAudio/Models/<repo>/latin/1120ms, where FluidAudio's ModelHub puts the variant.
    nonisolated static var variantDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "FluidAudio/Models")
            .appending(path: Repo.nemotronMultilingual.folderName)
            .appending(path: "\(StreamingNemotronMultilingualAsrManager.languageDirectory(for: languageCode))/\(chunkMs)ms")
    }

    nonisolated static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: variantDirectory.appending(path: "metadata.json").path(percentEncoded: false))
    }

    func download() {
        switch state {
        case .downloading, .ready: return
        default: break
        }
        state = .downloading(0)
        Task {
            do {
                _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: Self.languageCode, chunkMs: Self.chunkMs, progressHandler: { progress in
                        Task { @MainActor in
                            if let next = NemotronLiveModel.shared.state.advanced(to: progress.fractionCompleted) {
                                NemotronLiveModel.shared.state = next
                            }
                        }
                    })
                state = Self.isDownloaded ? .ready : .failed("The download ended without the model's files.")
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func delete() {
        shared = nil
        loading = nil
        try? FileManager.default.removeItem(at: Self.variantDirectory)
        state = .notDownloaded
    }

    /// The loaded models, loading them the first time (Core ML compiles them on the first launch: slow once).
    func models() async throws -> SharedNemotronMultilingualModels {
        if let shared { return shared }
        if let loading { return try await loading.value }
        let task = Task { try await StreamingNemotronMultilingualAsrManager.preloadShared(from: Self.variantDirectory) }
        loading = task
        do {
            let models = try await task.value
            shared = models
            loading = nil
            return models
        } catch {
            loading = nil
            throw error
        }
    }
}

/// The live words from Nemotron: the capture's buffers go to FluidAudio's streaming manager chunk by chunk; its token
/// timings (absolute, from the first sample = file frame 0, like Parakeet's) become words through the same parser as
/// Parakeet's (`ParakeetTranscriber.words(from:)`). Nemotron's RNN-T decode never revises a token once emitted, so
/// every word is final as soon as the next one begins: all but the last go out as `.finalized`, the last as the
/// volatile tail. The user's vocabulary goes in as decoder hints (`setCustomVocabulary`, biased inside the greedy
/// decode), so the live words can carry it.
@MainActor
final class NemotronLiveTranscriber: Transcriber {
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var loop: Task<Void, Never>?
    private var onEvent: (@MainActor (TranscriptionEvent) -> Void)?
    private var finalized = 0                            // words already sent as final

    func prepare(locale: Locale, onDownloadProgress: @escaping @MainActor (Progress) -> Void) async throws -> TranscriberSetup {
        guard NemotronLiveModel.isDownloaded else {
            throw RecorderError.transcriptionFailed("Nemotron 3.5 isn't downloaded (Settings › About › Live Words Model).")
        }
        let manager = StreamingNemotronMultilingualAsrManager()
        do {
            try await manager.loadFromShared(try await NemotronLiveModel.shared.models())
        } catch {
            throw RecorderError.transcriptionFailed("Nemotron 3.5 couldn't be loaded. \(error.localizedDescription)")
        }
        // The recording's language as Nemotron's prompt ("de-DE", "en-US"); "auto" lets it detect one.
        await manager.setLanguage(locale.identifier(.bcp47).isEmpty ? "auto" : locale.identifier(.bcp47))
        let terms = Vocabulary.current
        if !terms.isEmpty { await manager.setCustomVocabulary(terms.map { CustomVocabularyTerm(text: $0) }) }
        self.manager = manager
        // 16 kHz mono 16-bit, the WAV Feder writes for Apple's recognizer too; FluidAudio converts it to its floats.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            throw RecorderError.audioEngineFailed("No 16 kHz audio format.")
        }
        #if DEBUG
        print("[Scribe] Nemotron live: language \(locale.identifier(.bcp47)), \(terms.count) vocabulary terms")
        #endif
        return TranscriberSetup(locale: locale, audioFormat: format)
    }

    func start(input: AsyncStream<AnalyzerInput>, onEvent: @escaping @MainActor (TranscriptionEvent) -> Void) async throws {
        guard let manager else { throw RecorderError.transcriptionFailed("prepare(locale:) must succeed before start.") }
        self.onEvent = onEvent
        loop = Task { [weak self] in
            do {
                for await chunk in input {
                    _ = try await manager.process(audioBuffer: chunk.buffer)
                    self?.publish(await manager.getTokenTimings(), final: false)
                }
            } catch {
                onEvent(.failed(.transcriptionFailed(error.localizedDescription)))
            }
        }
    }

    func finish() async throws {
        await loop?.value                                // the capture finished the stream (seal)
        defer {
            let manager = self.manager
            Task { await manager?.cleanup() }
            self.manager = nil
            loop = nil
        }
        guard let manager else { return }
        do {
            let (_, timings) = try await manager.finishWithTokenTimings()
            publish(timings, final: true)
        } catch {
            throw RecorderError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// The words so far: the new complete ones as final, the last as the volatile tail (`final`: everything).
    private func publish(_ timings: [TokenTiming], final: Bool) {
        let words = ParakeetTranscriber.words(from: timings).words
        let complete = final ? words.count : max(0, words.count - 1)
        if complete > finalized {
            onEvent?(.finalized(Array(words[finalized..<complete])))
            finalized = complete
        }
        onEvent?(.volatile(final ? [] : Array(words[complete...])))
    }
}
#endif
