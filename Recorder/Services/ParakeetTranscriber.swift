import Foundation
import FluidAudio
import Observation

/// NVIDIA Parakeet TDT 0.6B "Ultra" (FluidAudio, CoreML, on device) for the full-accuracy pass after Stop. Measured on
/// 80 real German clips: read speech 11.0 % -> 8.9 % word errors (4.4 % -> 2.4 % character errors) against Apple's
/// SpeechTranscriber, phone calls equal (11.1 %), about 7x faster. 25 European languages. Optional: Apple Speech is the
/// default, and the ~610 MB model downloads from Hugging Face into Application Support/FluidAudio/Models only when the
/// user asks: in the onboarding's Optional Improvements (`request`: Wi-Fi only, remembered until done, so it starts by
/// itself when Wi-Fi comes, also at a later launch) or with "Download Parakeet" in Settings › Transcription (`download
/// (force: true)`: any network, the tap is the choice). A finished download selects it. Until it is there and chosen,
/// the pass uses Apple's recognizer (SpeechFileTranscriber). The download runs while the app is open (FluidAudio's
/// session); leaving the app pauses it, and the next foreground goes on from the partial files.
@MainActor @Observable
final class ParakeetModel {
    /// UserDefaults key of the engine choice ("parakeet" or "apple"); absent means Apple Speech (`defaultEngine`).
    nonisolated static let engineKey = "transcriptionEngine"
    nonisolated static let defaultEngine = "apple"
    nonisolated static var isPreferred: Bool { UserDefaults.standard.string(forKey: engineKey) == "parakeet" }
    nonisolated static let version: AsrModelVersion = .ultra
    /// UserDefaults: the onboarding asked for it and it isn't there yet.
    nonisolated static let wantedKey = "parakeetDownloadWanted"

    private(set) var state: ModelDownloadState
    private let network: NetworkPath
    /// The download the onboarding asked for (Wi-Fi only), so it can pause when Wi-Fi goes (`pauseOffWiFi`); a
    /// download from Settings isn't kept here and goes on.
    @ObservationIgnored private var automaticTask: Task<Void, Never>?

    init(network: NetworkPath) {
        self.network = network
        state = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: Self.version), version: Self.version)
            ? .ready : .notDownloaded
        if state == .ready { UserDefaults.standard.removeObject(forKey: Self.wantedKey) }
        #if DEBUG
        if Self.fakesDownload { UserDefaults.standard.removeObject(forKey: Self.wantedKey) }   // each test run fresh
        #endif
    }

    var isReady: Bool { state == .ready }
    var isWanted: Bool { UserDefaults.standard.bool(forKey: Self.wantedKey) }

    /// The onboarding's Optional Improvements: download it on Wi-Fi, now or as soon as there is Wi-Fi.
    func request() {
        guard state != .ready else { return }
        UserDefaults.standard.set(true, forKey: Self.wantedKey)
        automaticTask = Task { await download(force: false) }
    }

    /// Launch and every foreground (AppServices): goes on with a requested download.
    func resumeIfWanted() {
        guard isWanted else { return }
        automaticTask = Task { await download(force: false) }
    }

    /// NetworkPath changed. Wi-Fi: a requested download goes on, after a short wait so a network that just joined has
    /// settled (as NemotronModel: a captive portal or DHCP still running would fail it at once). Anything else: a
    /// requested download pauses. FluidAudio's session allows cellular and retries a dropped connection from the
    /// partial file, so without this the rest of the 610 MB came over mobile data; cancelled, ModelHub keeps the
    /// `.partial` files and the next Wi-Fi resumes from them.
    func networkChanged(_ kind: NetworkPath.Kind) {
        guard isWanted else { return }
        guard kind == .wifi else {
            if case .downloading = state { automaticTask?.cancel() }
            return
        }
        switch state {
        case .waitingForWiFi, .failed, .notDownloaded:
            automaticTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard network.kind == .wifi else { return }
                await download(force: false)
            }
        case .ready, .downloading:
            break
        }
    }

    /// `force == false`: Wi-Fi only (otherwise it waits, `.waitingForWiFi`); `force == true`: "Download Parakeet" in
    /// Settings, any connection. Once it is there it is the engine: asking for it was the choice.
    func download(force: Bool) async {
        switch state {
        case .ready, .downloading: return
        case .notDownloaded, .waitingForWiFi, .failed: break
        }
        if !force, await network.current() != .wifi {
            state = .waitingForWiFi
            return
        }
        state = .downloading(0)
        do {
            #if DEBUG
            if Self.fakesDownload { try await fakeDownload() } else { try await fetch() }
            #else
            try await fetch()
            #endif
            state = .ready
            UserDefaults.standard.set("parakeet", forKey: Self.engineKey)
            UserDefaults.standard.removeObject(forKey: Self.wantedKey)
        } catch {
            // Off Wi-Fi now, or paused because Wi-Fi went: wait for it (a requested download goes on by itself); on
            // Wi-Fi it is a real failure.
            let paused = error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
            state = isWanted && (paused || network.kind != .wifi) ? .waitingForWiFi : .failed(error.localizedDescription)
        }
    }

    private func fetch() async throws {
        _ = try await AsrModels.download(version: Self.version) { [weak self] progress in
            Task { @MainActor in
                if let self, let next = self.state.advanced(to: progress.fractionCompleted) { self.state = next }
            }
        }
        FluidAudioDiarizer.excludeModelsFromBackup()
    }
}

