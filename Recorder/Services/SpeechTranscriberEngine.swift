import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Apple on-device ASR (iOS 26): SpeechAnalyzer + SpeechTranscriber, fast volatile results (about one per second),
/// per-word audio time ranges on finalized results.
/// Needs only NSMicrophoneUsageDescription (no SFSpeechRecognizer authorization).
@MainActor
final class SpeechTranscriberEngine: Transcriber {
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    func prepare(locale requested: Locale, onDownloadProgress: @escaping @MainActor (Progress) -> Void) async throws -> TranscriberSetup {
        guard SpeechTranscriber.isAvailable else { throw RecorderError.transcriberUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw RecorderError.localeUnsupported(requested.identifier)
        }
        // == reporting [.volatileResults, .fastResults] + attributes [.audioTimeRange]. Without .fastResults the model
        // returns nothing until ~11.6 s of audio are buffered (its context window), then one burst: the live "lag".
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        do {
            do { try await AssetInventory.reserve(locale: locale) }
            catch {
                // Reservations persist per app and are capped (maximumReservedLocales). Free the ones left by
                // earlier system languages and retry once; the app only ever needs the current locale.
                for stale in await AssetInventory.reservedLocales where stale.identifier(.bcp47) != locale.identifier(.bcp47) {
                    await AssetInventory.release(reservedLocale: stale)
                }
                try await AssetInventory.reserve(locale: locale)
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                onDownloadProgress(request.progress)
                try await request.downloadAndInstall()
            }
        } catch {
            throw RecorderError.speechModelDownloadFailed(error.localizedDescription)
        }
        #if DEBUG
        print("[Scribe] transcriber locale \(locale.identifier(.bcp47)), asset status \(await AssetInventory.status(forModules: [transcriber])), reserved \(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) })")
        #endif
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RecorderError.audioEngineFailed("No compatible audio format for the transcriber.")
        }
        // Load the model now, before the microphone starts: start() then analyzes the first audio as it arrives instead
        // of queuing it behind model loading (the "Preparing…" overlay covers this time instead).
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        do { try await analyzer.prepareToAnalyze(in: format) }
        catch { throw RecorderError.transcriptionFailed(error.localizedDescription) }
        #if DEBUG
        print("[Scribe] analyzer prepared, format \(format)")
        #endif
        self.transcriber = transcriber
        self.analyzer = analyzer
        return TranscriberSetup(locale: locale, audioFormat: format)
    }

    func start(input: AsyncStream<AnalyzerInput>, onEvent: @escaping @MainActor (TranscriptionEvent) -> Void) async throws {
        guard let transcriber, let analyzer else {
            throw RecorderError.transcriptionFailed("prepare(locale:) must succeed before start.")
        }
        #if DEBUG
        let startedAt = ContinuousClock.now
        #endif
        resultsTask = Task {                                  // inherits MainActor: onEvent is called directly
            #if DEBUG
            print("[Scribe] results loop started")
            defer { print("[Scribe] results loop ended") }
            #endif
            do {
                for try await result in transcriber.results {
                    #if DEBUG
                    Self.logLag(of: result, since: startedAt)
                    #endif
                    if result.isFinal {
                        onEvent(.finalized(Self.words(from: result.text, fallbackRange: result.range)))
                    } else {
                        onEvent(.volatile(Self.words(from: result.text, fallbackRange: result.range)))
                    }
                }
            } catch {
                #if DEBUG
                print("[Scribe] results error: \(error)")
                #endif
                onEvent(.failed(.transcriptionFailed(error.localizedDescription)))
            }
        }
        do {
            try await analyzer.start(inputSequence: input)
            #if DEBUG
            print("[Scribe] analyzer started")
            #endif
        } catch {
            #if DEBUG
            print("[Scribe] analyzer start error: \(error)")
            #endif
            resultsTask?.cancel()
            throw RecorderError.transcriptionFailed(error.localizedDescription)
        }
    }

    func finish() async throws {
        defer { analyzer = nil; transcriber = nil; resultsTask = nil }
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }   // remaining volatile text arrives as final
        catch {
            resultsTask?.cancel()
            throw RecorderError.transcriptionFailed(error.localizedDescription)
        }
        await resultsTask?.value
    }

    /// One TranscriptWord per timed run. Runs without timing and punctuation-only tokens are glued to the previous
    /// word (or become a prefix of the next). A result with no timed run at all becomes one word spanning `fallbackRange`.
    nonisolated static func words(from text: AttributedString, fallbackRange: CMTimeRange) -> [TranscriptWord] {
        wordsAndConfidences(from: text, fallbackRange: fallbackRange).words
    }

    /// The same words plus each word's recognition confidence (the lowest of its runs; 1 when the result has none,
    /// i.e. without the .transcriptionConfidence attribute).
    nonisolated static func wordsAndConfidences(from text: AttributedString, fallbackRange: CMTimeRange)
        -> (words: [TranscriptWord], confidences: [Double]) {
        var words: [TranscriptWord] = []
        var confidences: [Double] = []
        var prefix = ""
        for run in text.runs {
            let token = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let confidence = run.transcriptionConfidence ?? 1
            if let range = run.audioTimeRange, !isPunctuation(token) {
                words.append(TranscriptWord(text: prefix + token, start: range.start.seconds, end: range.end.seconds))
                confidences.append(confidence)
                prefix = ""
            } else if words.isEmpty {
                prefix += token
            } else {
                words[words.count - 1].text += token
                confidences[confidences.count - 1] = min(confidences[confidences.count - 1], confidence)
            }
        }
        if words.isEmpty, !prefix.isEmpty {
            words.append(TranscriptWord(text: prefix, start: fallbackRange.start.seconds, end: fallbackRange.end.seconds))
            confidences.append(1)
        }
        return (words, confidences)
    }

    nonisolated private static func isPunctuation(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
    }

    #if DEBUG
    /// Device check for the live-lag fix: how far the newest recognized word trails the microphone (Xcode console).
    /// Expect about 1 s or less while someone is speaking (silence after the last word counts too). `input` is how far
    /// the audio consumed so far trails: result.range.end follows the fed audio even when no word has been recognized
    /// up to it, so it only grows when the iPhone's compute is the limit. Measured from analyzer start, which is within
    /// one tap buffer (~0.1 s) of the first audio now that prepare() loads the model.
    private static func logLag(of result: SpeechTranscriber.Result, since start: ContinuousClock.Instant) {
        let wall = (ContinuousClock.now - start) / .seconds(1)
        let textEnd = result.text.runs.compactMap { $0.audioTimeRange?.end.seconds }.max() ?? result.range.end.seconds
        let textLag = wall - textEnd
        let inputLag = wall - result.range.end.seconds
        print("[Scribe] \(result.isFinal ? "final" : "volatile") result \"\(String(result.text.characters).suffix(40))\": text \(String(format: "%.2f", textLag)) s behind, input \(String(format: "%.2f", inputLag)) s behind")
    }
    #endif
}
