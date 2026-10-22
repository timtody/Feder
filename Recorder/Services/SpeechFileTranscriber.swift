import Foundation
import AVFoundation
import CoreMedia
import Speech

/// The full-accuracy pass after Stop, on the saved WAV: Parakeet Ultra (ParakeetTranscriber) when chosen and
/// downloaded, otherwise SpeechTranscriber without .fastResults (full context window) and without volatile results.
/// Either way the words get the vocabulary's spelling right here (VocabularySpelling), so no second pass follows.
/// A DictationTranscriber pass with the vocabulary as contextual strings, merged by VocabularyMerge, did that until
/// October 2026 (FED-210): it was most of the time after Stop (5.4 s of 7.4 s for 5 minutes on an M5 Mac), missed
/// the user's own words often, and on the synthetic vocabulary sentences found barely more on Apple's words (75 % /
/// 32 % of the terms against 71 % / 31 %) and fewer on Parakeet's (67 % against 68 %; real recordings 93 %).
/// Runs at utility priority.
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
            let spelled = await Self.spellingVocabulary(parsed.words, confidences: parsed.confidences, locale: requested)
            return FileTranscript(words: spelled.words, confidences: spelled.confidences,
                                  alignmentOffset: ParakeetTranscriber.alignmentOffset, vocabularyApplied: true)
        }
        guard SpeechTranscriber.isAvailable else { throw RecorderError.transcriberUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw RecorderError.localeUnsupported(requested.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let (words, confidences) = try await analyze(fileURL, with: transcriber) { results in
            var words: [TranscriptWord] = []
            var confidences: [Double] = []
            for try await result in results where result.isFinal {
                let parsed = SpeechTranscriberEngine.wordsAndConfidences(from: result.text, fallbackRange: result.range)
                words += parsed.words
                confidences += parsed.confidences
            }
            return (words, confidences)
        }
        let spelled = await Self.spellingVocabulary(words, confidences: confidences, locale: requested)
        return FileTranscript(words: spelled.words, confidences: spelled.confidences, alignmentOffset: 0,
                              vocabularyApplied: true)
    }

    /// The vocabulary's spelling on the words (VocabularySpelling, FED-204): on real speech Parakeet's own 74 % of the
    /// terms became 93 %. The search runs off the main actor; only the near misses' words go to the spell checker.
    private static func spellingVocabulary(_ words: [TranscriptWord], confidences: [Double],
                                           locale: Locale) async -> (words: [TranscriptWord], confidences: [Double]) {
        let terms = Vocabulary.current
        guard !terms.isEmpty else { return (words, confidences) }
        let candidates = await VocabularySpelling.candidates(in: words, terms: terms)
        let nonWords = SpellCheck.nonWords(in: Set(candidates.values.flatMap { $0.flatMap(\.unknown) }), locale: locale)
        let spelled = VocabularySpelling.applying(candidates, to: words, confidences: confidences, nonWords: nonWords)
        #if DEBUG
        print("[Scribe] vocabulary spelling: \(words.count) words, \(candidates.count) places, " +
              "\(zip(words, spelled.words).filter { $0.text != $1.text }.count) changed")
        #endif
        return spelled
    }

    /// Transcripts saved before FED-210 whose vocabulary pass was still due: the spelling fix, no pass over the file.
    func applyVocabulary(to words: [TranscriptWord], fileURL: URL, locale: Locale) async -> [TranscriptWord] {
        await Self.spellingVocabulary(words, confidences: [], locale: locale).words
    }

    /// Runs one module over the whole file and returns what `collect` gathered from its results.
    private func analyze<Module: SpeechModule, Results: AsyncSequence, Output: Sendable>(
        _ fileURL: URL, with module: Module,
        collect: @escaping @MainActor (Results) async throws -> Output
    ) async throws -> Output where Results == Module.Results {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()              // normally installed already
        }
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
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
