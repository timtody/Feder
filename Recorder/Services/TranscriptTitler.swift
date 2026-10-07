import Foundation
import NaturalLanguage

/// What writes titles and summaries: Gemma 4 E2B (`LocalLanguageModel`), or on the simulator a stand-in
/// (`FakeTextWriter`, DEBUG). Sendable: the requests are awaited from the main actor.
nonisolated protocol TextWriter: AnyObject, Sendable {
    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String
    func unload() async
}

/// A short title and a short summary of a finished transcript, written on device in the transcript's language by
/// Gemma 4 E2B (`LocalLanguageModel`, downloaded once: BetterSummaries). Without Gemma there are no automatic titles
/// and summaries: Apple's Foundation Models model wrote them until October 2026 and its results were too weak
/// (wordy, meta-style summaries: "Anna Schmidt führt ein Gespräch mit …"; see README › Automatic titles). Runs in the
/// background after speakers are shown (SpeakerIdentifier, after the vocabulary pass). The transcript goes in with each
/// paragraph's speaker name. A request reads at most `LocalLanguageModel.contextTokens`, so a longer transcript is
/// summarized part by part first and the title is written from those summaries (map-reduce).
@MainActor
final class TranscriptTitler {
    /// Recording.summaryVersion of a transcript Apple's model described (before October 2026); kept so those stay
    /// marked, and Gemma (`localVersion`, higher) describes them again once it is there.
    nonisolated static let version = 2
    /// Recording.summaryVersion once Gemma has described a transcript (it answered or failed for good). Not after
    /// RetryLater.
    nonisolated static let localVersion = 100
    /// Tokens of a request that are not transcript: ~270 of instructions, at most 400 answered (measured with
    /// `tokenCount`), plus room for the speaker names' share and the chat template.
    nonisolated static let reservedTokens = 1_300

    /// Transcript characters per request for a model reading `contextSize` tokens: 3.5 characters per token, below the
    /// 3.8-4.5 measured for German and English transcripts (Gemma's 20,000: 65,450).
    nonisolated static func chunkCharacters(contextSize: Int) -> Int {
        max(3_000, (contextSize - reservedTokens) * 7 / 2)
    }

    /// Gemma failed for another reason than being stopped (missing or damaged files): the transcript stays undescribed.
    nonisolated struct LocalModelFailed: Error {
        var underlying: String
    }

    nonisolated struct Description: Sendable, Equatable {
        var title: String?      // nil when the model's title failed the checks: the name stays
        var summary: String
    }

    /// describe() throws this when the model can't answer now but may later (stopped because the app left the
    /// foreground or a recording started): the transcript is not marked described, so it is tried again.
    nonisolated struct RetryLater: Error {}

    /// Title and summary of `paragraphs` (the transcript's segments in order, each "Name: text"), or nil without a
    /// usable model answer. Throws RetryLater when the model can't answer right now (Gemma: stopped because the app
    /// left the foreground); a part summary failing that way stops the whole description, so no title is ever written
    /// from some of the parts only. Throws LocalModelFailed when Gemma can't run.
    /// `partial` gets the summary as the model writes it (the final request only, not the parts of a long transcript),
    /// so the card can show it growing.
    func describe(paragraphs: [String], locale recordingLocale: Locale, writer: any TextWriter,
                  partial: (@Sendable (String) -> Void)? = nil) async throws -> Description? {
        let locale = Self.textLocale(Self.withoutNames(paragraphs)) ?? recordingLocale
        return try await describe(paragraphs, locale: locale, writer: writer,
                                  limit: Self.chunkCharacters(contextSize: LocalLanguageModel.contextTokens), partial: partial)
    }

