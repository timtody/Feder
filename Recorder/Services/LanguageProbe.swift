import AVFoundation
import CoreMedia
import NaturalLanguage
import Speech

/// The language an imported recording is spoken in. A recording's language is the one picked in the record accessory,
/// but a file can come from anywhere (an English meeting shared while the accessory says German), and Apple's
/// SpeechTranscriber takes one locale and has no language identification (iOS 27 SDK). So an import is probed: three
/// 20 s windows of it (at a tenth, the middle and four fifths of a long file; its first minute otherwise) are
/// transcribed in each candidate language whose speech model is installed (the accessory's, then the iPhone's own; a
/// probe downloads nothing: the chosen language's model, if missing, comes with the words pass as before), and each
/// window's text is read by NLLanguageRecognizer. A model transcribing its own language writes text recognized as that
/// language; a wrong one doesn't (the German model writes English text for English speech, the English one writes
/// gibberish for German). In each window, of the candidates whose text is mostly their own language the most confident
/// wins; if none is, the language the text is recognized as, when Apple's transcriber knows it. The windows vote (a tie
/// goes to the accessory's language): judged as one, a 30 s English intro outweighed a German meeting. Measured on a Mac (build/qa/langprobe, German and English models): 32 of 32 real German files
/// (Multilingual LibriSpeech, 12 meetings and 20 utterances) and 6 of 6 synthetic English ones right with either
/// language chosen, a German meeting with an English intro German, a French file found through the text; confidence
/// alone was right too, but its English margin was thin (0.95 against the German model's 0.84), while the text check
/// separated every case. About a second for two languages on an M5. Nothing leaves the iPhone.
nonisolated enum LanguageProbe {
    /// The language to transcribe `fileURL` (an import: 16 kHz mono WAV) in; `chosen` when the probe can't tell.
    @concurrent
    static func language(of fileURL: URL, duration: TimeInterval, chosen: Locale) async -> Locale {
        #if targetEnvironment(simulator)
        return chosen                                         // no speech models there; the UI tests' imports are fakes
        #else
        guard SpeechTranscriber.isAvailable else { return chosen }
        let supported = await SpeechTranscriber.supportedLocales
        let candidates = await candidates(chosen: chosen, supported: supported)
        guard !candidates.isEmpty, let excerpt = try? excerpt(of: fileURL, duration: duration) else { return chosen }
        defer { try? FileManager.default.removeItem(at: excerpt) }
        var probes: [(locale: Locale, windows: [Window])] = []
        for locale in candidates {
            if let windows = try? await transcribe(excerpt, in: locale) { probes.append((locale, windows)) }
        }
        var votes: [Locale: (count: Int, confidence: Double)] = [:]
        for index in 0..<windowCount {
            guard let pick = pick(in: probes.map { ($0.locale, $0.windows[index]) }, supported: supported) else { continue }
            votes[pick.locale, default: (0, 0)].count += 1
            votes[pick.locale, default: (0, 0)].confidence += pick.confidence
        }
        let winner = votes.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            if (a.key == chosen) != (b.key == chosen) { return b.key == chosen }
            return a.value.confidence < b.value.confidence
        }
        #if DEBUG
        print("[Scribe] import language: \(winner?.key.identifier ?? "-") of \(votes.map { "\($0.key.identifier) \($0.value.count)" })")
        #endif
        return winner?.key ?? chosen
        #endif
    }

    /// A window's transcript in one candidate language: the mean confidence per letter, its letters and its text.
    private struct Window {
        var confidence = 0.0
        var letters = 0
        var text = ""
    }

    private static let windowCount = 3
    private static let windowLength: TimeInterval = 20

    /// The language one window is in: of the candidates whose text is mostly their own language the most confident;
    /// else the language the most confident one's text is in (a candidate's variant first: zh_TW, not the likely zh_CN,
    /// for Traditional Chinese text); nil when the window says nothing (silence, music, too few letters).
    private static func pick(in probes: [(locale: Locale, window: Window)], supported: [Locale])
        -> (locale: Locale, confidence: Double)? {
        // Letters, not words: Chinese and Japanese transcripts have no spaces between words.
        let usable = probes.filter { $0.window.letters >= 15 }
        guard let best = usable.max(by: { $0.window.confidence < $1.window.confidence }) else { return nil }
        let own = usable.filter { probe in
            guard let heard = dominant(probe.window.text) else { return false }
            return heard.language == language(of: probe.locale) && heard.share > 0.5
        }
        if let winner = own.max(by: { $0.window.confidence < $1.window.confidence }) {
            return (winner.locale, winner.window.confidence)
        }
        guard let heard = dominant(best.window.text), heard.share > 0.8,
              let locale = probes.first(where: { language(of: $0.locale) == heard.language })?.locale
                ?? variant(of: Locale(identifier: heard.language.rawValue), in: supported) else { return nil }
        return (locale, best.window.confidence)
    }

    /// The accessory's language first, then the iPhone's languages, as Apple's transcriber names them, each only when
    /// its model is installed. At most three, one per language.
    private static func candidates(chosen: Locale, supported: [Locale]) async -> [Locale] {
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        var result: [Locale] = []
        var languages: Set<NLLanguage> = []
        for wanted in [chosen] + Locale.preferredLanguages.map(Locale.init(identifier:)) {
            guard result.count < 3, let locale = variant(of: wanted, in: supported), installed.contains(locale.identifier),
                  let language = language(of: locale), languages.insert(language).inserted else { continue }
            result.append(locale)
        }
        return result
    }

    /// Apple's variant of `wanted`'s language (and script: Traditional or Simplified Chinese): its own region if Apple
    /// has it, else the language's likely one (US for English, FR for French, TW for Traditional Chinese), else the
    /// first. `supportedLocale(equivalentTo:)` picked one at random for a bare language or a region Apple doesn't have
    /// (en_SG, then en_GB for "en"; fr_CH for "fr"; Mac harness).
    private static func variant(of wanted: Locale, in supported: [Locale]) -> Locale? {
        let full = Locale.Language(identifier: wanted.language.maximalIdentifier)
        guard let code = full.languageCode else { return nil }
        let same = supported.filter { locale in
            let language = Locale.Language(identifier: locale.language.maximalIdentifier)
            return language.languageCode == code && language.script == full.script
        }
        if let region = wanted.region, let exact = same.first(where: { $0.region == region }) { return exact }
        return same.first { $0.region == full.region } ?? same.min { $0.identifier < $1.identifier }
    }

    /// The language NLLanguageRecognizer names for text in `locale`'s language: Chinese by its script (it says zh-Hans
    /// or zh-Hant, never zh), Cantonese as Chinese in its script.
    private static func language(of locale: Locale) -> NLLanguage? {
        let full = Locale.Language(identifier: locale.language.maximalIdentifier)
        guard let code = full.languageCode?.identifier else { return nil }
        if code == "zh" || code == "yue" {
            return full.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese
        }
        return NLLanguage(rawValue: code)
    }

    /// The windows one after another in a temporary WAV, `windowLength` each (the last may be shorter): three parts of
    /// a long file (past an intro or a silent start, and more than one part of it), else its first minute.
    private static func excerpt(of url: URL, duration: TimeInterval) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let rate = input.processingFormat.sampleRate
        let windows: [(start: TimeInterval, length: TimeInterval)] = duration > 90
            ? [0.1, 0.45, 0.8].map { (duration * $0, windowLength) }
            : [(0, windowLength * Double(windowCount))]
        let url = FileManager.default.temporaryDirectory.appending(path: "language-probe-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: url, settings: input.fileFormat.settings,
                                     commonFormat: input.processingFormat.commonFormat,
                                     interleaved: input.processingFormat.isInterleaved)
        for window in windows {
            input.framePosition = min(input.length, AVAudioFramePosition(window.start * rate))
            let frames = AVAudioFrameCount(max(0, min(window.length * rate, Double(input.length - input.framePosition))))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames)
            else { continue }
            try input.read(into: buffer, frameCount: frames)
            try output.write(from: buffer)
        }
        guard output.length > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }

    /// The excerpt transcribed in `locale` (installed), window by window (each result goes to the window it starts in).
    private static func transcribe(_ url: URL, in locale: Locale) async throws -> [Window] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.transcriptionConfidence])
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
        let results = Task { () async throws -> [Window] in
            var windows = Array(repeating: Window(), count: windowCount)
            var weighted = Array(repeating: 0.0, count: windowCount)
            for try await result in transcriber.results where result.isFinal {
                let index = min(windowCount - 1, max(0, Int(result.range.start.seconds / windowLength)))
                windows[index].text += String(result.text.characters) + " "
                for run in result.text.runs {
                    guard let confidence = run.transcriptionConfidence else { continue }
                    let count = result.text[run.range].characters.count { !$0.isWhitespace }
                    weighted[index] += confidence * Double(count)
                    windows[index].letters += count
                }
            }
            for index in windows.indices where windows[index].letters > 0 {
                windows[index].confidence = weighted[index] / Double(windows[index].letters)
            }
            return windows
        }
        let file = try AVAudioFile(forReading: url)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await results.value
    }

    /// The language most of `text` is in, and its share.
    private static func dominant(_ text: String) -> (language: NLLanguage, share: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3).max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}
