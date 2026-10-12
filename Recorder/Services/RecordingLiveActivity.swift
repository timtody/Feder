import ActivityKit
import Foundation

/// The recording's Live Activity (RecordingActivityAttributes; drawn by FederWidgets): started when the recording
/// starts, with the newest words (none while App Lock is on) and the microphone's level at most once a second (`show`: the latest values wait for
/// the next slot, so a busy stretch costs one update a second, a quiet one none), "Saving…" from Stop, ended once the
/// transcript is saved or the recording dropped. Local only: started and updated by the app, no push token. Without
/// Live Activities allowed (Settings › Feder) nothing happens.
enum RecordingLiveActivity {
    private static var current: Activity<RecordingActivityAttributes>?
    private static var state = RecordingActivityAttributes.ContentState(since: .now, isSaving: false)
    private static var lastUpdate = Date.distantPast
    private static var pending: Task<Void, Never>?
    /// The live text as of the last `show`; its tail is taken only when an update is sent.
    private static var latestText = LiveText()
    /// Seconds between two updates.
    private static let interval: TimeInterval = 1

    /// At launch: no recording runs yet, so a Live Activity still up belongs to a process that ended while recording
    /// (force-quit, a crash, a new build): it would show a running time and a Stop that does nothing.
    static func endLeftovers() {
        Task { await endAll() }
    }

    static func start(name: String, since: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        state = RecordingActivityAttributes.ContentState(since: since, isSaving: false, hidesWords: AppLock.isEnabled)
        latestText = LiveText()
        do {
            current = try Activity.request(attributes: RecordingActivityAttributes(name: name),
                                           content: ActivityContent(state: state, staleDate: nil))
            lastUpdate = .now
        } catch {
            #if DEBUG
            print("[Scribe] live activity: \(error)")
            #endif
        }
    }

    /// The newest words (nil: unchanged) and the level while recording; sent at most once a second. Called for every
    /// level reading: cheap until a slot is due.
    static func show(text: LiveText?, level: Float) {
        guard current != nil, !state.isSaving else { return }
        if let text { latestText = text }
        state.level = max(state.level, Double(level))        // the loudest since the last update (reset in send)
        guard pending == nil else { return }
        let wait = max(0, interval - Date.now.timeIntervalSince(lastUpdate))
        pending = Task {
            try? await Task.sleep(for: .seconds(wait))
            pending = nil
            send()
        }
    }

    /// A bookmark was set: its count goes out at once (the Live Activity's own bookmark button shows it), not in the
    /// next once-a-second slot.
    static func bookmarked(count: Int) {
        guard current != nil, !state.isSaving else { return }
        state.bookmarks = count
        pending?.cancel()
        pending = nil
        send()
    }

    static func saving() {
        guard current != nil else { return }
        pending?.cancel()
        pending = nil
        state.isSaving = true
        state.level = 0
        send()
    }

    static func end() {
        pending?.cancel()
        pending = nil
        guard let activity = current else { return }
        current = nil
        let id = activity.id
        Task { await end(id) }
    }

    private static func send() {
        guard let activity = current else { return }
        lastUpdate = .now
        // App Lock on (also turned on during the recording): no words leave the app for the Lock Screen, the Dynamic
        // Island, the Apple Watch's Smart Stack or a Mac's menu bar.
        state.hidesWords = AppLock.isEnabled
        if !state.isSaving { state.words = AppLock.isEnabled ? [] : tail(of: latestText) }
        let id = activity.id, state = state
        self.state.level = 0
        Task { await update(id, state) }
    }

    /// The last words of the live text, about one line and a half of the lock screen (the row shows what fits at its
    /// right end), each with its index in the transcript as id.
    nonisolated static func tail(of text: LiveText, count: Int = 14) -> [LiveWord] {
        let words = text.segments.flatMap { $0.text.split(separator: " ").map(String.init) }
            + text.provisional.map(\.word.text)
        let first = max(0, words.count - count)
        return words[first...].enumerated().map { LiveWord(id: first + $0.offset, text: $0.element) }
    }

    // By id, off the main actor: an Activity isn't Sendable, so it is looked up where it is used.
    @concurrent
    nonisolated private static func update(_ id: String, _ state: RecordingActivityAttributes.ContentState) async {
        await Activity<RecordingActivityAttributes>.activities.first { $0.id == id }?
            .update(ActivityContent(state: state, staleDate: nil))
    }

    @concurrent
    nonisolated private static func end(_ id: String) async {
        await Activity<RecordingActivityAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
    }

    @concurrent
    nonisolated private static func endAll() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
