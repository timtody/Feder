import Foundation

/// Gemma's short title for each bookmark (FED-14, an experiment): a few words naming the bookmarked sentence's subject,
/// shown in the Bookmarks row above the sentence itself. Written right after the summary, in the same Gemma session
/// (SpeakerIdentifier.describe), only for transcripts with bookmarks; without Gemma the row shows the sentence alone. If
/// the titles turn out poor on real recordings, they go and the sentence stays (FED-69).
nonisolated enum BookmarkTitler {
    /// Bookmarks titled per request: a lecture with many stays within the answer's tokens.
    static let perRequest = 15

    /// One title per place, in order ("" where Gemma gave none). Each passage is the bookmarked sentence after the one
    /// before it (`Place.before`), so a sentence like "This is the important part." gets its subject.
    static func titles(for places: [Bookmarks.Place], german: Bool, language: String,
                       writer: any TextWriter) async throws -> [String] {
        var titles: [String] = []
        for start in stride(from: 0, to: places.count, by: perRequest) {
            let part = Array(places[start..<min(places.count, start + perRequest)])
            let passages = part.enumerated().map { offset, place in
                "\(offset + 1): " + (place.before.isEmpty ? place.sentence : place.before + " " + place.sentence)
            }
            let prompt = (german ? "Markierte Abschnitte:\n" : "Bookmarked passages:\n") + passages.joined(separator: "\n")
                + "\n\n" + (german ? germanReminder : reminder)
            let answer = try await TranscriptTitler.local {
                try await writer.respond(instructions: german ? germanInstructions : instructions(language: language),
                                         prompt: prompt, maxTokens: 24 * part.count + 40, temperature: 0, partial: nil)
            }
            #if DEBUG
            print("[Scribe] bookmark titles (Gemma): \(answer)")
            #endif
            let parsed = parse(answer)
            titles += part.indices.map { parsed[$0 + 1] ?? "" }
        }
        return titles
    }

    /// "1: Moraine formation" lines by number; a title cleaned of quotes, Markdown and a closing period, at most 60
    /// characters.
    static func parse(_ answer: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in answer.split(whereSeparator: \.isNewline) {
            guard let match = line.wholeMatch(of: #/\s*[*#-]*\s*(\d+)\s*[:.)]\s*(.+)/#),
                  let number = Int(match.1) else { continue }
            var title = String(match.2).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*\"'„“”«»"))
                .trimmingCharacters(in: .whitespaces)
            if title.hasSuffix(".") { title.removeLast() }
            guard !title.isEmpty else { continue }
            result[number] = title.count > 60 ? String(title.prefix(59)) + "…" : title
        }
        return result
    }

    static func instructions(language: String) -> String {
        """
        You give each bookmarked passage of a recorded conversation a short title in \(language): 2 to 5 words naming \
        its subject, like a heading. The bookmark is on the passage's last sentence; the sentence before it is there \
        for context. Answer with one line per passage, in the order given: the passage's number, a colon and the \
        title, and nothing else. Use only what the passage says. The text comes from speech recognition and may \
        contain misheard words.
        """
    }

    static let reminder = "End of the passages. Now answer with one line per passage: its number, a colon and its title."

    static let germanInstructions = """
        Du gibst jedem markierten Abschnitt eines aufgenommenen Gesprächs einen kurzen Titel auf Deutsch: 2 bis 5 \
        Wörter, die sein Thema nennen, wie eine Überschrift. Das Lesezeichen liegt auf dem letzten Satz des Abschnitts; \
        der Satz davor steht zum Verständnis da. Antworte mit einer Zeile pro Abschnitt, in der gegebenen Reihenfolge: \
        die Nummer des Abschnitts, ein Doppelpunkt und der Titel, sonst nichts. Verwende nur, was im Abschnitt steht. \
        Der Text stammt aus einer Spracherkennung und kann falsch verstandene Wörter enthalten.
        """

    static let germanReminder = "Ende der Abschnitte. Antworte jetzt mit einer Zeile pro Abschnitt: Nummer, Doppelpunkt, Titel."
}
