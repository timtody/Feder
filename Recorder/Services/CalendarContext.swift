import EventKit
import Foundation
import Observation
import UIKit

/// What Feder may do with the calendar, as far as it knows.
nonisolated enum CalendarAccess: Sendable, Equatable {
    case unknown          // not read yet this launch (the switch shows what was stored meanwhile)
    case notDetermined    // never asked
    case writeOnly        // write-only access was given: reading needs the upgrade, asked once
    case denied           // denied or restricted: only the iPhone's Settings can change it
    case granted          // full access
}

/// "Name from Calendar" (roadmap #11): a transcript started during a calendar event gets the event's title as its name,
/// and the event's invitees are offered in the rename sheet. Opt-in, off until the user turns it on (the onboarding's
/// Calendar page or Settings › Recording), and the calendar permission is asked only on that tap: iOS 17's full access
/// means read, change and delete all events, and the system alert says so, so it is never asked at Transcribe (it would
/// collide with the microphone's alert and cover the live recording) or at Stop (where location asks).
///
/// The press does no I/O ("every press answers in its frame"): the events of today and tomorrow are read off the main
/// actor into an in-memory cache (`CalendarReader`), at launch when it is on, on every return to the foreground, when
/// the calendar changes (debounced 1 s), at a significant time change (midnight, a new time zone) and once access is
/// given. `AppServices.makeRecordingSession` hands this to the session only while it is on, and the session picks the
/// event from the cache (`event(at:)`, a scan of a few dozen structs). A cold launch from outside the app (Control
/// Center, the Action Button, Siri, the widget) can press before the first read has finished: the session then takes
/// what that read finds while it prepares (`pendingEvent`). The cache lives in memory only; what a transcript keeps is
/// the event's title and its invitees' names (`Recording.calendarEventTitle`, `calendarAttendees`), written at Stop.
@MainActor @Observable
final class CalendarContext {
    /// UserDefaults: "Name from Calendar"; absent means off.
    nonisolated static let enabledKey = "calendarContext"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Read off the main actor at every refresh, after a request and when the switch is turned on; Settings reads it.
    private(set) var access: CalendarAccess = .unknown
    /// The switch may show on: access is given, or not known yet this launch (so it doesn't flicker off at launch).
    var isUsable: Bool { access == .unknown || access == .granted }

    /// The events of `window`; empty and nil while off or without access.
    @ObservationIgnored private var events: [CalendarEvent] = []
    @ObservationIgnored private var window: DateInterval?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// A refresh asked for while one runs runs once more after it (a change during the read isn't lost).
    @ObservationIgnored private var again = false
    /// When the last read ended: the launch's read usually ends just before the app becomes active, which needs no
    /// second one.
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var changeDebounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let reader = CalendarReader()

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // UI tests: `-calendarOn` stores the switch on, `-resetCalendar` removes it (a new install's state). Tests that
        // only need it on pass `-calendarContext YES` instead (the argument domain), which doesn't outlast the launch.
        if ProcessInfo.processInfo.arguments.contains("-resetCalendar") {
            UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        } else if ProcessInfo.processInfo.arguments.contains("-calendarOn") {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
        #endif
        observe()
        if Self.isEnabled { refresh() }              // warm before a cold launch's Transcribe
    }

    // MARK: The press

    /// The event a transcript started at `date` is named after, from the cache (no EventKit call). nil while off, without
    /// access, or when the cache doesn't cover `date` (not read yet, or stale).
    func event(at date: Date) -> CalendarEvent? {
        guard Self.isEnabled, let window, window.contains(date) else { return nil }
        return CalendarRules.pick(events, at: date)
    }