    private func describe(_ paragraphs: [String], locale: Locale, writer: any TextWriter, limit: Int,
                          partial: (@Sendable (String) -> Void)?) async throws -> Description? {
        let language = Self.languageName(locale)
        var parts = Self.chunks(paragraphs, limit: limit)
        guard !parts.isEmpty else { return nil }
        // Map-reduce: while the text does not fit one request, summarize each part, then work on the summaries.
        var fromSummaries = false
        while parts.count > 1 {
            var summaries: [String] = []
            for part in parts {
                if let summary = try await summarize(part, language: language, fromSummaries: fromSummaries,
                                                     writer: writer) {
                    summaries.append(summary)
                }
            }
            let next = Self.chunks(summaries.enumerated().map { "Part \($0.offset + 1): \($0.element)" },
                                   limit: limit)
            guard !next.isEmpty, next.count < parts.count else { return nil }   // nothing came back, or no progress
            parts = next
            fromSummaries = true
        }
        let prompt = (fromSummaries ? "Summaries of the consecutive parts of one long conversation:\n" : "Transcript:\n")
            + parts[0]
        let instructions = Self.localTitleInstructions(language: language, locale: locale, fromSummaries: fromSummaries)
        // The task again after the transcript: without it Gemma went on with the transcript ("Anna Schmidt: …").
        let request = prompt + "\n\n" + Self.localReminder
        let text = try await Self.local {
            try await writer.respond(instructions: instructions, prompt: request, maxTokens: 400, temperature: 0) { text in
                if let summary = Self.partialSummary(in: text) { partial?(summary) }
            }
        }
        #if DEBUG
        print("[Scribe] title (Gemma): \(text)")
        #endif
        let answer = Self.parseLabelled(text)
        guard let answer else { return nil }
        let summary = Self.plainSentences(answer.summary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = summary.first else { return nil }
        let title = Self.cleanTitle(answer.title)
        #if DEBUG
        if title == nil { print("[Scribe] title rejected: \(answer.title)") }
        #endif
        return Description(title: title, summary: first.uppercased() + summary.dropFirst())
    }

    /// A part's summary as plain text.
    private func summarize(_ text: String, language: String, fromSummaries: Bool, writer: any TextWriter) async throws -> String? {
        let prompt = (fromSummaries ? "Summaries of consecutive parts of one long conversation:\n" : "Part of a transcript:\n")
            + text
        let answer = try await Self.local {
            try await writer.respond(instructions: Self.partInstructions(language: language), prompt: prompt,
                                     maxTokens: 400, temperature: 0, partial: nil)
        }
        let summary = Self.plainSentences(answer)
        #if DEBUG
        print("[Scribe] part summary (Gemma): \(summary)")
        #endif
        return summary.isEmpty ? nil : summary
    }

    /// Runs a Gemma request: stopped (the app left the foreground) = RetryLater, any other failure = LocalModelFailed.
    private static func local<T>(_ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch is CancellationError {
            throw RetryLater()
        } catch {
            #if DEBUG
            print("[Scribe] Gemma: \(error)")
            #endif
            throw LocalModelFailed(underlying: String(describing: error))
        }
    }

    // MARK: Pure helpers

    /// A transcript paragraph as the model reads it: "Name: text" ("Speaker 2" while unnamed), the text alone without
    /// a speaker.
    nonisolated static func paragraph(_ text: String, speaker: String?) -> String {
        guard let speaker else { return text }
        return "\(speaker): \(text)"
    }

    /// The paragraphs without their "Name: " prefixes (language detection should not read names).
    nonisolated static func withoutNames(_ paragraphs: [String]) -> [String] {
        paragraphs.map { $0.replacing(/^[^:\n]{1,40}:\s/, with: "") }
    }

    /// Names the app gives a transcript itself; only these are replaced by an automatic title.
    nonisolated static func isDefaultName(_ name: String) -> Bool {
        name.wholeMatch(of: /(New Transcript|New Recording) \d+|Untitled Transcript/) != nil
    }

    /// Paragraphs joined into chunks of at most `limit` characters (a longer paragraph is cut at word boundaries).
    nonisolated static func chunks(_ paragraphs: [String], limit: Int) -> [String] {
        var pieces: [String] = []
        for paragraph in paragraphs {
            var rest = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            while rest.count > limit {
                let cut = rest.index(rest.startIndex, offsetBy: limit)
                let end = rest[..<cut].lastIndex(of: " ") ?? cut
                pieces.append(String(rest[..<end]))
                rest = String(rest[end...]).trimmingCharacters(in: .whitespaces)
            }
            if !rest.isEmpty { pieces.append(rest) }
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if !current.isEmpty, current.count + 1 + piece.count > limit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : "\n" + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// The model's title made presentable, or nil: quotes, a "Title:" label, a trailing period and generic openings
    /// ("Meeting über …", "Besprechung zum …") are removed; at most 6 words (the prompt asks for 2-6, but a single
    /// German compound such as "Firmenkredit" names a topic well and is kept).
    nonisolated static func cleanTitle(_ raw: String) -> String? {
        let quotes = CharacterSet(charactersIn: "\"'„“”‚‘’«»‹›`*#")
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(quotes))
        title = title.replacing(/^(?i:titel|title)\s*:\s*/, with: "")
        title = title.replacing(/^(?i:(meeting|besprechung|gespräch|diskussion|unterhaltung|telefonat|discussion|conversation|call)\s+(über|zu|zum|zur|zu den|about|on|of|regarding)\s+(the\s+|die\s+|den\s+|das\s+)?)/,
                                with: "")
        title = title.replacing(/^(?i:(zusammenfassung|überblick|summary|overview)\s+(der|des|von|zum|zur|zu|of|on)\s+(the\s+)?)/,
                                with: "")
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(quotes).union(CharacterSet(charactersIn: ".:;,!")))
        guard let first = title.first else { return nil }
        title = first.uppercased() + title.dropFirst()
        let words = title.split(whereSeparator: \.isWhitespace).count
        return (1...6).contains(words) ? title : nil
    }

    /// The "Summary: …" and "Title: …" lines of a plain-text answer.
    /// The summary line of a plain-text answer as far as it is written (Gemma's three lines arrive token by token).
    nonisolated static func partialSummary(in text: String) -> String? {
        guard let match = text.firstMatch(of: /(?i)(?:summary|zusammenfassung)\s*\**:\s*\**([^\n]*)/) else { return nil }
        let summary = String(match.1).replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return summary.isEmpty ? nil : summary
    }

    nonisolated static func parseLabelled(_ text: String) -> TitleAndSummary? {
        var title: String?, summary: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*")))
            if let match = trimmed.firstMatch(of: /^(?i:title|titel)\s*\**:\s*\**(.*)/) { title = String(match.1) }
            if let match = trimmed.firstMatch(of: /^(?i:summary|zusammenfassung)\s*\**:\s*\**(.*)/) { summary = String(match.1) }
        }
        guard let title, let summary else { return nil }
        return TitleAndSummary(topics: [], summary: summary, title: title)
    }

