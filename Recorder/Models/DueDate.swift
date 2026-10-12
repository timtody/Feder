import Foundation

/// An action item's deadline as it was said ("by Friday", "bis Freitag 17 Uhr", "end of the month"), resolved to a date
/// relative to the recording, not to today: a meeting's "by Friday" is the Friday after the meeting, also when Gemma
/// reads an old transcript (the sweep after an update).
///
/// Apple's `NSDataDetector` finds most phrases in many languages, but it has no reference date: it resolves against
/// now (measured on macOS 27): date-only phrases get 12:00; "bis Freitag" / "until Friday" come back as a range from now
/// whose end is the deadline; a weekday said on that weekday is the one a week later; "January 5" is the next one after
/// now. So its answer is rebased onto the recording's day: (a) a day and month keep their day and month, the year from
/// the phrase or else the first such day on or after the recording; (b) a weekday is the next one strictly after the
/// recording's day (the same weekday: a week later, as the detector does); (c) anything else relative ("tomorrow",
/// "übermorgen", "in 3 days") keeps its whole-day distance from today, counted from the recording's day with calendar
/// days (not 86,400 s, because of daylight saving time). What it misses or misreads ("next week", "Dienstag nächste
/// Woche", "Anfang nächster Woche", "end of the month", "Ende Oktober", "in zwei Wochen", a bare "14.10.", "on the 14th",
/// "end of day") is covered by own rules, English and German.
/// The day and the time can come from different parts of the phrase: the detector finds only "14:00" in "18.10. um
/// 14:00", and in "bis 18.10. um 14 Uhr" the date and the time are two matches; each match is read on its own, the day
/// taken from the first that names one (or from the own rules), the time from the first that says one.
/// A time counts only when one was said ("15:00", "17 Uhr", "17.30 Uhr", "3 pm", "noon", "tonight"); otherwise it is a
/// day. Unresolved ("before the workshop", "asap"): nil, and the card shows the phrase as said.
nonisolated enum DueDate {
    static func resolve(_ phrase: String, recordedAt: Date,
                        calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'„“”‚‘’«»")))
        guard !text.isEmpty else { return nil }
        let day = calendar.startOfDay(for: recordedAt)
        let folded = fold(text)
        let readings = detected(text, day: day, calendar: calendar)
        let time = readings.lazy.compactMap(\.time).first
        guard let date = self.day(said: folded, readings: readings, day: day, calendar: calendar)
                ?? (time != nil ? day : nil) else { return nil }        // a time alone ("um 15 Uhr"): that day
        let found: (date: Date, hasTime: Bool)
        if let time, let exact = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) {
            found = (exact, true)
        } else {
            found = (noon(date, calendar), false)
        }
        // A deadline before the recording, or years after it, is a misreading: the phrase stays as said.
        guard found.date >= day,
              let latest = calendar.date(byAdding: .year, value: 3, to: day), found.date < latest else { return nil }
        return found
    }

    /// The day of the deadline. The weeks and months first: the detector reads "Dienstag nächste Woche" as the coming
    /// Tuesday once rebased, and "nächste Woche" not at all. End of day last: "EOD Friday" is the Friday.
    private static func day(said text: String, readings: [Reading], day: Date, calendar: Calendar) -> Date? {
        if let date = weekOrMonth(text, day: day, calendar: calendar) { return date }
        if let date = readings.lazy.compactMap(\.day).first { return date }
        if let date = counted(text, day: day, calendar: calendar) { return date }
        if let date = bareDate(text, day: day, calendar: calendar) { return date }
        if let date = dayOfMonth(text, day: day, calendar: calendar) { return date }
        // A weekday in a word the detector doesn't match ("Freitagmittag", "bis Mittwochabend").
        if let weekday = weekday(in: text) { return next(weekday, after: day, calendar) }
        return endOfDay(text, day: day)
    }

    // MARK: NSDataDetector, rebased

    /// Immutable and thread-safe (NSRegularExpression); made once.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// What one of the detector's matches says: the day, rebased onto the recording's (nil when the match is only a
    /// time of day: "14:00", "um 9.30 Uhr"), and the time of day when one was said.
    private struct Reading {
        var day: Date?
        var time: (hour: Int, minute: Int)?
    }

    private static func detected(_ text: String, day: Date, calendar: Calendar) -> [Reading] {
        guard let detector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard var date = match.date else { return nil }
            if match.duration > 0 { date = date.addingTimeInterval(match.duration) }   // "bis Freitag": the range's end
            let matched = Range(match.range, in: text).map { fold(String(text[$0])) } ?? fold(text)
            let read = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
            // Two numbers ("14.10", "10/14", "17.30") are a day and a month only when the detector read them as one: it
            // reads "17.30 Uhr" and "um 9.30" as times, and their day and month are then today's, not the phrase's.
            let pairs = numberPairs(matched)
            let dayAndMonth = pairs.contains { ($0.0 == read.day && $0.1 == read.month) || ($0.1 == read.day && $0.0 == read.month) }
                || (matched.contains(where: \.isNumber) && words(matched).contains { monthNumber(String($0)) != nil })
            let hasTime = hasTimeCue(matched) || pairs.contains { $0.0 == read.hour && $0.1 == read.minute }
            let time = hasTime ? (hour: read.hour ?? 12, minute: read.minute ?? 0) : nil
            let target: Date?
            if dayAndMonth {
                var parts = calendar.dateComponents([.year, .month, .day], from: date)
                if !namesYear(matched) {                               // the first such day on or after the recording
                    parts.year = calendar.component(.year, from: day)
                    if let candidate = calendar.date(from: parts), candidate < day { parts.year = (parts.year ?? 0) + 1 }
                }
                target = calendar.date(from: parts)
            } else if let weekday = weekday(in: matched) {
                target = next(weekday, after: day, calendar)
            } else {
                let today = calendar.startOfDay(for: .now)
                let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
                // Only a time ("14:00" is today's to the detector): the day is said elsewhere, or is the recording's.
                target = hasTime && offset == 0 ? nil : calendar.date(byAdding: .day, value: offset, to: day)
            }
            return Reading(day: target, time: time)
        }
    }

    // MARK: Own rules (what the detector misses), English and German

    /// "this week", "Ende der Woche" (the Friday of the recording's week), "next week", "nächste Woche" (the Friday of
    /// the week after it), "übernächste Woche" (a week later); weeks from Monday, and said on a Saturday or Sunday, "this
    /// week" and "next week" are the coming one. A weekday said with them is that day instead of Friday ("Dienstag
    /// nächste Woche", "Wednesday this week"; one already past is a misreading, the phrase stays as said), and so are
    /// the week's start and middle ("Anfang nächster Woche": Monday, "mid next week": Wednesday). "end of the month",
    /// "Monatsende", "Ende nächsten Monats", "Ende Oktober" (that month's last day).
    private static func weekOrMonth(_ text: String, day: Date, calendar: Calendar) -> Date? {
        let said: Int? = if text.contains(/\b(ubernachste[nrs]? woche|week after next)\b/) { 2 }
            else if text.contains(/\b(next week|nachste[nrs]? woche|kommende[nrs]? woche)\b/) { 1 }
            else if text.contains(/\b(this week|end of (the |this )?week|diese[nrs]? woche|(ende|anfang|mitte) der woche|mid-?week)\b/) { 0 }
            else { nil }
        if let said {
            let weekday = calendar.component(.weekday, from: day)
            let weeks = said == 0 && (weekday == 1 || weekday == 7) ? 1 : said
            // The day said in the week `weeks` on, counted from its Monday (Monday = 0 of `(weekday + 5) % 7`).
            return calendar.date(byAdding: .day, value: 7 * weeks, to: day).flatMap { week in
                calendar.date(byAdding: .day,
                              value: (dayOfWeek(text) + 5) % 7 - (calendar.component(.weekday, from: week) + 5) % 7,
                              to: week)
            }
        }
        if text.contains(/\b(end of next month|(ende|zum ende) (des )?nachsten monats)\b/) {
            return calendar.date(byAdding: .month, value: 1, to: day).flatMap { lastDay(of: $0, calendar) }
        }
        if text.contains(/\b(end of (the |this )?month|(ende|zum ende) (des|dieses) monats|monatsende)\b/) {
            return lastDay(of: day, calendar)
        }
        if let match = text.firstMatch(of: /\b(?:end of|ende|zum ende|bis ende)\s+([a-z]+)(?:\s+(\d{4}))?\b/),
           let month = monthNumber(String(match.1)) {
            var parts = DateComponents(year: match.2.flatMap { Int($0) } ?? calendar.component(.year, from: day),
                                       month: month, day: 1)
            if match.2 == nil, month < calendar.component(.month, from: day) { parts.year = (parts.year ?? 0) + 1 }
            return calendar.date(from: parts).flatMap { lastDay(of: $0, calendar) }
        }
        return nil
    }

    /// The weekday (Sunday = 1) a part of a week names: a weekday said, the start ("Anfang", "early", "beginning":
    /// Monday), the middle ("Mitte", "mid": Wednesday), else Friday (a week as a deadline: its working days' end).
    private static func dayOfWeek(_ text: String) -> Int {
        if let weekday = weekday(in: text) { return weekday }
        if text.contains(/\b(anfang|beginning|start|early)\b/) { return 2 }
        if text.contains(/\b(mitte|mid|middle|midweek)\b/) { return 4 }
        return 6
    }

    /// "end of day", "EOD", "Feierabend": the recording's day, when no other day was said ("EOD Friday" is the Friday:
    /// it is asked for last).
    private static func endOfDay(_ text: String, day: Date) -> Date? {
        text.contains(/\b(end of (the )?day|end of business|eod|cob|feierabend|heute noch)\b/) ? day : nil
    }

    /// "in 3 Tagen", "in zwei Wochen", "in a week", "in einer Woche", "in 14 Tagen".
    private static func counted(_ text: String, day: Date, calendar: Calendar) -> Date? {
        guard let match = text.firstMatch(of: /\bin\s+(\d{1,3}|[a-z]+)\s+(tag|tagen|days?|wochen?|weeks?|monate?n?|months?)\b/),
              let count = Int(match.1) ?? numberWords[String(match.1)] else { return nil }
        let unit = String(match.2)
        let component: Calendar.Component = unit.hasPrefix("wo") || unit.hasPrefix("we") ? .weekOfYear
            : unit.hasPrefix("mo") ? .month : .day
        return calendar.date(byAdding: component, value: count, to: day)
    }

    /// A bare "14.10." or "14.10.2026" (the detector wants "am 14.10." or the year); not a time at a sentence's end
    /// ("um 10.10.", "10.10. Uhr").
    private static func bareDate(_ text: String, day: Date, calendar: Calendar) -> Date? {
        let isTime = { (match: Regex<(Substring, Substring, Substring, Substring?)>.Match) in
            ["um", "at", "gegen"].contains(text[..<match.range.lowerBound].split(separator: " ").last ?? "")
                || text[match.range.upperBound...].drop(while: \.isWhitespace).hasPrefix("uhr")
        }
        guard let match = text.matches(of: /(?:^|[^\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?/).first(where: { !isTime($0) }),
              let dayNumber = Int(match.1), let month = Int(match.2), (1...31).contains(dayNumber),
              (1...12).contains(month) else { return nil }
        var parts = DateComponents(month: month, day: dayNumber)
        if let yearText = match.3, let year = Int(yearText) {
            parts.year = year < 100 ? 2000 + year : year
        } else {
            parts.year = calendar.component(.year, from: day)
            if let candidate = calendar.date(from: parts), candidate < day { parts.year = (parts.year ?? 0) + 1 }
        }
        guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == dayNumber else { return nil }
        return date
    }

    /// "on the 14th", "bis zum 14.": that day of the recording's month, or of the next month when it has passed.
    private static func dayOfMonth(_ text: String, day: Date, calendar: Calendar) -> Date? {
        let match = text.firstMatch(of: /\b(?:on|by|until|till|before) the (\d{1,2})(?:st|nd|rd|th)\b/)?.1
            ?? text.firstMatch(of: /\b(?:am|bis zum|zum|bis) (\d{1,2})\.(?:[^\d]|$)/)?.1
        guard let match, let number = Int(match), (1...31).contains(number) else { return nil }
        for months in 0...1 {
            guard let month = calendar.date(byAdding: .month, value: months, to: day) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: month)
            parts.day = number
            if let date = calendar.date(from: parts), calendar.component(.day, from: date) == number, date >= day {
                return date
            }
        }
        return nil
    }

    // MARK: Reading the matched text

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10,
        "ein": 1, "einem": 1, "einer": 1, "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6,
        "sieben": 7, "acht": 8, "neun": 9, "zehn": 10,
    ]

    /// The languages a due phrase may come in: Feder's (English, German) and the transcription languages the detector
    /// also reads.
    private static let languages = ["en", "de", "fr", "es", "it", "nl"]

    /// Folded weekday names (wide) of those languages, with the calendar's weekday number (Sunday = 1).
    private static let weekdayNames: [(name: String, weekday: Int)] = languages.flatMap { code in
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: code)
        return (calendar.weekdaySymbols + calendar.standaloneWeekdaySymbols).enumerated()
            .map { (fold($0.element), $0.offset % 7 + 1) }
    }

    /// Folded month names (wide and abbreviated, without a period) of those languages, with the month number.
    private static let monthNames: [(name: String, month: Int)] = languages.flatMap { code in
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: code)
        let lists = [calendar.monthSymbols, calendar.standaloneMonthSymbols, calendar.shortMonthSymbols,
                     calendar.shortStandaloneMonthSymbols]
        return lists.flatMap { list in
            list.enumerated().map { (fold($0.element).trimmingCharacters(in: CharacterSet(charactersIn: ".")), $0.offset + 1) }
        }
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { !$0.isLetter })
    }

    /// The weekday a text names: a whole name, or a word starting with one ("freitags", "Freitagabend"); English
    /// abbreviations ("Fri") only as whole words.
    private static func weekday(in text: String) -> Int? {
        for word in words(text) {
            if let hit = weekdayNames.first(where: { word.hasPrefix($0.name) }) { return hit.weekday }
            if let index = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: String(word)) { return index + 1 }
        }
        return nil
    }

    private static func monthNumber(_ word: String) -> Int? {
        monthNames.first(where: { $0.name.count >= 3 && $0.name == word })?.month
    }

    /// Two numbers written as one date or time: "14.10", "10/14", "17.30", "10-14". Not `\b`: Swift's default word
    /// boundaries are Unicode's, where "14.10.2026" is one word.
    private static func numberPairs(_ text: String) -> [(Int, Int)] {
        text.matches(of: /(?:^|[^\d])(\d{1,2})\s*[.\/-]\s*(\d{1,2})(?=[^\d]|$)/).compactMap { match in
            Int(match.1).flatMap { first in Int(match.2).map { (first, $0) } }
        }
    }

    private static func namesYear(_ text: String) -> Bool {
        text.contains(/(?:^|[^\d])(?:19|20)\d{2}(?:[^\d]|$)/)
            || text.contains(/(?:^|[^\d])\d{1,2}[.\/]\d{1,2}[.\/]\d{2}(?:[^\d]|$)/)
    }

    /// A time of day was said: digits with a colon, "Uhr" or "h" ("15h", "14h30"), "um"/"at" before a number,
    /// "am"/"pm" after one, noon, tonight. (A dotted "17.30" counts when the detector read it as a time: `detected`.)
    private static func hasTimeCue(_ text: String) -> Bool {
        text.contains(/\d{1,2}\s*:\s*\d{2}/) || text.contains(/\d\s*uhr\b/) || text.contains(/\d\s*h(?:\d{2})?\b/)
            || text.contains(/\b(um|at|gegen) \d{1,2}(?:[^\d]|$)/)
            || text.contains(/\d\s*(am|pm|a\.m\.|p\.m\.)/)
            || text.contains(/\b(noon|midday|mittag|mittags|tonight|heute abend)\b/)
    }

    // MARK: Helpers

    /// Lower case without accents ("nächste" → "nachste"), so the rules match however it was written.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The weekday's next day strictly after `day` (the same weekday: a week later, as the detector does).
    private static func next(_ weekday: Int, after day: Date, _ calendar: Calendar) -> Date? {
        let ahead = (weekday - calendar.component(.weekday, from: day) + 7) % 7
        return calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: day)
    }

    private static func noon(_ day: Date, _ calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private static func lastDay(of date: Date, _ calendar: Calendar) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return nil }
        return calendar.date(byAdding: .day, value: -1, to: month.end)
    }
}