    /// For a press that found no event: the event once a read still running (a cold launch) or due (the cache doesn't
    /// cover `date`) has finished, waiting at most `limit` for it. Returns at once when the cache is current.
    func pendingEvent(at date: Date, waitingUpTo limit: Duration) async -> CalendarEvent? {
        guard Self.isEnabled else { return nil }
        if refreshing == nil, window?.contains(date) != true { refresh() }
        if let refreshing {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await refreshing.value }
                group.addTask { try? await Task.sleep(for: limit) }
                await group.next()
                group.cancelAll()
            }
        }
        return event(at: date)
    }

    // MARK: The switch

    enum EnableResult { case enabled, declined, needsSettings }

    /// The onboarding's "Name from Calendar" and Settings' switch: asks for full access when it was never asked (the
    /// system alert), then stores the switch on and reads the calendar. `.declined`: the user said no in the alert just
    /// now; `.needsSettings`: denied before (or restricted), or write-only access that wasn't upgraded, so only the
    /// iPhone's Settings can allow it (the caller offers Open Settings).
    func enable() async -> EnableResult {
        let status = await reader.status()
        switch status {
        case .granted:
            break
        case .notDetermined, .writeOnly, .unknown:
            guard await reader.requestFullAccess() else {
                access = status == .writeOnly ? .writeOnly : .denied
                return status == .writeOnly ? .needsSettings : .declined
            }
        case .denied:
            access = .denied
            return .needsSettings
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        access = .granted
        refresh()
        return .enabled
    }

    /// The switch off (Settings, the onboarding's No Thanks): nothing is read any more and the cache is emptied.
    /// Transcripts keep the names and invitees they have, as Save Location keeps places.
    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        changeDebounce?.cancel()
        clear()
    }

    // MARK: Reading

    /// Reads the events of today and tomorrow off the main actor into the cache; once more after a running read when
    /// asked meanwhile. Off: empties the cache instead.
    func refresh() {
        guard Self.isEnabled else { clear(); return }
        guard refreshing == nil else { again = true; return }
        refreshing = Task {
            repeat {
                again = false
                let window = Self.window(around: .now)
                #if DEBUG
                let started = ContinuousClock.now
                #endif
                let (access, events) = await reader.events(in: window)
                guard Self.isEnabled else { clear(); break }           // turned off during the read
                self.access = access
                self.events = events
                self.window = access == .granted ? window : nil
                #if DEBUG
                print("[Scribe] calendar: \(events.count) events in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))")
                #endif
            } while again
            refreshing = nil
            lastRead = .now
        }
    }

    private func clear() {
        events = []
        window = nil
    }

    /// The start of today to the start of the day after tomorrow: EventKit returns the events overlapping it, so one
    /// running past midnight is in, and a cache read before midnight still covers the next day.
    nonisolated static func window(around date: Date) -> DateInterval {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 2, to: today) ?? date.addingTimeInterval(2 * 86_400)
        return DateInterval(start: today, end: end)
    }

    /// The calendar changed (debounced: a sync delivers changes in bursts), the day or time zone changed, the app came
    /// to the foreground (a suspended app may have missed changes; not while a read runs or one just ended, which is
    /// current).
    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.storeChanged() }          // queue: .main => main thread
            },
            center.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.refreshing == nil,
                          self.lastRead.map({ .now - $0 > .seconds(2) }) ?? true else { return }
                    self.refresh()
                }
            },
        ]
    }

    private func storeChanged() {
        guard Self.isEnabled else { return }
        changeDebounce?.cancel()
        changeDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.refresh()
        }
    }
}

