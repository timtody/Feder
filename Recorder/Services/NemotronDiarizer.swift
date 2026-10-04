import Foundation
import AVFoundation
import FluidAudio   // v0.17.4, product "FluidAudio"
import Observation

/// Post-recording diarization with NVIDIA Nemotron 3 Diarization (FluidAudio `Nemotron3Diarizer`, preset
/// `c128-split-w8a8`: 98 MB + 2 MB, W8A8 weights, Neural Engine graph, 10.24 s chunks, up to 8 speakers, 10 ms frames)
/// on the whole saved file. DiarizerSelector uses it once its model is downloaded (NemotronModel) and falls back to
/// pyannote (FluidAudioDiarizer) until then or when it fails.
///
/// Measured on DiarBench (36 synthetic German meetings from Multilingual LibriSpeech voices, 2-4 speakers, normal / fast
/// / overlapping turn-taking, clean + simulated room, Parakeet words, the app's final alignment): 1.8 % wrong words
/// against 16.9 % for the previous pipeline (pyannote with the live speaker count and live fallback), fast turn-taking
/// 3.0 % against 29.5 %, the exact speaker count in 70/72 recordings (49/72); 9-10 minute meetings with 7-8 returning
/// speakers 1.6 % against 14.6 %. About 0.19 s per audio minute on an M5 Mac, diarization plus voices (pyannote about
/// 0.5 s). Not measured on an iPhone: Neural Engine compile time and memory of this preset (measured alternative: preset
/// `offline`, GPU, 190 MB, 1.65 %: change only `presetName`).
///
/// Turns from Nemotron's per-frame probabilities for 8 arrival-ordered speaker slots: every 10 ms frame goes to the most
/// probable slot when that probability is > 0.5 (otherwise silence), runs of one slot separated by <= 0.1 s are joined,
/// and a slot with less than 2 s in the whole recording is dropped (its frames go to the next most probable slot): that
/// removes 1-11-word phantom speakers (exact count 70/72 with it). Slots are renumbered by first appearance. Nemotron has
/// no speaker-count setting: the detail menu's "Speakers: n" regroups its turns by voice (SpeakerClustering).
///
/// Threading follows FluidAudioDiarizer: one detached worker task owns the non-Sendable model (loaded once, kept) and
/// serializes requests; only Sendable values cross. The file is streamed through the model in 10 s blocks
/// (`appendAudio`; bit-identical to `processComplete` on all 80 DiarBench recordings, up to 10 minutes), so a long
/// recording is never held in memory whole.
nonisolated final class NemotronDiarizer: Sendable {
    static let presetName = "c128-split-w8a8"
    static let activityThreshold: Float = 0.5
    static let joinGap: TimeInterval = 0.1
    static let minSpeakerSeconds: TimeInterval = 2.0

    private enum Request: Sendable {
        case download(@Sendable (Double) -> Void, CheckedContinuation<Void, any Error>)
        case diarize(URL, CheckedContinuation<[SpeakerTurn], any Error>)
    }

    private let requests: AsyncStream<Request>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Request>.makeStream()
        requests = continuation
        Task.detached(priority: .userInitiated) {
            var diarizer: Nemotron3Diarizer?
            /// Loads the model once, then returns it. `loadFromHuggingFace` downloads whatever is missing, so only
            /// `.download` (NemotronModel: Wi-Fi or "Download Now") may get here without the model on disk.
            func load(progress: ProgressHandler?) async throws -> Nemotron3Diarizer {
                if let diarizer { return diarizer }
                guard let config = Nemotron3Config.preset(named: Self.presetName) else {
                    throw RecorderError.diarizationFailed("Unknown Nemotron preset \(Self.presetName).")
                }
                let models = try await Nemotron3Models.loadFromHuggingFace(config: config, progressHandler: progress)
                let loaded = Nemotron3Diarizer(config: config, models: models)
                diarizer = loaded
                FluidAudioDiarizer.excludeModelsFromBackup()
                return loaded
            }
            for await request in stream {
                switch request {
                case .download(let progress, let reply):
                    do { _ = try await load { progress($0.fractionCompleted) }; reply.resume() }
                    catch { reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription)) }
                case .diarize(let url, let reply):
                    do {
                        guard diarizer != nil || Self.isDownloaded else {
                            throw RecorderError.diarizationFailed("The Nemotron model isn't downloaded.")
                        }
                        reply.resume(returning: try Self.turns(of: url, with: try await load(progress: nil)))
                    } catch {
                        reply.resume(throwing: RecorderError.diarizationFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    deinit { requests.finish() }

    /// Downloads (if needed, ~100 MB) and loads the model; `progress` gets the fraction downloaded.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { requests.yield(.download(progress, $0)) }
    }

    /// Exclusive turns of the whole file, speakerIndex 0-based by first appearance. Throws when the model isn't
    /// downloaded (it never downloads here) or fails.
    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        try await withCheckedThrowingContinuation { requests.yield(.diarize(fileURL, $0)) }
    }

    /// The preset's model and assets are complete on disk: FluidAudio writes its weights-version marker only after
    /// both (Application Support/FluidAudio/Models/nemotron-3-diarization), and discards an older version's files.
    static var isDownloaded: Bool {
        guard let config = Nemotron3Config.preset(named: presetName),
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let repo = base.appending(path: "FluidAudio/Models/\(Repo.nemotron3Diarization.folderName)", directoryHint: .isDirectory)
        let marker = try? String(contentsOf: repo.appending(path: ModelNames.Nemotron3.weightsVersionFile), encoding: .utf8)
        guard marker?.trimmingCharacters(in: .whitespacesAndNewlines) == ModelNames.Nemotron3.weightsVersion else {
            return false
        }
        return ["\(config.hubSubdirectory)/\(config.modelFileName)/coremldata.bin",
                ModelNames.Nemotron3.silenceEmbeddingFile, ModelNames.Nemotron3.preEncodeProjectionFile]
            .allSatisfy { FileManager.default.fileExists(atPath: repo.appending(path: $0).path) }
    }

    // MARK: Worker task only

    /// Streams the file (16 kHz mono; anything else is converted per block) through the model, then `turns`.
    private static func turns(of url: URL, with diarizer: Nemotron3Diarizer) throws -> [SpeakerTurn] {
        diarizer.reset()
        let file = try AVAudioFile(forReading: url)
        let converter = AudioConverter(sampleRate: 16_000)
        let block = AVAudioFrameCount(file.processingFormat.sampleRate * 10)
        var probabilities: [Float] = []
        var frames = 0
        func collect(_ results: [Nemotron3ChunkResult]) {
            for result in results {
                probabilities += result.probabilities
                frames += result.frameCount
            }
        }
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else {
                throw RecorderError.diarizationFailed("No audio buffer.")
            }
            try file.read(into: buffer, frameCount: block)
            guard buffer.frameLength > 0 else { break }
            diarizer.appendAudio(try converter.resampleBuffer(buffer))
            collect(try diarizer.processBufferedAudio())
        }
        collect(try diarizer.finishStream())
        let config = diarizer.config
        return turns(probabilities: probabilities, frames: frames, slots: config.numSpeakers,
                     frameSeconds: Double(config.outputFrameSeconds))
    }

    // MARK: Pure

    struct Run: Equatable {
        var slot: Int
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Exclusive turns from per-frame probabilities (`frames` x `slots`, row-major): exclusive runs, slots with less
    /// than `minSpeakerSeconds` dropped (smallest first, while more than one remains), renumbered by first appearance.
    static func turns(probabilities: [Float], frames: Int, slots: Int, frameSeconds: Double) -> [SpeakerTurn] {
        var dropped = Set<Int>()
        var runs = exclusiveRuns(probabilities: probabilities, frames: frames, slots: slots, frameSeconds: frameSeconds)
        while true {
            var total: [Int: Double] = [:]
            for run in runs { total[run.slot, default: 0] += run.end - run.start }
            guard total.count > 1,
                  let weakest = total.filter({ $0.value < minSpeakerSeconds })
                      .min(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }) else { break }
            dropped.insert(weakest.key)
            runs = exclusiveRuns(probabilities: probabilities, frames: frames, slots: slots, frameSeconds: frameSeconds,
                                 excluding: dropped)
        }
        var number: [Int: Int] = [:]
        return runs.map { run in
            let index = number[run.slot] ?? { let n = number.count; number[run.slot] = n; return n }()
            return SpeakerTurn(speakerIndex: index, start: run.start, end: run.end)
        }
    }

    /// Runs of the most probable slot (> activityThreshold) per frame, same-slot gaps <= joinGap closed. Seconds.
    static func exclusiveRuns(probabilities p: [Float], frames: Int, slots: Int, frameSeconds: Double,
                              excluding dropped: Set<Int> = []) -> [Run] {
        var runs: [Run] = []
        var current: (slot: Int, start: Int)?
        func close(at frame: Int) {
            guard let c = current else { return }
            let run = Run(slot: c.slot, start: Double(c.start) * frameSeconds, end: Double(frame) * frameSeconds)
            if let last = runs.last, last.slot == run.slot, run.start - last.end <= joinGap + 1e-9 {
                runs[runs.count - 1].end = run.end
            } else {
                runs.append(run)
            }
            current = nil
        }
        for f in 0..<frames {
            var best = -1, bestP = activityThreshold
            for s in 0..<slots where !dropped.contains(s) && p[f * slots + s] > bestP { best = s; bestP = p[f * slots + s] }
            if best != current?.slot {
                close(at: f)
                if best >= 0 { current = (best, f) }
            }
        }
        close(at: frames)
        return runs
    }
}

/// The Nemotron model's one-time download (~100 MB into Application Support/FluidAudio/Models/nemotron-3-diarization):
/// automatic at launch and on every return to the foreground on Wi-Fi only (not on cellular, hotspot or Low Data Mode),
/// on any network via "Download Now" in Settings. Until it is there, speakers are identified with pyannote.
@MainActor @Observable
final class NemotronModel {
    private(set) var state: ModelDownloadState
    private let diarizer: NemotronDiarizer

    init(diarizer: NemotronDiarizer) {
        self.diarizer = diarizer
        state = NemotronDiarizer.isDownloaded ? .ready : .notDownloaded
    }

    /// Launch and every return to the foreground (`force == false`: Wi-Fi only), or "Download Now" (`force == true`).
    func download(force: Bool) async {
        switch state {
        case .ready, .downloading: return
        case .notDownloaded, .waitingForWiFi, .failed: break
        }
        if !force, await ModelDownload.isExpensiveNetwork() {
            state = .waitingForWiFi
            return
        }
        state = .downloading(0)
        do {
            try await diarizer.download { [weak self] fraction in
                Task { @MainActor in
                    if let self, let next = self.state.advanced(to: fraction) { self.state = next }
                }
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
