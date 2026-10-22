import Foundation
import NaturalLanguage

/// What writes titles and summaries: Gemma 4 E2B (`LocalLanguageModel`), or on the simulator a stand-in
/// (`FakeTextWriter`, DEBUG). Sendable: the requests are awaited from the main actor.
nonisolated protocol TextWriter: AnyObject, Sendable {
    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String
    /// The next answer in a conversation (the Ask tab); see `LocalLanguageModel.chat`.
    func chat(instructions: String, turns: [ChatTurn], maxTokens: Int, temperature: Float,
              partial: (@Sendable (String) -> Void)?) async throws -> String
    func unload() async
}

/// One message of a conversation with Gemma (the Ask tab), as the model reads it.
nonisolated struct ChatTurn: Sendable, Equatable {
    enum Role: Sendable { case user, assistant }
    var role: Role
    var text: String
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
        var topics: [String] = []   // the "Topics:" line's items (search); empty when the answer had none
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
    func describe(paragraphs: [String], locale recordingLocale: Locale, writer: any TextWriter, bookmarked: Bool = false,
                  partial: (@Sendable (String) -> Void)? = nil) async throws -> Description? {
        // The app's language, not the transcript's: the summary is read in the app, next to its German or English
        // labels (an English recording on a German iPhone gets a German summary).
        let locale = Self.appLocale
        return try await describe(paragraphs, locale: locale, writer: writer, bookmarked: bookmarked,
                                  limit: Self.chunkCharacters(contextSize: LocalLanguageModel.contextTokens), partial: partial)
    }

    /// Not private: the Mac model bench (build/qa/litertbench) calls it with an explicit locale.
    func describe(_ paragraphs: [String], locale: Locale, writer: any TextWriter, bookmarked: Bool, limit: Int,
                          partial: (@Sendable (String) -> Void)?) async throws -> Description? {
        let german = Self.isGerman(locale)
        let bookmarkNote = bookmarked ? "\n" + Self.bookmarkNote(german: german) : ""
        let language = Self.languageName(locale)
        var parts = Self.chunks(paragraphs, limit: limit)
        guard !parts.isEmpty else { return nil }
        // Map-reduce: while the text does not fit one request, summarize each part, then work on the summaries.
        var fromSummaries = false
        while parts.count > 1 {
            var summaries: [String] = []
            for part in parts {
                if let summary = try await summarize(part, language: language, german: german,
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
        let instructions = (german ? Self.germanTitleInstructions(fromSummaries: fromSummaries)
                                   : Self.localTitleInstructions(language: language, locale: locale,
                                                                 fromSummaries: fromSummaries))
            + (fromSummaries ? "" : bookmarkNote)
        // The task again after the transcript: without it Gemma went on with the transcript ("Anna Schmidt: …").
        let request = prompt + "\n\n" + (german ? Self.germanReminder : Self.localReminder)
        let text = try await Self.local {
            try await writer.respond(instructions: instructions, prompt: request, maxTokens: 400, temperature: 0) { text in
                if let summary = Self.partialSummary(in: text) { partial?(summary) }
            }
        }
        #if DEBUG
        print("[Scribe] title (Gemma): \(text)")
        #endif
        let answer = await Self.parsed(text)
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
    private func summarize(_ text: String, language: String, german: Bool, fromSummaries: Bool, note: String,
                           writer: any TextWriter) async throws -> String? {
        let heading = german
            ? (fromSummaries ? "Zusammenfassungen aufeinanderfolgender Teile eines langen Gesprächs:\n" : "Teil eines Transkripts:\n")
            : (fromSummaries ? "Summaries of consecutive parts of one long conversation:\n" : "Part of a transcript:\n")
        let prompt = heading + text
        let instructions = (german ? Self.germanPartInstructions : Self.partInstructions(language: language)) + note
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

    /// The summary line of a plain-text answer as far as it is written (Gemma's three lines arrive token by token).
    nonisolated static func partialSummary(in text: String) -> String? {
        guard let match = lineBroken(text).firstMatch(of: /(?i)(?:summary|zusammenfassung)\s*\**:\s*\**([^\n]*)/)
        else { return nil }
        let summary = String(match.1).replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return summary.isEmpty ? nil : summary
    }

    /// The three lines of an answer, also when Gemma wrote them as one ("Themen: …; Zusammenfassung: … Titel: …",
    /// E4B and E2B on LiteRT-LM for long transcripts, FED-151): a line break goes in before a Summary or Title label
    /// in mid-line. Not before Topics, which always comes first: a summary may say "drei Themen: …". Capitalized only, as
    /// Gemma writes its labels: English prose may say "a short summary: …".
    nonisolated static func lineBroken(_ text: String) -> String {
        text.replacing(/[ \t]*;?[ \t]*(\**(?:Summary|SUMMARY|Zusammenfassung|ZUSAMMENFASSUNG|Title|TITLE|Titel|TITEL)\**[ \t]*:)/) { match in
            "\n" + match.1
        }
    }

    /// The "Topics: …", "Summary: …" and "Title: …" lines of an answer; nil without a summary, and without a title
    /// unless the summary ends a sentence (cut off at the token limit, it may end mid-sentence).
    /// Without a "Title:" line (Gemma 4 E4B on LiteRT-LM left the label out in 2 of the 6 German answers of its bench
    /// run and once more in a rerun, FED-142, and the transcript got no summary at all), a finished summary is kept with
    /// an empty title, so the transcript keeps its name, or with the one line after it as the title when that line
    /// reads as one (`unlabelledTitle`) and nothing else follows (with two lines, one may be the summary's own last
    /// sentence). The summary must end a sentence for that too: otherwise the line may be the summary wrapped
    /// ("… formt U-Täler und" / "Moränen hinterlassen …").
    nonisolated static func parseLabelled(_ text: String) -> TitleAndSummary? {
        var title: String?, summary: String?, topics: [String] = [], topicLine = "", german = false
        var afterSummary: [Substring] = []   // the non-empty lines after the summary's, labelled or not
        for line in lineBroken(text).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*")))
            if summary != nil, !trimmed.isEmpty { afterSummary.append(line) }
            if let match = trimmed.firstMatch(of: /^(?i:title|titel)\s*\**:\s*\**(.*)/) { title = String(match.1) }
            if let match = trimmed.firstMatch(of: /^(?i:(summary|zusammenfassung))\s*\**:\s*\**(.*)/) {
                summary = String(match.2)
                german = match.1.lowercased() == "zusammenfassung"
                afterSummary = []
            }
            if let match = trimmed.firstMatch(of: /^(?i:topics|themen)\s*\**:\s*\**(.*)/) {
                topicLine = String(match.1)
                topics = topicList(topicLine)
            }
        }
        guard let summary else { return nil }
        if title == nil, let end = summary.trimmingCharacters(in: Self.closingMarks).last, ".!?…".contains(end) {
            title = afterSummary.count == 1 ? unlabelledTitle(afterSummary[0], topicLine: topicLine, german: german) : nil
            title = title ?? ""
        }
        guard let title else { return nil }
        return TitleAndSummary(topics: topics, summary: summary, title: title)
    }

    /// `parseLabelled` off the main actor: `hasVerb`'s tagger loads its model on first use (13 ms on an M-series Mac).
    @concurrent nonisolated static func parsed(_ text: String) async -> TitleAndSummary? { parseLabelled(text) }

    /// `line` as a title written without its "Title:" label, or nil when it may be anything else. Narrow on purpose:
    /// a line taken wrongly replaces a default-named transcript's name, while nil keeps the summary and the name.
    /// A title names the conversation's topics, so it must share a word with the Topics line, and with a colon both
    /// halves must ("Kreditprojekt: Testphase und Abnahmeplanung" was one of the bench's unlabelled titles, shaped like
    /// the prompt's example); that keeps out most lines of transcript ("Anna Schmidt: Bis Freitag"), other labels
    /// ("Wichtig: …") and filler ("Alles klar") without closed lists, though not one whose words are topics too
    /// ("Nächste Schritte: Abnahmeplanung" when "Nächste Schritte" is a topic). A title has no verb, a sentence does:
    /// that keeps out the summary's own last sentence written without a period ("Die Abnahme folgt im November",
    /// "Budget questions welcome"); verbless filler that names a topic ("Ende der Gletscher-Vorlesung") still passes.
    /// The checks of its shape keep out list items, sentences and the summary's wrapped rest. A real title in one of
    /// those shapes (with a comma, in lower case, with a verb, "## …", "1. Quartal: …") stays nil, as does one without
    /// a Topics line.
    nonisolated static func unlabelledTitle(_ line: Substring, topicLine: String, german: Bool) -> String? {
        if line.firstMatch(of: /^\s*([-–—•+·▪]|\*\s|\d+[.)](?!\d))/) != nil { return nil }   // a list item
        let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*")))
        let core = trimmed.trimmingCharacters(in: closingMarks.union(CharacterSet(charactersIn: "„‚«‹")))
        guard let first = core.first, let last = core.last, first.isUppercase || first.isNumber,
              !".!?…:;,".contains(last), !core.contains(where: { ",;".contains($0) }),
              core.firstMatch(of: /[.!?…]\s/) == nil else { return nil }
        if core.firstMatch(of: /^(?i:title|titel|topics|themen|summary|zusammenfassung)\b/) != nil { return nil }
        // The raw line, not `topicList`'s items: E4B often joins its topics with commas (3 of the bench run's 6 German
        // answers), which leaves one item, dropped when it is longer than 60 characters.
        let topicWords = matchWords(topicLine)
        let namesTopic = { (part: Substring) in
            matchWords(part).contains { word in topicWords.contains { $0.contains(word) || word.contains($0) } }
        }
        if let colon = core.firstIndex(of: ":") {
            guard namesTopic(core[..<colon]), namesTopic(core[core.index(after: colon)...]) else { return nil }
        } else if !namesTopic(core[...]) {
            return nil
        }
        // A closing remark, which may name a topic ("Viel Erfolg mit dem Permafrost").
        if core.firstMatch(of: /^(?i:viele?\s+(erfolg|spaß|glück)|alles\s+gute|ich\s+hoffe|hoffentlich|gerne?\b|danke|vielen\s+dank|good\s+luck|i\s+hope|hope\s+this|thanks|thank\s+you|let\s+me\s+know|have\s+fun|enjoy)\b/) != nil {
            return nil
        }
        guard let title = cleanTitle(trimmed), title.split(whereSeparator: \.isWhitespace).count >= 2,
              !hasVerb(core, german: german) else { return nil }
        return trimmed
    }

    /// Whether `text` has a verb, by NLTagger's word classes in the summary's language (German or English, the app's
    /// languages); true when the tagger has no word classes for it, so nothing unchecked passes. Tried on a Mac: the
    /// bench's "Gletscherformen und Rückzug" and "Kreditprojekt: Testphase und Abnahmeplanung" have none; "Die Moränen
    /// bleiben im Tal liegen", "Fazit Gletscher schmelzen" and "Budget questions welcome" have one.
    nonisolated static func hasVerb(_ text: String, german: Bool) -> Bool {
        let language: NLLanguage = german ? .german : .english
        guard NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass) else { return true }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        var verb = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            verb = tag == .verb
            return !verb
        }
        return verb
    }

    /// What may close a sentence or title after its last mark: spaces, quotes, brackets, Markdown emphasis.
    nonisolated static let closingMarks = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’»›`)]}*"))

    /// The words that tie a title to a topic: lower case, at least 5 letters, so "und", "der" and "the" don't count;
    /// matched by containment, so "Rückzug" names the topic "Gletscherrückzug".
    nonisolated static func matchWords(_ text: some StringProtocol) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 5 }
    }

    /// The Topics line's items (kept for search): split at semicolons, Markdown and end punctuation removed, at
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
nonisolated struct TitleAndSummary: Sendable {
    var topics: [String]
    var summary: String
    var title: String
}
