import SwiftUI

/// The one full-screen card a transcript is always shown in, Apple Music's "Now Playing" for a transcript: the live
/// recording (`RecordView`) while a session records, the saved transcript (`RecordingDetailView`) otherwise. A
/// NavigationStack only for the system's bottom toolbar and the detail's sheets: there is no top bar (no Back, nothing
/// at the top right); the grabber at the top and swiping down close the card (`onClose`).
///
/// When Stop saves a recording, the same card turns into its transcript in place (no push, no new page), like Voice
/// Memos' recording sheet: the recording already shows the transcript's title and date line where the transcript has
/// them, so they stay put; the big timer shrinks into the date line's duration; the live text fades out and the
/// transcript's fades in below; and the large Stop's Liquid Glass melts into the transcript's bottom toolbar (`Turn`).
struct TranscriptCard: View {
    let content: TranscriptCardContent
    /// The grabber, a failure screen's Close/Cancel and Delete: MainView dismisses the card (during a recording back
    /// into the accessory, which keeps recording).
    let onClose: () -> Void
    let onRetry: () -> Void
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// From Stop until the transcript's own toolbar has taken over.
    @State private var turn: Turn?
    @State private var recordGeometry = RecordGeometry()
    @State private var transcriptReady = false       // the transcript has been on screen for a few frames

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
                               geometry: $recordGeometry, onClose: onClose, onRetry: onRetry, onMinimize: onClose)
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

/// The Stop melting into the transcript's bottom toolbar: the Stop's Liquid Glass disc stretches, necks and splits into
/// the bar's two glass shapes (Share and Speakers in one capsule, Delete a circle) while its red square shrinks away
/// and the bar's symbols fade in. The system bar can't do this itself: a toolbar item is at most a 48 pt glass, and
/// only a regular-glass capsule at least ~92 pt wide morphed into the bar's group (a round 48 pt Stop or a red
/// `.glassProminent` one just faded, and Delete never split off the same blob). So these are replicas: two glass shapes
/// in a GlassEffectContainer that start on top of each other on the Stop (one blob) and move to the bar's measured
/// frames; then the real bar is shown under them in the same frame and they go (TranscriptCard.handOver). Only drawn:
/// no touches, hidden from VoiceOver; users and tests always reach the real toolbar.
private struct MeltLayer: View {
    /// nil: on standby, as the Stop (TranscriptCard).
    let clock: TurnClock?
    let stop: CGRect
    let bar: (group: CGRect, delete: CGRect)

    /// From the Stop to the bar, on the turn's clock. A spring of 0.45 s with a little bounce (0.25), like `.bouncy`,
    /// eased onto its end over its last 0.2 s, so it is there at exactly 0.55 s. A SwiftUI `.bouncy(duration: 0.5)`
    /// with completion `.removed` (at `.logicallyComplete` it was still ~2 pt off, a visible jump when the real bar
    /// took over) only completed 1.0–1.4 s after Stop: the bar looked finished for over half a second before its
    /// buttons worked.
    nonisolated static let duration: TimeInterval = 0.55
    nonisolated private static let response: TimeInterval = 0.45
    nonisolated private static let damping = 0.75                       // 1 - bounce

