import Foundation

/// What writes titles and summaries: Gemma 4 E2B (`LocalLanguageModel`), or on the simulator a stand-in
/// (`FakeTextWriter`, DEBUG). Sendable: the requests are awaited from the main actor.
nonisolated protocol TextWriter: AnyObject, Sendable {
    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String
    func unload() async
}

/// A short title and a short summary of a finished transcript, written on device in the app's language by
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
    /// 101 (October 2026): summaries are written in the app's language, with German instructions on a German iPhone
    /// (before: in the transcript's detected language, with English instructions, and German users got English
    /// summaries); the sweep writes the older ones again.
    nonisolated static let localVersion = 101
    /// Tokens of a request that are not transcript: ~270 of instructions, at most 400 answered (measured with
    /// `tokenCount`), plus room for the speaker names' share and the chat template.
    nonisolated static let reservedTokens = 1_300
    /// The same for a styled summary (FED-15): longer instructions (~450 tokens) and an answer of at most 700.
    nonisolated static let styledReservedTokens = 1_750

    /// Transcript characters per request for a model reading `contextSize` tokens: 3.5 characters per token, below the
    /// 3.8-4.5 measured for German and English transcripts (Gemma's 20,000: 65,450).
    nonisolated static func chunkCharacters(contextSize: Int, reserved: Int = reservedTokens) -> Int {
        max(3_000, (contextSize - reserved) * 7 / 2)
    }

    /// Gemma failed for another reason than being stopped (missing or damaged files): the transcript stays undescribed.
    nonisolated struct LocalModelFailed: Error {
        var underlying: String
    }

    nonisolated struct Description: Sendable, Equatable {
        var title: String?      // nil when the model's title failed the checks: the name stays
        var summary: String
        var topics: [String] = []   // the "Topics:" line's items (person pages); empty when the answer had none
        var style: SummaryStyle = .brief   // how `summary` is written: Brief's is one paragraph, the others lines
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
    /// `bookmarked`: some paragraphs carry `bookmarkMarker` (moments marked while recording): the instructions then
    /// say that the summary must cover them. Without bookmarks the request is exactly the benched one.
    /// `style` (FED-15): Brief is the benched request, unchanged; the others ask for the summary as lines between the
    /// Topics and Title lines (`styledInstructions`) and are parsed into the stored lines (`parseStyled`).
    func describe(paragraphs: [String], locale recordingLocale: Locale, writer: any TextWriter, bookmarked: Bool = false,
                  style: SummaryStyle = .brief, partial: (@Sendable (String) -> Void)? = nil) async throws -> Description? {
        // The app's language, not the transcript's: the summary is read in the app, next to its German or English
        // labels (an English recording on a German iPhone gets a German summary).
        let locale = Self.appLocale
        let reserved = style == .brief ? Self.reservedTokens : Self.styledReservedTokens
        return try await describe(paragraphs, locale: locale, writer: writer, bookmarked: bookmarked, style: style,
                                  limit: Self.chunkCharacters(contextSize: LocalLanguageModel.contextTokens,
                                                              reserved: reserved),
                                  partial: partial)
    }

    /// Internal, not private: the Mac summary bench (build/qa/summarybench) chooses the language with `locale`.
    func describe(_ paragraphs: [String], locale: Locale, writer: any TextWriter, bookmarked: Bool,
                  style: SummaryStyle, limit: Int,
                  partial: (@Sendable (String) -> Void)?) async throws -> Description? {
        let german = Self.isGerman(locale)
        let bookmarkNote = bookmarked ? "\n" + Self.bookmarkNote(german: german) : ""
        let language = Self.languageName(locale)
        let styled = style != .brief
        var parts = Self.chunks(paragraphs, limit: limit)
        guard !parts.isEmpty else { return nil }
        // Map-reduce: while the text does not fit one request, summarize each part, then work on the summaries.
        var fromSummaries = false
        while parts.count > 1 {
            var summaries: [String] = []
            for part in parts {
                if let summary = try await summarize(part, language: language, german: german, style: style,
                                                     fromSummaries: fromSummaries,
                                                     note: fromSummaries ? "" : bookmarkNote, writer: writer) {
                    summaries.append(summary)
                }
            }
            let next = Self.chunks(summaries.enumerated().map { "\(german ? "Teil" : "Part") \($0.offset + 1): \($0.element)" },
                                   limit: limit)
            guard !next.isEmpty, next.count < parts.count else { return nil }   // nothing came back, or no progress
            parts = next
            fromSummaries = true
        }
        let heading = german
            ? (fromSummaries ? "Zusammenfassungen der aufeinanderfolgenden Teile eines langen Gesprächs:\n" : "Transkript:\n")
            : (fromSummaries ? "Summaries of the consecutive parts of one long conversation:\n" : "Transcript:\n")
        let prompt = heading + parts[0]
        // The bookmarks' note only where the marked lines are read: the parts' summaries carry no markers.
        let instructions = (styled
                ? Self.styledInstructions(style, language: language, german: german, fromSummaries: fromSummaries)
                : german ? Self.germanTitleInstructions(fromSummaries: fromSummaries)
                         : Self.localTitleInstructions(language: language, locale: locale, fromSummaries: fromSummaries))
            + (fromSummaries ? "" : bookmarkNote)
        // The task again after the transcript: without it Gemma went on with the transcript ("Anna Schmidt: …").
        let reminder = styled ? Self.styledReminder(german: german) : german ? Self.germanReminder : Self.localReminder
        let request = prompt + "\n\n" + reminder
        // A styled answer is several lines long: 700 tokens (Brief's three lines stay within 400).
        let text = try await Self.local {
            try await writer.respond(instructions: instructions, prompt: request, maxTokens: styled ? 700 : 400,
                                     temperature: 0) { text in
                if !styled, let summary = Self.partialSummary(in: text) { partial?(summary) }
            }
        }
        #if DEBUG
        print("[Scribe] title (Gemma, \(style.rawValue)): \(text)")
        #endif
        if styled {
            guard let answer = Self.parseStyled(text, style: style, german: german) else { return nil }
            return Description(title: Self.cleanTitle(answer.title), summary: answer.summary, topics: answer.topics,
                               style: style)
        }
        let answer = Self.parseLabelled(text)
        guard let answer else { return nil }
        let summary = Self.plainSentences(answer.summary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = summary.first else { return nil }
        let title = Self.cleanTitle(answer.title)
        #if DEBUG
        if title == nil { print("[Scribe] title rejected: \(answer.title)") }
        #endif
        return Description(title: title, summary: first.uppercased() + summary.dropFirst(), topics: answer.topics)
    }

    /// A part's summary as plain text.
    private func summarize(_ text: String, language: String, german: Bool, style: SummaryStyle, fromSummaries: Bool,
                           note: String, writer: any TextWriter) async throws -> String? {
        let heading = german
            ? (fromSummaries ? "Zusammenfassungen aufeinanderfolgender Teile eines langen Gesprächs:\n" : "Teil eines Transkripts:\n")
            : (fromSummaries ? "Summaries of consecutive parts of one long conversation:\n" : "Part of a transcript:\n")
        let prompt = heading + text
        let instructions = (style != .brief ? Self.styledPartInstructions(style, language: language, german: german)
                            : german ? Self.germanPartInstructions : Self.partInstructions(language: language)) + note
        let answer = try await Self.local {
            try await writer.respond(instructions: instructions, prompt: prompt,
                                     maxTokens: 400, temperature: 0, partial: nil)
        }
        let summary = Self.plainSentences(answer)
        #if DEBUG
        print("[Scribe] part summary (Gemma): \(summary)")
        #endif
        return summary.isEmpty ? nil : summary
    }

    /// Runs a Gemma request: stopped (the app left the foreground) = RetryLater, any other failure = LocalModelFailed.
    /// (Also ActionItemExtractor's.)
    static func local<T>(_ request: () async throws -> T) async throws -> T {
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
    nonisolated static func paragraph(_ text: String, speaker: String?, bookmarked: Bool = false) -> String {
        let line = speaker.map { "\($0): \(text)" } ?? text
        return bookmarked ? bookmarkMarker + " " + line : line
    }

    /// What starts a paragraph with a bookmark (moments marked while recording, Bookmarks), in the instructions'
    /// language: a word in brackets the small model reads as a label, not as speech.
    nonisolated static var bookmarkMarker: String { isGerman(appLocale) ? "[Lesezeichen]" : "[Bookmarked]" }

    /// The instructions' sentence for a transcript with bookmarks: cover the marked lines, never write the marker. Not
    /// benched yet on real meetings (FED-69); without bookmarks nothing changes.
    nonisolated static func bookmarkNote(german: Bool) -> String {
        german
            ? "Zeilen, die mit \(bookmarkMarker) beginnen, hat die aufnehmende Person als wichtig markiert: Die " +
              "Zusammenfassung muss ihren Inhalt enthalten. Schreib nie \(bookmarkMarker)."
            : "Lines that begin with \(bookmarkMarker) were marked as important by the person who recorded: the summary " +
              "must cover what they say. Never write \(bookmarkMarker)."
    }

    /// Names the app gives a transcript itself; only these are replaced by an automatic title. The name is stored in the
    /// language the app ran in when it was made, so the English and the German forms both count.
    nonisolated static func isDefaultName(_ name: String) -> Bool {
        name.wholeMatch(of: /(New Transcript|New Recording|Neues Transkript|Neue Aufnahme) \d+|Untitled Transcript|Unbenanntes Transkript/) != nil
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
        var title: String?, summary: String?, topics: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*")))
            if let match = trimmed.firstMatch(of: /^(?i:title|titel)\s*\**:\s*\**(.*)/) { title = String(match.1) }
            if let match = trimmed.firstMatch(of: /^(?i:summary|zusammenfassung)\s*\**:\s*\**(.*)/) { summary = String(match.1) }
            if let match = trimmed.firstMatch(of: /^(?i:topics|themen)\s*\**:\s*\**(.*)/) { topics = topicList(String(match.1)) }
        }
        guard let title, let summary else { return nil }
        return TitleAndSummary(topics: topics, summary: summary, title: title)
    }

    /// The Topics line's items (kept for person pages): split at semicolons, Markdown and end punctuation removed, at
    /// most 12 of at most 60 characters (a longer item is a sentence, not a topic).
    nonisolated static func topicList(_ line: String) -> [String] {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,*_\"„“”"))
        return Array(line.split(separator: ";")
            .map { $0.trimmingCharacters(in: trim) }
            .filter { !$0.isEmpty && $0.count <= 60 }
            .prefix(12))
    }

    /// A plain-text answer as one paragraph: Markdown emphasis, headings and list markers removed.
    nonisolated static func plainSentences(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.replacing(/^\s*([#>*-]+|\d+\.)\s*/, with: "").replacingOccurrences(of: "**", with: "") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The app's language for the summaries: German when the app runs in German (the iPhone's language), English
    /// otherwise.
    nonisolated static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first == "de" ? "de" : "en")
    }

    nonisolated static func isGerman(_ locale: Locale) -> Bool { locale.language.languageCode?.identifier == "de" }

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

    /// The same instructions in German, for a German iPhone: with English instructions and "in German" the small model
    /// still answered in English when the transcript was English or mixed, and English instructions pull it towards
    /// English phrasing even for German transcripts. The labels stay parseable ("Titel", "Zusammenfassung").
    nonisolated static func germanTitleInstructions(fromSummaries: Bool) -> String {
        let source = fromSummaries
            ? "Du bekommst Zusammenfassungen der aufeinanderfolgenden Teile eines langen Gesprächs; fasse das ganze " +
              "Gespräch zusammen."
            : "Das Transkript stammt aus einer Spracherkennung und kann falsch verstandene Wörter enthalten. Jede Zeile " +
              "beginnt mit dem Namen der sprechenden Person und einem Doppelpunkt („Sprecher 2“, solange der Name " +
              "unbekannt ist)."
        return """
        Du schreibst eine Zusammenfassung und einen Titel eines aufgenommenen Gesprächs für die Person, die es \
        aufgenommen hat, auf Deutsch, auch wenn das Gespräch in einer anderen Sprache geführt wurde.
        Antworte mit genau drei Zeilen und sonst nichts:
        Themen: alle Themen des Gesprächs, durch Semikolons getrennt
        Zusammenfassung: zwei oder drei kurze Sätze (jeweils unter 30 Wörtern), die alle Themen abdecken
        Titel: 2 bis 6 Wörter

        Zusammenfassung: der konkrete Inhalt jedes Themas: Ergebnisse und Entscheidungen, Termine, Zahlen und Namen, \
        und wer welche Aufgabe übernimmt. Dritte Person, Aktiv. Schreib die Fakten selbst; beschreib nie das Gespräch \
        („fasst zusammen“, „es wird besprochen“, „im Gespräch geht es um“). Nenn Personen beim Namen. Eine Person \
        ohne Namen („Sprecher 3“) ist „ein Teilnehmer“; schreib nie „Sprecher“ mit einer Nummer.
        Titel: das konkrete Thema wie eine Dokumentüberschrift, zum Beispiel „Kreditprojekt: Testphase und Abnahme“. \
        Beginne nie mit „Zusammenfassung“, „Überblick“, „Meeting“, „Besprechung“ oder „Gespräch“.
        Verwende nur, was im Text steht: erfinde nie Namen, Zahlen, Termine oder Entscheidungen. \(source)
        """
    }

    nonisolated static let germanReminder = "Ende des Textes. Antworte jetzt mit genau drei Zeilen, „Themen: …“, " +
        "„Zusammenfassung: …“ und „Titel: …“, auf Deutsch und nach den Anweisungen."

    nonisolated static let germanPartInstructions = """
        Du fasst einen Teil eines langen aufgenommenen Gesprächs auf Deutsch zusammen, in höchstens drei Sätzen \
        Fließtext (ein Absatz, kein Markdown, keine Listen). Nenn jedes Thema dieses Teils mit seinen wichtigsten \
        Fakten und Entscheidungen, in der Reihenfolge, in der sie vorkommen, und wer was gesagt oder entschieden hat, \
        wo der Text Personen nennt (nie „Sprecher 1“ oder ähnlich). Verwende nur, was im Text steht: erfinde nie \
        Namen, Zahlen, Orte, Termine oder Details. Das Transkript stammt aus einer Spracherkennung und kann falsch \
        verstandene Wörter enthalten. Jede Zeile beginnt mit dem Namen der sprechenden Person und einem Doppelpunkt.
        """

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

// MARK: - Summary styles (FED-15)

/// The styled summaries' requests and their parsing. Brief keeps the benched request above untouched; the other styles
/// ask for the summary as lines between the Topics and the Title line (topics first and title last, as benched: listing
/// the topics first makes a long meeting's summary cover more than its first part). No content examples in any style:
/// a small model copies them into its answer (ActionItemExtractor has none either). The stored summary is the parsed
/// lines joined with "\n": headings ("Decisions"), "• " bullets, and "Q: "/"F: " and "A: " lines; a Brief summary is
/// one paragraph (`plainSentences`), so `Recording.summaryWrittenStyle` tells the card how to draw it.
extension TranscriptTitler {
    /// What the "Summary:" block looks like, per style and language.
    nonisolated static func styleFormat(_ style: SummaryStyle, german: Bool) -> String {
        switch (style, german) {
        case (.meeting, false):
            "Decisions:\n- one line per decision, with its numbers and dates\nTo-dos:\n- one line per task: what is " +
            "to be done, who does it and by when, as it was said\nOpen questions:\n- one line per question that " +
            "was left open"
        case (.meeting, true):
            "Entscheidungen:\n- eine Zeile je Entscheidung, mit ihren Zahlen und Terminen\nAufgaben:\n- eine Zeile " +
            "je Aufgabe: was zu tun ist, wer es erledigt und bis wann, so wie es gesagt wurde\nOffene Fragen:\n- " +
            "eine Zeile je Frage, die offen geblieben ist"
        case (.lecture, false):
            "- one line per key idea: the idea and what the speaker said about it"
        case (.lecture, true):
            "- eine Zeile je Kernaussage: die Aussage und was die vortragende Person dazu gesagt hat"
        case (.interview, false):
            "Q: a question that was asked, in short\nA: the answer, in one or two sentences"
        case (.interview, true):
            "F: eine gestellte Frage, kurz\nA: die Antwort, in ein oder zwei Sätzen"
        case (.bulletPoints, false), (.brief, false):
            "- one line per point"
        case (.bulletPoints, true), (.brief, true):
            "- eine Zeile je Punkt"
        }
    }

    /// The style's own rules, before the rules every style shares.
    nonisolated static func styleRules(_ style: SummaryStyle, german: Bool) -> String {
        switch (style, german) {
        case (.meeting, false):
            "Under a heading with nothing to list, write \"- none\". A decision is something agreed; a to-do is a " +
            "concrete task someone takes on, agrees to or is asked to do, not a topic or something already done. At " +
            "most 8 lines under each heading."
        case (.meeting, true):
            "Steht unter einer Überschrift nichts, schreib „- keine“. Eine Entscheidung ist etwas Vereinbartes; eine " +
            "Aufgabe ist etwas Konkretes, das jemand übernimmt, zusagt oder erledigen soll, kein Thema und nichts " +
            "schon Erledigtes. Höchstens 8 Zeilen je Überschrift."
        case (.lecture, false):
            "3 to 8 key ideas in the order they come, with the definitions, examples, numbers and names given; never " +
            "describe the talk (\"the lecturer explains\"). If reading or a task for next time was set, that is the " +
            "last line."
        case (.lecture, true):
            "3 bis 8 Kernaussagen in ihrer Reihenfolge, mit den genannten Definitionen, Beispielen, Zahlen und Namen; " +
            "beschreib nie den Vortrag („es wird erklärt“). Wurde Lektüre oder eine Aufgabe fürs nächste Mal genannt, " +
            "ist das die letzte Zeile."
        case (.interview, false):
            "One Q and one A line per question, in the order asked, at most 10 pairs; leave out small talk; name who " +
            "answers where the text names them."
        case (.interview, true):
            "Eine F- und eine A-Zeile je Frage, in der gestellten Reihenfolge, höchstens 10 Paare; lass Smalltalk " +
            "weg; nenn, wer antwortet, wo der Text es sagt."
        case (.bulletPoints, false), (.brief, false):
            "3 to 8 lines covering every topic in order: results, decisions, dates, numbers, names, and who does what."
        case (.bulletPoints, true), (.brief, true):
            "3 bis 8 Zeilen, die alle Themen in ihrer Reihenfolge abdecken: Ergebnisse, Entscheidungen, Termine, " +
            "Zahlen, Namen und wer was übernimmt."
        }
    }

    /// Gemma's instructions for a styled summary: Brief's (`localTitleInstructions`, `germanTitleInstructions`) with
    /// the "Summary:" block in the style's form; the title's rules and the prohibitions are the same.
    nonisolated static func styledInstructions(_ style: SummaryStyle, language: String, german: Bool,
                                               fromSummaries: Bool) -> String {
        let format = styleFormat(style, german: german)
        let rules = styleRules(style, german: german)
        if german {
            let source = fromSummaries
                ? "Du bekommst Zusammenfassungen der aufeinanderfolgenden Teile eines langen Gesprächs; fasse das " +
                  "ganze Gespräch zusammen."
                : "Das Transkript stammt aus einer Spracherkennung und kann falsch verstandene Wörter enthalten. Jede " +
                  "Zeile beginnt mit dem Namen der sprechenden Person und einem Doppelpunkt („Sprecher 2“, solange " +
                  "der Name unbekannt ist)."
            return """
            Du schreibst eine Zusammenfassung und einen Titel eines aufgenommenen Gesprächs für die Person, die es \
            aufgenommen hat, auf Deutsch, auch wenn das Gespräch in einer anderen Sprache geführt wurde.
            Antworte genau in dieser Form und sonst nichts:
            Themen: alle Themen des Gesprächs, durch Semikolons getrennt
            Zusammenfassung:
            \(format)
            Titel: 2 bis 6 Wörter

            Zusammenfassung: \(rules) Jede Zeile unter 25 Wörtern. Dritte Person, Aktiv. Schreib die Fakten selbst; \
            beschreib nie das Gespräch („fasst zusammen“, „es wird besprochen“, „im Gespräch geht es um“). Nenn \
            Personen beim Namen. Eine Person ohne Namen („Sprecher 3“) ist „ein Teilnehmer“; schreib nie „Sprecher“ \
            mit einer Nummer.
            Titel: das konkrete Thema wie eine Dokumentüberschrift, zum Beispiel „Kreditprojekt: Testphase und \
            Abnahme“. Beginne nie mit „Zusammenfassung“, „Überblick“, „Meeting“, „Besprechung“ oder „Gespräch“.
            Verwende nur, was im Text steht: erfinde nie Namen, Zahlen, Termine, Entscheidungen oder Aufgaben. \(source)
            """
        }
        let source = fromSummaries
            ? "You get summaries of the consecutive parts of one long conversation; cover the whole conversation."
            : "The transcript comes from speech recognition and may contain misheard words. Each line starts with the " +
              "speaker's name and a colon (\"Speaker 2\" while the name is unknown)."
        return """
        You write a summary and a title of a recorded conversation for the person who recorded it, in \(language).
        Answer in exactly this form and nothing else:
        Topics: every topic of the conversation, separated by semicolons
        Summary:
        \(format)
        Title: 2 to 6 words

        Summary: \(rules) Each line under 25 words. Third person, active voice. Write the facts themselves; never \
        describe the conversation ("fasst zusammen", "es wird besprochen", "im Gespräch geht es um", "discussed", \
        "the meeting covered"). Name people by their names. A speaker without a name ("Speaker 3") is "a \
        participant"; never write "Speaker" with a number.
        Title: the specific subject like a document heading, for example "Credit Project: Test Phase and Sign-off". \
        Never begin with "Zusammenfassung", "Überblick", "Meeting", "Besprechung", "Gespräch", "Summary" or \
        "Discussion".
        Use only what the text says: never invent names, numbers, dates, decisions or tasks. \(source)
        """
    }

    nonisolated static func styledReminder(german: Bool) -> String {
        german
            ? "Ende des Textes. Antworte jetzt in der vorgegebenen Form: „Themen: …“, dann „Zusammenfassung:“ mit " +
              "ihren Zeilen, dann „Titel: …“, auf Deutsch und nach den Anweisungen."
            : "End of the text. Now answer in the form given: \"Topics: …\", then \"Summary:\" with its lines, then " +
              "\"Title: …\", following the instructions."
    }

    /// A part of a long transcript, for a styled summary: as Brief's parts, in up to five sentences, keeping what the
    /// style lists (a part summary of three sentences dropped most tasks and questions).
    nonisolated static func styledPartInstructions(_ style: SummaryStyle, language: String, german: Bool) -> String {
        let keep: String
        switch (style, german) {
        case (.meeting, false): keep = "Keep every decision, every task with who and by when, and every question left open. "
        case (.meeting, true): keep = "Behalte jede Entscheidung, jede Aufgabe mit wer und bis wann, und jede offene Frage. "
        case (.lecture, false): keep = "Keep every key idea with its explanation. "
        case (.lecture, true): keep = "Behalte jede Kernaussage mit ihrer Erklärung. "
        case (.interview, false): keep = "Keep every question asked and the gist of its answer. "
        case (.interview, true): keep = "Behalte jede gestellte Frage und den Kern ihrer Antwort. "
        default: keep = ""
        }
        if german {
            return """
                Du fasst einen Teil eines langen aufgenommenen Gesprächs auf Deutsch zusammen, in höchstens fünf \
                Sätzen Fließtext (ein Absatz, kein Markdown, keine Listen). Nenn jedes Thema dieses Teils mit seinen \
                wichtigsten Fakten und Entscheidungen, in der Reihenfolge, in der sie vorkommen, und wer was gesagt \
                oder entschieden hat, wo der Text Personen nennt (nie „Sprecher 1“ oder ähnlich). \(keep)Verwende \
                nur, was im Text steht: erfinde nie Namen, Zahlen, Orte, Termine oder Details. Das Transkript stammt \
                aus einer Spracherkennung und kann falsch verstandene Wörter enthalten. Jede Zeile beginnt mit dem \
                Namen der sprechenden Person und einem Doppelpunkt.
                """
        }
        return """
            You summarize one part of a long recorded conversation in \(language), in at most five sentences of \
            plain text (one paragraph, no Markdown, no lists). Name every topic of this part, each with its key \
            facts and decisions, in the order they come up, and who said or decided what where the text names people \
            (never "Speaker 1" or similar). \(keep)Use only what the text says: never invent names, numbers, places, \
            dates or details. The transcript comes from speech recognition and may contain misheard words. Each line \
            starts with the speaker's name and a colon.
            """
    }

    // MARK: Parsing a styled answer (pure)

    /// The Meeting style's headings as stored, in the summary's language (chosen like "Teil"/"Part": the stored
    /// summary is not translated later).
    nonisolated static func meetingHeadings(german: Bool) -> [String] {
        german ? ["Entscheidungen", "Aufgaben", "Offene Fragen"] : ["Decisions", "To-dos", "Open questions"]
    }

    /// At most this many lines under a heading (Meeting), bullets (Lecture, Bullet Points) and question-answer pairs.
    nonisolated static let styledSectionLimit = 8
    nonisolated static let styledBulletLimit = 10
    nonisolated static let interviewPairLimit = 10
    /// A line longer than this is cut at a word (the instructions ask for under 25 words).
    nonisolated static let styledLineLimit = 300

    /// A styled answer: the Topics and Title lines as in `parseLabelled` (the title may be missing: a rewrite never
    /// uses it, and an answer cut off at 700 tokens still has its summary), the summary as the lines between the
    /// "Summary:" line and the next labelled line, in the style's stored form. Gemma's Markdown goes (`**`, `#`), list
    /// markers ("- ", "* ", "1.") become "• ", Meeting's headings are matched loosely ("Beschlüsse", "Action Items")
    /// and written as `meetingHeadings`, lines that say there is nothing ("- none", "Keine offenen Fragen") are dropped
    /// with their empty heading. nil when no line is left, also after reading the whole answer as bullets.
    nonisolated static func parseStyled(_ text: String, style: SummaryStyle, german: Bool) -> TitleAndSummary? {
        let lines = text.split(whereSeparator: \.isNewline).map { styledClean(String($0)) }
        var title = "", topics: [String] = [], summaryAt: Int?, inline = ""
        var labelled: [Int] = []
        for (index, line) in lines.enumerated() {
            if let match = line.firstMatch(of: /^(?i:title|titel)\s*:\s*(.*)/) {
                title = String(match.1)
                labelled.append(index)
            } else if let match = line.firstMatch(of: /^(?i:topics|themen)\s*:\s*(.*)/) {
                topics = topicList(String(match.1))
                labelled.append(index)
            } else if summaryAt == nil, let match = line.firstMatch(of: /^(?i:summary|zusammenfassung)\s*:\s*(.*)/) {
                summaryAt = index
                inline = String(match.1)
                labelled.append(index)
            }
        }
        let rest = lines.indices.filter { !labelled.contains($0) }.map { lines[$0] }
        var body = rest
        if let summaryAt {
            let end = labelled.filter { $0 > summaryAt }.min() ?? lines.count
            body = [inline] + lines[(summaryAt + 1)..<end]
        }
        var summary = styledLines(body, style: style, german: german)
        if summary.isEmpty { summary = styledLines([inline] + rest, style: .bulletPoints, german: german) }
        guard !summary.isEmpty else { return nil }
        return TitleAndSummary(topics: topics, summary: summary.joined(separator: "\n"), title: title)
    }

    /// The summary's lines in the style's stored form.
    nonisolated static func styledLines(_ body: [String], style: SummaryStyle, german: Bool) -> [String] {
        switch style {
        case .meeting: meetingLines(body, german: german)
        case .interview: interviewLines(body, german: german)
        case .brief, .lecture, .bulletPoints: bulletLines(body)
        }
    }

    /// Markdown emphasis and heading marks gone, whitespace trimmed.
    nonisolated static func styledClean(_ line: String) -> String {
        line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacing(/^\s*#+\s*/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A line without its list marker ("- ", "* ", "• ", "1. ", "2) "), and whether it had one.
    nonisolated static func listItem(_ line: String) -> (text: String, marked: Bool) {
        if let match = line.firstMatch(of: /^\s*(?:[-*•–—]|\d+[.)])\s*(.*)$/) {
            return (String(match.1).replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces), true)
        }
        return (line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces), false)
    }

    /// A line that only says there is nothing: "none", "-", "keine", or "No decisions were made", "Keine offenen
    /// Fragen" (a few words naming what there is none of; "No overtime until March" is content and stays).
    nonisolated static func saysNone(_ text: String) -> Bool {
        guard ActionItemExtractor.cleanValue(text) != nil else { return true }
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!;: "))
        guard lower.firstMatch(of: /^(none|nothing|nichts|keine?n?|no)\b/) != nil,
              lower.split(separator: " ").count <= 6 else { return false }
        return lower.firstMatch(of: /decision|entscheid|beschl|task|to-?do|aufgabe|question|frage|point|punkt/) != nil
    }

    /// A line that is only a heading Gemma added ("Key ideas:", "Kernaussagen:"): no marker, ends with a colon, a
    /// few words.
    nonisolated static func isHeading(_ item: (text: String, marked: Bool)) -> Bool {
        !item.marked && item.text.hasSuffix(":") && item.text.split(separator: " ").count <= 4
    }

    /// A line as stored: the first letter capitalized, cut at a word after `styledLineLimit` characters.
    nonisolated static func styledText(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespaces)
        if line.count > styledLineLimit {
            let cut = line.index(line.startIndex, offsetBy: styledLineLimit)
            line = String(line[..<(line[..<cut].lastIndex(of: " ") ?? cut)]) + "…"
        }
        guard let first = line.first else { return line }
        return first.uppercased() + line.dropFirst()
    }

    nonisolated static func bulletLines(_ body: [String]) -> [String] {
        var lines: [String] = []
        for raw in body {
            let item = listItem(raw)
            guard !item.text.isEmpty, !isHeading(item), !saysNone(item.text) else { continue }
            lines.append("• " + styledText(item.text))
        }
        return Array(lines.prefix(styledBulletLimit))
    }

    /// Decisions, to-dos, open questions, in this order, each under its heading; lines before any heading first, as
    /// bullets without one.
    nonisolated static func meetingLines(_ body: [String], german: Bool) -> [String] {
        var sections: [[String]] = [[], [], [], []]       // before any heading, decisions, to-dos, open questions
        var current = 0
        for raw in body {
            var item = listItem(raw)
            guard !item.text.isEmpty else { continue }
            if let match = item.text.firstMatch(of: /^([^:]{1,40}?)\s*:\s*(.*)$/),
               let section = meetingSection(String(match.1)) {
                current = section                           // "Decisions:", or "Decisions: the budget moves"
                item.text = String(match.2)
                guard !item.text.isEmpty else { continue }
            } else if !item.marked, let section = meetingSection(item.text) {
                current = section                           // "Decisions" without a colon
                continue
            }
            guard !isHeading(item), !saysNone(item.text) else { continue }
            if sections[current].count < styledSectionLimit { sections[current].append("• " + styledText(item.text)) }
        }
        let headings = meetingHeadings(german: german)
        var lines = sections[0]
        for (index, heading) in headings.enumerated() where !sections[index + 1].isEmpty {
            lines.append(heading)
            lines += sections[index + 1]
        }
        return lines
    }

    /// Which of Meeting's headings `text` is (1 decisions, 2 to-dos, 3 open questions), if any.
    nonisolated static func meetingSection(_ text: String) -> Int? {
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":. "))
        if lower.wholeMatch(of: /decisions?( made)?|entscheidungen?|beschl(ü|u)sse?|vereinbarungen|agreements?/) != nil {
            return 1
        }
        if lower.wholeMatch(of: /to-?dos?|tasks?|aufgaben|action items?|next steps|nächste schritte|todos/) != nil {
            return 2
        }
        if lower.wholeMatch(of: /(open|offene|offenen) (questions?|fragen|punkte|points)|questions|fragen/) != nil {
            return 3
        }
        return nil
    }

    /// "Q: …"/"A: …" pairs (German "F: …"), in order; a line of neither kind goes with the answer before it, or
    /// stands as a bullet before the first question.
    nonisolated static func interviewLines(_ body: [String], german: Bool) -> [String] {
        var pairs: [(question: String?, answer: String?)] = []
        var lead: [String] = []
        for raw in body {
            let item = listItem(raw)
            guard !item.text.isEmpty else { continue }
            if let match = item.text.firstMatch(of: /^(?i:q|f|frage|question)\s*\d*\s*:\s*(.*)$/) {
                let question = String(match.1).trimmingCharacters(in: .whitespaces)
                if !question.isEmpty { pairs.append((question, nil)) }
            } else if let match = item.text.firstMatch(of: /^(?i:a|antwort|answer)\s*\d*\s*:\s*(.*)$/) {
                let answer = String(match.1).trimmingCharacters(in: .whitespaces)
                guard !answer.isEmpty, !saysNone(answer) else { continue }
                if let last = pairs.indices.last, pairs[last].answer == nil {
                    pairs[last].answer = answer
                } else {
                    pairs.append((nil, answer))
                }
            } else if !isHeading(item), !saysNone(item.text) {
                if let last = pairs.indices.last {
                    pairs[last].answer = [pairs[last].answer, item.text].compactMap { $0 }.joined(separator: " ")
                } else {
                    lead.append("• " + styledText(item.text))
                }
            }
        }
        var lines = Array(lead.prefix(styledSectionLimit))
        for pair in pairs.prefix(interviewPairLimit) {
            if let question = pair.question { lines.append((german ? "F: " : "Q: ") + styledText(question)) }
            if let answer = pair.answer { lines.append("A: " + styledText(answer)) }
        }
        return lines
    }
}
