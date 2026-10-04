import Foundation
import FoundationModels
import NaturalLanguage

/// A short title and a short summary of a finished transcript, written on device in the transcript's language, by
/// Apple's language model (Foundation Models, Apple Intelligence) or, once downloaded in Settings ("Better
/// Summaries"), by Gemma 4 E2B (`LocalLanguageModel`). Runs in the background after speakers are shown
/// (SpeakerIdentifier, after the vocabulary pass). The transcript goes in with each paragraph's speaker name. A model
/// reads only so much at once (Apple's: 4,096 tokens on iOS 26, 8,192 on iOS 27, for instructions, prompt and answer
/// together; Gemma: `LocalLanguageModel.contextTokens`), so a longer transcript is summarized part by part first and
/// the title is written from those summaries (map-reduce); a request that still overflows is tried again with smaller
/// parts. No model (older iPhone, Apple Intelligence off, unsupported language) = nil, silently.
@MainActor
final class TranscriptTitler {
    /// Recording.summaryVersion once a transcript has been described by Apple's model (it answered, refused or failed
    /// for good). Not after RetryLater. 2: speaker names in the text, parts sized by the model's window.
    nonisolated static let version = 2
    /// The same for Gemma ("Better Summaries"): higher, so turning it on describes every transcript again, and turning it
    /// off keeps its descriptions.
    nonisolated static let localVersion = 100
    /// Tokens of a request that are not transcript: ~270 of instructions, ~155 of output schema, at most 400 answered
    /// (measured with `tokenCount`, macOS 27), plus room for the speaker names' share and the chat template.
    nonisolated static let reservedTokens = 1_300

    /// Transcript characters per request for a model reading `contextSize` tokens: 3.5 characters per token, below the
    /// 3.8-4.5 measured for German and English transcripts (4,096: 9,786; 8,192: 24,122; Gemma's 20,000: 65,450).
    nonisolated static func chunkCharacters(contextSize: Int) -> Int {
        max(3_000, (contextSize - reservedTokens) * 7 / 2)
    }

    /// The model that writes: Apple's, or the downloaded Gemma.
    enum Writer {
        case apple
        case local(LocalLanguageModel)

        var chunkCharacters: Int {
            switch self {
            case .apple: TranscriptTitler.chunkCharacters(contextSize: SystemLanguageModel.default.contextSize)
            case .local: TranscriptTitler.chunkCharacters(contextSize: LocalLanguageModel.contextTokens)
            }
        }
    }

