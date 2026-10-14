import SwiftUI

/// The one full-screen card a transcript is always shown in, Apple Music's "Now Playing" for a transcript: the live
/// recording (`RecordView`) while a session records, the saved transcript (`RecordingDetailView`) otherwise. A
/// NavigationStack only for the system's bottom toolbar and the detail's sheets: there is no top bar (nothing at the
/// top right); the glass back button at the top left and swiping the card to the right close it (`onClose`), as a
/// pushed page is swiped away. Swiping down only scrolls the content (the zoom's own interactive dismissal is off).
///
/// When Stop saves a recording, the same card turns into its transcript in place (no push, no new page), like Voice
/// Memos' recording sheet: the recording already shows the transcript's title and date line where the transcript has
/// them, so they stay put; the big timer shrinks into the date line's duration; the live text fades out and the
/// transcript's fades in below; and the large Stop's Liquid Glass melts into the transcript's bottom toolbar (`Turn`).
struct TranscriptCard: View {
    let content: TranscriptCardContent
    /// The back button, the swipe to the right, a failure screen's Close/Cancel and Delete: MainView dismisses the
    /// card (during a recording back into the accessory, which keeps recording).
    let onClose: () -> Void
    let onRetry: () -> Void
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// From Stop until the transcript's own toolbar has taken over.
    @State private var turn: Turn?
    @State private var recordGeometry = RecordGeometry()
    @State private var transcriptReady = false       // the transcript has been on screen for a few frames
    @State private var swipe: CGFloat = 0            // how far the card has been swiped to the right
    @State private var width: CGFloat = 402

    /// What happens between Stop and the transcript's own toolbar.
    private struct Turn {
        let session: RecordingSession
        /// The Stop melts into the bar (MeltLayer); otherwise (Reduce Motion, sizes the bar wasn't measured at) the
        /// Stop fades out and the bar fades in.
        let melts: Bool
        /// Times all of it: RecordView's timer, fades and place, the melt, the transcript's body fading in.
        let clock = TurnClock()
        /// Nothing was saved after all (discarded while turning): the melt fades away, the rest stays as it is while
        /// the card closes.
        var abandoned = false

        /// When everything has arrived: the timer in the date line and, melting, the glass on the bar's items.
        func length(reduceMotion: Bool) -> TimeInterval {
            max(RecordView.flightDuration(reduceMotion: reduceMotion), melts ? MeltLayer.duration : 0)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // The recording stays under the transcript until the turn is over: its live text is still fading out.
                if let session = turn?.session ?? (content.transcript == nil ? content.session : nil) {
                    RecordView(session: session, turn: turn?.clock, melts: turn?.melts == true,
                               geometry: $recordGeometry, onClose: onClose, onRetry: onRetry)
                        .id(session.id)
                        .transition(.identity)              // the transcript's identical title and date line take over
                }
                if let transcript = content.transcript {
                    // Its summary, tags and text fade in as the recording's live text has faded out (TurnClock), into
                    // the space it left: not over the live text (a crossfade showed both at once, live paragraphs over
                    // the transcript's at other heights), and not later (the body stood empty for ~0.25 s, the card
                    // read as cleared and refilled).
                    RecordingDetailView(recording: transcript, search: content.search,
                                        fadesInBody: content.turnedFromRecording,
                                        holdsBody: turn.map { !$0.clock.liveTextGone } ?? false,
                                        turning: turn != nil, onClose: onClose)
                        .id(ObjectIdentifier(transcript))   // not `id`: a deleted @Model traps when read
                        .transition(.identity)              // its title and date line lie exactly over the recording's
                }
            }
            .appScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
        .overlay {
            // Melting, from the first frame of the turn. Before that, while recording, on standby: the same glass over
            // the Stop, all but transparent (1 %), so the render server has made its layers by the time of Stop.
            // Inserted only at Stop, its first frame held the screen up for ~0.1 s (simulator; without the melt the
            // turn's first frames came at once), and the motion was a tenth of a second in when it was first seen.
            if let turn, turn.melts, !turn.abandoned {
                meltLayer(clock: turn.clock)
            } else if turn == nil, meltsOnStop {
                meltLayer(clock: nil)
                    .opacity(0.01)
            }
        }
        // Swiped to the right it follows the finger, then closes (zooming back into its source) or springs back.
        .offset(x: swipe)
        .background {
            CardSwipeToClose(onChange: { swipe = $0 }, onEnd: swipeEnded)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .interactiveDismissDisabled()                // not the zoom's swipe down: vertical drags scroll the content
        .navigationTransition(.zoom(sourceID: content.sourceID, in: namespace))   // out of / back into its source
        // `initial`: a card opened while the recording is being saved (Stop, swiped down, the accessory's "Saving…"
        // tapped) turns too; without it, it never did, and its Stop looked active but did nothing.
        .onChange(of: content.session?.state, initial: true) { _, state in
            switch state {
            case .finishing:
                if content.transcript == nil, let session = content.session { beginTurn(session) }
            case .discarded:
                // Nothing was saved after all: the card closes (MainView) as it stands, only the melt fades. (Ending the
                // turn here put the live text, timer and Stop back for a frame before it closed.)
                if turn != nil, content.transcript == nil { withAnimation(.easeOut(duration: 0.2)) { turn?.abandoned = true } }
            case .failed:
                // The failure screen crossfades in (RecordView) as the melt fades away, rather than a cut.
                if turn != nil, content.transcript == nil { withAnimation(.easeOut(duration: 0.25)) { turn = nil } }
            default: break
            }
        }
        .onChange(of: content.transcript.map(ObjectIdentifier.init)) { transcriptArrived() }
    }