    /// 0 on the Stop, 1 on the bar; past 1 while it overshoots.
    nonisolated static func progress(_ t: TimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        guard t < duration else { return 1 }
        let w = 2 * Double.pi / response, z = damping, wd = w * (1 - z * z).squareRoot()
        let rest = exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))   // what is left of the way
        let ease = min(max((t - (duration - 0.2)) / 0.2, 0), 1)                 // onto exactly 1 at the end
        return 1 - rest * (1 - ease * ease * (3 - 2 * ease))
    }

    var body: some View {
        TimelineView(.animation(paused: clock?.isOver ?? true)) { context in
            frame(at: clock?.time(at: context.date) ?? 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func frame(at t: TimeInterval) -> some View {
        let p = Self.progress(t)
        let group = Self.mix(stop, bar.group, p)
        let delete = Self.mix(stop, bar.delete, p)
        // The red square is gone within 0.1 s, before the glass necks apart: slower, it hung for a few frames as a pink
        // dot in the gap between the two shapes. The symbols fade in from 0.15 s on, over 0.25 s.
        let mark = 1 - min(max(t / 0.1, 0), 1)
        let symbols = min(max((t - 0.15) / 0.25, 0), 1)
        return ZStack(alignment: .topLeading) {
            // The glass alone in the container. Content inside it takes on the glass's vibrancy (the red turned pink,
            // the symbols grey), so the symbols and the red square are drawn above it.
            GlassEffectContainer(spacing: 30) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    glass(group)
                    glass(delete)
                }
            }
            ZStack(alignment: .topLeading) {
                Color.clear
                symbol("square.and.arrow.up", at: Self.shareCentre, in: group, of: bar.group)
                symbol("person.2", at: Self.speakersCentre, in: group, of: bar.group)
                symbol("trash", at: Self.deleteCentre, in: delete, of: bar.delete)
            }
            .opacity(1 - (1 - symbols) * (1 - symbols))     // ease out
            // The Stop's red square shrinks away where the Stop was, instead of riding into the Share capsule.
            RoundedRectangle(cornerRadius: stop.width * 0.08, style: .continuous)
                .fill(.red)
                .frame(width: stop.width * 0.36, height: stop.width * 0.36)
                .scaleEffect(0.2 + 0.8 * mark)
                .opacity(mark * mark)
                .position(x: stop.midX, y: stop.midY)
        }
    }

    /// The frame `p` of the way from `a` to `b`.
    nonisolated private static func mix(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
               width: max(0, a.width + (b.width - a.width) * p), height: max(0, a.height + (b.height - a.height) * p))
    }

    private func glass(_ frame: CGRect) -> some View {
        Color.clear
            .glassEffect(.regular.interactive(), in: Capsule())
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    /// A bar symbol at its measured place in its glass, scaled along while the glass is still the Stop.
    private func symbol(_ name: String, at centre: CGPoint, in frame: CGRect, of final: CGRect) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))      // the bar's symbols (regular was visibly thinner)
            .imageScale(.large)
            .foregroundStyle(Color.primary)
            .position(x: frame.minX + centre.x * frame.width / final.width,
                      y: frame.minY + centre.y * frame.height / final.height)
    }

    // The transcript's bar (Share, Speakers, flexible space, Delete), measured on iOS 27, iPhone 17 (402 × 874 pt),
    // from the system's glass views: Share and Speakers in one capsule (28, 798, 116 × 48), Delete a circle
    // (326, 798, 48 × 48), 28 pt from the screen's edges and 42 pt above the safe area's bottom. The symbols' centres
    // in their glass, from their image views (replicas there match the real bar to 0.02 pt).
    private static let shareCentre = CGPoint(x: 25.33, y: 22.67)
    private static let speakersCentre = CGPoint(x: 85.33, y: 25.0)
    private static let deleteCentre = CGPoint(x: 23.83, y: 23.33)

    static func barItems(in safeArea: CGRect) -> (group: CGRect, delete: CGRect) {
        let y = safeArea.maxY - 42
        return (CGRect(x: 28, y: y, width: 116, height: 48),
                CGRect(x: safeArea.maxX - 28 - 48, y: y, width: 48, height: 48))   // portrait only: safe x = screen x
    }

    /// Only where the bar was measured: iOS 27 on a Face ID iPhone (a home indicator below the bar), text sizes below
    /// the accessibility ones. Elsewhere the bar's glass may sit or be sized differently, and the replicas would jump
    /// when the real bar takes over; there the Stop fades out and the bar fades in instead.
    static func canMelt(_ geometry: RecordGeometry, dynamicTypeSize: DynamicTypeSize) -> Bool {
        guard #available(iOS 27, *) else { return false }
        return geometry.bottomInset > 0 && geometry.stop.width > 0 && !dynamicTypeSize.isAccessibilitySize
    }
}

