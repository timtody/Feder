import Foundation

/// A calendar event as Feder keeps it in memory (`CalendarContext`): the title that names a transcript started during it
/// and its invitees' names, which the rename sheet offers. Made from EventKit's `EKEvent` inside `CalendarReader` (and
/// from the simulator's fake), so only these values cross actors. Nothing else of the event is kept: no identifier,
/// location, notes, URL or e-mail address.
nonisolated struct CalendarEvent: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    /// Display names (`CalendarRules.attendees`): not the user, no rooms, no addresses, at most 30.
    var attendees: [String]
    /// The user is an attendee or the organizer, or the event has no attendees: their own. False only in a calendar they
    /// can change (someone else's event in one they can only read isn't kept at all: `CalendarRules.event`).
    var userTakesPart: Bool
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

/// The rules of calendar naming, pure so the simulator's fake runs them too: which events count, which one names a
/// transcript at a press, and the invitees' names as the rename sheet offers them.
nonisolated enum CalendarRules {
    /// Pressing Transcribe up to this long before an event starts counts as during it (people come in early).
    static let lead: TimeInterval = 5 * 60
    /// An all-hands with 300 invitees would bury the rename sheet: the organizer first, then the event's order.
    static let maxAttendees = 30
    /// A title longer than this is cut (a pasted agenda as the title).
    static let maxTitleLength = 100

    /// The event as Feder keeps it, or nil when it can't name a transcript: all-day, cancelled, declined by the user,
    /// without a title, or someone else's in a calendar the user can only read.
    static func event(title rawTitle: String?, start: Date, end: Date, isAllDay: Bool, isCanceled: Bool,
                      attendees: [CalendarParticipant], organizer: CalendarParticipant?,
                      calendarIsWritable: Bool) -> CalendarEvent? {
        guard !isAllDay, !isCanceled, end > start, let title = title(rawTitle) else { return nil }
        if attendees.contains(where: { $0.isCurrentUser && $0.declined }) { return nil }
        // An event the user is invited to or organizes is theirs. One they aren't on, in a calendar they can only read
        // (a partner's calendar shared view-only, a colleague's delegated Exchange or Google calendar), is dropped
        // here, not merely ranked last: whenever nothing of the user's own ran, its "Therapy" or "1:1 HR" named their
        // private conversation (also on the Lock Screen) and its invitees were stored with it. In a calendar the user
        // can change it stays, after their own: there it is theirs when it has no attendees, and Google and CalDAV
        // don't always mark the user (`isCurrentUser`), so their own invitation can look like someone else's.
        // (Calendars hidden in the Calendar app are read like the others: EventKit doesn't say which are hidden.)
        let isUser = attendees.contains(where: \.isCurrentUser) || organizer?.isCurrentUser == true
        guard isUser || calendarIsWritable else { return nil }
        return CalendarEvent(title: title, start: start, end: end,
                             attendees: self.attendees(attendees, organizer: organizer),
                             userTakesPart: isUser || attendees.isEmpty)
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

    /// The event that names a transcript started at `date`: one running then or starting within `lead` after it;
    /// events the user takes part in first, then the one starting closest to the press (at 10:01 the 10:00 meeting,
    /// not the 9:00-17:00 workshop around it), then the shorter one. nil when none qualifies.
    static func pick(_ events: [CalendarEvent], at date: Date, lead: TimeInterval = lead) -> CalendarEvent? {
        events
            .filter { $0.start <= date.addingTimeInterval(lead) && $0.end > date }
            .min { a, b in
                if a.userTakesPart != b.userTakesPart { return a.userTakesPart }
                let da = abs(a.start.timeIntervalSince(date)), db = abs(b.start.timeIntervalSince(date))
                if da != db { return da < db }
                return a.end.timeIntervalSince(a.start) < b.end.timeIntervalSince(b.start)
            }
    }
}
