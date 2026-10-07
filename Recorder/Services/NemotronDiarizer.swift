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
        case prewarm(CheckedContinuation<Void, Never>)
        case diarize(URL, CheckedContinuation<[SpeakerTurn], any Error>)
    }

    private let requests: AsyncStream<Request>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Request>.makeStream()
        requests = continuation
        Task.detached(priority: .userInitiated) {
            var diarizer: Nemotron3Diarizer?
            /// Loads the model once, then returns it. `loadFromHuggingFace` downloads whatever is missing, so only
            /// `.download` (NemotronModel: Wi-Fi or "Download Nemotron") may get here without the model on disk.
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
                case .prewarm(let reply):
                    // Loads a downloaded model ahead of the first recording: after a new build iOS compiles it for
                    // the Neural Engine again on first use (178 s on an iPhone 17, then 0.1-0.4 s), which the first
                    // recording's speakers used to wait for. Never downloads.
                    if diarizer == nil, Self.isDownloaded { _ = try? await load(progress: nil) }
                    reply.resume()
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

    /// Loads the model if it is downloaded and not loaded yet (AppServices.prewarmModels); never downloads, never throws.
    func prewarm() async {
        await withCheckedContinuation { requests.yield(.prewarm($0)) }
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

/// The Nemotron model's one-time download (~100 MB into Application Support/FluidAudio/Models/nemotron-3-diarization).
/// Automatic on Wi-Fi only (NetworkPath `.wifi`: not on cellular, a hotspot or Low Data Mode): at launch, on every
/// return to the foreground and as soon as Wi-Fi appears while the app is open (`networkChanged`); before the user has
/// passed the Welcome page nothing downloads (AppServices.modelDownloadsAllowed). "Download Now Using Cellular" in
/// Settings downloads on any connection (`force`). Until it is there, speakers are identified with pyannote.
/// A failure while the phone is off Wi-Fi (offline, the connection dropped) is not "Download Failed" but waiting: it
/// starts again by itself on Wi-Fi. A download that started on Wi-Fi finishes on cellular if Wi-Fi drops (FluidAudio's
/// session allows cellular and can't be configured from outside), so the copy says it "starts" on Wi-Fi.
/// The record accessory shows the download (`state`). After the files the model is loaded and compiled for the Neural
/// Engine before `download` returns; the state stays `.downloading(1)` meanwhile (`preparingFraction`), shown as
/// "Preparing speaker model…".
@MainActor @Observable
final class NemotronModel {
    private(set) var state: ModelDownloadState
    private let diarizer: NemotronDiarizer
    private let network: NetworkPath

    /// `.downloading(f)` with f at least this: the files are there and the model is being loaded.
    nonisolated static let preparingFraction = 0.999

    init(diarizer: NemotronDiarizer, network: NetworkPath) {
        self.diarizer = diarizer
        self.network = network
        state = NemotronDiarizer.isDownloaded ? .ready : .notDownloaded
    }

    /// Launch, every return to the foreground and Wi-Fi arriving (`force == false`: Wi-Fi only), or "Download Now Using
    /// Cellular" / "Try Again" in Settings (`force == true`: any connection).
    func download(force: Bool) async {
        switch state {
        case .ready, .downloading: return
        case .notDownloaded, .waitingForWiFi, .failed: break
        }
        let kind = await network.current()
        if !force, kind != .wifi {
            state = .waitingForWiFi
            return
        }
        #if DEBUG
        if Self.fakesDownload { return await fakeDownload() }
        #endif
        state = .downloading(0)
        do {
            try await diarizer.download { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    // The end is always published (advanced(to:) skips steps under half a per cent): it is "Preparing".
                    if fraction >= 1 { self.state = .downloading(1) }
                    else if let next = self.state.advanced(to: fraction) { self.state = next }
                }
            }
            state = .ready
        } catch {
            // Off Wi-Fi now (offline, dropped, or a forced download on a connection that went away): wait for Wi-Fi
            // instead of reporting a failure; on Wi-Fi it is a real failure (Try Again, and the next foreground).
            state = network.kind == .wifi ? .failed(error.localizedDescription) : .waitingForWiFi
        }
    }

    /// NetworkPath changed: Wi-Fi starts a waiting (or failed) automatic download, after a short wait so a network
    /// that just joined has settled (a captive portal or DHCP still running would fail it at once).
    func networkChanged(_ kind: NetworkPath.Kind, allowed: Bool) {
        guard allowed, kind == .wifi else { return }
        switch state {
        case .waitingForWiFi, .failed, .notDownloaded:
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard network.kind == .wifi else { return }
                await download(force: false)
            }
        case .ready, .downloading:
            break
        }
    }
}

#if DEBUG
extension NemotronModel {
    /// Simulator QA: `-fakeNemotronDownload` pretends Nemotron isn't downloaded yet and downloads it in
    /// `-fakeNemotronDownloadSeconds` (default 8), then "prepares" it for 2 s. The network comes from NetworkPath's fakes
    /// (`-fakeNoWiFi`, `-fakeOffline`, `-fakeLowData`, `-fakeWiFiAfter`).
    static var fakesDownload: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-fakeNemotronDownload")
        #else
        false
        #endif
    }

    private func fakeDownload() async {
        let seconds = UserDefaults.standard.double(forKey: "fakeNemotronDownloadSeconds")
        let duration = seconds > 0 ? seconds : 8
        state = .downloading(0)
        for step in 1...50 {
            try? await Task.sleep(for: .seconds(duration / 50))
            state = .downloading(Double(step) / 50)
        }
        try? await Task.sleep(for: .seconds(2))
        state = .ready
    }
}
#endif