/// What the card shows, owned by MainView. An observable object the card reads itself, not values handed to the
/// cover's content closure: MainView's body doesn't read them, and the cover then came up with the stale (empty)
/// values of its last evaluation, a blank card.
@MainActor @Observable
final class TranscriptCardContent {
    /// The recording (the accessory shows it too); the card shows it while there is no `transcript`.
    var session: RecordingSession?
    var transcript: Recording?
    /// Opened from a search result: its highlights and "n of m".
    var search: TranscriptSearchContext?
    /// The transcript took the recording's place in the open card (its summary, tags and text fade in).
    var turnedFromRecording = false
    /// Where the card zooms out of and back into: the accessory or a row (`OpenTranscriptAction.rowSource`).
    var sourceID = TranscriptCardContent.recorderSource

    /// The accessory's zoom source id.
    static let recorderSource = "recorder"
}

/// Music's "Now Playing" grabber: a short bar at the top centre of the card says it can be swiped down; a tap closes it
/// too. `hint` says where it goes (back into the accessory while recording, back to the list for a transcript).
struct CardGrabber: View {
    let hint: LocalizedStringKey
    let action: () -> Void

    /// The opaque band at the top that the grabber sits on (its 28 pt row, 8 pt from the top, and a little below it):
    /// content scrolled up disappears under it, so nothing ever sits beside or under the grabber (Music's Now Playing).
    static let band: CGFloat = 34
    /// Below the band, scrolled-away content fades out over this height instead of being cut off at a line.
    static let fade: CGFloat = 12
    /// Where the card's content starts: below the band and its fade (at rest nothing is faded). The recording and the
    /// transcript both start their title here.
    static let contentTop: CGFloat = band + fade

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(width: 80, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Minimize")
        .accessibilityHint(hint)
    }
}

extension View {
    /// The card's grabber floating over the top of this view on an opaque band (also under the status bar), with a
    /// short fade below it. Not a top `safeAreaBar` (which gave the system's scroll edge effect): on iOS 27 that switched
    /// off the transcript's text selection, a long press selected nothing and showed no Copy
    /// (testLongPressMenusKeepTextSelection).
    func cardGrabber(hint: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        overlay(alignment: .top) {
            CardGrabber(hint: hint, action: action)
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: CardGrabber.band)
                            .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .top))   // + status bar
                        LinearGradient(colors: [Color(uiColor: .systemBackground),
                                                Color(uiColor: .systemBackground).opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CardGrabber.fade)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
    }
}

/// Opens a transcript in MainView's card, zooming out of the view marked `.cardSource(sourceID)` (and back into it
/// when the card closes). Set by MainView for the lists and Settings › People › person.
struct OpenTranscriptAction {
    let open: (Recording, TranscriptSearchContext?, String) -> Void

    func callAsFunction(_ recording: Recording, search: TranscriptSearchContext? = nil, sourceID: String) {
        open(recording, search, sourceID)
    }

    /// The zoom source id of a transcript's row in one list. Scoped by list: every tab stays alive in the TabView, so
    /// the same transcript is a row in several lists at once, and an id shared between them zoomed out of a hidden one.
    static func rowSource(_ list: String, _ recording: Recording) -> String { "\(list):\(recording.id)" }
}

extension EnvironmentValues {
    @Entry var openTranscript: OpenTranscriptAction? = nil
    /// The namespace of the card's zoom transition (MainView's).
    @Entry var cardZoom: Namespace.ID? = nil
}

extension View {
    /// Marks this view as where the card zooms out of, and back into, for `sourceID`.
    func cardSource(_ sourceID: String) -> some View {
        modifier(CardSourceModifier(sourceID: sourceID))
    }
}

private struct CardSourceModifier: ViewModifier {
    let sourceID: String
    @Environment(\.cardZoom) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: sourceID, in: namespace)
        } else {
            content                                              // previews: no card
        }
    }
}