#if DEBUG
extension ParakeetModel {
    /// Simulator QA: `-fakeParakeetDownload` offers Parakeet in the onboarding and downloads it in
    /// `-fakeParakeetDownloadSeconds` (default 8). The network comes from NetworkPath's fakes.
    static var fakesDownload: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-fakeParakeetDownload")
        #else
        false
        #endif
    }

    private func fakeDownload() async throws {
        let seconds = UserDefaults.standard.double(forKey: "fakeParakeetDownloadSeconds")
        let duration = seconds > 0 ? seconds : 8
        for step in 1...50 {
            try await Task.sleep(for: .seconds(duration / 50))
            state = .downloading(Double(step) / 50)
        }
    }
}
#endif

/// Step 1 of the full-accuracy pass with Parakeet: words with timestamps and confidences from the saved file.
@MainActor
enum ParakeetTranscriber {
    /// Parakeet's word times lead the audio by about 0.12 s, so speaker turns are moved back by that much when aligned
    /// with its words (FileTranscript.alignmentOffset); the stored word times stay as Parakeet gave them. Measured on
    /// DiarBench (Nemotron turns): 2.22 -> 1.77 % wrong words, flat for -0.08 ... -0.16 s; Apple's words need no shift
    /// (-0.12 s there: 2.59 -> 3.69 %).
    nonisolated static let alignmentOffset: TimeInterval = -0.12

    static func supports(_ locale: Locale) -> Bool { language(for: locale) != nil }

    static func transcribe(fileURL: URL, locale: Locale) async throws -> (words: [TranscriptWord], confidences: [Double]) {
        let models = try await AsrModels.loadFromCache(version: ParakeetModel.version)   // loaded per job, then freed
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(fileURL, decoderState: &state, language: language(for: locale))
        return words(from: result.tokenTimings ?? [])
    }

    private static func language(for locale: Locale) -> Language? {
        locale.language.languageCode.flatMap { Language(rawValue: $0.identifier) }
    }

    /// SentencePiece tokens -> words: a token starting with "▁" (or a space), or following a bare "▁", begins a word;
    /// the rest continue it.
    /// A punctuation-only word is glued to the previous one. A word's confidence is its lowest token's.
    nonisolated static func words(from tokens: [TokenTiming]) -> (words: [TranscriptWord], confidences: [Double]) {
        var words: [TranscriptWord] = []
        var confidences: [Double] = []
        var pendingBoundary = false                 // a bare "▁" token: the next piece starts a new word
        for token in tokens where !token.token.isEmpty && token.token != "<blank>" && token.token != "<pad>" {
            let marked = token.token.hasPrefix("▁") || token.token.hasPrefix(" ")
            let piece = marked ? String(token.token.drop { $0 == "▁" || $0 == " " }) : token.token
            guard !piece.isEmpty else { pendingBoundary = true; continue }
            let startsWord = marked || pendingBoundary
            pendingBoundary = false
            let punctuationOnly = piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if words.isEmpty || (startsWord && !punctuationOnly) {
                words.append(TranscriptWord(text: piece, start: token.startTime, end: token.endTime))
                confidences.append(Double(token.confidence))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = max(words[words.count - 1].end, token.endTime)
                confidences[confidences.count - 1] = min(confidences[confidences.count - 1], Double(token.confidence))
            }
        }
        return (words, confidences)
    }
}
