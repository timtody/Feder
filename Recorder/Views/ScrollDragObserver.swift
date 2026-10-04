import SwiftUI
import UIKit

/// Reports when the finger starts and stops dragging the scroll view next to it (put it in the `.background` of a
/// List or ScrollView). SwiftUI's `onScrollPhaseChange` stays `.idle` for a List that fits on screen (measured on
/// iOS 27), and pull-to-search must know the moment the finger lifts: a bounce after a fling, or pulling down and
/// pushing back up while holding, must not count. This adds a target to the scroll view's own pan gesture recognizer,
/// so scrolling, taps and swipe actions are untouched. `onEnd` gets the pull past the top (in points, > 0 when pulled
/// down) at the moment the finger lifted.
struct ScrollDragObserver: UIViewRepresentable {
    var onBegin: () -> Void
    var onEnd: (_ pull: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onBegin = onBegin
        context.coordinator.onEnd = onEnd
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The List's scroll view is not an ancestor of a background view but in the same container: search the
            // nearest ancestors' subtrees, closest first.
            Task { @MainActor [weak self] in
                guard let self, let coordinator, coordinator.scrollView == nil else { return }
                var ancestor = superview
                while let current = ancestor {
                    if let scrollView = Self.firstScrollView(in: current) {
                        coordinator.attach(to: scrollView)
                        return
                    }
                    ancestor = current.superview
                }
            }
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            var queue = view.subviews                      // breadth first: the outermost scroll view, not a row's
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let scrollView = next as? UIScrollView { return scrollView }
                queue.append(contentsOf: next.subviews)
            }
            return nil
        }
    }

    final class Coordinator: NSObject {
        var onBegin: () -> Void = {}
        var onEnd: (CGFloat) -> Void = { _ in }
        private(set) weak var scrollView: UIScrollView?

        func attach(to scrollView: UIScrollView) {
            self.scrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
        }

        func detach() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
            scrollView = nil
        }

        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onBegin()
            case .ended, .cancelled, .failed:
                guard let scrollView else { return }
                onEnd(-(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
            default:
                break
            }
        }
    }
}
