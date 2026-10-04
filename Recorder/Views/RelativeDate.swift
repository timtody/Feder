import Foundation

extension Date {
    /// "Today at 12:00", "Yesterday at 12:00", "Last Wednesday at 12:00" within the past week, otherwise
    /// "Thu, 1st October at 12:00" (with the year when it isn't the current one). The words are English like the rest
    /// of the UI; the time follows the region's 12/24-hour setting (English for that region, e.g. en_DE -> "12:00").
    func relativeDayText(now: Date = .now, calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
        let time = formatted(.dateTime.hour().minute().locale(locale))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let day: String
        switch days {
        case 0: day = "Today"
        case 1: day = "Yesterday"
        case 2...6: day = "Last " + formatted(.dateTime.weekday(.wide).locale(locale))
        default:
            let ordinal = NumberFormatter()
            ordinal.numberStyle = .ordinal
            ordinal.locale = locale
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
