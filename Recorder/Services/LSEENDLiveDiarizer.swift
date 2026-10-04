import Foundation
import FluidAudio   // v0.17.4, product "FluidAudio"

/// Live speaker labels while recording: FluidAudio's streaming LS-EEND diarizer (DIHARD-III variant, up to 10 speakers,
/// 8 kHz mono, 0.1 s frames, ~0.9 s right context, CPU only). One ~45 MB CoreML model is downloaded from Hugging Face
/// into Application Support/FluidAudio/Models on the first prepare(), then it works offline. The labels are provisional:
/// after Stop, the offline diarization (DiarizerSelector: Nemotron, or pyannote) overwrites them, so the offline pass stays
/// the source of truth.
///
/// LSEENDModel and LSEENDDiarizer are non-Sendable classes whose streaming calls are synchronous, blocking CoreML work,
/// so, exactly like FluidAudioDiarizer, one detached worker task owns them and serializes requests. Only Sendable values
/// ([Float], LiveSpeakerTurns, continuations) cross the boundary. No @unchecked Sendable anywhere. The worker runs at
/// .utility so SpeechAnalyzer (.userInitiated) keeps priority on the CPU.
nonisolated final class LSEENDLiveDiarizer: LiveDiarizer, Sendable {
    static let variant: LSEENDVariant = .dihard3          // general purpose, up to 10 speakers
    static let stepSize: LSEENDStepSize = .step500ms      // one CoreML call per 0.5 s of audio (10/s at the 100 ms default)
    static let publishInterval: TimeInterval = 0.5        // seconds of audio between two snapshots: every step

    private enum Request: Sendable {
        case prepare(CheckedContinuation<Void, any Error>)
        case session(AsyncStream<[Float]>, AsyncStream<LiveSpeakerTurns>.Continuation)
    }

    private let requests: AsyncStream<Request>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Request>.makeStream()
        requests = continuation
        Task.detached(priority: .utility) {
            var model: LSEENDModel?                         // loaded once, shared by every recording's diarizer
            for await request in stream {
                switch request {
                case .prepare(let reply):
                    guard model == nil else { reply.resume(); continue }
                    do {
                        model = try await Self.loadModel()
                        FluidAudioDiarizer.excludeModelsFromBackup()
                        reply.resume()
                    } catch {
                        reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription))
                    }
                case .session(let samples, let out):
                    if let model {
                        await Self.run(model: model, samples: samples, out: out)
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

    /// One recording, with a fresh LSEENDDiarizer (the streaming state lives in the diarizer, not in the model). Feeds
    /// every chunk in order: time is the count of fed samples, so nothing may be dropped. Once nobody listens any more
    /// (or inference failed) it only drains, so capture is never blocked and the worker becomes free again.
    private static func run(model: LSEENDModel, samples: AsyncStream<[Float]>,
                            out: AsyncStream<LiveSpeakerTurns>.Continuation) async {
        defer { out.finish() }
        // Frame-based config on purpose: LSEENDDiarizer overwrites frameDurationSeconds with the model's 0.1 s AFTER
        // the seconds-based initializer converted with its 0.08 s default. 3 frames = 0.3 s minimum speech, 5 frames
        // = 0.5 s minimum gap: no label flicker on breaths and blips.
        guard let diarizer = try? LSEENDDiarizer(model: model,
                                                 timelineConfig: DiarizerTimelineConfig(minFramesOn: 3, minFramesOff: 5))
        else {
            for await _ in samples {}
            return
        }
        let frameHz = diarizer.modelFrameHz ?? 10
        var numbering: [Int: Int] = [:]                     // LS-EEND slot -> speakerIndex, for this recording
        var publishedAt: TimeInterval = 0
        var listening = true
        for await chunk in samples {
            guard listening else { continue }
            do {
                guard try diarizer.process(samples: chunk) != nil else { continue }   // nil until a 0.5 s step is full
            } catch {
                listening = false                           // live labels end for this recording only
                continue
            }
            let processed = Double(diarizer.numFramesProcessed) / frameHz
            guard processed - publishedAt >= publishInterval else { continue }
            publishedAt = processed
            if case .terminated = out.yield(snapshot(of: diarizer.timeline, until: processed, numbering: &numbering)) {
                listening = false
            }
        }
        guard listening else { return }
        _ = try? diarizer.finalizeSession()                 // flushes the right context and closes open segments
        out.yield(snapshot(of: diarizer.timeline, until: .infinity, numbering: &numbering))
    }

    /// Every segment so far (closed + still open, read from the timeline itself, so segments closed by finalize() are
    /// included), with LS-EEND's model slots (0..<10, possibly sparse) renumbered 0, 1, 2 ... by first appearance. The
    /// mapping persists for the recording, so a number once shown never moves to another slot.
    private static func snapshot(of timeline: DiarizerTimeline, until processedUntil: TimeInterval,
                                 numbering: inout [Int: Int]) -> LiveSpeakerTurns {
        let segments = timeline.speakers.values
            .flatMap { $0.finalizedSegments + $0.tentativeSegments }
            .sorted { ($0.startFrame, $0.speakerIndex) < ($1.startFrame, $1.speakerIndex) }
        var turns: [SpeakerTurn] = []
        turns.reserveCapacity(segments.count)
        for segment in segments {
            let index: Int
            if let known = numbering[segment.speakerIndex] {
                index = known
            } else {
                index = numbering.count
                numbering[segment.speakerIndex] = index
            }
            turns.append(SpeakerTurn(speakerIndex: index, start: TimeInterval(segment.startTime),
                                     end: TimeInterval(segment.endTime)))
        }
        return LiveSpeakerTurns(turns: turns, processedUntil: processedUntil)
    }

    /// LSEENDModel.loadFromHuggingFace downloads only when the .mlmodelc directory is missing (LSEENDInference.swift:64-73),
    /// and ModelHub creates that directory, which holds the resumable `.partial` files, before it fetches anything
    /// (ModelHub.swift:623-641). So on failure the directory is kept: ModelHub.download runs again, skips the finished
    /// files and resumes the partial ones by byte range (FileDownloader.swift:45-47, 74, 322-343); it throws while
    /// offline, keeping the partials for the next foreground prepare. Only a model that still fails to open after a
    /// completed download is treated as a corrupt cache: removed and downloaded once more from scratch.
    private static func loadModel() async throws -> LSEENDModel {
        do {
            return try await LSEENDModel.loadFromHuggingFace(variant: variant, stepSize: stepSize)
        } catch {
            try await ModelHub.download(variant.repo, subdirectory: relativePath, to: repoURL)
            do {
                return try LSEENDModel(modelURL: modelURL)   // default .cpuOnly, as loadFromHuggingFace
            } catch {
                try? FileManager.default.removeItem(at: modelURL)
                return try await LSEENDModel.loadFromHuggingFace(variant: variant, stepSize: stepSize)
            }
        }
    }

    /// The paths loadFromHuggingFace uses (LSEENDInference.swift:51-62):
    /// Application Support/FluidAudio/Models/ls-eend/dih3/optimized/dih3/500ms/ls_eend_dih3_500ms.mlmodelc
    private static var repoURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "FluidAudio/Models/\(variant.repo.folderName)", directoryHint: .isDirectory)
    }

    private static var relativePath: String {
        let file = variant.fileName(forStep: stepSize)
        return variant.repo.subPath.map { "\($0)/\(file)" } ?? file
    }

    private static var modelURL: URL {
        repoURL.appending(path: relativePath, directoryHint: .isDirectory)
    }
}
