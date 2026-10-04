import Foundation
import FluidAudio
import Observation

/// NVIDIA Parakeet TDT 0.6B "Ultra" (FluidAudio, CoreML, on device) for the full-accuracy pass after Stop. Measured on
/// 80 real German clips: read speech 11.0 % -> 8.9 % word errors (4.4 % -> 2.4 % character errors) against Apple's
/// SpeechTranscriber, phone calls equal (11.1 %), about 7x faster. 25 European languages. The ~610 MB model downloads
/// once from Hugging Face into Application Support/FluidAudio/Models: automatically on Wi-Fi, on cellular only when the
/// user taps "Download Now". Until it is there, the pass uses Apple's recognizer.
@MainActor @Observable
final class ParakeetModel {
    /// UserDefaults key of the engine choice ("parakeet" or "apple"); absent means Parakeet.
    nonisolated static let engineKey = "transcriptionEngine"
    nonisolated static var isPreferred: Bool { UserDefaults.standard.string(forKey: engineKey) ?? "parakeet" == "parakeet" }
    nonisolated static let version: AsrModelVersion = .ultra

    private(set) var state: ModelDownloadState

    init() {
        state = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: Self.version), version: Self.version)
            ? .ready : .notDownloaded
    }

    var isReady: Bool { state == .ready }

    /// Launch and every return to the foreground (`force == false`: Wi-Fi only), or "Download Now" (`force == true`).
    func download(force: Bool) async {
        guard Self.isPreferred else { return }
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
            _ = try await AsrModels.download(version: Self.version) { [weak self] progress in
                Task { @MainActor in
                    if let self, let next = self.state.advanced(to: progress.fractionCompleted) { self.state = next }
                }
            }
            FluidAudioDiarizer.excludeModelsFromBackup()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

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
