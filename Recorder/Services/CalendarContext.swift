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
/// and the event's invitees are offered in the rename sheet. Opt-in, off until the user turns it on in Settings ›
/// Recording, and the calendar permission is asked only on that tap: iOS 17's full access means read, change and delete
/// all events, and the system alert says so, so it is never asked at Transcribe (it would collide with the microphone's
/// alert and cover the live recording) or at Stop (where location asks). Not from an onboarding page: a page before
/// the system alert must lead to it with a single Continue (HIG › Privacy, App Review 5.1.1(iv)), and one with a way
/// out ("No Thanks") is a common rejection.
///
/// The press does no I/O ("every press answers in its frame"): the events of today and tomorrow are read off the main
/// actor into an in-memory cache (`CalendarReader`), at launch when it is on, on every return to the foreground, when
/// the calendar changes (debounced 1 s), at a significant time change (midnight, a new time zone) and once access is
/// given. `AppServices.makeRecordingSession` hands this to the session only while it is on, and the session picks the
/// event from the cache (`event(at:)`, a scan of a few dozen structs). A press can come before the read that makes the
/// cache current has ended: on a cold launch from outside the app (Control Center, the Action Button, Siri, the widget)
/// before the first one, on a return to the foreground before the one that catches up on changes made meanwhile (a
/// meeting cancelled or moved on the Mac). The session then picks again from that read once it has prepared
/// (`recheck`). The cache lives in memory only; what a transcript keeps is the event's title and its invitees' names
/// (`Recording.calendarEventTitle`, `calendarAttendees`), written at Stop.
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
    /// Counts the reads that filled the cache. A session notes it at the press, so after preparing it can tell whether
    /// the cache it picked from has been read again since (`recheck`).
    @ObservationIgnored private(set) var generation = 0
    /// Presses waiting for the running read (`recheck`), resumed when it ends or when their wait is over.
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var changeDebounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let reader = CalendarReader()

    init() {
        #if DEBUG && targetEnvironment(simulator)
        _ = CalendarFake.launchedAt                                // `-fakeCalendarLaterAfter` counts from here
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

    /// What a recheck after preparing found: `.unchanged` when no read has filled the cache since the press (its pick
    /// stands), else the event for the press from the newer cache (nil: none any more).
    enum Recheck: Equatable { case unchanged, event(CalendarEvent?) }

    /// The press's pick again, from a read that ended after the cache it was made from (`generation` at the press):
    /// one still running at the press (a cold launch's first read), one the return to the foreground started (a
    /// suspended app reads changes made meanwhile only then, and a press from Control Center or the Action Button
    /// comes with that return), or one due now (the cache doesn't cover `date`). Waits at most `limit` for a running
    /// read; returns at once when none runs and the cache is still the press's. Switched off meanwhile: `.unchanged`
    /// (the name stays as shown, as at Stop).
    func recheck(at date: Date, pickedFrom generation: Int, waitingUpTo limit: Duration) async -> Recheck {
        guard Self.isEnabled else { return .unchanged }
        if refreshing == nil, window?.contains(date) != true { refresh() }
        await waitForRead(upTo: limit)
        guard Self.isEnabled, self.generation != generation else { return .unchanged }
        return .event(event(at: date))
    }

    /// Returns when the running read has ended or after `limit`, whichever comes first. Not a task group racing
    /// `refreshing.value` against a sleep: awaiting a task's value ignores cancellation, so the group waited for the
    /// whole read however long it took, and a slow calendar held up the recording's start.
    private func waitForRead(upTo limit: Duration) async {
        guard refreshing != nil else { return }
        let id = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.waiters.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { waiters[id] = $0 }
        timeout.cancel()
    }

    // MARK: The switch

    enum EnableResult { case enabled, declined, needsSettings }

    /// Settings' switch turned on: asks for full access when it was never asked (the system alert), then stores the
    /// switch on and reads the calendar. `.declined`: the user said no in the alert just
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

    /// "Open Settings" in the switch's "Allow Calendar Access" alert: the user chose the feature, so it is stored on
    /// now. The switch still shows off while access is denied (`isUsable`), and turns on by itself once they come back
    /// with access given: iOS doesn't relaunch an app that was given a permission, so they came back to the switch
    /// still off and had to find it and tap it again; now the read on the return (didBecomeActive) finds the access.
    /// Not given, nothing is read (each read only checks the status) and no press finds an event.
    func enableWhenAllowed() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
    }

    /// The switch off: nothing is read any more and the cache is emptied. Transcripts keep the names and invitees they
    /// have, as Save Location keeps places.
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
                generation += 1
                #if DEBUG
                print("[Scribe] calendar: \(events.count) events in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))")
                #endif
            } while again
            refreshing = nil
            lastRead = .now
            let waiting = waiters.values
            waiters = [:]
            for waiter in waiting { waiter.resume() }
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
    #if DEBUG && targetEnvironment(simulator)
    private var fakeStatusReads = 0                       // `-fakeCalendarAccess deniedFirst`
    #endif

    func status() -> CalendarAccess {
        #if DEBUG && targetEnvironment(simulator)
        if let fake = CalendarFake.access {
            fakeStatusReads += 1
            return CalendarFake.deniedFirst && fakeStatusReads > 1 ? .granted : fake
        }
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
/// `-fakeCalendarEvent "<event>;<event>…"` puts events into the cache at each read, and access counts as given. Each is
/// `Title[@start+minutes][!flag,…][|Attendee|…]`: by default from 10 minutes before the read to 50 minutes after it
/// (`@-60+420`: from an hour before for seven hours; `@+4+30`: in four minutes for half an hour), in a calendar the
/// user can change, organized by them. Flags: `allday`; `canceled`; `declined` (the user declined it); `others`
/// (someone else's: not organized by the user, who is on it only when an attendee is marked `*`); `shared` (someone
/// else's in a calendar shared with the user read-only).
/// Everything runs through the same CalendarRules as EventKit's, the attendees too: a leading `*` marks the user, `#`
/// a room, `-` someone who declined, `~` a non-participant ("Design Review|Maria Lopez|Berger, Tom|tom@example.com|
/// *Julius Taylor|#Room 4.12|-Paul Declined"). `-fakeCalendarEventLater <events>` with `-fakeCalendarLaterAfter <s>`:
/// reads starting that long after launch find those instead (the calendar changed on another device meanwhile).
/// `-fakeCalendarDelay <s>`: every read takes that long (a cold launch's race). `-fakeCalendarAccess
/// denied|granted|deniedFirst`: what the status and the request say, without the system alert; `deniedFirst`: denied
/// when first asked, given from then on (allowed in the iPhone's Settings).
nonisolated enum CalendarFake {
    static var spec: String? { UserDefaults.standard.string(forKey: "fakeCalendarEvent") }
    static var delay: Double { UserDefaults.standard.double(forKey: "fakeCalendarDelay") }
    static let launchedAt = Date.now                      // touched in CalendarContext.init
    static var deniedFirst: Bool { UserDefaults.standard.string(forKey: "fakeCalendarAccess") == "deniedFirst" }
    static var access: CalendarAccess? {
        switch UserDefaults.standard.string(forKey: "fakeCalendarAccess") {
        case "denied", "deniedFirst": .denied
        case "granted": .granted
        default: spec == nil ? nil : .granted
        }
    }
    static var isActive: Bool { spec != nil || access != nil }

    static func events(now: Date) -> [CalendarEvent] {
        let defaults = UserDefaults.standard
        let later = defaults.string(forKey: "fakeCalendarEventLater")
        let isLater = later != nil && now.timeIntervalSince(launchedAt) >= defaults.double(forKey: "fakeCalendarLaterAfter")
        guard let spec = isLater ? later : spec else { return [] }
        return spec.split(separator: ";").compactMap { event(String($0), now: now) }
    }

    private static func event(_ spec: String, now: Date) -> CalendarEvent? {
        let parts = spec.split(separator: "|").map(String.init)
        guard var head = parts.first else { return nil }
        var flags: Set<Substring> = []
        if let bang = head.lastIndex(of: "!") {
            flags = Set(head[head.index(after: bang)...].split(separator: ","))
            head = String(head[..<bang])
        }
        var start = now.addingTimeInterval(-600), end = now.addingTimeInterval(3000)
        if let at = head.lastIndex(of: "@") {
            let times = head[head.index(after: at)...]       // "-60+420", "+4+30"
            if let plus = times.dropFirst().firstIndex(of: "+"), let from = Double(times[..<plus]),
               let minutes = Double(times[times.index(after: plus)...]) {
                start = now.addingTimeInterval(from * 60)
                end = start.addingTimeInterval(minutes * 60)
                head = String(head[..<at])
            }
        }
        var attendees = parts.dropFirst().map { raw -> CalendarParticipant in
            var participant = CalendarParticipant(name: String(raw.drop { "*#-~".contains($0) }))
            participant.isCurrentUser = raw.hasPrefix("*")
            participant.isPerson = !raw.hasPrefix("#")
            participant.declined = raw.hasPrefix("-")
            participant.isNonParticipant = raw.hasPrefix("~")
            return participant
        }
        if flags.contains("declined") { attendees.append(CalendarParticipant(name: "Me", isCurrentUser: true, declined: true)) }
        let shared = flags.contains("shared"), others = shared || flags.contains("others")
        return CalendarRules.event(title: head, start: start, end: end, isAllDay: flags.contains("allday"),
                                   isCanceled: flags.contains("canceled"), attendees: attendees,
                                   organizer: others ? nil : CalendarParticipant(name: "Me", isCurrentUser: true),
                                   calendarIsWritable: !shared)
    }
}
#endif
