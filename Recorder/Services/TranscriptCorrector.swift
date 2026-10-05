import Foundation
import NaturalLanguage

/// Smart Corrections (Settings, experimental, off by default). After the vocabulary pass, Gemma 4 E2B
/// (`LocalLanguageModel`, the Better Summaries model) reads the transcript as "Name: text" lines, about a dozen speaker
/// turns at a time, and writes them back corrected: grammar, spelling, punctuation and obviously misheard words, nothing
/// else (`instructions`). Who said what stays with the diarization, which hears the voices; the model reads text only,
/// and in conversations a sentence that runs on across a change of speaker is common (finishing the other's sentence,
/// an interjection), so it isn't evidence of a wrong speaker. Chunks of 10–15 turns,
/// because longer inputs make a small model skip lines or start summarizing; a low temperature, so it copies instead of
/// paraphrasing. The vocabulary goes along as a glossary (`instructions(glossary:)`), so a term the vocabulary pass
/// could not place can still be spelled right. `CorrectionMerge` aligns every answer with the words, which keep their times, and rejects an answer
/// that changes more than a correction would, so a chunk is either corrected or left as it was. German transcripts
/// only (the instructions are German). Runs in SpeakerIdentifier's background pass through `BetterSummaries.run`
/// (foreground only, never while recording), chunk after chunk; each chunk is handed back as it is answered, so an
/// interrupted pass keeps what it has and goes on from there (`Recording.correctedUntil`).
///
/// The first version (until October 2026) asked Apple's Foundation Models model about single suspicious words (low
/// recognition confidence, misspelled) with sound-alike vocabulary terms as hints, under code-side checks; on 80 real
/// German clips it did not lower the word error rate (11.0 → 11.2 %) and pushed vocabulary terms into ordinary
/// sentences ("Es" → "ESG"). Its measurements are in the README.
@MainActor
final class TranscriptCorrector {
    static let settingKey = "smartCorrections"           // Bool, absent means OFF (Settings screen, experimental)
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? false }

    /// Speaker turns per request, at most; the turns are evened out over the requests, so 16 turns go as 8 + 8.
    nonisolated static let maxTurnsPerRequest = 15
    /// Characters per request, at most (long monologue paragraphs): about 1,700 tokens, and the answer is as long again.
    nonisolated static let maxCharactersPerRequest = 6_000
    /// Sampling temperature: low, so the model copies the text instead of paraphrasing it (0.2–0.3, not greedy).
    nonisolated static let temperature: Float = 0.25

    nonisolated static let instructions = """
    Du korrigierst automatisch erstellte Transkripte auf Deutsch.

    Regeln:
    1. Korrigiere nur Grammatik, Rechtschreibung, Zeichensetzung und offensichtlich falsch verstandene Wörter.
    2. Ändere NICHT den Inhalt, den Stil oder die Wortwahl der Sprecher.
    3. Jede Zeile bleibt bei ihrem Sprecher. Verschiebe keine Wörter in eine andere Zeile, auch wenn ein Satz über \
    einen Sprecherwechsel weiterläuft.
    4. Unverständliche Stellen markierst du mit [unklar]. Erfinde nichts.
    5. Behalte das Format „Name: Text“ bei, eine Zeile für jede Zeile der Eingabe.
    6. Gib NUR das korrigierte Transkript aus, ohne Kommentar.

    Beispiel:
    Eingabe:
    Anna: das geht dir an Kragen ich will
    Ben: nur sagen das stimmt
    Ausgabe:
    Anna: Das geht dir an den Kragen. Ich will
    Ben: nur sagen: Das stimmt.
    """

    /// The instructions with the vocabulary (Settings: your words, plus the built-in consulting and banking terms) as
    /// a glossary after them, so a misheard term can be written as it is spelled there; nothing without a vocabulary.
    nonisolated static func instructions(glossary: [String]) -> String {
        guard !glossary.isEmpty else { return instructions }
        return instructions + """


        Glossar (Namen und Fachbegriffe, die in diesen Gesprächen häufig vorkommen; so schreiben, wenn sie offensichtlich \
        gemeint sind, aber nicht einsetzen, wo ein anderes Wort passt):
        \(glossary.joined(separator: ", "))
        """
    }

    /// Whether the corrections apply to a transcript: German, by its text when NaturalLanguage is sure, else by the
    /// recording's locale.
    nonisolated static func isGerman(_ texts: [String], recordingLocale: Locale) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(texts.joined(separator: " ").prefix(2_000)))
        if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.8 {
            return language == .german
        }
        return recordingLocale.language.languageCode?.identifier == "de"
    }

    /// The next chunk of `paragraphs` from `start`: the turns left evened out over the requests still to come (at most
    /// `maxTurnsPerRequest` each), and at most `maxCharactersPerRequest` characters (a longer paragraph goes alone).
    nonisolated static func chunk(of paragraphs: [CorrectionMerge.Paragraph], from start: Int) -> Range<Int> {
        let remaining = paragraphs.count - start
        guard remaining > 0 else { return start..<start }
        let requests = (remaining + maxTurnsPerRequest - 1) / maxTurnsPerRequest
        let turns = (remaining + requests - 1) / requests
        var end = start, characters = 0
        while end < paragraphs.count, end - start < turns {
            let length = paragraphs[end].text.count
            if end > start, characters + length > maxCharactersPerRequest { break }
            characters += length
            end += 1
        }
        return start..<end
    }

    /// Corrects `paragraphs` from index `start` on, chunk by chunk, with `model`. After every chunk `apply` gets the
    /// whole list as corrected so far, how far (transcript seconds) the pass has come, and whether this chunk changed
    /// anything (false: the answer was rejected, the chunk stays); it returns whether to go on (false once the
    /// transcript changed under the pass). `name` names a speaker for the lines. Throws CancellationError when stopped
    /// (the app resigned active, a recording started).
    func correct(_ paragraphs: [CorrectionMerge.Paragraph], from start: Int, name: (Int?) -> String,
                 glossary: [String], model: LocalLanguageModel,
                 apply: ([CorrectionMerge.Paragraph], TimeInterval, Bool) -> Bool) async throws {
        var paragraphs = paragraphs
        var cursor = start
        let instructions = Self.instructions(glossary: glossary)
        while cursor < paragraphs.count {
            let range = Self.chunk(of: paragraphs, from: cursor)
            let names = range.map { name(paragraphs[$0].speakerIndex) }
            let prompt = zip(range, names).map { "\($1): \(paragraphs[$0].text)" }.joined(separator: "\n")
            let maxTokens = min(3_000, prompt.count / 2 + 150)       // the answer is about as long as the request
            #if DEBUG
            let started = ContinuousClock.now
            #endif
            let answer = try await model.respond(instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                                                 temperature: Self.temperature)
            try Task.checkCancellation()
            var corrected: [CorrectionMerge.Paragraph]?
            if let texts = CorrectionMerge.lines(in: answer, names: names) {
                corrected = await CorrectionMerge.apply(texts, to: Array(paragraphs[range]))
            }
            let changed: Bool
            if let corrected, !corrected.isEmpty, corrected.map(\.words) != paragraphs[range].map(\.words) {
                paragraphs.replaceSubrange(range, with: corrected)
                cursor = range.lowerBound + corrected.count
                changed = true
            } else {
                cursor = range.upperBound
                changed = false
            }
            #if DEBUG
            let took = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds], width: .narrow))
            let outcome = corrected == nil ? "rejected" : (changed ? "applied" : "unchanged")
            print("[Scribe] corrections: \(range.count) turns, \(prompt.count) chars: \(outcome) in \(took)")
            if corrected == nil { print("[Scribe] corrections: rejected answer:\n\(answer)") }
            #endif
            guard apply(paragraphs, paragraphs[cursor - 1].end, changed) else { return }
        }
    }
}
