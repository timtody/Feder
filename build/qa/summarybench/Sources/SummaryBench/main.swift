import Foundation

// Summary styles bench (FED-15): every style with the English and the German instructions on the given texts, through
// the app's own TranscriptTitler (requests, map-reduce, parsing) and Gemma 4 E2B. Prints each request's tokens
// (instructions, transcript, answer), the time, the raw answer and the stored summary, so format adherence, invented
// content and the token reserve can be checked by reading.
//
// usage: SummaryBench <modelDir> <styles: all|brief,meeting,…> <languages: en|de|both> <repeat> <text.txt>…
//        SummaryBench parse        (the parser on canned answers and the parsing checks, no model; exits 1 on a
//                                   failed check)
// A text is one "Name: text" paragraph per line; <repeat> joins it that many times (the long-transcript case).

/// Forwards to Gemma and keeps what each request was, for the token counts.
final class MeasuringWriter: TextWriter, @unchecked Sendable {
    let model: LocalLanguageModel
    var requests: [(instructions: String, prompt: String, answer: String, seconds: Double)] = []

    init(model: LocalLanguageModel) { self.model = model }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String {
        let start = Date()
        let answer = try await model.respond(instructions: instructions, prompt: prompt, maxTokens: maxTokens,
                                             temperature: temperature, partial: nil)
        requests.append((instructions, prompt, answer, Date().timeIntervalSince(start)))
        return answer
    }

    func unload() async { await model.unload() }
}

/// Answers from a script, in order, and keeps each request: the title fallback's request count, without a model.
final class ScriptedWriter: TextWriter, @unchecked Sendable {
    var answers: [String]
    var requests: [(instructions: String, prompt: String)] = []

    init(answers: [String]) { self.answers = answers }

    func respond(instructions: String, prompt: String, maxTokens: Int, temperature: Float,
                 partial: (@Sendable (String) -> Void)?) async throws -> String {
        requests.append((instructions, prompt))
        return answers.isEmpty ? "" : answers.removeFirst()
    }

    func unload() async {}
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(what)")
}

let args = CommandLine.arguments

