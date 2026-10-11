import ActivityKit
import Foundation

/// The recording's Live Activity (RecordingActivityAttributes; drawn by FederWidgets): started when the recording
/// starts, "Saving…" from Stop, ended once the transcript is saved or the recording dropped. Local only: started and
/// updated by the app, no push token. Without Live Activities allowed (Settings › Feder) nothing happens.
enum RecordingLiveActivity {
    private static var current: Activity<RecordingActivityAttributes>?

    static func start(name: String, since: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            #if DEBUG
            NSLog("[Scribe] live activity: not enabled")
            #endif
            return
        }
        end()
        let content = ActivityContent(state: RecordingActivityAttributes.ContentState(since: since, isSaving: false),
                                      staleDate: nil)
        do {
            current = try Activity.request(attributes: RecordingActivityAttributes(name: name), content: content)
            #if DEBUG
            NSLog("[Scribe] live activity: started %@", current?.id ?? "-")
            #endif
        } catch {
            #if DEBUG
            NSLog("[Scribe] live activity: %@", String(describing: error))
            #endif
        }
    }

    /// At launch: no recording runs yet, so a Live Activity still up belongs to a process that ended while recording
    /// (force-quit, a crash, a new build): it would show a running time and a Stop that does nothing.
    static func endLeftovers() {
        Task { await endAll() }
    }

    @concurrent
    nonisolated private static func endAll() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func saving() {
        guard let activity = current else { return }
        let id = activity.id
        let state = RecordingActivityAttributes.ContentState(since: activity.content.state.since, isSaving: true)
        Task { await update(id, state) }
    }

    static func end() {
        guard let activity = current else { return }
        current = nil
        let id = activity.id
        Task { await end(id) }
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
}
