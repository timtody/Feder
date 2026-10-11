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
/// days (not 86,400 s, because of daylight saving time). What it misses ("next week", "nächste Woche", "end of the
/// month", "Ende Oktober", "in zwei Wochen", a bare "14.10.", "on the 14th", "end of day") is covered by own rules,
/// English and German.
/// A time counts only when one was said ("15:00", "17 Uhr", "3 pm", "noon", "tonight"); otherwise it is a day.
/// Unresolved ("before the workshop", "asap"): nil, and the card shows the phrase as said.
nonisolated enum DueDate {
    static func resolve(_ phrase: String, recordedAt: Date,
                        calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'„“”‚‘’«»")))
        guard !text.isEmpty else { return nil }
        let day = calendar.startOfDay(for: recordedAt)
        let folded = fold(text)
        let found: (date: Date, hasTime: Bool)?
        if let date = weekOrMonth(folded, day: day, calendar: calendar) {
            found = (noon(date, calendar), false)
        } else if let detected = detected(text, day: day, calendar: calendar) {
            found = detected
        } else if let date = counted(folded, day: day, calendar: calendar) ?? bareDate(folded, day: day, calendar: calendar)
                    ?? dayOfMonth(folded, day: day, calendar: calendar) {
            found = (noon(date, calendar), false)
        } else {
            found = nil
        }
        // A deadline before the recording, or years after it, is a misreading: the phrase stays as said.
        guard let found, found.date >= day,
              let latest = calendar.date(byAdding: .year, value: 3, to: day), found.date < latest else { return nil }
        return found
    }

    // MARK: NSDataDetector, rebased

    /// Immutable and thread-safe (NSRegularExpression); made once.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func detected(_ text: String, day: Date, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
        guard let detector,
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = match.date else { return nil }
        if match.duration > 0 { date = date.addingTimeInterval(match.duration) }   // "bis Freitag": the range's end
        let matched = Range(match.range, in: text).map { fold(String(text[$0])) } ?? fold(text)
        let hasTime = hasTimeCue(matched)
        let target: Date?
        if namesDayAndMonth(matched) {
            var parts = calendar.dateComponents([.year, .month, .day], from: date)
            if !namesYear(matched) {                                   // the first such day on or after the recording
                parts.year = calendar.component(.year, from: day)
                if let candidate = calendar.date(from: parts), candidate < day { parts.year = (parts.year ?? 0) + 1 }
            }
            target = calendar.date(from: parts)
        } else if let weekday = weekday(in: matched) {
            var ahead = (weekday - calendar.component(.weekday, from: day) + 7) % 7
            if ahead == 0 { ahead = 7 }
            target = calendar.date(byAdding: .day, value: ahead, to: day)
        } else {
            let today = calendar.startOfDay(for: .now)
            let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
            target = calendar.date(byAdding: .day, value: offset, to: day)
        }
        guard let target else { return nil }
        guard hasTime else { return (noon(target, calendar), false) }
        let time = calendar.dateComponents([.hour, .minute], from: date)
        guard let exact = calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: 0,
                                        of: target) else { return nil }
        return (exact, true)
    }

    // MARK: Own rules (what the detector misses), English and German

    /// "this week", "Ende der Woche" (the first Friday on or after the recording), "next week", "nächste Woche" (a week
    /// later), "end of day", "Feierabend" (the recording's day), "end of the month", "Monatsende", "Ende nächsten
    /// Monats", "Ende Oktober" (that month's last day).
    private static func weekOrMonth(_ text: String, day: Date, calendar: Calendar) -> Date? {
        let friday = calendar.date(byAdding: .day, value: (6 - calendar.component(.weekday, from: day) + 7) % 7, to: day)
        if text.contains(/\b(next week|nachste[nrs]? woche|kommende[nrs]? woche)\b/) {
            return friday.flatMap { calendar.date(byAdding: .day, value: 7, to: $0) }
        }
        if text.contains(/\b(this week|end of (the|this) week|diese[nrs]? woche|ende der woche)\b/) { return friday }
        if text.contains(/\b(end of (the )?day|end of business|eod|cob|feierabend|heute noch)\b/) { return day }
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

    /// "in 3 Tagen", "in zwei Wochen", "in a week", "in einer Woche", "in 14 Tagen".
    private static func counted(_ text: String, day: Date, calendar: Calendar) -> Date? {
        guard let match = text.firstMatch(of: /\bin\s+(\d{1,3}|[a-z]+)\s+(tag|tagen|days?|wochen?|weeks?|monate?n?|months?)\b/),
              let count = Int(match.1) ?? numberWords[String(match.1)] else { return nil }
        let unit = String(match.2)
        let component: Calendar.Component = unit.hasPrefix("wo") || unit.hasPrefix("we") ? .weekOfYear
            : unit.hasPrefix("mo") ? .month : .day
        return calendar.date(byAdding: component, value: count, to: day)
    }

    /// A bare "14.10." or "14.10.2026" (the detector wants "am 14.10." or the year).
    private static func bareDate(_ text: String, day: Date, calendar: Calendar) -> Date? {
        guard let match = text.firstMatch(of: /(?:^|[^\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?/),
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

    /// A day and a month: "14.10", "10/14", "14 October", "October 14th", "25. November".
    private static func namesDayAndMonth(_ text: String) -> Bool {
        // Not `\b`: Swift's default word boundaries are Unicode's, where "14.10.2026" is one word.
        if text.contains(/(?:^|[^\d])\d{1,2}\s*[.\/-]\s*\d{1,2}(?:[^\d]|$)/) { return true }
        return text.contains(where: \.isNumber) && words(text).contains { monthNumber(String($0)) != nil }
    }

    private static func namesYear(_ text: String) -> Bool {
        text.contains(/(?:^|[^\d])(?:19|20)\d{2}(?:[^\d]|$)/)
            || text.contains(/(?:^|[^\d])\d{1,2}[.\/]\d{1,2}[.\/]\d{2}(?:[^\d]|$)/)
    }

    /// A time of day was said: digits with a colon, "Uhr", "am"/"pm" after a number, noon, tonight.
    static func hasTimeCue(_ text: String) -> Bool {
        text.contains(/\d{1,2}\s*:\s*\d{2}/) || text.contains(/\d\s*uhr\b/) || text.contains(/\bum \d{1,2}\b/)
            || text.contains(/\d\s*(am|pm|a\.m\.|p\.m\.)/)
            || text.contains(/\b(noon|midday|mittag|mittags|tonight|heute abend)\b/)
    }

    // MARK: Helpers

    /// Lower case without accents ("nächste" → "nachste"), so the rules match however it was written.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func noon(_ day: Date, _ calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private static func lastDay(of date: Date, _ calendar: Calendar) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return nil }
        return calendar.date(byAdding: .day, value: -1, to: month.end)
    }
}
