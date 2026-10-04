import Foundation

extension Date {
    /// "Today at 12:00", "Yesterday at 12:00", "Last Wednesday at 12:00" within the past week, otherwise
    /// "Thu, 1st October at 12:00" (with the year when it isn't the current one). The words are English like the rest
    /// of the UI; the time follows the region's 12/24-hour setting (English for that region, e.g. en_DE -> "12:00").
    func relativeDayText(now: Date = .now, calendar: Calendar = .current) -> String {
        let locale = RelativeDateFormat.locale
        let time = formatted(.dateTime.hour().minute().locale(locale))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let day: String
        switch days {
        case 0: day = "Today"
        case 1: day = "Yesterday"
        case 2...6: day = "Last " + formatted(.dateTime.weekday(.wide).locale(locale))
        default:
            let ordinal = RelativeDateFormat.ordinal
            let dayNumber = calendar.component(.day, from: self)
            let sameYear = calendar.isDate(self, equalTo: now, toGranularity: .year)
            day = formatted(.dateTime.weekday(.abbreviated).locale(locale)) + ", "
                + (ordinal.string(from: NSNumber(value: dayNumber)) ?? "\(dayNumber)") + " "
                + formatted(.dateTime.month(.wide).locale(locale))
                + (sameYear ? "" : " " + formatted(.dateTime.year().locale(locale)))
        }
        return "\(day) at \(time)"
    }
}

/// Made once: the list builds this text twice per row per render (the line and its VoiceOver label), and a Locale
/// and a NumberFormatter per call were the row's biggest cost. The region is read at launch.
private enum RelativeDateFormat {
    static let locale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
    static let ordinal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter
    }()
}
