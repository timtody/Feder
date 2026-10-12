import Foundation

/// The action items of a finished transcript (who does what by when), found on device by Gemma 4 E2B in the app's
/// language, right after the summary (SpeakerIdentifier, its own step and its own version): a separate request rather
/// than a fourth line in the summary's, so the benched summary prompt stays as it is, older transcripts get action items
/// without every summary and title being written again, and the small model does one task at a time. The cost is a
/// second reading of the transcript after Stop. Without Gemma there are none.
/// The transcript goes in as for the summary ("Name: text" lines). A transcript longer than one request is read part by
/// part (the summary's parts), each part's items in order, repeats dropped (`ActionItem.deduplicated`); no reduce step:
/// a list doesn't need one.
@MainActor
final class ActionItemExtractor {
    /// Recording.actionItemsVersion once Gemma has looked (it answered, also "none", or the answer was unusable). Not
    /// after RetryLater. A new version makes the sweep look again; `ActionItem.merged` keeps what the user did with the
    /// old items.
    nonisolated static let version = 1
    /// At most this many items per transcript (each request asks for at most 10).
    nonisolated static let maxItems = 15

    /// One answer line: "Task: … | Who: … | Due: …".
    nonisolated struct Parsed: Equatable, Sendable {
        var task: String
        var owner: String?
        var due: String?
    }

    /// The items of `paragraphs` (each "Name: text"), dates resolved relative to `recordedAt` (DueDate). Throws
    /// RetryLater when Gemma can't answer now (the app left the foreground, a recording started): a part stopped that
    /// way stops the whole extraction, so nothing is stored from some parts only. LocalModelFailed when Gemma can't run.
    func extract(paragraphs: [String], recordedAt: Date, writer: any TextWriter) async throws -> [ActionItem] {
        let german = TranscriptTitler.isGerman(TranscriptTitler.appLocale)
        let parts = TranscriptTitler.chunks(paragraphs, limit: TranscriptTitler.chunkCharacters(
            contextSize: LocalLanguageModel.contextTokens))
        var found: [Parsed] = []
        for (index, part) in parts.enumerated() {
            let heading = parts.count == 1
                ? (german ? "Transkript:\n" : "Transcript:\n")
                : (german ? "Teil \(index + 1) von \(parts.count) eines Transkripts:\n"
                          : "Part \(index + 1) of \(parts.count) of a transcript:\n")
            // The task again after the transcript, as for the summary: without it Gemma went on with the transcript.
            let prompt = heading + part + "\n\n" + (german ? Self.germanReminder : Self.reminder)
            let instructions = german ? Self.germanInstructions : Self.instructions
            let answer = try await TranscriptTitler.local {
                try await writer.respond(instructions: instructions, prompt: prompt, maxTokens: 500, temperature: 0,
                                         partial: nil)
            }
            #if DEBUG
            print("[Scribe] action items (Gemma): \(answer)")
            #endif
            found += Self.parse(answer)
        }
        return Self.items(found, recordedAt: recordedAt)
    }

    /// Parsed lines as items: the due phrase resolved, repeats dropped, at most `maxItems`.
    nonisolated static func items(_ parsed: [Parsed], recordedAt: Date) -> [ActionItem] {
        let items = parsed.map { line in
            let due = line.due.flatMap { DueDate.resolve($0, recordedAt: recordedAt) }
            return ActionItem(task: line.task, owner: line.owner, duePhrase: line.due, due: due?.date,
                              dueHasTime: due?.hasTime ?? false)
        }
        return ActionItem.deduplicated(items, limit: maxItems)
    }

    // MARK: Parsing (pure)

