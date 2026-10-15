import SwiftUI
import UIKit

/// Swiping the card to the right closes it, like a pushed page: UIKit's own back gesture, a screen-edge pan from the
/// left edge (`UIScreenEdgePanGestureRecognizer`, what `UINavigationController` uses). Only touches that start in the
/// edge's few points can begin it, so the card's own gestures stay as they are: the transcript scrolls vertically,
/// text is selected with a long press, the name rows and their long-press menus, the title field, the tag chips'
/// horizontal scroll and the bottom toolbar all keep their touches, and UIKit's scroll views and text views give way
/// to a screen-edge pan anyway. Not a SwiftUI `DragGesture`: on the whole card it competed with the ScrollView's drag
/// (a high-priority one blocked scrolling, a simultaneous one scrolled while closing), and it has no edge.
///
/// The recognizer is added to the cover's own view (the nearest ancestor below the window), found like
/// `ScrollDragObserver` finds the List's scroll view, and removed with this view. `onChange` reports the finger's
/// horizontal travel while it is down, `onEnd` the travel and velocity when it lifts.
///
/// A full-screen cover takes the presenting view (the tabs) out of the window once it is up, so the swiped card slid
/// over the window's empty background (FED-136). While the finger is down that view is put back under the cover, as
/// UIKit does for a dismissal; it goes again once the card has sprung back, and stays when the card closes (the
/// dismissal moves it where it belongs).
struct CardSwipeToClose: UIViewRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let coordinator, coordinator.host == nil else { return }
            // The cover's view: the topmost ancestor that is not the window itself.
            var host = superview
            while let above = host?.superview, !(above is UIWindow) { host = above }
            if let host { coordinator.attach(to: host) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat) -> Void = { _ in }
        var onEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
        private(set) weak var host: UIView?
        private var recognizer: UIScreenEdgePanGestureRecognizer?

        func attach(to host: UIView) {
            let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(pan(_:)))
            recognizer.edges = .left
            recognizer.delegate = self
            host.addGestureRecognizer(recognizer)
            self.host = host
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer { host?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            host = nil
        }

        @objc private func pan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let host else { return }
            let x = max(0, recognizer.translation(in: host).x)
            switch recognizer.state {
            case .began:
                revealPresenter()
            case .changed:
                onChange(x)
            case .ended:
                onEnd(x, recognizer.velocity(in: host).x)
                concealPresenter()
            case .cancelled, .failed:
                onEnd(0, 0)
                concealPresenter()
            default:
                break
            }
        }

        /// The view the cover covers, put back into the window under it while swiping.
        private weak var revealed: UIView?
        private var swipes = 0                       // a new swipe within the spring back keeps the view

        private func revealPresenter() {
            swipes += 1
            guard revealed == nil, let window = host?.window, let root = window.rootViewController?.view,
                  root.window == nil else { return }    // in the window still: nothing to do, nothing to take out later
            root.frame = window.bounds
            window.insertSubview(root, at: 0)
            revealed = root
        }

        /// After the card's spring back (0.3 s, TranscriptCard.swipeEnded): out again while the cover stays up. Closing,
        /// the dismissal has taken the view over by then and puts it back for good.
        private func concealPresenter() {
            let swipe = swipes
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.4))
                guard let self, swipe == self.swipes, let root = self.revealed else { return }
                self.revealed = nil
                guard let window = root.window, let presented = window.rootViewController?.presentedViewController,
                      !presented.isBeingDismissed, root.superview === window else { return }
                root.removeFromSuperview()
            }
        }

        /// The edge pan wins over anything else that starts at the edge (a scroll, a text selection drag), as the
        /// navigation controller's back gesture does.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
