import AVFoundation
import NaturalLanguage
import Speech

/// The language an imported recording is spoken in. A recording's language is the one picked in the record accessory,
/// but a file can come from anywhere (an English meeting shared while the accessory says German), and Apple's
/// SpeechTranscriber takes one locale and has no language identification (iOS 27 SDK). So an import is probed: 30 s of
/// it are transcribed in each candidate language (the accessory's, then the iPhone's own languages whose speech model
/// is installed), and each transcript's text is read by NLLanguageRecognizer. A model transcribing its own language
/// writes text recognized as that language; a wrong one doesn't (the German model writes English text for English
/// speech, the English one writes gibberish for German). Of the candidates whose text is their own language, the most
/// confident wins; if none is, the language the text is recognized as, when Apple's transcriber knows it. Measured on
/// a Mac (build/qa/langprobe, German and English models): 32 of 32 real German files (Multilingual LibriSpeech, 12
/// meetings and 20 utterances) and 6 of 6 synthetic English ones right, a French one found through the text;
/// confidence alone was right too, but its English margin was thin (0.95 against the German model's 0.84), while the
/// text check separated every case. About 0.5 s for two languages on an M5. Nothing leaves the iPhone.
nonisolated enum LanguageProbe {
    /// The language to transcribe `fileURL` (an import: 16 kHz mono WAV) in; `chosen` when the probe can't tell.
    @concurrent
    static func language(of fileURL: URL, duration: TimeInterval, chosen: Locale) async -> Locale {
        #if targetEnvironment(simulator)
        return chosen                                         // no speech models there; the UI tests' imports are fakes
        #else
        guard SpeechTranscriber.isAvailable, let excerpt = try? excerpt(of: fileURL, duration: duration) else {
            return chosen
        }
        defer { try? FileManager.default.removeItem(at: excerpt) }
        let supported = await SpeechTranscriber.supportedLocales
        var probes: [(locale: Locale, confidence: Double, text: String)] = []
        for locale in await candidates(chosen: chosen, supported: supported) {
            guard let probe = try? await transcribe(excerpt, in: locale), probe.words >= 5 else { continue }
            probes.append((locale, probe.confidence, probe.text))
        }
        guard let best = probes.max(by: { $0.confidence < $1.confidence }) else { return chosen }
        let own = probes.filter { probe in
            guard let language = NLLanguage(locale: probe.locale) else { return false }
            return hypotheses(of: probe.text)[language, default: 0] > 0.8
        }
        if let winner = own.max(by: { $0.confidence < $1.confidence }) {
            #if DEBUG
            print("[Scribe] import language: \(winner.locale.identifier) of \(probes.map { "\($0.locale.identifier) \($0.confidence)" })")
            #endif
            return winner.locale
        }
        // No candidate heard its own language: the one the text is in (French shared to a German and English iPhone).
        if let heard = hypotheses(of: best.text).max(by: { $0.value < $1.value }), heard.value > 0.8,
           let locale = variant(of: Locale(identifier: heard.key.rawValue), in: supported) {
            #if DEBUG
            print("[Scribe] import language: \(locale.identifier), heard in \(best.locale.identifier)'s text")
            #endif
            return locale
        }
        return chosen
        #endif
    }

    /// The accessory's language first, then the iPhone's languages, as Apple's transcriber names them: the chosen one
    /// even if its model isn't installed yet (the transcription needs it anyway), the others only when installed (a
    /// probe downloads nothing for a guess). At most three, one per language.
    private static func candidates(chosen: Locale, supported: [Locale]) async -> [Locale] {
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        var result: [Locale] = []
        var languages: Set<String> = []
        for (index, wanted) in ([chosen] + Locale.preferredLanguages.map(Locale.init(identifier:))).enumerated() {
            guard result.count < 3, let locale = variant(of: wanted, in: supported),
                  let language = locale.language.languageCode?.identifier, !languages.contains(language),
                  index == 0 || installed.contains(locale.identifier) else { continue }
            languages.insert(language)
            result.append(locale)
        }
        return result
    }

    /// Apple's variant of `wanted`'s language: its own region if Apple has it, else the language's likely one (US for
    /// English, FR for French), else the first. `supportedLocale(equivalentTo:)` picked one at random for a bare
    /// language or a region Apple doesn't have (en_SG, then en_GB for "en"; fr_CH for "fr"; Mac harness).
    private static func variant(of wanted: Locale, in supported: [Locale]) -> Locale? {
        guard let code = wanted.language.languageCode?.identifier else { return nil }
        let same = supported.filter { $0.language.languageCode?.identifier == code }
        if let region = wanted.region, let exact = same.first(where: { $0.region == region }) { return exact }
        let likely = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier).region
        return same.first { $0.region == likely } ?? same.min { $0.identifier < $1.identifier }
    }

    /// 30 s of the file into a temporary WAV: from a tenth in for a long file (past an intro or a silent start), else
    /// from the start.
    private static func excerpt(of url: URL, duration: TimeInterval) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let rate = input.processingFormat.sampleRate
        let start = duration > 60 ? min(duration * 0.1, 60) : 0
        input.framePosition = AVAudioFramePosition(start * rate)
        let frames = AVAudioFrameCount(min(30 * rate, Double(input.length - input.framePosition)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try input.read(into: buffer, frameCount: frames)
        let url = FileManager.default.temporaryDirectory.appending(path: "language-probe-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: url, settings: input.fileFormat.settings,
                                     commonFormat: input.processingFormat.commonFormat,
                                     interleaved: input.processingFormat.isInterleaved)
        try output.write(from: buffer)
        return url
    }

    /// The excerpt transcribed in `locale`: the mean confidence per letter, the word count and the text.
    private static func transcribe(_ url: URL, in locale: Locale) async throws
        -> (confidence: Double, words: Int, text: String) {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.transcriptionConfidence])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()            // only the chosen language can be missing
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
        let results = Task { () async throws -> (Double, Int, String) in
            var weighted = 0.0, letters = 0, text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters) + " "
                for run in result.text.runs {
                    guard let confidence = run.transcriptionConfidence else { continue }
                    let count = result.text[run.range].characters.count { !$0.isWhitespace }
                    weighted += confidence * Double(count)
                    letters += count
                }
            }
            return (letters > 0 ? weighted / Double(letters) : 0, text.split(separator: " ").count, text)
        }
        let file = try AVAudioFile(forReading: url)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await results.value
    }

    private static func hypotheses(of text: String) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3)
    }
}

private extension NLLanguage {
    nonisolated init?(locale: Locale) {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        self.init(rawValue: code)
    }
}
