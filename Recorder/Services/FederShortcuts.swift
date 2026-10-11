import AppIntents

/// Siri and the Shortcuts app: "Transcribe with Feder" starts a transcript, "Stop transcribing in Feder" stops it. The
/// Action Button can run either, or the Control Center control (FederWidgets). Phrases in English and German
/// (AppShortcuts.xcstrings); each must contain the app's name.
struct FederShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: [
            "Transcribe with \(.applicationName)",
            "Start transcribing in \(.applicationName)",
            "Start a transcript in \(.applicationName)",
        ], shortTitle: "Transcribe", systemImageName: "waveform")
        AppShortcut(intent: StopRecordingIntent(), phrases: [
            "Stop transcribing in \(.applicationName)",
            "Stop \(.applicationName)",
        ], shortTitle: "Stop Transcribing", systemImageName: "stop.circle")
    }
}
