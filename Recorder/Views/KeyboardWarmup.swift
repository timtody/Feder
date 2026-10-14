import UIKit
import os

/// Sets up the keyboard once, while the naming tip is up, so the tap on the name doesn't pay for it (FED-9). The
/// session's first rename sheet started to move about 0.3 s after the tap on the iPhone 17 simulator, later ones after
/// 0.13-0.16 s: ~250 ms of the main thread were UIKit setting up the session's first keyboard inside the presentation
/// (README › Performance › Rename). An invisible field takes the keys and gives them back in the same turn, before
/// anything is drawn, while the tip waits for its tap.
/// Only while the tip's popover is the topmost presentation (nothing else up, no sheet) and nothing else has the keys:
/// taking them would end a field's edit or the shake-to-undo responder's turn (ShakeUndoResponder). Not with VoiceOver,
/// which could move its focus to the field. Once per launch.
enum KeyboardWarmup {
    /// Whether it ran in this launch (also testNameSpeakersTip's marker, TranscriptView).
    private(set) static var done = false
    #if DEBUG
    private static let log = Logger(subsystem: "de.timtody.feder", category: "Interaction")
    #endif

    static func runWhileTipShows() {
        guard !done, !UIAccessibility.isVoiceOverRunning,
              let window = UIApplication.shared.connectedScenes.lazy
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        guard top.modalPresentationStyle == .popover, FirstResponder.current == nil else { return }
        done = true
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        field.alpha = 0
        field.isAccessibilityElement = false
        field.accessibilityElementsHidden = true
        field.autocorrectionType = .no
        window.addSubview(field)
        #if DEBUG
        let start = ContinuousClock.now
        #endif
        UIView.performWithoutAnimation {
            field.becomeFirstResponder()
            field.resignFirstResponder()
        }
        field.removeFromSuperview()
        #if DEBUG
        log.log("keyboard warmed up in \(String(describing: ContinuousClock.now - start), privacy: .public)")
        #endif
    }
}

/// Which responder has the keys: UIKit has no public getter, but an action sent to nil goes to the first responder.
private enum FirstResponder {
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.feder_reportFirstResponder), to: nil, from: nil, for: nil)
        defer { found = nil }
        return found?.isFirstResponder == true ? found : nil     // with no first responder it may land elsewhere
    }

    fileprivate static weak var found: UIResponder?
}

extension UIResponder {
    @objc fileprivate func feder_reportFirstResponder() { FirstResponder.found = self }
}
