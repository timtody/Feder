import Foundation

// FED-151: what TranscriptTitler.describe() stores of a model's answer (title, summary), checked on canned answers:
// the real E4B answers without "Titel:" (FED-142 bench), fully labelled German and English ones, and answers built to
// trip the unlabelled-title fallback. The answer goes through describe() with a TextWriter that returns it, so the
// parsing, cleaning and checks are the app's. See run.sh.

nonisolated enum LocalLanguageModel { static let contextTokens = 20_000 }   // all TranscriptTitler reads of it

nonisolated final class Canned: TextWriter {
    let answer: String
    init(_ answer: String) { self.answer = answer }
    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String { answer }
    func chat(instructions: String, turns: [ChatTurn], maxTokens: Int, temperature: Float,
              partial: (@Sendable (String) -> Void)?) async throws -> String { answer }
    func unload() async {}
}

/// "-" when describe() returns nil (no summary), else the title ("·" for none: the name stays) and the summary.
func stored(_ answer: String) async -> (title: String, summary: String) {
    let description = try? await TranscriptTitler().describe(["Anna: Hallo."], locale: Locale(identifier: "de_DE"),
                                                            writer: Canned(answer), bookmarked: false,
                                                            limit: 60_000, partial: nil)
    guard let description else { return ("-", "-") }
    return (description.title ?? "·", description.summary)
}

if CommandLine.arguments.count > 1 {
    // LiteRTBench output: each "-- raw answer:" up to "-- stored:", printed as stored now.
    for path in CommandLine.arguments.dropFirst() {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for (index, match) in text.matches(of: /-- raw answer:\n(.*?)\n-- stored:/.dotMatchesNewlines()).enumerated() {
            let result = await stored(String(match.1))
            print("\((path as NSString).lastPathComponent) #\(index): \(result.title) | \(result.summary.prefix(60))")
        }
    }
    exit(0)
}

let glacierTopics = "Themen: Gletscher und Talformen; Moränen; Gletscherrückzug; Permafrost"
let glacierSummary = "Zusammenfassung: Ein Gletscher formt U-Täler durch Abschleifen, wobei Moränen unsortierten Schutt hinterlassen. Die Alpengletscher verlieren seit 1850 etwa 60 Prozent ihres Volumens. Die Teilnehmer lesen nächste Woche Kapitel 7 über Permafrost."
let glacier = glacierTopics + "\n" + glacierSummary + "\n"
let budget = "Topics: Q2 budget; Travel overrun; License budget reallocation; Q3 forecast\nSummary: Lena Vogel noted the Q2 travel overrun and license underspend. Anna Schmidt will send the numbers by Friday.\n"

