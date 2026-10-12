import EventKit
import EventKitUI
import Foundation
import UIKit

/// An action item as a reminder or a calendar event (the card's Action Items row): what goes into Apple's Reminders or
/// Calendar, and only on the user's tap. They sync with the user's own accounts (iCloud, Exchange, Google), like a
/// shared file: the user's choice (Legal.json says so).
nonisolated struct ReminderDraft: Sendable {
    var title: String
    var notes: String
    var url: URL
    /// Year, month and day: an all-day reminder; with hour and minute when a time was said.
    var due: DateComponents?
    /// Only when a time was said: an all-day reminder gets Reminders' own all-day notification.
    var alarm: Date?

    @MainActor
    init(_ item: ActionItem, in recording: Recording, calendar: Calendar = .current) {
        title = item.task
        notes = ActionItemText.notes(item, transcript: recording.name, recordedAt: recording.createdAt)
        url = FederURL.transcript(recording.id)
        if let date = item.due {
            due = calendar.dateComponents(item.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day],
                                          from: date)
            alarm = item.dueHasTime ? date : nil
        }
    }
}

/// Writes reminders with EventKit, off the main actor: one long-lived `EKEventStore` (not Sendable, and slow to create
/// per Apple, so it lives here and is made once, at the first use). Asks for full access to Reminders at the first Add
/// to Reminders, never before: iOS has no write-only access for reminders. Reads nothing.
actor ReminderWriter {
    static let shared = ReminderWriter()

    nonisolated enum Failure: Error {
        case noList                  // Reminders has no list to add to (defaultCalendarForNewReminders is nil)
    }

    private var store: EKEventStore?

    private var eventStore: EKEventStore {
        if let store { return store }
        let made = EKEventStore()
        store = made
        return made
    }

    /// Adds the drafts to Reminders' default list, all or none (one commit), once Feder has full access: asked for the
    /// first time (iOS's alert; afterwards iOS answers with the earlier choice). false: not allowed (denied now or
    /// before, or restricted), nothing added.
    func add(_ drafts: [ReminderDraft]) async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            break
        case .notDetermined:
            guard try await eventStore.requestFullAccessToReminders() else { return false }
        default:
            return false
        }
        try save(drafts)
        return true
    }

    private func save(_ drafts: [ReminderDraft]) throws {
        let store = eventStore
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList }
        do {
            for draft in drafts {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = draft.title
                reminder.notes = draft.notes
                reminder.url = draft.url
                reminder.dueDateComponents = draft.due
                if let alarm = draft.alarm { reminder.addAlarm(EKAlarm(absoluteDate: alarm)) }
                try store.save(reminder, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()                                     // nothing half-added
            throw error
        }
    }
}

/// An action item as a calendar event, shown in Apple's own New Event editor (EventKitUI) for the user to check and
/// add. Since iOS 17 the editor runs in another process and needs no calendar access, so Feder asks for none (WWDC23
/// "Discover Calendar and EventKit"); it also gives no event back, so an item counts as added when the editor reports
/// `.saved`, and no event id is kept.
nonisolated struct EventDraft: Sendable {
    var title: String
    var notes: String
    var url: URL
    var due: Date?
    var hasTime: Bool

    @MainActor
    init(_ item: ActionItem, in recording: Recording) {
        title = item.task
        notes = ActionItemText.notes(item, transcript: recording.name, recordedAt: recording.createdAt)
        url = FederURL.transcript(recording.id)
        due = item.due
        hasTime = item.dueHasTime
    }
}

@MainActor
enum EventEditor {
    /// One store for the editor, made once (`warmUp`, when the Action Items row opens), so the press doesn't make it.
    private static var store: EKEventStore?
    /// The editor's delegate, kept while the editor is up (the controller holds it weakly).
    private static var delegate: Delegate?

    static func warmUp() async {
        guard store == nil else { return }
        let made = await makeStore()
        if store == nil { store = made }
    }

    /// Also makes one event: the store's first `EKEvent` took 76 ms on the main actor in the press (the next 1 ms;
    /// iOS 27 simulator), here it is off it.
    @concurrent
    nonisolated private static func makeStore() async -> sending EKEventStore {
        let store = EKEventStore()
        _ = EKEvent(eventStore: store)
        return store
    }

    /// Presents Apple's New Event editor prefilled with `draft`, at once over whatever is frontmost (the card's full-screen
    /// cover); `onSaved` runs when the user added it. A time said: that hour, one hour long; a day: all day; none: the
    /// next full hour today.
    static func present(_ draft: EventDraft, onSaved: @escaping @MainActor () -> Void) {
        guard let top = topViewController() else { return }
        let store = self.store ?? EKEventStore()
        self.store = store
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.notes = draft.notes
        event.url = draft.url
        let calendar = Calendar.current
        if let due = draft.due, draft.hasTime {
            event.startDate = due
            event.endDate = due.addingTimeInterval(3_600)
        } else if let due = draft.due {
            event.isAllDay = true
            event.startDate = calendar.startOfDay(for: due)
            event.endDate = event.startDate
        } else {
            let hour = calendar.dateInterval(of: .hour, for: .now)?.end ?? .now
            event.startDate = hour
            event.endDate = hour.addingTimeInterval(3_600)
        }
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        let delegate = Delegate(onSaved: onSaved)
        self.delegate = delegate
        controller.editViewDelegate = delegate
        top.present(controller, animated: true)
    }

    /// The frontmost view controller (as ShareSheet presents).
    private static func topViewController() -> UIViewController? {
        guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// Dismisses the editor (the delegate must) and reports Add.
    private final class Delegate: NSObject, EKEventEditViewDelegate {
        let onSaved: @MainActor () -> Void

        init(onSaved: @escaping @MainActor () -> Void) {
            self.onSaved = onSaved
        }

        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true)
            if action == .saved { onSaved() }
            if EventEditor.delegate === self { EventEditor.delegate = nil }
        }
    }
}
