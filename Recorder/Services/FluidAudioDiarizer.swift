import Foundation
import FluidAudio   // v0.17.4, product "FluidAudio"

/// FluidAudio's offline pyannote pipeline (community-1 segmentation + WeSpeaker embeddings + VBx, ~21 MB of Core ML
/// models downloaded from Hugging Face on first use into Application Support, then fully offline). Two roles:
/// - the owner of the WeSpeaker models: speakers' voices for recognition (`voices`) and the span embeddings of the
///   speaker-count clustering (`embeddings`), for every diarizer (VoiceEmbedder);
/// - the fallback diarizer while Nemotron (NemotronDiarizer) is not downloaded or fails (DiarizerSelector).
///
/// OfflineDiarizerManager is a non-Sendable class whose async methods are @concurrent, so it cannot be stored in an
/// actor and awaited (Swift 6 SIL error: "sending 'self'-isolated 'self.manager' to @concurrent instance method").
/// One detached worker task therefore owns the loaded models for the lifetime of this object, serializes requests and
/// builds a short-lived manager per request (its config, which carries the speaker count, is fixed at init;
/// `initialize(models:)` only stores the already loaded models). Only Sendable values (URLs, spans, turns, voices,
/// continuations, the Sendable OfflineDiarizerModels) cross task boundaries. No @unchecked Sendable anywhere.
///
/// Config: `.default` (exclusiveSegments, AHC threshold 0.6) with three changes, measured on DiarBench (36 synthetic
/// German meetings, clean + room, Parakeet words): VBx `warmStartFa` 0.07 -> 0.1 (0.07 merged similar voices: 21.3 %
/// vs 18 % wrong words), `minSegmentDurationSeconds` 1.0 -> 0.3 (FluidAudio drops every output segment shorter than
/// that, i.e. most interjections) and segmentation `stepRatio` 0.2 -> 0.1 (finer windows for fast turn-taking).
/// Together 18.8 % -> 16.2 % wrong words; Nemotron: 1.8 %.
///
/// Models are loaded with `OfflineDiarizerModels.load()` + `initialize(models:)` rather than `prepareModels()`:
/// `prepareModels()` deletes the whole model repo (including FileDownloader's resumable `.partial` files) on ANY
/// first-load failure before retrying, so a connection drop mid-download restarts the 21 MB fetch from zero on the
/// next foreground sweep. `OfflineDiarizerModels.load()` goes straight to ModelHub, which keeps the cache for
/// transient network errors (byte-range resume) and purges only on corruption. Only the manager's private prewarm
/// is skipped (the first `process` pays the CoreML warm-up instead).
nonisolated final class FluidAudioDiarizer: SpeakerDiarizer, Sendable {
    private enum Request: Sendable {
        case prepare(CheckedContinuation<Void, any Error>)
        case diarize(URL, SpeakerCount, CheckedContinuation<[SpeakerTurn], any Error>)
        case voices(URL, [Int: [VoiceWindows.Window]], CheckedContinuation<[Int: SpeakerVoice], any Error>)
        case embeddings(URL, [VoiceWindows.Span], CheckedContinuation<[[Float]], any Error>)
    }

    private let requests: AsyncStream<Request>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Request>.makeStream()
        requests = continuation
        Task.detached(priority: .userInitiated) {
            var models: OfflineDiarizerModels?
            func prepare() async throws -> OfflineDiarizerModels {   // loads once, then returns the cached models
                if let models { return models }
                let loaded = try await OfflineDiarizerModels.load()
                models = loaded
                Self.excludeModelsFromBackup()
                return loaded
            }
            for await request in stream {
                switch request {
                case .prepare(let reply):
                    do { _ = try await prepare(); reply.resume() }
                    catch { reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription)) }
                case .diarize(let url, let speakers, let reply):
                    do {
                        var config = OfflineDiarizerConfig.default
                        config.clustering.warmStartFa = 0.1                   // see the type comment
                        config.embedding.minSegmentDurationSeconds = 0.3
                        config.segmentation.stepRatio = 0.1
                        if case .exactly(let n) = speakers { config.clustering.numSpeakers = n }   // K-Means re-cluster
                        let manager = OfflineDiarizerManager(config: config)
                        manager.initialize(models: try await prepare())
                        let result = try await manager.process(url)           // memory-mapped, resamples to 16 kHz itself
                        reply.resume(returning: Self.turns(from: result))
                    } catch OfflineDiarizationError.noSpeechDetected {
                        // Too little voiced audio for a single speaker embedding (< ~2 s): a legitimate outcome,
                        // not a failure. No turns -> un-attributed paragraphs, status .done.
                        reply.resume(returning: [])
                    } catch {
                        reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription))
                    }
                case .voices(let url, let windows, let reply):
                    // VoiceEmbedder is created per request inside this task: no MLModel ever crosses a task boundary.
                    do { reply.resume(returning: try VoiceEmbedder(models: try await prepare()).voices(fileURL: url, windows: windows)) }
                    catch { reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription)) }
                case .embeddings(let url, let spans, let reply):
                    do { reply.resume(returning: try VoiceEmbedder(models: try await prepare()).embeddings(fileURL: url, spans: spans)) }
                    catch { reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription)) }
                }
            }
        }
    }

    deinit { requests.finish() }

    /// FluidAudio v0.17.4 downloads its models to `Application Support/FluidAudio/Models`
    /// (MLModelConfigurationUtils.swift:37-47) and never sets the do-not-backup attribute. Application Support is
    /// backed up by default and Apple's iOS Data Storage Guidelines require re-downloadable data to be excluded.
    /// Idempotent; the attribute on the directory covers everything below it, and FluidAudio's cache purge only
    /// removes the repo subfolder, so it survives a re-download. The path is built here rather than via
    /// `OfflineDiarizerModels.defaultModelsDirectory()` so the directory layout is explicit.
    /// Also called for the Nemotron, Parakeet and live models: they are downloaded below the same directory.
    static func excludeModelsFromBackup() {
        guard var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        dir.append(path: "FluidAudio/Models", directoryHint: .isDirectory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { requests.yield(.prepare($0)) }
    }

    func diarize(fileURL: URL, speakers: SpeakerCount) async throws -> [SpeakerTurn] {
        try await withCheckedThrowingContinuation { requests.yield(.diarize(fileURL, speakers, $0)) }
    }

    func diarization(fileURL: URL, speakers: SpeakerCount) async throws -> Diarization {
        Diarization(turns: try await diarize(fileURL: fileURL, speakers: speakers), diarizer: .pyannote)
    }

    func voices(fileURL: URL, windows: [Int: [VoiceWindows.Window]]) async throws -> [Int: SpeakerVoice] {
        guard !windows.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { requests.yield(.voices(fileURL, windows, $0)) }
    }

    /// VoiceEmbedder.embeddings (each span inside its real surrounding audio), for SpeakerClustering.
    func embeddings(fileURL: URL, spans: [VoiceWindows.Span]) async throws -> [[Float]] {
        guard !spans.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { requests.yield(.embeddings(fileURL, spans, $0)) }
    }

    /// FluidAudio labels clusters "S1", "S2", ... (OfflineDiarizerManager.swift:536). Renumber 0-based by first
    /// appearance so the app shows "Speaker 1" for whoever spoke first. (Its speakerDatabase centroids are not used:
    /// voices come from the final labels, VoiceEmbedder.)
    static func turns(from result: DiarizationResult) -> [SpeakerTurn] {
        var index: [String: Int] = [:]
        return result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { segment in
                let i = index[segment.speakerId] ?? { let n = index.count; index[segment.speakerId] = n; return n }()
                return SpeakerTurn(speakerIndex: i,
                                   start: TimeInterval(segment.startTimeSeconds),
                                   end: TimeInterval(segment.endTimeSeconds))
            }
    }
}
