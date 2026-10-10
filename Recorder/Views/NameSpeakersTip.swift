import SwiftUI
import TipKit

/// The hint that names are tappable (TipKit, Apple's own tips), on the first speaker's name row of a transcript whose
/// speakers are final and still all "Speaker N" (RecordingDetailView). Shown once: tapping a name (any rename) or
/// closing the tip ends it for good. Before it, nothing said that the bold "Speaker 1" is a button.
struct NameSpeakersTip: Tip {
    var title: Text { Text("Name the Speakers") }

    var message: Text? {
        PeopleDirectory.isRecognitionEnabled
            ? Text("Tap a speaker's name to change it. Feder then recognizes them by voice in later recordings.")
            : Text("Tap a speaker's name to change it everywhere in this transcript.")
    }

    var image: Image? { Image(systemName: "person.crop.circle.badge.questionmark") }

    /// Configures TipKit once at launch. DEBUG, simulator: UI tests (`-seedSamples`) see no tips unless `-showTips`
    /// (`-resetTips` forgets what was shown), so a popover doesn't cover what other tests tap.
    static func configure() {
        #if DEBUG
        // Settings › About › Reset Onboarding (Debug builds) asks for the tips to come back at the next launch.
        if UserDefaults.standard.bool(forKey: resetOnLaunchKey) {
            UserDefaults.standard.removeObject(forKey: resetOnLaunchKey)
            try? Tips.resetDatastore()
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-resetTips") { try? Tips.resetDatastore() }
        if arguments.contains("-seedSamples"), !arguments.contains("-showTips") { Tips.hideAllTipsForTesting() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    /// UserDefaults (Debug builds): reset the tips at the next launch.
    static let resetOnLaunchKey = "debugResetTipsOnLaunch"
}
