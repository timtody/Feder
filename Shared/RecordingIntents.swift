import ActivityKit
import AppIntents
import Foundation

// Shared by the app and the widget extension (FederWidgets): the intents the Control Center control, the Action
// Button, Siri and Shortcuts run, and the Live Activity's attributes. Every intent runs in the app's process (opened
// in the foreground, or, for the Live Activity's Stop, the app that is recording), so the extension only needs the
// types.

/// Starts a transcript: opens Feder and starts recording, as Transcribe in the app does. In the foreground: iOS lets
/// an app start the microphone only there (or with an AudioRecordingIntent's own rules), and the user sees the live
/// transcript at once.
nonisolated struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Transcribing"
    static let description = IntentDescription("Opens Feder and starts a new transcript.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingControl.shared.requestStart()
        return .result()
    }
}

/// Stops the recording that is running (the Live Activity's Stop, Siri, Shortcuts); the transcript is saved as with
/// Stop in the app.
nonisolated struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Transcribing"
    static let description = IntentDescription("Stops the recording and saves the transcript.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingControl.shared.requestStop()
        return .result()
    }
}

/// Where the intents reach the app: MainView sets `start` and `stop` when it appears. A start asked for before that
/// (the intent launched the app) waits in `pendingStart` until MainView picks it up.
@MainActor
final class RecordingControl {
    static let shared = RecordingControl()

    var start: (() -> Void)?
    var stop: (() async -> Void)?
    private(set) var pendingStart = false

    func requestStart() {
        if let start { start() } else { pendingStart = true }
    }

    func requestStop() async {
        await stop?()
    }

    /// MainView, once it can record: true if a start was asked for meanwhile.
    func takePendingStart() -> Bool {
        defer { pendingStart = false }
        return pendingStart
    }
}

/// The Live Activity while recording (lock screen, Dynamic Island): the time from `since`, the newest transcribed words
/// (running from right to left; none while App Lock is on), the microphone's level (the island's meter) and Stop; "Saving…" from Stop until the
/// transcript is saved. The app updates it at most once a second (RecordingLiveActivity): iOS draws a Live Activity
/// from these snapshots and animates between them, it has no live drawing of its own.
nonisolated struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var since: Date
        var isSaving: Bool
        /// The newest words, each with its place in the transcript as id: an update moves the ones still there to the
        /// left and brings the new ones in from the right.
        var words: [LiveWord] = []
        /// The microphone's level 0...1 at the last update.
        var level: Double = 0
        /// App Lock is on: no words are sent, and "Recording" stands in their place. Optional, so the state of an
        /// activity started by an earlier build still decodes (nil reads as false).
        var hidesWords: Bool?
    }

    /// The transcript's name (kept for the system's own listings; the views don't show it).
    var name: String
}

nonisolated struct LiveWord: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var text: String
}

/// The URL the lock screen widget opens: start a transcript.
nonisolated enum FederURL {
    static let scheme = "feder"
    static let record = URL(string: "feder://record")!

    /// A transcript's card (the link of an action item added to Reminders or Calendar).
    static func transcript(_ id: UUID) -> URL {
        URL(string: "feder://transcript/\(id.uuidString)")!
    }
}
