#if DEBUG
import Foundation
import os
import Synchronization

/// DEBUG timing of the interaction paths, from a press to the first frame of what it causes: the Transcribe tap to the
/// card's first frame, Stop to the first frame of the turn, a row to the transcript's first frame, a tab to the tab, a
/// keystroke to the results. Always as signposts (Instruments: Points of Interest, so a Time Profiler recording can be
/// read per press);
/// with the launch argument `-interactionTrace` also one log line per press (`log stream --predicate 'subsystem ==
/// "de.timtody.feder" AND category == "Interaction"'`): how long the press's own turn of the main thread took
/// ("turn": everything SwiftUI did before it could commit a frame), and when the first frame of the new state was
/// committed ("frame": the view's first appearance, measured on the next turn of the run loop, after the commit).
nonisolated enum InteractionTrace {
    private struct Pending {
        let began: ContinuousClock.Instant
        let interval: OSSignpostIntervalState
        var turn: Duration?
    }

    private static let signposter = OSSignposter(subsystem: "de.timtody.feder", category: .pointsOfInterest)
    private static let logger = Logger(subsystem: "de.timtody.feder", category: "Interaction")
    private static let verbose = ProcessInfo.processInfo.arguments.contains("-interactionTrace")
    private static let pending = Mutex<[String: Pending]>([:])
    /// When each path's last press began, kept past its first frame for `point`.
    private static let began = Mutex<[String: ContinuousClock.Instant]>([:])

    /// A press was handled: `name` names the path. The main thread's turn is timed until the run loop is free again.
    @MainActor
    static func begin(_ name: String) {
        let now = ContinuousClock.now
        let interval = signposter.beginInterval("Press", id: signposter.makeSignpostID(), "\(name)")
        pending.withLock { $0[name] = Pending(began: now, interval: interval) }
        began.withLock { $0[name] = now }
        DispatchQueue.main.async {                           // after this turn of the run loop (and its commit)
            let turn = ContinuousClock.now - now
            let frameKnown: Bool = pending.withLock { state in
                guard var entry = state[name], entry.turn == nil else { return true }
                entry.turn = turn
                state[name] = entry
                return false
            }
            signposter.emitEvent("Turn", "\(name) \(milliseconds(turn)) ms")
            if verbose, !frameKnown { logger.log("\(name, privacy: .public): turn \(milliseconds(turn), privacy: .public) ms") }
        }
    }

    /// The new state is on screen: called when its view first appears; the frame is counted as committed on the next
    /// turn of the run loop.
    @MainActor
    static func shown(_ name: String) {
        DispatchQueue.main.async {
            let now = ContinuousClock.now
            guard let entry = pending.withLock({ $0.removeValue(forKey: name) }) else { return }
            let frame = now - entry.began
            signposter.endInterval("Press", entry.interval, "\(name) frame \(milliseconds(frame)) ms")
            guard verbose else { return }
            let turn = entry.turn.map { "\(milliseconds($0)) ms" } ?? "-"
            logger.log("\(name, privacy: .public): turn \(turn, privacy: .public), first frame \(milliseconds(frame), privacy: .public) ms")
        }
    }

    /// A step after the press's first frame, timed from the press: the rename sheet's field taking focus and its
    /// keyboard starting to rise, which the sheet's `onAppear` comes before (FED-9).
    @MainActor
    static func point(_ name: String, _ step: String) {
        let now = ContinuousClock.now
        guard let start = began.withLock({ $0[name] }) else { return }
        let elapsed = milliseconds(now - start)
        signposter.emitEvent("Step", "\(name) \(step) \(elapsed) ms")
        if verbose { logger.log("\(name, privacy: .public): \(step, privacy: .public) \(elapsed, privacy: .public) ms") }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}
#else
/// Release: nothing is traced; the calls compile to nothing.
nonisolated enum InteractionTrace {
    @inlinable @MainActor static func begin(_ name: String) {}
    @inlinable @MainActor static func shown(_ name: String) {}
    @inlinable @MainActor static func point(_ name: String, _ step: String) {}
}
#endif
