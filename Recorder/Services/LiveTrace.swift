#if DEBUG
import Foundation
import os
import Synchronization

/// DEBUG timing of the live screen, from a transcription result (or a live-label snapshot, or a label coming due) to
/// the pixels: RecordingSession received it -> published the new LiveText -> LiveTranscriptModel.update -> the body of
/// the first changed paragraph -> its text drawn (WordFadeRenderer). Always as signposts (Instruments: subsystem
/// de.timtody.feder, category "Live"); with the launch argument `-liveTrace` also one console line per update and
/// a summary when the recording stops. Main-actor work per update = "session" + "model"; "drawn" is how long after the
/// result the new text was drawn.
nonisolated enum LiveTrace {
    private struct Update {
        var id: Int
        var kind: String
        var received: ContinuousClock.Instant
        var interval: OSSignpostIntervalState
        var session: Duration?                     // received -> published
        var words = 0, paragraphs = 0
        var model: (at: Duration, work: Duration)?
        var firstChanged: Int?                     // first LiveParagraph id the model update changed
        var body: Duration?
    }

    private struct State {
        var count = 0
        var current: Update?                       // received, not published yet
        var pending: Update?                       // published, not drawn yet
        var session: [Double] = []                 // ms per update, since the last summary
        var model: [Double] = []
        var drawn: [Double] = []
    }

    private static let signposter = OSSignposter(subsystem: "de.timtody.feder", category: "Live")
    private static let state = Mutex(State())
    private static let verbose = ProcessInfo.processInfo.arguments.contains("-liveTrace")

    /// RecordingSession got a volatile or final result, a live-label snapshot, or a pending label came due.
    static func received(_ kind: String) {
        let interval = signposter.beginInterval("Update", id: signposter.makeSignpostID(), "\(kind)")
        state.withLock { state in
            state.count += 1
            state.current = Update(id: state.count, kind: kind, received: .now, interval: interval)
        }
    }

    /// RecordingSession published the new LiveText (`changed`), or found nothing to show.
    static func published(changed: Bool, words: Int, paragraphs: Int) {
        let now = ContinuousClock.now
        let superseded: Update? = state.withLock { state in
            guard var update = state.current else { return nil }
            state.current = nil
            update.session = now - update.received
            update.words = words
            update.paragraphs = paragraphs
            state.session.append(milliseconds(now - update.received))
            guard changed else {
                signposter.endInterval("Update", update.interval, "unchanged")
                return nil
            }
            defer { state.pending = update }
            return state.pending
        }
        if let superseded { finish(superseded, outcome: "superseded") }
    }

    /// LiveTranscriptModel.update, started at `start`, changed the paragraphs from id `firstChanged` on (nil: the
    /// paragraphs came out the same, e.g. a label that doesn't change what is drawn; nothing to draw then).
    static func modelUpdated(start: ContinuousClock.Instant, firstChanged: Int?) {
        let end = ContinuousClock.now
        let unchanged: Update? = state.withLock { state in
            state.model.append(milliseconds(end - start))
            guard var update = state.pending, update.model == nil else { return nil }
            update.model = (start - update.received, end - start)
            update.firstChanged = firstChanged
            state.pending = firstChanged == nil ? nil : update
            return firstChanged == nil ? update : nil
        }
        if let unchanged { finish(unchanged, outcome: "nothing new to draw") }
    }

    /// The body of live paragraph `id` was evaluated.
    static func body(paragraph id: Int) {
        state.withLock { state in
            guard var update = state.pending, update.body == nil, let first = update.firstChanged, id >= first else { return }
            update.body = .now - update.received
            state.pending = update
        }
    }

    /// Live text was drawn: the first draw after the changed paragraph's body completes the update.
    static func drawn() {
        let done: Update? = state.withLock { state in
            guard let update = state.pending, update.body != nil else { return nil }
            state.pending = nil
            state.drawn.append(milliseconds(.now - update.received))
            return update
        }
        if let done { finish(done, outcome: "drawn +" + format(.now - done.received) + " ms") }
    }

    /// Prints the percentiles of everything traced since the last summary (with `-liveTrace`).
    static func summary() {
        let (session, model, drawn) = state.withLock { state in
            defer { state.session = []; state.model = []; state.drawn = [] }
            return (state.session, state.model, state.drawn)
        }
        guard verbose else { return }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard let last = sorted.last else { return "-" }
            func at(_ q: Double) -> Double { sorted[Int(Double(sorted.count - 1) * q)] }
            return String(format: "n %d, p50 %.3f, p90 %.3f, max %.3f ms", sorted.count, at(0.5), at(0.9), last)
        }
        print("[Scribe] live trace summary: session \(stats(session)); model.update \(stats(model)); received to drawn \(stats(drawn))")
    }

    private static func finish(_ update: Update, outcome: String) {
        signposter.endInterval("Update", update.interval, "\(outcome)")
        guard verbose else { return }
        func ms(_ duration: Duration?) -> String { duration.map(format) ?? "-" }
        print("[Scribe] live trace \(update.kind) #\(update.id): session \(ms(update.session)) ms, model \(ms(update.model?.work)) ms "
              + "at +\(ms(update.model?.at)), body +\(ms(update.body)), \(outcome) (\(update.words) words, \(update.paragraphs) paragraphs)")
    }

    private static func format(_ duration: Duration) -> String { String(format: "%.3f", milliseconds(duration)) }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
#else
/// Release: nothing is traced; the calls compile to nothing.
nonisolated enum LiveTrace {
    @inlinable static func received(_ kind: String) {}
    @inlinable static func published(changed: Bool, words: Int, paragraphs: Int) {}
    @inlinable static func modelUpdated(start: ContinuousClock.Instant, firstChanged: Int?) {}
    @inlinable static func body(paragraph id: Int) {}
    @inlinable static func drawn() {}
    @inlinable static func summary() {}
}
#endif