    /// The answer's "Task: … | Who: … | Due: …" lines (German "Aufgabe: … | Wer: … | Bis: …"), list markers and
    /// Markdown emphasis removed; "Tasks: none" / "Aufgaben: keine" and anything else: no lines. A task keeps 2-25
    /// words; an owner that is a speaker number ("Speaker 2", "Sprecher 3") or "a participant" is nobody.
    nonisolated static func parse(_ text: String) -> [Parsed] {
        var parsed: [Parsed] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.replacingOccurrences(of: "**", with: "")
                .replacing(/^\s*([-*•]|\d+[.)])\s*/, with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let match = line.firstMatch(of: /^(?i:task|aufgabe)\s*:\s*(.*)$/) else { continue }
            // Fields split at "|", and at a "Who:"/"Due:" label the model wrote without one.
            let fields = String(match.1)
                .replacing(/\s+(?=(?i:who|wer|due|bis|frist)\s*:)/, with: "|")
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let task = cleanTask(fields.first ?? "") else { continue }
            var owner: String?, due: String?
            for field in fields.dropFirst() {
                if let value = field.firstMatch(of: /^(?i:who|wer)\s*:\s*(.*)$/) {
                    owner = cleanOwner(String(value.1))
                } else if let value = field.firstMatch(of: /^(?i:due|bis|frist)\s*:\s*(.*)$/) {
                    due = cleanValue(String(value.1))
                }
            }
            parsed.append(Parsed(task: task, owner: owner, due: due))
        }
        return parsed
    }

    nonisolated private static let quotes = CharacterSet(charactersIn: "\"'„“”‚‘’«»‹›`")

    /// "-", "none", "keine", "unbekannt" and the like: no value.
    nonisolated static func cleanValue(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces.union(quotes))
        let empty: Set<String> = ["", "-", "–", "—", "none", "keine", "keiner", "niemand", "nobody", "unknown",
                                  "unbekannt", "n/a", "na", "k.a.", "k. a."]
        return empty.contains(value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) ? nil : value
    }

    /// Nobody named: a speaker number or a stand-in for one is no owner. A speaker number next to a name goes, the name
    /// stays: Gemma wrote "Speaker 3 und Marco" and "Speaker 3 zusammen mit Marco vom Betrieb" in the bench although
    /// the instructions forbid it, and the card would show the number.
    nonisolated static func cleanOwner(_ raw: String) -> String? {
        guard var owner = cleanValue(raw)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return nil }
        owner = owner.replacing(/(?i)\b(speaker|sprecher|sprecherin)\s*\d+\b/, with: "")
        // What joined the number to the name: "and", "und", "with", "mit", "zusammen mit", "together with", "&", ",".
        let joiners = /(?i)^(?:\s|,|&|\/|\+|and\b|und\b|or\b|oder\b|together with\b|zusammen mit\b|with\b|mit\b)+/
        owner = owner.replacing(joiners, with: "")
        while let last = owner.firstMatch(of: /(?i)(?:\s|,|&|\/|\+|\band|\bund|\bor|\boder|\bwith|\bmit)+$/) {
            guard !last.output.isEmpty else { break }
            owner.removeSubrange(last.range)
        }
        let standIns: Set<String> = ["a participant", "participant", "ein teilnehmer", "eine teilnehmerin",
                                     "teilnehmer", "someone", "jemand"]
        return owner.isEmpty || standIns.contains(owner.lowercased()) ? nil : owner
    }

    /// The task as a short instruction: quotes and a trailing period gone, the first letter capitalized; nil unless it
    /// has 2-25 words.
    nonisolated static func cleanTask(_ raw: String) -> String? {
        var task = raw.trimmingCharacters(in: .whitespaces.union(quotes))
        while task.hasSuffix(".") || task.hasSuffix(";") { task.removeLast() }
        task = task.trimmingCharacters(in: .whitespaces.union(quotes))
        guard let first = task.first else { return nil }
        task = first.uppercased() + task.dropFirst()
        let words = task.split(whereSeparator: \.isWhitespace).count
        return (2...25).contains(words) ? task : nil
    }

    // MARK: Instructions

    /// Gemma's instructions: strict ("Tasks: none", never invent, never "Speaker N"), as a small model lists topics and
    /// decisions as tasks otherwise. No example task: a small model copies examples into its answer.
    nonisolated static let instructions = """
        You list the action items of a recorded conversation for the person who recorded it, in English. An action \
        item is a concrete task that someone in the conversation takes on, agrees to do, or is asked to do. Not \
        topics, decisions, opinions or things already done.
        Answer with one line per action item and nothing else:
        Task: what is to be done, as a short instruction (at most 12 words) | Who: the name of the person who does \
        it, as written in the transcript, or - | Due: the deadline exactly as it was said ("by Friday", "on 14 \
        October", "tomorrow"), or -

        If there are none, answer with exactly one line: Tasks: none
        A speaker without a name ("Speaker 3") is -; never write "Speaker" with a number. Use only what the text says: \
        never invent tasks, names or deadlines. At most 10 lines. The transcript comes from speech recognition and may \
        contain misheard words. Each line starts with the speaker's name and a colon ("Speaker 2" while the name is \
        unknown).
        """

    nonisolated static let reminder = "End of the text. Now list the action items, one line each as \"Task: … | " +
        "Who: … | Due: …\", or answer \"Tasks: none\"."

    /// The same in German, for a German iPhone (as the summary's: English instructions pulled the model towards English
    /// answers). The labels stay parseable ("Aufgabe", "Wer", "Bis").
    nonisolated static let germanInstructions = """
        Du listest die Aufgaben aus einem aufgenommenen Gespräch für die Person, die es aufgenommen hat, auf Deutsch, \
        auch wenn das Gespräch in einer anderen Sprache geführt wurde. Eine Aufgabe ist etwas Konkretes, das jemand im \
        Gespräch übernimmt, zusagt oder erledigen soll. Keine Themen, Entscheidungen, Meinungen oder schon Erledigtes.
        Antworte mit einer Zeile pro Aufgabe und sonst nichts:
        Aufgabe: was zu tun ist, als kurze Anweisung im Infinitiv (höchstens 12 Wörter) | Wer: der Name der Person, \
        die es erledigt, wie er im Transkript steht, oder - | Bis: die Frist genau so, wie sie gesagt wurde („bis \
        Freitag“, „am 14. Oktober“, „morgen“), oder -

        Gibt es keine, antworte mit genau einer Zeile: Aufgaben: keine
        Eine Person ohne Namen („Sprecher 3“) ist -; schreib nie „Sprecher“ mit einer Nummer. Verwende nur, was im \
        Text steht: erfinde nie Aufgaben, Namen oder Fristen. Höchstens 10 Zeilen. Das Transkript stammt aus einer \
        Spracherkennung und kann falsch verstandene Wörter enthalten. Jede Zeile beginnt mit dem Namen der sprechenden \
        Person und einem Doppelpunkt („Sprecher 2“, solange der Name unbekannt ist).
        """

    nonisolated static let germanReminder = "Ende des Textes. Liste jetzt die Aufgaben auf, je eine Zeile als " +
        "„Aufgabe: … | Wer: … | Bis: …“, oder antworte „Aufgaben: keine“."
}
