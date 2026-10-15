import CryptoKit
import Foundation

/// A calendar event as Feder keeps it in memory (`CalendarContext`): the title offered as the name of a transcript
/// started during it and its invitees' names, which the rename sheet offers. Made from EventKit's `EKEvent` inside
/// `CalendarReader` (and from the simulator's fake), so only these values cross actors. Nothing else of the event is
/// kept: no identifier, location, notes, URL or e-mail address; only its calendar's identifier, in memory, for the
/// Preferred Calendar.
nonisolated struct CalendarEvent: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    /// Display names (`CalendarRules.attendees`): not the user, no rooms, no addresses, at most 30.
    var attendees: [String]
    /// The user is an attendee or the organizer, or the event has no attendees: their own.
    var userTakesPart: Bool
    /// `EKCalendar.calendarIdentifier` of the calendar it is in: its events come first when it is the preferred one.
    var calendarID = ""
    /// It counts only while its calendar is the Preferred Calendar: every event of a subscribed calendar, and someone
    /// else's in a calendar the user can only read (`CalendarRules.event`).
    var onlyWhenPreferred = false
}

/// A calendar Settings' Preferred Calendar lists: by account, with its colour, as the Calendar app shows it
/// (`CalendarContext.calendars`, read with the events).
nonisolated struct CalendarChoice: Sendable, Equatable, Identifiable {
    /// `EKCalendar.calendarIdentifier`.
    var id: String
    var title: String
    /// Its account's name ("iCloud", "Exchange", "Gmail"; "On My iPhone" for local calendars, "Subscribed Calendars"
    /// for those subscribed on this iPhone).
    var account: String
    /// sRGB, 0...1: the dot in front of its name.
    var red = 0.5, green = 0.5, blue = 0.5

    /// How the preference finds it again under a new identifier (`CalendarRules.preferred`).
    var fingerprint: String { CalendarRules.fingerprint(title: title, account: account) }

    /// The calendars by account, in their order (`calendars` comes sorted by account): Settings' sections.
    static func byAccount(_ calendars: [CalendarChoice]) -> [(account: String, calendars: [CalendarChoice])] {
        var groups: [(account: String, calendars: [CalendarChoice])] = []
        for calendar in calendars {
            if groups.last?.account == calendar.account {
                groups[groups.count - 1].calendars.append(calendar)
            } else {
                groups.append((calendar.account, [calendar]))
            }
        }
        return groups
    }
}

/// The row under a transcript's date line while it has a calendar event (CalendarTitleRow), on the recording and on the
/// saved transcript alike (`CalendarRules.titleOffer`).
nonisolated enum CalendarTitleOffer: Sendable, Equatable {
    /// The event's title, with Use as Title and ⊗.
    case offer(String)
    /// The name is the event's title, taken with Use as Title: no row since FED-135 (renamed like any other name).
    case taken
}

/// An attendee or the organizer as EventKit describes them, reduced to what `CalendarRules` decides on.
nonisolated struct CalendarParticipant: Sendable, Equatable {
    var name: String?
    /// EventKit's `isCurrentUser`. Not reliable on every account type (CalDAV, Google): the user's own name can then
    /// slip into the invitees, which is harmless (only an offer).
    var isCurrentUser = false
    /// A person (or EventKit doesn't know); false for a room, a resource or a group.
    var isPerson = true
    /// `participantRole == .nonParticipant`: copied in for information, not invited.
    var isNonParticipant = false
    var declined = false
}

