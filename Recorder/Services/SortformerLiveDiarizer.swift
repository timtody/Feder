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
/// capture feeds it, labelled by TranscriptAligner on the exact word times), words right when first labelled: with
/// -55 dBFS noise (a phone mic never gives digital silence; four noise seeds) 92.7-93.3 % against LS-EEND's
/// 85.4-87.3 %, clean 93.9 against 81.9 %. A new speaker labelled correctly p50 1.5 s after their first word, none of
/// 21 missed, against LS-EEND's 1.7-1.9 s with one to four missed; p90 clean 3.0 against 10.0 s, with noise 6-24 s
/// (two late speakers in one meeting) against 13-17 s. README › Live latency notes has the table.
///
/// CPU and Neural Engine, not CPU only like LS-EEND: on the CPU alone it took 0.21-0.30 s of CPU per second of audio on
/// an M5 (LS-EEND 0.01-0.02) and fell behind real time while the Mac was busy; with the Neural Engine 0.02 s of CPU and
/// the same labels overall (93.9 against 94.0 % on the CPU, though single meetings differ by up to 6 points either
/// way). The Neural Engine's own time is not small: fed as fast as it goes, it ran 8 times real time (about 60 ms per
/// 0.48 s chunk, busy an eighth of the time; LS-EEND's whole cost is under a twentieth of that). Not the GPU (.all gave
/// the same labels as the Neural Engine): it stays free for the UI and Gemma. The first load after an install compiles
/// the model for the Neural Engine (10-15 s on the Mac; on the iPhone unmeasured, Nemotron took minutes there).
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

    /// Downloads the model if it is missing, then has the worker load it. The download runs in the caller's task, so
    /// cancelling that (AppServices, when another model was chosen meanwhile) stops it, keeping its `.partial` files
    /// for a later prepare, and nothing is loaded; the worker only ever loads complete files.
    func prepare() async throws {
        try await Self.downloadIfMissing()
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { requests.yield(.prepare($0)) }
    }

    func start(samples: AsyncStream<[Float]>) -> AsyncStream<LiveSpeakerTurns> {
        // Snapshots are full states, so a slow consumer only needs the newest one.
        let (turns, out) = AsyncStream<LiveSpeakerTurns>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requests.yield(.session(samples, out))
        return turns
    }

    /// The download only, in prepare's task but off the main actor (isDownloaded reads the disk), resumable:
    /// ModelHub.download skips finished files and resumes the `.partial` ones by byte range
    /// (FileDownloader.swift:322-343); it throws while offline (or cancelled) and keeps them for the next prepare.
    @concurrent private static func downloadIfMissing() async throws {
        guard !isDownloaded else { return }
        try await ModelHub.download(repo, to: modelsDirectory, variant: bundle)
    }

    // MARK: Worker (runs on the detached task only)

    /// Loads the complete download directly, not through SortformerModels.loadFromHuggingFace: on any load error
    /// that isn't cancellation or a network failure, FluidAudio's ModelHub.loadModels deletes the whole `sortformer`
    /// folder and downloads the 246 MB again at once, on whatever connection there is (ModelHub.swift:131-140), which
    /// would bypass AppServices' Wi-Fi rule and repeat at every foreground. On the CPU and Neural Engine first;
    /// FluidAudio reports Neural Engine compile hangs and failures for Sortformer (issues #726, #828), so if that load
    /// fails, the CPU alone (0.21-0.30 s of CPU per second of audio on an M5 against 0.02 s; the same labels overall).
    /// Only when that fails too are the files taken as corrupt: they are removed, so AppServices sees a missing model
    /// and downloads it again on Wi-Fi, or with "Download Now Using Cellular".
    private static func loadModels() async throws -> SortformerModels {
        do {
            return try await load(computeUnits)
        } catch {
            #if DEBUG
            print("[Scribe] Sortformer: Neural Engine load failed (\(error.localizedDescription)); CPU only")
            #endif
            do {
                return try await load(.cpuOnly)
            } catch {
                try? FileManager.default.removeItem(at: modelURL)
                throw error
            }
        }
    }

    /// The model as ModelHub.loadModels configures it (the bench ran exactly this): the given compute units, low
    /// precision accumulation allowed (a GPU setting; the GPU isn't used).
    private static func load(_ units: MLComputeUnits) async throws -> SortformerModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        configuration.allowLowPrecisionAccumulationOnGPU = true
        let main = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        return try SortformerModels(config: config, main: main)
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
