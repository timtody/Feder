import Foundation

extension Date {
    /// "Today at 12:00", "Yesterday at 12:00", "Last Wednesday at 12:00" within the past week, otherwise
    /// "Thu, 1st October at 12:00" (with the year when it isn't the current one); in German "Heute um 12:00", "Gestern",
    /// "Mittwoch", "Do., 1. Oktober". The words follow the app's language (`AppLanguage`), the time the region's
    /// 12/24-hour setting (e.g. en_DE -> "12:00").
    func relativeDayText(now: Date = .now, calendar: Calendar = .current) -> String {
        let locale = RelativeDateFormat.locale
        let time = formatted(.dateTime.hour().minute().locale(locale))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let day: String
        switch days {
        case 0: day = String(localized: "Today")
        case 1: day = String(localized: "Yesterday")
        case 2...6: day = String(localized: "Last \(formatted(.dateTime.weekday(.wide).locale(locale)))")
        default:
            let ordinal = RelativeDateFormat.ordinal
            let dayNumber = calendar.component(.day, from: self)
            let sameYear = calendar.isDate(self, equalTo: now, toGranularity: .year)
            day = formatted(.dateTime.weekday(.abbreviated).locale(locale)) + ", "
                + (ordinal.string(from: NSNumber(value: dayNumber)) ?? "\(dayNumber)") + " "
                + formatted(.dateTime.month(.wide).locale(locale))
                + (sameYear ? "" : " " + formatted(.dateTime.year().locale(locale)))
        }
        return String(localized: "\(day) at \(time)")
    }
}

/// Made once: the list builds this text twice per row per render (the line and its VoiceOver label), and a Locale
/// and a NumberFormatter per call were the row's biggest cost. The region is read at launch.
private enum RelativeDateFormat {
    static let locale = Locale(identifier: AppLanguage.code + "_" + (Locale.current.region?.identifier ?? "US"))
    static let ordinal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter
    }()
}

/// The language the app's own texts are shown in: the first of the phone's languages the app has (English or
/// German), not simply the phone's region. Dates, language names and the like use it so they match the words around
/// them: an English UI on a German-region phone still says "Today", a German UI says "Heute".
nonisolated enum AppLanguage {
    static let code: String = Bundle.main.preferredLocalizations.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
    static let locale = Locale(identifier: code)
}