/// The rules of calendar naming, pure so the simulator's fake runs them too: which events count, which one a transcript
/// started at a press belongs to, the row offering its title, and the invitees' names as the rename sheet offers them.
nonisolated enum CalendarRules {
    /// Pressing Transcribe up to this long before an event starts counts as during it (people come in early).
    static let lead: TimeInterval = 5 * 60
    /// An all-hands with 300 invitees would bury the rename sheet: the organizer first, then the event's order.
    static let maxAttendees = 30
    /// A title longer than this is cut (a pasted agenda as the title).
    static let maxTitleLength = 100

    /// The event as Feder keeps it, or nil when it never counts: all-day, cancelled, declined by the user,
    /// without a title, or Feder's own (`isFeders`: an action item added with Add to Calendar, which carries the
    /// transcript's feder:// link; prefilled on the full hour without attendees, it counted as the user's own and,
    /// shorter, beat the meeting starting with it, so the transcript got the to-do's name and none of the invitees).
    /// Someone else's in a calendar the user can only read, and every event of a subscribed calendar, is kept but
    /// counts only while that calendar is the Preferred Calendar (`onlyWhenPreferred`).
    static func event(title rawTitle: String?, start: Date, end: Date, isAllDay: Bool, isCanceled: Bool,
                      attendees: [CalendarParticipant], organizer: CalendarParticipant?,
                      calendarIsWritable: Bool, calendarIsSubscribed: Bool = false, isFeders: Bool = false,
                      calendarID: String = "") -> CalendarEvent? {
        guard !isAllDay, !isCanceled, !isFeders, end > start, let title = title(rawTitle) else { return nil }
        if attendees.contains(where: { $0.isCurrentUser && $0.declined }) { return nil }
        // An event the user is invited to or organizes is theirs. One they aren't on, in a calendar they can only read
        // (a partner's calendar shared view-only, a colleague's delegated Exchange or Google calendar), counts only
        // while that calendar is the Preferred Calendar (`pick`), not merely ranked last: whenever nothing of the
        // user's own ran, its "Therapy" or "1:1 HR" named their private conversation (also on the Lock Screen) and its
        // invitees were stored with it. The same holds for every event of a subscribed calendar (an Outlook calendar
        // published as a link, holidays, sports fixtures; read-only, the user never marked): counted always, a match
        // on TV would be offered for the user's own conversation. Choosing such a calendar is the user's word that its
        // events are theirs, so a work calendar reaching the iPhone read-only (FED-65: Outlook's) offers their meetings.
        // In a calendar the user can change it counts, after their own: there it is theirs when it has no attendees,
        // and Google and CalDAV don't always mark the user (`isCurrentUser`), so their own invitation can look like
        // someone else's. (Calendars hidden in the Calendar app are read like the others: EventKit doesn't say which
        // are hidden.)
        let isUser = attendees.contains(where: \.isCurrentUser) || organizer?.isCurrentUser == true
        return CalendarEvent(title: title, start: start, end: end,
                             attendees: self.attendees(attendees, organizer: organizer),
                             userTakesPart: isUser || attendees.isEmpty, calendarID: calendarID,
                             onlyWhenPreferred: calendarIsSubscribed || !(isUser || calendarIsWritable))
    }

    /// Trimmed, one line, at most `maxTitleLength` characters; nil when nothing is left.
    static func title(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard line.count > maxTitleLength else { return line }
        return String(line.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The invitees' display names: the organizer first (when not listed already), then the attendees in the event's
    /// order. Left out: the user, rooms, resources and groups, people copied in without taking part, those who declined,
    /// anyone without a name, and every name that is an address (an e-mail is never stored, and no name is guessed
    /// from one). Duplicates (case and accents ignored) once; at most `maxAttendees`.
    static func attendees(_ attendees: [CalendarParticipant], organizer: CalendarParticipant?) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for participant in (organizer.map { [$0] } ?? []) + attendees {
            guard names.count < maxAttendees, !participant.isCurrentUser, participant.isPerson,
                  !participant.isNonParticipant, !participant.declined,
                  let name = displayName(participant.name) else { continue }
            if seen.insert(SearchFolding.fold(name)).inserted { names.append(name) }
        }
        return names
    }

    /// A participant's name as people say it: "Schmidt, Anna" → "Anna Schmidt" (one comma, letters on both sides), a
    /// trailing " (Company)" dropped (Exchange's directory names). nil for an empty name or an address.
    static func displayName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !name.contains("@") else { return nil }
        if name.hasSuffix(")"), let open = name.lastIndex(of: "("), open > name.startIndex {
            name = name[..<open].trimmingCharacters(in: .whitespaces)
        }
        let parts = name.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let last = parts[0].trimmingCharacters(in: .whitespaces), first = parts[1].trimmingCharacters(in: .whitespaces)
            if isName(last), isName(first) { name = "\(first) \(last)" }
        }
        return name.isEmpty ? nil : name
    }

    /// Letters, with the spaces, hyphens and apostrophes of names ("Müller-Lüdenscheidt", "O'Brien", "van der Berg").
    private static func isName(_ part: String) -> Bool {
        !part.isEmpty && part.contains(where: \.isLetter)
            && part.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" || $0 == "’" || $0 == "." }
    }

    /// The event a transcript started at `date` belongs to (its title offered, its invitees kept): one running then or
    /// starting within `lead` after it, and one that counts only in the preferred calendar (`onlyWhenPreferred`) only
    /// when it is in that one; events in the preferred calendar first (`preferring`, Settings' Preferred Calendar: the
    /// work calendar's meeting, not the private reminder block over it), then those the user takes part in, then the
    /// one starting closest to the press (at 10:01 the 10:00 meeting, not the 9:00-17:00 workshop around it), then the
    /// shorter one. nil when none qualifies; with nothing of the preferred calendar running, the others count as before.
    static func pick(_ events: [CalendarEvent], at date: Date, lead: TimeInterval = lead,
                     preferring calendarID: String? = nil) -> CalendarEvent? {
        events
            .filter { $0.start <= date.addingTimeInterval(lead) && $0.end > date
                && (!$0.onlyWhenPreferred || $0.calendarID == calendarID) }
            .min { a, b in
                if let calendarID, (a.calendarID == calendarID) != (b.calendarID == calendarID) {
                    return a.calendarID == calendarID
                }
                if a.userTakesPart != b.userTakesPart { return a.userTakesPart }
                let da = abs(a.start.timeIntervalSince(date)), db = abs(b.start.timeIntervalSince(date))
                if da != db { return da < db }
                return a.end.timeIntervalSince(a.start) < b.end.timeIntervalSince(b.start)
            }
    }

    /// The calendar row of a transcript named `name` that was started during `event` (its title, nil: none). The event
    /// never names a transcript by itself (FED-11, the user's decision): it is offered next to the name the app gave
    /// (New Transcript N, later Gemma's title) until the user takes it (Use as Title: `nameBefore` keeps the name it
    /// replaced, `.taken`), dismisses it, or types a title. nil also when the name already is the event's without Use
    /// as Title (named after it before FED-11, or Gemma chose the same words: nothing to offer, nothing to go back to).
    static func titleOffer(event: String?, name: String, nameBefore: String?, dismissed: Bool,
                           nameIsUserSet: Bool) -> CalendarTitleOffer? {
        guard let event, !event.isEmpty, !dismissed, !nameIsUserSet else { return nil }
        let isEvent = name.compare(event, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        if isEvent { return nameBefore == nil ? nil : .taken }
        return .offer(event)
    }

    /// The preferred calendar among `calendars`: by its identifier; else the one calendar with its name in an account of
    /// its name (`fingerprint`): Apple's advice, as a full sync can change an identifier, and an account added again
    /// gets new ones. nil when it isn't there any more, or when more than one match (two accounts both called
    /// "Exchange" with a "Calendar" each): the preference then counts as None and stays stored, so it is found again
    /// when the calendar comes back.
    static func preferred(id: String, fingerprint: String, in calendars: [CalendarChoice]) -> CalendarChoice? {
        if let calendar = calendars.first(where: { $0.id == id }) { return calendar }
        let matches = calendars.filter { $0.fingerprint == fingerprint }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A hash of a calendar's name and its account's name: what the preference keeps of them instead of the names. Google
    /// names the main calendar after the address, an Exchange account is often called by it, and Feder keeps no e-mail
    /// addresses (privacy policy, Calendar).
    static func fingerprint(title: String, account: String) -> String {
        SHA256.hash(data: Data("\(title)\u{1F}\(account)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