    /// Lifted after a swipe: past a third of the width, or flicked, the card closes (UIKit's back gesture decides
    /// alike); either way the content slides back into place, while the card zooms back or stays.
    private func swipeEnded(translation: CGFloat, velocity: CGFloat) {
        if translation > width / 3 || velocity > 500 { onClose() }
        withAnimation(.easeOut(duration: 0.3)) { swipe = 0 }
    }

    private func meltLayer(clock: TurnClock?) -> some View {
        MeltLayer(clock: clock, stop: recordGeometry.stop, bar: MeltLayer.barItems(in: recordGeometry.safeArea))
            .ignoresSafeArea()
            // There at once, exactly over the Stop it replaces; fading away only when nothing was saved.
            .transition(.asymmetric(insertion: .identity, removal: .opacity))
    }

    /// The card shows a recording whose Stop would melt (beginTurn).
    private var meltsOnStop: Bool {
        guard content.transcript == nil, case .recording = content.session?.state else { return false }
        return !reduceMotion && MeltLayer.canMelt(recordGeometry, dynamicTypeSize: dynamicTypeSize)
    }

    // MARK: Turn

    /// Stop with something transcribed: the card starts turning into the transcript at once, while the session is
    /// still saving, not once it is saved. Measured on the simulator (iPhone 17, iOS 27): Stop -> saved 120–180 ms,
    /// 70 ms of it stopping the audio engine; on an iPhone the transcriber's last words add about 0.1 s (up to the
    /// 2 s cap). Until the real toolbar has taken over (handOver: the transcript saved and on screen, the timer landed,
    /// the glass on the bar's items, about 0.6 s after Stop) its items are replicas, which take no taps.
    /// Nothing transcribed: no turn, the session discards the recording and MainView closes the card.
    private func beginTurn(_ session: RecordingSession) {
        guard turn == nil, !session.text.isEmpty else { return }
        let melts = !reduceMotion && MeltLayer.canMelt(recordGeometry, dynamicTypeSize: dynamicTypeSize)
        // A plain update: RecordView and MeltLayer move and fade their parts frame by frame on the turn's clock. Not
        // inside withAnimation: the melt's glass, inserted in an animated update, "materialised" over the Stop instead
        // of being there at once.
        let turn = Turn(session: session, melts: melts)
        self.turn = turn
        let clock = turn.clock, length = turn.length(reduceMotion: reduceMotion)
        Task {
            // A little before the live text is quite gone: the body's fade starts a frame or two after the flag (the
            // wait's polling, the next update), and the card stood empty for ~50 ms in between.
            await clock.wait(until: RecordView.fadeOut * 0.8)
            clock.liveTextGone = true
            await clock.wait(until: length)
            clock.isOver = true                          // the timelines stand still on the end
            handOver()
        }
    }

    /// The saved transcript took the recording's place (lying over it, its bar hidden). Its bar is shown only once it
    /// has been on screen for a few frames: shown in the same update that inserts its view, iOS "materialises" the
    /// bar (an empty frame, then ~230 ms of blur) even without animation.
    private func transcriptArrived() {
        transcriptReady = false
        guard turn != nil, content.transcript != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            transcriptReady = true
            handOver()
        }
    }

    /// The real toolbar takes over from the replicas, or fades in after the faded Stop. In one update without animation
    /// for the melt: the bar appears exactly under the replicas (same frames, same symbols), which go in that same
    /// frame (kept over the real bar they gave a darker double rim and ghost symbols), as does the recording.
    private func handOver() {
        guard let turn, content.transcript != nil, transcriptReady, turn.clock.isOver else { return }
        if turn.melts {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { self.turn = nil }
        } else {
            withAnimation(.easeOut(duration: 0.25)) { self.turn = nil }
        }
    }
}

/// The turn's clock (TranscriptCard → RecordView, MeltLayer): seconds since the first frame drawn after Stop, advanced
/// by the frames themselves (their TimelineView dates), each step at most 1/30 s. Right after Stop the main thread is
/// busy for ~0.1 s (saving the transcript, inserting its view; simulator). Timed by the wall clock from Stop, that
/// part of every motion was skipped: the first frame drawn already showed the live text half faded and the timer
/// 24 pt up, and the fade read as a cut. On this clock a stall only holds the motion up for a moment.
@MainActor @Observable
final class TurnClock {
    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var elapsed: TimeInterval = 0
    /// The live text has (all but) faded out (RecordView.fadeOut): the transcript's body fades in.
    var liveTextGone = false
    /// Everything has arrived: the timelines stand still, the real toolbar can take over.
    var isOver = false

    private static let maxStep: TimeInterval = 1.0 / 30

    /// The turn's time in the frame of `date` (a TimelineView's), read by several timelines in a frame, which get the
    /// same date. Past the end once it is over. Not observed: it changes in every frame, during the views' updates.
    func time(at date: Date) -> TimeInterval {
        if isOver { return .infinity }
        if lastFrame == nil { InteractionTrace.shown("stop") }   // the first frame drawn after Stop
        if let lastFrame {
            guard date > lastFrame else { return elapsed }
            elapsed += min(date.timeIntervalSince(lastFrame), Self.maxStep)
        }
        lastFrame = date
        return elapsed
    }

    /// Returns once the frames have reached `time`; without frames (the card not on screen) a little later by the
    /// wall clock.
    func wait(until time: TimeInterval) async {
        let start = ContinuousClock.now
        while elapsed < time, ContinuousClock.now - start < .seconds(time + 0.5), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
}

/// Where RecordView's Stop and the card's safe area are, in window coordinates: the melt's start and the bar's place.
nonisolated struct RecordGeometry: Equatable, Sendable {
    var stop = CGRect.zero
    var safeArea = CGRect.zero
    var bottomInset: CGFloat = 0
}
