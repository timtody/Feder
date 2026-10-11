import Foundation
import CoreML       // MLComputeUnits
import FluidAudio   // v0.17.4, product "FluidAudio"

/// Live speaker labels with NVIDIA's streaming Sortformer (FluidAudio's `SortformerDiarizer`, `.balancedV2_1`: v2.1
/// weights, 4 speaker slots, 16 kHz mono, 0.08 s frames, a 0.48 s chunk with 0.56 s right context, so about 1.04 s
/// behind the audio). Debug builds only for now, chosen in Settings › About (AppServices.liveLabelsModel), to compare
/// it with LS-EEND on the iPhone before it replaces it; release builds always use LSEENDLiveDiarizer.
///
/// Why: LS-EEND often lumps a later speaker into Speaker 1 for many seconds. Mac bench (`build/qa/sortformer`, 12
/// three-minute German meetings of real voices with 2-4 speakers, streamed through this class in 0.1 s pieces as the
/// capture feeds it, labelled by TranscriptAligner on the exact word times): words right as first shown 93.9 % against
/// LS-EEND's 76.1 % (with -55 dBFS noise, as a phone mic never gives digital silence: 92.7 against 78.7 %); a new
/// speaker labelled correctly p50 1.5 s, p90 3.2 s after their first word against 1.9 / 14.6 s, none missed (LS-EEND
/// missed one; with noise Sortformer's p90 was 24.2 s against 12.3 s, three late speakers in two meetings).
///
/// CPU and Neural Engine, not CPU only like LS-EEND: on the CPU it took 0.22 s of CPU per second of audio on an M5
/// (LS-EEND 0.01-0.03) and fell behind real time while the Mac was busy; with the Neural Engine 0.02 s and nearly the
/// same labels (one meeting compared: 99.0 against 98.8 % right). Not the GPU (.all gave the same labels as the Neural
/// Engine): it stays free for the UI and Gemma. The first load after an install compiles the model for the Neural
/// Engine (10-15 s on the Mac; on the iPhone unmeasured, Nemotron took minutes there).
///
/// Limits: four speaker slots (LS-EEND has ten), and a 246 MB download (fp16 head; LS-EEND 45 MB) pinned to one
/// Hugging Face commit (AppServices.modelRevisions). Like LS-EEND's, the labels are provisional: after Stop the offline
/// diarization (Nemotron, or pyannote) replaces them.
///
/// Built exactly like LSEENDLiveDiarizer: SortformerModels and SortformerDiarizer are non-Sendable, their streaming
/// calls are synchronous CoreML work, so one detached worker task at .utility owns them and serializes requests; only
/// Sendable values ([Float], LiveSpeakerTurns, continuations) cross. The model is loaded once and shared by every
/// recording's diarizer (the streaming state lives in the diarizer).
nonisolated final class SortformerLiveDiarizer: LiveDiarizer, Sendable {
    static let config = SortformerConfig.balancedV2_1
    /// The timeline the Mac bench was measured with: 4 frames (0.32 s) minimum speech, 6 frames (0.48 s) minimum gap.
    static let timelineConfig = DiarizerTimelineConfig(numSpeakers: 4, frameDurationSeconds: 0.08,
                                                       minFramesOn: 4, minFramesOff: 6)
    /// One snapshot per chunk: 6 frames = 0.48 s of audio. A 0.5 s minimum would skip every other chunk and publish
    /// only every 0.96 s.
    static let publishInterval = TimeInterval(config.chunkLen) * TimeInterval(config.frameDurationSeconds)
    static let sampleRate = Double(config.sampleRate)      // 16 kHz; the capture converts to it
    static let computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    var sampleRate: Double { Self.sampleRate }

    private enum Request: Sendable {
        case prepare(CheckedContinuation<Void, any Error>)
        case session(AsyncStream<[Float]>, AsyncStream<LiveSpeakerTurns>.Continuation)
    }

    private let requests: AsyncStream<Request>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Request>.makeStream()
        requests = continuation
        Task.detached(priority: .utility) {
            var models: SortformerModels?                   // loaded once, shared by every recording's diarizer
            for await request in stream {
                switch request {
                case .prepare(let reply):
                    guard models == nil else { reply.resume(); continue }
                    do {
                        models = try await Self.loadModels()
                        FluidAudioDiarizer.excludeModelsFromBackup()
                        reply.resume()
                    } catch {
                        reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription))
                    }
                case .session(let samples, let out):
                    if let models {
                        let diarizer = SortformerDiarizer(config: Self.config, timelineConfig: Self.timelineConfig)
                        diarizer.initialize(models: models)
                        await LiveDiarizerStream.run(diarizer, samples: samples, publishInterval: Self.publishInterval,
                                                     out: out)
                    } else {
                        for await _ in samples {}               // never downloads on the recording path
                        out.finish()
                    }
                }
            }
        }
    }

    deinit { requests.finish() }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { requests.yield(.prepare($0)) }
    }

    func start(samples: AsyncStream<[Float]>) -> AsyncStream<LiveSpeakerTurns> {
        // Snapshots are full states, so a slow consumer only needs the newest one.
        let (turns, out) = AsyncStream<LiveSpeakerTurns>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requests.yield(.session(samples, out))
        return turns
    }

    // MARK: Worker (runs on the detached task only)

    /// ModelHub.loadModels (inside loadFromHuggingFace) downloads only when the .mlmodelc directory is missing or the
    /// revision marker differs (ModelHub.swift:343-344), and a directory left by an interrupted download (its
    /// `.partial` files) would fail to load and be purged with them (ModelHub.swift:134-137). So an incomplete model is
    /// first downloaded explicitly, which resumes the partial files by byte range (FileDownloader.swift:322-343); it
    /// throws while offline and keeps them for the next prepare. A model that still fails to load after a complete
    /// download is a corrupt cache: loadModels removes it and downloads it once more.
    private static func loadModels() async throws -> SortformerModels {
        if !isDownloaded {
            try await ModelHub.download(repo, to: modelsDirectory, variant: bundle)
        }
        return try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: computeUnits)
    }

    private static let repo = Repo.sortformer

    /// "v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc" (ModelNames.Sortformer.bundle(for:)).
    private static var bundle: String { config.modelVariant?.fileName(precision: config.precision) ?? "" }

    /// The directory loadFromHuggingFace uses: Application Support/FluidAudio/Models.
    private static var modelsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "FluidAudio/Models", directoryHint: .isDirectory)
    }

    /// Application Support/FluidAudio/Models/sortformer, holding the `.fluidaudio-revision` marker of a pinned download.
    private static var repoURL: URL {
        modelsDirectory.appending(path: repo.folderName, directoryHint: .isDirectory)
    }

    private static var modelURL: URL {
        repoURL.appending(path: bundle, directoryHint: .isDirectory)
    }

    /// The model is complete on disk from the pinned revision, so `prepare` only loads it and needs no network
    /// (AppServices then prepares it on any connection; a missing one waits for Wi-Fi). As for LS-EEND, the directory
    /// alone proves nothing (it holds the `.partial` files while downloading): `coremldata.bin` must be there and no
    /// `.partial` left. And the marker must name the pinned commit, as ModelCache.matchesRevision requires: after a
    /// change of the pin FluidAudio deletes the folder and downloads again, which must wait for Wi-Fi like a first
    /// download.
    static var isDownloaded: Bool {
        let revision = ModelRegistry.revisionOverrides[repo.remotePath] ?? repo.revision
        let marker = try? String(contentsOf: repoURL.appending(path: ".fluidaudio-revision"), encoding: .utf8)
        guard marker?.trimmingCharacters(in: .whitespacesAndNewlines) == revision || (marker == nil && revision == "main")
        else { return false }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: modelURL.appending(path: "coremldata.bin").path(percentEncoded: false)),
              let files = fileManager.enumerator(at: modelURL, includingPropertiesForKeys: nil) else { return false }
        return !files.contains { ($0 as? URL)?.pathExtension == "partial" }
    }
}
