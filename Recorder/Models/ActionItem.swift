import Foundation

/// A to-do Gemma found in a transcript (ActionItemExtractor): who does what by when, as the conversation said it.
/// Stored encoded in `Recording.actionItems`. Every field is decided now: Swift's synthesized `Decodable` ignores
/// default values, so a field added later must be Optional, or the stored arrays stop decoding.
/// The owner is text, not a speaker number: the corrections and Try Again renumber the speakers (`compaction`,
/// `renumberSpeakers`), and a number would then name the wrong person; like the summary, a later rename doesn't change it.
nonisolated struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// "Send the numbers to finance": a short instruction, in the app's language of the moment it was found.
    var task: String
    /// A name as the transcript had it; nil when nobody was named (never "Speaker N").
    var owner: String?
    /// The deadline as it was said ("by Friday", "before the workshop"), nil without one.
    var duePhrase: String?
    /// `duePhrase` resolved relative to the recording (DueDate), when it could be; stored at extraction.
    var due: Date?
    /// A time of day was said ("at 3 pm", "17 Uhr"); otherwise `due` is a day (its 12:00).
    var dueHasTime: Bool = false
    /// When the user added it to Reminders or Calendar from the card.
    var addedToReminders: Date?
    var addedToCalendar: Date?
    /// The user removed it: kept, hidden, so a later extraction (a new `ActionItemExtractor.version`) doesn't bring it
    /// back.
    var isRemoved: Bool = false

    var isAdded: Bool { addedToReminders != nil || addedToCalendar != nil }

    /// What makes two tasks the same: case, accents, punctuation and spacing ignored ("Send the numbers to finance." and
    /// "send the numbers to Finance").
    static func key(_ task: String) -> String {
        SearchFolding.fold(task)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// `items` without repeats (the same task from two parts of a long transcript, by `key`), the first kept, at most
    /// `limit`.
    static func deduplicated(_ items: [ActionItem], limit: Int) -> [ActionItem] {
        var seen: Set<String> = []
        var kept: [ActionItem] = []
        for item in items where kept.count < limit && seen.insert(key(item.task)).inserted {
            kept.append(item)
        }
        return kept
    }

    /// A new extraction over what the transcript had: an item found again keeps its id, when it was added and whether
    /// it was removed (matched by `key`), so a new version never brings back a removed item or forgets that one was
    /// added. Old items the new extraction didn't find stay when the user did something with them (added: they are in
    /// Reminders or Calendar; removed: hidden, still remembered), the others go.
    static func merged(_ new: [ActionItem], keepingFlagsOf old: [ActionItem]) -> [ActionItem] {
        var previous: [String: ActionItem] = [:]
        for item in old where previous[key(item.task)] == nil { previous[key(item.task)] = item }
        var matched: Set<String> = []
        var result = new.map { item in
            let itemKey = key(item.task)
            guard let before = previous[itemKey] else { return item }
            matched.insert(itemKey)
            var kept = item
            kept.id = before.id
            kept.addedToReminders = before.addedToReminders
            kept.addedToCalendar = before.addedToCalendar
            kept.isRemoved = before.isRemoved
            return kept
        }
        result += old.filter { !matched.contains(key($0.task)) && ($0.isAdded || $0.isRemoved) }
        return result
    }
}

/// An action item as text: the card's caption, the line in exports and Copy, the notes of a reminder or event. Dates in
/// the app's language (`AppLanguage`) with the region's formats, as the card's other dates.
nonisolated enum ActionItemText {
    static let locale = Locale(identifier: AppLanguage.code + "_" + (Locale.current.region?.identifier ?? "US"))

    /// The due date as the card shows it ("Fri, 16 Oct", "Fri, 16 Oct, 15:00"; the year when it isn't this year's),
    /// else the phrase as it was said; nil without either.
    static func due(_ item: ActionItem, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let due = item.due else { return item.duePhrase }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)
        if !calendar.isDate(due, equalTo: now, toGranularity: .year) { style = style.year() }
        if item.dueHasTime { style = style.hour().minute() }
        return due.formatted(style)
    }

    /// The line under the task: owner · due · In Reminders · In Calendar (what there is of it).
    static func caption(_ item: ActionItem) -> String? {
        let parts = [item.owner, due(item)].compactMap { $0 } + places(item)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where it was added, "In Reminders, In Calendar", nil when nowhere: the item menu's VoiceOver value (its
    /// checkmark).
    static func added(_ item: ActionItem) -> String? {
        let places = places(item)
        return places.isEmpty ? nil : places.joined(separator: ", ")
    }

    private static func places(_ item: ActionItem) -> [String] {
        [item.addedToReminders.map { _ in String(localized: "In Reminders") },
         item.addedToCalendar.map { _ in String(localized: "In Calendar") }].compactMap { $0 }
    }

    /// "Send the numbers to finance (Anna Schmidt, Friday, 16 October 2026)": the exports' and Copy's line.
    static func line(_ item: ActionItem) -> String {
        var details: [String] = []
        if let owner = item.owner { details.append(owner) }
        if let due = item.due {
            var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year().locale(locale)
            if item.dueHasTime { style = style.hour().minute() }
            details.append(due.formatted(style))
        } else if let phrase = item.duePhrase {
            details.append(phrase)
        }
        return details.isEmpty ? item.task : "\(item.task) (\(details.joined(separator: ", ")))"
    }

    /// The Action Items sheet's Share: a heading with the transcript's title, then one line per item ("• " and `line`),
    /// plain text that reads the same in Messages, Mail and Notes.
    static func list(_ items: [ActionItem], transcript title: String) -> String {
        ([String(localized: "Action Items from “\(title)”")] + items.map { "• " + line($0) }).joined(separator: "\n")
    }

    /// A reminder's or event's notes: "Anna Schmidt · From “Budget Review”, 6 Oct 2026" (the transcript's link is the
    /// item's URL).
    static func notes(_ item: ActionItem, transcript title: String, recordedAt: Date) -> String {
        let date = recordedAt.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        let source = String(localized: "From “\(title)”, \(date)")
        return [item.owner, source].compactMap { $0 }.joined(separator: " · ")
    }
}
