import SwiftUI
import TipKit
import UIKit

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

    /// TipKit remembers a tip by its id. Settings › About › Reset Onboarding (Debug builds) counts `generationKey` up,
    /// so the tip is a new one that shows again at once: `Tips.resetDatastore()` only works before `Tips.configure`,
    /// that is at the next launch, and the reset is meant to replay everything now.
    var id: String {
        let generation = UserDefaults.standard.integer(forKey: Self.generationKey)
        return generation == 0 ? "NameSpeakersTip" : "NameSpeakersTip.\(generation)"
    }

    /// Configures TipKit once at launch. DEBUG, simulator: UI tests (`-seedSamples`) see no tips unless `-showTips`
    /// (`-resetTips` forgets what was shown), so a popover doesn't cover what other tests tap.
    static func configure() {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-resetTips") { try? Tips.resetDatastore() }
        if arguments.contains("-seedSamples"), !arguments.contains("-showTips") { Tips.hideAllTipsForTesting() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    /// UserDefaults: which generation of the tip is current (see `id`; 0 until a Debug build's Reset Onboarding).
    static let generationKey = "nameSpeakersTipGeneration"

    /// Takes the tip's popover away at once, without its animation, so a sheet can be presented in the same turn
    /// (TranscriptView.rename). The popover is the key window's topmost presented controller while the tip shows;
    /// anything else (the tip already closed) is left alone.
    @MainActor static func closePopoverAtOnce() {
        let window = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        guard top.modalPresentationStyle == .popover, let presenter = top.presentingViewController else { return }
        presenter.dismiss(animated: false)
    }

    #if DEBUG
    /// Reset Onboarding: the tip shows again, on the next transcript with unnamed final speakers.
    static func showAgain() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: generationKey) + 1, forKey: generationKey)
    }
    #endif
}