/// Owns the app's one `EKEventStore` (Apple: expensive to create, keep one for the app's lifetime; created on the first
/// read, never at launch while the switch is off) and reads it off the main actor: `events(matching:)` is synchronous.
/// EventKit's objects aren't Sendable, so they stay in here and only `CalendarEvent`s leave.
actor CalendarReader {
    private var store: EKEventStore?

    func status() -> CalendarAccess {
        #if DEBUG && targetEnvironment(simulator)
        if let fake = CalendarFake.access { return fake }
        #endif
        return switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        default: .denied                                  // denied, restricted
        }
    }

    /// The events overlapping `window` that can name a transcript (CalendarRules.event), with the access they were read
    /// with. Nothing without full access.
    func events(in window: DateInterval) async -> (CalendarAccess, [CalendarEvent]) {
        #if DEBUG && targetEnvironment(simulator)
        if CalendarFake.isActive {
            if CalendarFake.delay > 0 { try? await Task.sleep(for: .seconds(CalendarFake.delay)) }
            let access = status()
            return (access, access == .granted ? CalendarFake.events(now: .now) : [])
        }
        #endif
        let access = status()
        guard access == .granted else {
            store = nil
            return (access, [])
        }
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        return (access, store.events(matching: predicate).compactMap(Self.event))
    }

    /// The system's full-access alert (iOS 17+; asked once, also to upgrade write-only access). Asked on a store of
    /// its own: the actor's store can't be handed to the imported async call (not Sendable). A store made before access
    /// was given may not see the events, so the next read makes a new one.
    func requestFullAccess() async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if let fake = CalendarFake.access { return fake == .granted }
        #endif
        let granted = await Self.request()
        if granted { store = nil }
        return granted
    }

    @concurrent
    nonisolated private static func request() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Birthdays and subscribed calendars (holidays, sports) never name a transcript.
    nonisolated private static func event(_ event: EKEvent) -> CalendarEvent? {
        guard let calendar = event.calendar, calendar.type != .birthday, calendar.type != .subscription,
              !calendar.isSubscribed, let start = event.startDate, let end = event.endDate else { return nil }
        return CalendarRules.event(title: event.title, start: start, end: end, isAllDay: event.isAllDay,
                                   isCanceled: event.status == .canceled,
                                   attendees: (event.attendees ?? []).map(participant),
                                   organizer: event.organizer.map(participant),
                                   calendarIsWritable: calendar.allowsContentModifications)
    }

    nonisolated private static func participant(_ participant: EKParticipant) -> CalendarParticipant {
        CalendarParticipant(name: participant.name, isCurrentUser: participant.isCurrentUser,
                            isPerson: participant.participantType == .person || participant.participantType == .unknown,
                            isNonParticipant: participant.participantRole == .nonParticipant,
                            declined: participant.participantStatus == .declined)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator QA without EventKit (the simulator has no accounts with invitations, and `attendees` can't be set):
/// `-fakeCalendarEvent "Title|Attendee|…"` puts one event from 10 minutes before each read to 50 minutes after it into
/// the cache, the user taking part, and access counts as given. Its attendees run through the same CalendarRules as
/// EventKit's: a leading `*` marks the user, `#` a room, `-` someone who declined, `~` a non-participant ("Maria
/// Lopez|Berger, Tom|tom@example.com|*Julius Taylor|#Room 4.12|-Paul Declined"). `-fakeCalendarDelay <s>`: every read
/// takes that long (a cold launch's race). `-fakeCalendarAccess denied|granted`: what the status and the request say,
/// without the system alert.
nonisolated enum CalendarFake {
    static var spec: String? { UserDefaults.standard.string(forKey: "fakeCalendarEvent") }
    static var delay: Double { UserDefaults.standard.double(forKey: "fakeCalendarDelay") }
    static var access: CalendarAccess? {
        switch UserDefaults.standard.string(forKey: "fakeCalendarAccess") {
        case "denied": .denied
        case "granted": .granted
        default: spec == nil ? nil : .granted
        }
    }
    static var isActive: Bool { spec != nil || access != nil }

    static func events(now: Date) -> [CalendarEvent] {
        guard let spec else { return [] }
        let parts = spec.split(separator: "|").map(String.init)
        guard let title = parts.first else { return [] }
        let attendees = parts.dropFirst().map { raw -> CalendarParticipant in
            var participant = CalendarParticipant(name: String(raw.drop { "*#-~".contains($0) }))
            participant.isCurrentUser = raw.hasPrefix("*")
            participant.isPerson = !raw.hasPrefix("#")
            participant.declined = raw.hasPrefix("-")
            participant.isNonParticipant = raw.hasPrefix("~")
            return participant
        }
        let me = CalendarParticipant(name: "Me", isCurrentUser: true)
        let event = CalendarRules.event(title: title, start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3000),
                                        isAllDay: false, isCanceled: false, attendees: Array(attendees), organizer: me,
                                        calendarIsWritable: true)
        return event.map { [$0] } ?? []
    }
}
#endif
