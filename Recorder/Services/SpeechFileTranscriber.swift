import Foundation
import AVFoundation
import CoreMedia
import Speech

/// The full-accuracy pass after Stop, on the saved WAV, in two steps:
/// - `transcribe` (before speakers are identified): Parakeet Ultra (ParakeetTranscriber) when chosen and downloaded,
///   otherwise SpeechTranscriber without .fastResults (full context window) and without volatile results.
/// - `applyVocabulary` (after speakers are shown, in the background): only with a vocabulary, DictationTranscriber
///   with the vocabulary as contextual strings. SpeechTranscriber ignores contextual strings (measured: identical output
///   with and without), DictationTranscriber honours them but is less accurate on ordinary words, so VocabularyMerge
///   takes over just the vocabulary terms it recognized. This step is most of the post-stop time (a whole-file
///   Dictation pass: 5.4 s of 7.4 s for 5 minutes on an M5 Mac), so speakers never wait for it.
/// Runs at utility priority. A later step failing never loses an earlier one.
@MainActor
final class SpeechFileTranscriber: FileTranscriber {
    /// Ready Parakeet model; nil or not ready = Apple's recognizer for step 1.
    private let parakeet: ParakeetModel?

    init(parakeet: ParakeetModel? = nil) {
        self.parakeet = parakeet
    }

    func transcribe(fileURL: URL, locale requested: Locale) async throws -> FileTranscript {
        if ParakeetModel.isPreferred, parakeet?.isReady == true, ParakeetTranscriber.supports(requested),
           let parsed = try? await ParakeetTranscriber.transcribe(fileURL: fileURL, locale: requested), !parsed.words.isEmpty {
            return FileTranscript(words: parsed.words, confidences: parsed.confidences,
                                  alignmentOffset: ParakeetTranscriber.alignmentOffset)
        }
        guard SpeechTranscriber.isAvailable else { throw RecorderError.transcriberUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw RecorderError.localeUnsupported(requested.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let (words, confidences) = try await analyze(fileURL, with: transcriber, context: nil) { results in
            var words: [TranscriptWord] = []
            var confidences: [Double] = []
            for try await result in results where result.isFinal {
                let parsed = SpeechTranscriberEngine.wordsAndConfidences(from: result.text, fallbackRange: result.range)
                words += parsed.words
                confidences += parsed.confidences
            }
            return (words, confidences)
        }
        return FileTranscript(words: words, confidences: confidences, alignmentOffset: 0)
    }

    func applyVocabulary(to words: [TranscriptWord], fileURL: URL, locale: Locale) async -> [TranscriptWord] {
        await mergeVocabulary(Vocabulary.current, into: words, fileURL: fileURL, locale: locale)
    }

    /// Vocabulary terms recognized by DictationTranscriber (which honours contextual strings).
    private func mergeVocabulary(_ vocabulary: [String], into words: [TranscriptWord], fileURL: URL,
                                 locale: Locale) async -> [TranscriptWord] {
        guard !vocabulary.isEmpty, !words.isEmpty,
              let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { return words }
        let dictation = DictationTranscriber(locale: dictationLocale, preset: .timeIndexedLongDictation)
        guard let hinted = try? await analyze(fileURL, with: dictation, context: Vocabulary.analysisContext(), collect: { results in
            var words: [TranscriptWord] = []
            for try await result in results where result.isFinal {
                words += SpeechTranscriberEngine.words(from: result.text, fallbackRange: result.range)
            }
            return words
        }) else { return words }
        let merged = VocabularyMerge.apply(vocabulary: vocabulary, hinted: hinted, to: words)
        #if DEBUG
        print("[Scribe] full-accuracy pass: \(words.count) words, vocabulary pass: \(hinted.count) words, " +
              "\(zip(words, merged).filter { $0.text != $1.text }.count + abs(words.count - merged.count)) terms merged")
        #endif
        return merged
    }

    /// Runs one module over the whole file and returns what `collect` gathered from its results.
    private func analyze<Module: SpeechModule, Results: AsyncSequence, Output: Sendable>(
        _ fileURL: URL, with module: Module, context: AnalysisContext?,
        collect: @escaping @MainActor (Results) async throws -> Output
    ) async throws -> Output where Results == Module.Results {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()              // normally installed already
        }
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
        if let context { try? await analyzer.setContext(context) }
        let results = Task { try await collect(module.results) }
        do {
            let file = try AVAudioFile(forReading: fileURL)
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()             // empty file
            }
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw RecorderError.transcriptionFailed(error.localizedDescription)
        }
        return try await results.value
    }
}

extension Vocabulary {
    /// The vocabulary as the analyzer's context (contextual strings, `.general` tag).
    static func analysisContext() -> AnalysisContext {
        let context = AnalysisContext()
        let words = current
        if !words.isEmpty { context.contextualStrings[.general] = words }
        return context
    }
}
