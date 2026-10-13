import SwiftUI
import UIKit
import os

/// Shaking the iPhone undoes the card's last correction or the Action Items sheet's last removal (FED-7) with iOS's
/// own alert ("Undo Speaker Changed", Cancel and Undo, its haptic), as in every app. UIKit's shake
/// (`UIApplication.motionEnded`) asks the key window's *first responder* for its `undoManager`, and with nothing focused
/// there is none: in the card nothing is focused after a correction (the name row's menu or the merge question took
/// the tap, Edit Text's Done ended the fields, a swipe removed the item), so every shake found no UndoManager and did
/// nothing, while the toast's Undo, which calls the correction's undo directly, worked (iPhone 17, iOS 27.0.1). A shake
/// after typing in the title showed "Undo Typing" (the iOS 27 simulator): the field was first responder.
/// This 0-pt view is first responder while an Undo is on offer, and its `undoManager` is the environment's, the one
/// the actions are registered on (the card's and its sheets' are the same: the window's). It handles no motion itself:
/// UIResponder passes the shake up to UIApplication, which shows the alert, so Settings › Accessibility › Touch › Shake
/// to Undo turns it off as in every app. Not a shake detector of our own with an alert of our own: that would ignore
/// the setting, and iOS draws this alert.
/// It takes first responder only at edges: on the next turn after an Undo newly on offer or after whatever held the
/// keys let go (`blocked`), and at once when its window becomes key again (after App Lock, which resigned it on
/// leaving). Taken while a field is edited it would end the edit, so it never does then; a field tapped later simply
/// takes over.
struct ShakeUndoResponder: UIViewRepresentable {
    /// Changes with every Undo registered for shaking; nil when none is on offer (the view lets go of first responder).
    let offer: Int?
    /// The card's own keys are elsewhere (its title, tag field or Edit Text, the rename sheet, one of its questions): it
    /// waits until they let go. Not the Action Items sheet or what that presents: the view stays first responder under
    /// it, and a Remove there claims it.
    let blocked: Bool

    private static let log = Logger(subsystem: "de.timtody.feder", category: "Undo")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ResponderView {
        let view = ResponderView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.coordinator = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ResponderView, context: Context) {
        view.manager = context.environment.undoManager
        context.coordinator.update(offer: offer, blocked: blocked)
    }

    static func dismantleUIView(_ view: ResponderView, coordinator: Coordinator) {
        coordinator.stopObserving()
        if view.isFirstResponder { view.resignFirstResponder() }
    }

    final class ResponderView: UIView {
        weak var coordinator: Coordinator?
        weak var manager: UndoManager?

        override var canBecomeFirstResponder: Bool { coordinator?.offer != nil && manager != nil }
        override var undoManager: UndoManager? { manager }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.windowChanged(window)
        }
    }

    final class Coordinator {
        weak var view: ResponderView?
        private(set) var offer: Int?
        private var blocked = false
        private var observer: NSObjectProtocol?

        func update(offer: Int?, blocked: Bool) {
            let newOffer = offer != nil && offer != self.offer
            let unblocked = self.blocked && !blocked
            self.offer = offer
            self.blocked = blocked
            if offer == nil {
                if view?.isFirstResponder == true { Task { self.resign() } }
            } else if !blocked, newOffer || unblocked {
                // On the next turn: taking first responder ends a field's edit, which changes SwiftUI's focus state,
                // and not within this view update.
                Task { self.claim() }
            }
        }

        /// In a window: claimed there on the next turn if an Undo is on offer by then, and again, at once, whenever that
        /// window becomes key (App Lock's window had the keys, and App Lock resigned the first responder on leaving).
        func windowChanged(_ window: UIWindow?) {
            stopObserving()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claim() }
            }
            Task { self.claim() }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func claim() {
            guard let view, offer != nil, !blocked, view.window?.isKeyWindow == true, !view.isFirstResponder else { return }
            let took = view.becomeFirstResponder()
            let canUndo = view.manager?.canUndo ?? false
            ShakeUndoResponder.log.debug("shake undo: first responder \(took), can undo \(canUndo)")
        }

        private func resign() {
            guard let view, offer == nil, view.isFirstResponder else { return }
            view.resignFirstResponder()
            ShakeUndoResponder.log.debug("shake undo: resigned")
        }
    }
}