/// (name, answer, expected title: a title, "·" for none with the summary kept, "-" for no summary at all)
let cases: [(String, String, String)] = [
    // The real answers without "Titel:" (Gemma 4 E4B on LiteRT-LM, FED-142 bench, e4bgpu-all #5 and #7).
    ("E4B glacier", glacier + "Gletscherformen und Rückzug", "Gletscherformen und Rückzug"),
    ("E4B credit project", "Themen: Kreditprojekt Testphase; Abnahmeplanung; Personalplanung\nZusammenfassung: Lena passt die Erwartungswerte bis Freitag an; Jonas schickt die Fehlerliste; Anna eskaliert den Termin beim Lenkungskreis und klärt die Vertretung für Thomas mit Petra. Die Abnahme verschiebt sich auf den 25. November.\nKreditprojekt: Testphase und Abnahmeplanung",
     "Kreditprojekt: Testphase und Abnahmeplanung"),

    // All three lines written as one (E2B on LiteRT-LM, long transcripts): the line breaks go in before the labels.
    ("one line, labelled", "Themen: Budget; Reisekosten; Lizenzen; Prognose; Zusammenfassung: Lena Vogel und Anna Schmidt besprechen das Budget. Anna sendet die Zahlen bis Freitag. Titel: Q2 Budget und Finanzplanung", "Q2 Budget und Finanzplanung"),

    // Fully labelled, as E2B always answers: unchanged by FED-151.
    ("labelled de", "Themen: Budget Q2, Reisekosten, Lizenzbudget, Finanzabteilung\nZusammenfassung: Lena Vogel und Anna Schmidt besprechen das Budget für das zweite Quartal. Anna Schmidt sendet die Zahlen bis Freitag.\nTitel: Q2 Budget und Finanzplanung",
     "Q2 Budget und Finanzplanung"),
    ("labelled en", budget + "Title: Q2 Budget Review and Reallocation", "Q2 Budget Review and Reallocation"),
    ("labelled bold", "**Themen:** Moränen\n**Zusammenfassung:** Ein Gletscher formt Täler.\n**Titel:** „Gletscher und Täler“", "Gletscher und Täler"),
    ("labelled, blank lines", glacierTopics + "\n\n" + glacierSummary + "\n\nTitel: Gletscher im Alpenraum\n\n", "Gletscher im Alpenraum"),
    ("labelled one word", glacier + "Titel: Gletscherrückzug", "Gletscherrückzug"),
    ("labelled too long", glacier + "Titel: Ein sehr langer Titel mit viel zu vielen Wörtern", "·"),
    ("labelled, line after", glacier + "Titel: Gletscher im Alpenraum\nGletscherformen und Rückzug", "Gletscher im Alpenraum"),
    ("labelled empty, title below", glacier + "Titel:\nGletscherformen und Rückzug", "·"),
    ("no summary", "Themen: Moränen\nTitel: Gletscher und Täler", "-"),
    ("refusal", "Ich kann dieses Transkript nicht zusammenfassen.", "-"),

    // Unlabelled lines that are titles.
    ("unlabelled en", budget + "Q2 Budget Review and Reallocation", "Q2 Budget Review and Reallocation"),
    ("blank lines, trailing blank", glacierTopics + "\n\n" + glacierSummary + "\n\n  Gletscherformen und Rückzug  \n\n", "Gletscherformen und Rückzug"),
    ("bold", glacier + "**Gletscherformen und Rückzug**", "Gletscherformen und Rückzug"),
    ("topics joined by commas", "Themen: Karriereweg, Daten-Engineering, Kafka-Migration, Gehaltsvorstellungen, Arbeitsbedingungen\nZusammenfassung: Maria wechselte ins Daten-Engineering.\nDaten-Engineering und Gehaltsvorstellungen",
     "Daten-Engineering und Gehaltsvorstellungen"),

    // Unlabelled lines that are not titles: the summary is kept, the name stays.
    ("summary's last sentence", glacier + "Die Moränen bleiben im Tal liegen", "·"),
    ("summary's sentence, no period", glacier + "Die Abnahme der Gletscher folgt im November", "·"),
    ("sentence with a period", glacier + "Gletscher schmelzen schneller.", "·"),
    ("quoted sentence", glacier + "„Die Gletscher schmelzen.“", "·"),
    ("label-like filler with a verb", glacier + "Fazit Gletscher schmelzen", "·"),
    ("english filler with a verb", budget + "Budget questions welcome", "·"),
    ("bullet", glacier + "- Gletscherformen und Rückzug", "·"),
    ("bullet, no space", glacier + "•Gletscherformen und Rückzug", "·"),
    ("star bullet", glacier + "* Gletscherformen und Rückzug", "·"),
    ("numbered", glacier + "1. Gletscherformen und Rückzug", "·"),
    ("heading", glacier + "## Gletscherformen und Rückzug", "·"),
    ("two lines after", glacier + "Die Moränen bleiben liegen\nGletscherformen und Rückzug", "·"),
    ("lower case", glacier + "gletscherformen und Rückzug", "·"),
    ("comma", glacier + "Gletscher, Moränen und Rückzug", "·"),
    ("one word", glacier + "Gletscherrückzug", "·"),
    ("no topic word", glacier + "Alles klar", "·"),
    ("transcript line", glacier + "Anna Schmidt: Bis Freitag", "·"),
    ("other label", glacier + "Wichtig: Kapitel 7 über Permafrost", "·"),
    ("other label, list", glacier + "Teilnehmer: Gletscher-AG, Lena", "·"),
    ("own label without colon", glacier + "Titel Gletscherformen und Rückzug", "·"),
    ("topics after summary", glacierSummary + "\n" + glacierTopics, "·"),
    ("closing remark", glacier + "Viel Erfolg mit dem Permafrost", "·"),
    ("no topics line", glacierSummary + "\nGletscherformen und Rückzug", "·"),
    ("no title at all", glacier, "·"),

    // The summary is not finished (cut off or wrapped): nothing, as before FED-151.
    ("summary wrapped", "Themen: Moränen; Gletscherrückzug\nZusammenfassung: Ein Gletscher formt U-Täler und\nMoränen hinterlassen Gletscherschutt", "-"),
    ("summary cut off", "Themen: Moränen\nZusammenfassung: Ein Gletscher formt U-Täler und die", "-"),

    // Known limits: verbless lines that name topics pass (README › Automatic titles).
    ("limit: verbless filler", glacier + "Ende der Gletscher Vorlesung", "Ende der Gletscher Vorlesung"),
    ("limit: topic as label", "Themen: Nächste Schritte; Abnahmeplanung\nZusammenfassung: Lena passt die Planung an.\nNächste Schritte: Abnahmeplanung", "Nächste Schritte: Abnahmeplanung"),
    ("limit: emoji kept, as in a labelled title", glacier + "Gletscherformen und Rückzug 🧊", "Gletscherformen und Rückzug 🧊"),
]

var failures = 0
for (name, answer, expected) in cases {
    let result = await stored(answer)
    let ok = result.title == expected
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name): \(result.title)\(ok ? "" : " (expected \(expected))")")
}
print("\(cases.count - failures)/\(cases.count) as expected")
exit(failures == 0 ? 0 : 1)