    /// A plain-text answer as one paragraph: Markdown emphasis, headings and list markers removed.
    nonisolated static func plainSentences(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.replacing(/^\s*([#>*-]+|\d+\.)\s*/, with: "").replacingOccurrences(of: "**", with: "") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The language the transcript is actually in, when NaturalLanguage is sure (the recording's locale is the phone's
    /// language, and the simulator's fake transcriber speaks English on a German Mac).
    nonisolated static func textLocale(_ paragraphs: [String]) -> Locale? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(paragraphs.joined(separator: " ").prefix(2_000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.8
        else { return nil }
        return Locale(identifier: language.rawValue)
    }

    nonisolated static func languageName(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// Gemma's instructions for title and summary: explicit (a small model follows examples and prohibitions literally; without them it wrote "Anna fasst die Ergebnisse zusammen" and "Zusammenfassung der …").
    nonisolated static func localTitleInstructions(language: String, locale: Locale, fromSummaries: Bool) -> String {
        let german = locale.language.languageCode?.identifier == "de"
        let example = german ? "Kreditprojekt: Testphase und Abnahme" : "Credit Project: Test Phase and Sign-off"
        let source = fromSummaries
            ? "You get summaries of the consecutive parts of one long conversation; cover the whole conversation."
            : "The transcript comes from speech recognition and may contain misheard words. Each line starts with the " +
              "speaker's name and a colon (\"Speaker 2\" while the name is unknown)."
        return """
        You write a summary and a title of a recorded conversation for the person who recorded it, in \(language).
        Answer with exactly three lines and nothing else:
        Topics: every topic of the conversation, separated by semicolons
        Summary: two or three short sentences (each under 30 words) covering every topic
        Title: 2 to 6 words

        Summary: the concrete content of every topic: its results and decisions, dates, numbers and names, and who \
        takes on which task. Third person, active voice. Write the facts themselves; never describe the conversation \
        ("fasst zusammen", "es wird besprochen", "im Gespräch geht es um", "discussed", "the meeting covered"). Name \
        people by their names. A speaker without a name ("Speaker 3") is "\(german ? "ein Teilnehmer" : "a participant")"; \
        never write "Speaker" with a number.
        Title: the specific subject like a document heading, for example "\(example)". Never begin with \
        "Zusammenfassung", "Überblick", "Meeting", "Besprechung", "Gespräch", "Summary" or "Discussion".
        Use only what the text says: never invent names, numbers, dates or decisions. \(source)
        """
    }

    nonisolated static let localReminder = "End of the text. Now answer with exactly three lines, \"Topics: …\", " +
        "\"Summary: …\" and \"Title: …\", following the instructions."

    nonisolated static func partInstructions(language: String) -> String {
        """
        You summarize one part of a long recorded conversation in \(language), in at most three sentences of plain \
        text (one paragraph, no Markdown, no lists). Name every topic of this part, each with its key facts and \
        decisions, in the order they come up, and who said or decided what where the text names people (never \
        "Speaker 1" or similar). Use only what the text says: never invent names, numbers, places, dates or details. \
        The transcript comes from speech recognition and may contain misheard words. Each line starts with the \
        speaker's name and a colon.
        """
    }
}

/// A parsed answer: the topics are asked for first, so the summary of a long conversation covers more than its
/// first part.
nonisolated struct TitleAndSummary {
    var topics: [String]
    var summary: String
    var title: String
}