if args.count > 1, args[1] == "parse" {
    let answers: [(SummaryStyle, Bool, String)] = [
        (.meeting, false, "Topics: budget; travel\nSummary:\nDecisions:\n- Part of the licence budget moves to travel.\nTo-dos:\n- Anna sends the numbers by Friday.\nOpen questions:\n- none\nTitle: Budget Review"),
        (.meeting, true, "**Themen:** Testphase; Abnahme\n**Zusammenfassung:**\n**Entscheidungen:**\n* Die Abnahme verschiebt sich auf den 25. November.\n**Aufgaben:**\n1. Lena passt die Erwartungswerte bis Freitag an.\n**Offene Fragen:**\n- Keine offenen Fragen.\n**Titel:** Kreditprojekt: Abnahme"),
        (.interview, false, "Topics: career\nSummary:\nQ: How did you start?\nA: Anna started as a tester in 2019.\nQ: What is next?\nA: She leads the team from January.\nTitle: Career Interview"),
        (.lecture, true, "Themen: Gletscher\nZusammenfassung:\nKernaussagen:\n- Gletscher formen Täler zu U-Tälern.\n- Moränen sind Schutt.\nTitel: Gletscher und Moränen"),
        (.bulletPoints, false, "Topics: a\nSummary: - First point\n- Second point\nTitle: Points"),
        (.bulletPoints, false, "Topics: a\nThe first point.\nThe second point.\nTitle: Points"),
        // Decisions that begin with their date or number (review of FED-15: the dates were cut off).
        (.meeting, true, "Themen: Abnahme\nEntscheidungen:\n- 25. November: Abnahme der Software\n- 1. Dezember Go-live\n- 15.11. Abgabe des Berichts\n- 3.5 % mehr Budget\n- 9:30 Uhr Treffen\n- 2027: Budget steigt\nAufgaben:\n- 1: Lena passt die Erwartungswerte an.\nOffene Fragen:\n- Keine Entscheidung zur Miete\nTitel: Abnahme"),
    ]
    for (style, german, answer) in answers {
        let parsed = TranscriptTitler.parseStyled(answer, style: style, german: german)
        print("== \(style.rawValue) \(german ? "de" : "en"): title \(parsed?.title ?? "-") topics \(parsed?.topics ?? [])\n\(parsed?.summary ?? "nil")\n")
    }

    // A number is a list marker only where it can't be content.
    let items: [(line: String, text: String, marked: Bool)] = [
        ("- 25. November: Abnahme der Software", "25. November: Abnahme der Software", true),
        ("- 1. Dezember Go-live", "1. Dezember Go-live", true),
        ("- 15.11. Abgabe des Berichts", "15.11. Abgabe des Berichts", true),
        ("- 3.5 % mehr Budget", "3.5 % mehr Budget", true),
        ("- 9:30 Uhr Treffen", "9:30 Uhr Treffen", true),
        ("- 2027: Budget steigt", "2027: Budget steigt", true),
        ("- 2. Quartal: Budget steigt", "2. Quartal: Budget steigt", true),
        ("25. November: Abnahme der Software", "25. November: Abnahme der Software", false),
        ("1. Dec. go-live", "1. Dec. go-live", false),
        ("15.11. Abgabe des Berichts", "15.11. Abgabe des Berichts", false),
        ("9:30 Uhr Treffen", "9:30 Uhr Treffen", false),
        ("2027: Budget steigt", "2027: Budget steigt", false),
        ("-5 °C am Morgen", "-5 °C am Morgen", false),
        ("1. Lena passt die Erwartungswerte an.", "Lena passt die Erwartungswerte an.", true),
        ("2) Anna sends the numbers.", "Anna sends the numbers.", true),
        ("- 1: Die Abnahme verschiebt sich.", "Die Abnahme verschiebt sich.", true),
        ("- 3) The budget moves.", "The budget moves.", true),
        ("* Point", "Point", true),
        ("  • Punkt", "Punkt", true),
        ("Plain line", "Plain line", false),
    ]
    for item in items {
        let result = TranscriptTitler.listItem(item.line)
        check(result.text == item.text && result.marked == item.marked,
              "listItem \"\(item.line)\" → \"\(result.text)\" \(result.marked ? "marked" : "plain")")
    }

    // Only lines that say there is nothing go, not those naming what is open.
    let nones: [(text: String, none: Bool)] = [
        ("none", true), ("Keine.", true), ("No decisions were made.", true), ("Keine offenen Fragen.", true),
        ("Es wurden keine Entscheidungen getroffen.", true), ("There were no open questions.", true),
        ("No action items", true), ("Keine Aufgaben vergeben", true), ("None identified", true),
        ("No decision on the rent", false), ("Keine Entscheidung zur Miete", false), ("No overtime until March", false),
        ("No.", false), ("No, the budget stays", false), ("Keine Einigung beim Budget", false),
    ]
    for none in nones {
        check(TranscriptTitler.saysNone(none.text) == none.none, "saysNone \"\(none.text)\" \(none.none)")
    }

    // A styled answer without a title: one Brief request over the text the styled one read (here three parts'
    // summaries), not the map-reduce again; none when the title isn't needed.
    let paragraphs = (1...3).map { "Anna Schmidt: Teil \($0) " + String(repeating: "Die Abnahme verschiebt sich. ", count: 5) }
    for needsTitle in [true, false] {
        let writer = ScriptedWriter(answers: ["Abnahme verschoben.", "Go-live geplant.", "Budget steigt.",
                                              "Themen: Abnahme\nEntscheidungen:\n- Die Abnahme verschiebt sich.",
                                              "Themen: Abnahme\nZusammenfassung: Die Abnahme verschiebt sich.\nTitel: Kreditprojekt: Abnahme"])
        let description = try await TranscriptTitler().describe(paragraphs, locale: Locale(identifier: "de"),
                                                                 writer: writer, bookmarked: false, style: .meeting,
                                                                 needsTitle: needsTitle, limit: 200, partial: nil)
        let count = writer.requests.count
        check(count == (needsTitle ? 5 : 4), "needsTitle \(needsTitle): \(count) requests (3 parts, the styled one\(needsTitle ? ", Brief's" : ""))")
        check(description?.title == (needsTitle ? "Kreditprojekt: Abnahme" : nil), "title \(description?.title ?? "-")")
        check(description?.summary == "Entscheidungen\n• Die Abnahme verschiebt sich.", "summary \(description?.summary ?? "nil")")
        if needsTitle, count == 5 {
            let brief = writer.requests[4], styled = writer.requests[3]
            check(brief.instructions == TranscriptTitler.germanTitleInstructions(fromSummaries: true),
                  "the title's request has Brief's instructions")
            check(brief.prompt.contains("Teil 1: Abnahme verschoben.") && !brief.prompt.contains("Anna Schmidt")
                  && brief.prompt.hasPrefix(styled.prompt.components(separatedBy: "\n\n").first ?? "-"),
                  "and the parts' summaries the styled request read")
        }
    }
    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}

guard args.count > 5 else {
    print("usage: SummaryBench <modelDir> <styles> <en|de|both> <repeat> <text.txt>…  |  SummaryBench parse")
    exit(1)
}
let model = LocalLanguageModel(variant: .e2b, directory: URL(fileURLWithPath: args[1]))
let styles = args[2] == "all" ? SummaryStyle.allCases : args[2].split(separator: ",").compactMap { SummaryStyle(rawValue: String($0)) }
let languages = args[3] == "both" ? ["en", "de"] : [args[3]]
let repeatCount = Int(args[4]) ?? 1
let titler = TranscriptTitler()
var loadStart = Date()
try await model.load()
print("Gemma load: \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s")

for path in args[5...] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let paragraphs = Array(repeating: lines, count: repeatCount).flatMap { $0 }
    let characters = paragraphs.joined(separator: "\n").count
    let tokens = try await model.tokenCount(paragraphs.joined(separator: "\n"))
    print("\n######## \((path as NSString).lastPathComponent) ×\(repeatCount): \(characters) characters, \(tokens) tokens")
    for language in languages {
        for style in styles {
            let writer = MeasuringWriter(model: model)
            let reserved = style == .brief ? TranscriptTitler.reservedTokens : TranscriptTitler.styledReservedTokens
            let start = Date()
            let description: TranscriptTitler.Description?
            do {
                description = try await titler.describe(paragraphs, locale: Locale(identifier: language), writer: writer,
                                                        bookmarked: false, style: style, needsTitle: true,
                                                        limit: TranscriptTitler.chunkCharacters(
                                                            contextSize: LocalLanguageModel.contextTokens, reserved: reserved),
                                                        partial: nil)
            } catch {
                print("== \(style.rawValue) \(language): error \(error)")
                continue
            }
            let seconds = Date().timeIntervalSince(start)
            print("\n======== \(style.rawValue) · \(language) · \(String(format: "%.1f", seconds)) s · \(writer.requests.count) request(s)")
            for (index, request) in writer.requests.enumerated() {
                let instructionTokens = try await model.tokenCount(request.instructions)
                let promptTokens = try await model.tokenCount(request.prompt)
                let answerTokens = try await model.tokenCount(request.answer)
                print("-- request \(index + 1): instructions \(instructionTokens) tokens, prompt \(promptTokens), answer \(answerTokens), \(String(format: "%.1f", request.seconds)) s")
            }
            // The final request's answer; with a styled one's title fallback (Brief's request after it), both.
            for request in writer.requests.suffix(style != .brief && writer.requests.count > 1 ? 2 : 1) {
                print("-- raw answer:\n\(request.answer)")
            }
            print("-- stored: title \(description?.title ?? "-") · topics \(description?.topics ?? [])\n\(description?.summary ?? "nil")")
        }
    }
}