    /// A request did not fit the model's window: tried again with smaller parts.
    private struct ContextExceeded: Error {}
    /// Gemma failed for another reason than being stopped (missing or damaged files): SpeakerIdentifier uses Apple's
    /// model for this transcript instead.
    nonisolated struct LocalModelFailed: Error {
        var underlying: String
    }
    /// Greedy: the same transcript gets the same title. The token cap stops a rare greedy repetition loop (once 360 s,
    /// until the context window was full).
    nonisolated static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 400)

    nonisolated struct Description: Sendable, Equatable {
        var title: String?      // nil when the model's title failed the checks: the name stays
        var summary: String
    }

    /// describe() throws this when the model can't answer now but may later (`isTransient`: rate limited while the app
    /// runs in the background, model assets updating, time-out): the transcript is not marked described, so the next
    /// launch or return to the foreground tries again. Refusals and other failures are final (nil).
    nonisolated struct RetryLater: Error {}

    var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    func canDescribe(_ locale: Locale) -> Bool { isAvailable && SystemLanguageModel.default.supportsLocale(locale) }

    /// Title and summary of `paragraphs` (the transcript's segments in order, each "Name: text"), or nil without a
    /// usable model answer. Throws RetryLater when the model can't answer right now (Gemma: stopped because the app
    /// left the foreground); a part summary failing that way stops the whole description, so no title is ever written
    /// from some of the parts only. Throws LocalModelFailed when Gemma can't run.
    /// `partial` gets the summary as the model writes it (the final request only, not the parts of a long transcript),
    /// so the card can show it growing.
    func describe(paragraphs: [String], locale recordingLocale: Locale, writer: Writer = .apple,
                  partial: (@Sendable (String) -> Void)? = nil) async throws -> Description? {
        let locale = Self.textLocale(Self.withoutNames(paragraphs)) ?? recordingLocale
        if case .apple = writer, !canDescribe(locale) { return nil }
        var limit = writer.chunkCharacters
        for _ in 0..<3 {
            do {
                return try await describe(paragraphs, locale: locale, writer: writer, limit: limit, partial: partial)
            } catch is ContextExceeded {
                #if DEBUG
                print("[Scribe] title: context exceeded at \(limit) characters per part, smaller parts")
                #endif
                partial?("")                                    // what was streamed is abandoned
                limit = limit * 6 / 10
            }
        }
        return nil
    }

    private func describe(_ paragraphs: [String], locale: Locale, writer: Writer, limit: Int,
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
        let answer: TitleAndSummary?
        switch writer {
        case .apple:
            answer = try await generate(prompt: prompt,
                                        instructions: Self.titleInstructions(language: language, locale: locale,
                                                                             fromSummaries: fromSummaries),
                                        partial: partial)
        case .local(let model):
            let instructions = Self.localTitleInstructions(language: language, locale: locale, fromSummaries: fromSummaries)
            // The task again after the transcript: without it Gemma went on with the transcript ("Anna Schmidt: …").
            let request = prompt + "\n\n" + Self.localReminder
            let text = try await Self.local {
                try await model.respond(instructions: instructions, prompt: request) { text in
                    if let summary = Self.partialSummary(in: text) { partial?(summary) }
                }
            }
            #if DEBUG
            print("[Scribe] title (Gemma): \(text)")
            #endif
            answer = Self.parseLabelled(text)
        }
        guard let answer else { return nil }
        let summary = Self.plainSentences(answer.summary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = summary.first else { return nil }
        let title = Self.cleanTitle(answer.title)
        #if DEBUG
        if title == nil { print("[Scribe] title rejected: \(answer.title)") }
        #endif
        return Description(title: title, summary: first.uppercased() + summary.dropFirst())
    }

    /// A part's summary as plain text (structured output returned "{" for some parts), under the guardrails for
    /// transforming the user's own text.
    private func summarize(_ text: String, language: String, fromSummaries: Bool, writer: Writer) async throws -> String? {
        let prompt = (fromSummaries ? "Summaries of consecutive parts of one long conversation:\n" : "Part of a transcript:\n")
            + text
        if case .local(let local) = writer {
            let answer = try await Self.local {
                try await local.respond(instructions: Self.partInstructions(language: language), prompt: prompt)
            }
            let summary = Self.plainSentences(answer)
            #if DEBUG
            print("[Scribe] part summary (Gemma): \(summary)")
            #endif
            return summary.isEmpty ? nil : summary
        }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: Self.partInstructions(language: language))
        do {
            let summary = Self.plainSentences(try await session.respond(to: prompt, options: Self.options).content)
            #if DEBUG
            print("[Scribe] part summary: \(summary)")
            #endif
            return summary.isEmpty ? nil : summary
        } catch {
            #if DEBUG
            print("[Scribe] part summary: \(error)")
            #endif
            if Self.isTransient(error) { throw RetryLater() }
            if Self.isContextExceeded(error) { throw ContextExceeded() }
            return nil
        }
    }

    /// Structured output first. The default guardrails, and the model itself, now and then refuse harmless
    /// conversations (`.refusal` for "ich möchte gerne Geld auf mein Konto einzahlen" with these instructions); then
    /// once more with the guardrails for transforming the user's own text, which only apply to plain-text answers
    /// (`plain` reads the answer).
    private func generate(prompt: String, instructions: String,
                          partial: (@Sendable (String) -> Void)?) async throws -> TitleAndSummary? {
        do {
            let session = LanguageModelSession(instructions: instructions)
            guard let partial else {
                return try await session.respond(to: prompt, generating: TitleAndSummary.self, options: Self.options).content
            }
            // Streamed: every snapshot carries the summary as far as it is written (the topics come first, so the
            // summary starts a moment after the model does).
            let stream = session.streamResponse(to: prompt, generating: TitleAndSummary.self, options: Self.options)
            for try await snapshot in stream {
                if let summary = snapshot.content.summary, !summary.isEmpty { partial(summary) }
            }
            return try await stream.collect().content
        } catch let error where Self.isRefusal(error) {
            #if DEBUG
            print("[Scribe] title: refused, plain text instead")
            #endif
            partial?("")                                        // the refused attempt's text goes
            let permissive = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: permissive, instructions: instructions + "\n" + Self.plainFormat)
            do {
                return Self.parseLabelled(try await session.respond(to: prompt, options: Self.options).content)
            } catch {
                #if DEBUG
                print("[Scribe] title, plain text: \(error)")
                #endif
                if Self.isTransient(error) { throw RetryLater() }
                if Self.isContextExceeded(error) { throw ContextExceeded() }
                return nil
            }
        } catch {
            #if DEBUG
            print("[Scribe] title: \(error)")
            #endif
            if Self.isTransient(error) { throw RetryLater() }
            if Self.isContextExceeded(error) { throw ContextExceeded() }
            return nil
        }
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

    /// The request did not fit the model's window (iOS 26: GenerationError, iOS 27: LanguageModelError).
    nonisolated static func isContextExceeded(_ error: any Error) -> Bool {
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
            if case .contextSizeExceeded = error { return true }
            return false
        }
        guard let error = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = error { return true }
        return false
    }

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

    /// A refusal or guardrail violation: asked once more as plain text. iOS 26 throws LanguageModelSession
    /// .GenerationError; iOS 27 throws LanguageModelError instead (GenerationError is deprecated there and not thrown).
    nonisolated static func isRefusal(_ error: any Error) -> Bool {
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return true
            default: return false
            }
        }
        guard let error = error as? LanguageModelSession.GenerationError else { return false }
        switch error {
        case .guardrailViolation, .refusal: return true
        default: return false
        }
    }

    /// The model can't answer now but may later: rate limited (Apple: only while the app runs in the background), busy,
    /// model assets missing or updating, timed out, or cancelled. Everything else (refusals, context window, unsupported
    /// language, unreadable answers, unknown errors) would fail the same way again.
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if #available(iOS 27.0, macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .rateLimited, .timeout: return true
                default: return false
                }
            }
            if error is SystemLanguageModel.Error { return true }                  // its only case: assetsUnavailable
            if let error = error as? LanguageModelSession.Error, error == .concurrentRequests { return true }
        }
        guard let error = error as? LanguageModelSession.GenerationError else { return false }
        switch error {
        case .rateLimited, .concurrentRequests, .assetsUnavailable: return true
        default: return false
        }
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

    nonisolated static let plainFormat = "Answer in plain text without Markdown. For a title, answer with exactly two " +
        "lines: \"Summary: …\" and then \"Title: …\"."

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

    nonisolated static func titleInstructions(language: String, locale: Locale, fromSummaries: Bool) -> String {
        let example = locale.language.languageCode?.identifier == "de" ? "Testphase Kreditprojekt und Abnahme"
                                                                       : "Credit Project Test Phase and Sign-off"
        let source = fromSummaries
            ? "You get summaries of the consecutive parts of one long conversation. The summary names the main topics " +
              "of the whole conversation, not only those of the first or the last part."
            : "The transcript comes from speech recognition and may contain misheard words; ignore words that make no " +
              "sense. Each line starts with the speaker's name and a colon (\"Speaker 2\" while the name is unknown)."
        return """
        You write the title and a short summary of a recorded conversation. Write both in \(language).
        Summary: one or two complete, short sentences that state what was said, asked or decided, in the third person \
        (never "ich", "wir", "I" or "we"). Name people by their names where the text gives them, but never write \
        "Speaker 1" or similar. Prefer the active voice. State the content directly; do not begin with phrases like \
        "In dem Gespräch" or "Die Diskussion".
        Title: 2 to 6 words (at least two) that name the specific main topic, like a document heading, for example \
        "\(example)". A natural phrase, not a list of keywords. No quotation marks, no final period, and do not begin \
        with generic words like "Meeting über", "Besprechung", "Gespräch über" or "Discussion of".
        Use only what the text says: never invent names, numbers, places, dates, decisions or details. \(source)
        """
    }

    /// Gemma's instructions for title and summary: more explicit than Apple's (a small model follows examples and
    /// prohibitions literally; without them it wrote "Anna fasst die Ergebnisse zusammen" and "Zusammenfassung der …").
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

@Generable
nonisolated struct TitleAndSummary {
    // Generated first: listing the topics makes the summary of a long conversation cover more than its first part.
    @Guide(description: "The main topics of the whole conversation, in order", .maximumCount(5))
    var topics: [String]
    @Guide(description: "One or two complete, short sentences: the main topics and what was said, asked or decided")
    var summary: String
    @Guide(description: "2 to 6 words: a natural heading for the most important topic (at most two topics), not a list")
    var title: String
}
