import SwiftUI
import UIKit

/// The transcript card while recording (Music's "Now Playing" for a recording; `TranscriptCard`), opened out of the tab
/// bar's record accessory with a zoom transition. Laid out like Voice Memos' recording sheet and exactly like the
/// transcript it turns into: at the top the name the transcript will get and its date line (start time, then the
/// place once it is found), in the transcript's fonts and at its positions; the live transcript below; at the bottom
/// the level meter and the big timer above a large Stop. MainView owns the session (it starts it and handles
/// Saved/Discarded), so swiping the card to the right, or its back button, shrinks it back into the accessory and
/// recording goes on. On Stop the card turns into the transcript in place (`turn`): title and date line stay put, the timer
/// shrinks into the date line's duration, the live text fades out, and the Stop melts into the transcript's toolbar
/// (TranscriptCard). Preparation, model download and every failure are shown as in-screen overlays.
struct RecordView: View {
    let session: RecordingSession
    /// Stop has saved, or is saving, something: the card is turning into the transcript, timed by this clock. The
    /// timer moves into the date line's duration (Reduce Motion: it fades out and the duration in), the live text,
    /// meter and caption fade out, and the Stop gives way to the melt (`melts`: TranscriptCard draws its glass from this
    /// frame on) or fades.
    var turn: TurnClock? = nil
    var melts = false
    /// Where the Stop and the card's safe area are, for the melt.
    var geometry: Binding<RecordGeometry>? = nil
    let onClose: () -> Void                        // the back button (into the accessory, still recording), a failure screen's Close / Cancel
    let onRetry: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?       // keeps the time on screen through `.finishing`
    @ScaledMetric(relativeTo: .subheadline) private var dateLineSize: CGFloat = 15   // .subheadline's size
    @State private var timerFrames = TimerFrames()
    @State private var stopPresses = 0        // haptic on the press itself
    @State private var showsPreparing = false // "Preparing…" only once preparing has taken a moment

    /// The live text's, meter's and caption's fade-out at Stop; then the transcript's body fades in (TranscriptCard).
    /// 0.2 s, not 0.15: even if a frame or two are held up, the fade is still seen as one.
    static let fadeOut: TimeInterval = 0.2

    /// From Stop until the timer has landed in the date line. Until then the card keeps showing this view's title,
    /// date line and timer (TranscriptCard): the transcript is often saved within 0.15 s, and showing its own date
    /// line then cut the flight short.
    static func flightDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0.25 : 0.45 }

    private var turning: Bool { turn != nil }

    /// The turn's timelines tick until everything has arrived, and stand still otherwise.
    private var isMoving: Bool { turn.map { !$0.isOver } ?? false }

    /// The turn's time in a frame (0 while recording).
    private func time(_ date: Date) -> TimeInterval { turn?.time(at: date) ?? 0 }

    /// What is left of something fading out over `duration` from the turn's start: 1 before, 0 after.
    private func remaining(_ date: Date, over duration: TimeInterval) -> Double {
        guard turn != nil else { return 1 }
        return 1 - min(max(time(date) / duration, 0), 1)
    }

    /// The timer's flight, 0 on the big timer, 1 landed; eased in and out (Reduce Motion: linear, it only fades).
    private func flightProgress(_ date: Date) -> CGFloat {
        guard turn != nil else { return 0 }
        let t = min(max(time(date) / Self.flightDuration(reduceMotion: reduceMotion), 0), 1)
        if reduceMotion { return t }
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private var isRecording: Bool {
        if case .recording = session.state { return true }
        return false
    }

    private var isPreparing: Bool {
        switch session.state {
        case .idle, .preparing: true
        default: false
        }
    }

    /// How long preparing may take before "Preparing…" is shown.
    static let preparingDelay: Duration = .milliseconds(400)

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }

    /// The transcript area is replaced by a state overlay outside of recording/finishing.
    private var showsOverlay: Bool {
        switch session.state {
        case .recording, .finishing, .finished, .discarded: false
        case .idle, .preparing, .downloadingSpeechModel, .failed: true
        }
    }

    private var localeCaption: String {
        let identifier = (session.locale ?? RecordingSession.transcriptionLocale).identifier
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? ""
        return String(localized: "\(name) · On device")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .opacity(isFailed ? 0 : 1)
            TimelineView(.animation(paused: !isMoving)) { context in
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(remaining(context.date, over: Self.fadeOut))
            }
            .overlay { stateOverlay }
        }
        // The card's back button, as on a transcript: back into the accessory, still recording.
        .cardCloseButton(hint: "Back to the transcripts; recording goes on", action: onClose)
        .safeAreaBar(edge: .bottom) {                  // a bar: text scrolling under it fades out (scroll edge effect)
            controls
        }
        .coordinateSpace(.named(Self.space))
        .overlay {
            // The one timer: big above the Stop while recording, then shrinking into the date line's duration (both
            // places are hidden stand-ins, measured before Stop).
            if !isFailed, let hero = timerFrames.hero {
                TimelineView(.animation(paused: !isMoving)) { context in
                    let progress = flightProgress(context.date)
                    let slot = reduceMotion ? hero : timerFrames.slot ?? hero
                    timer(progress: progress)
                        .position(x: hero.midX + (slot.midX - hero.midX) * progress,
                                  y: hero.midY + (slot.midY - hero.midY) * progress)
                        .opacity(reduceMotion ? 1 - progress : 1)
                }
                .accessibilityHidden(true)                   // read with the meter ("Recording")
            }
        }
        .onGeometryChange(for: RecordGeometry.self) { proxy in
            RecordGeometry(safeArea: proxy.frame(in: .global), bottomInset: proxy.safeAreaInsets.bottom)
        } action: { value in
            geometry?.wrappedValue.safeArea = value.safeArea
            geometry?.wrappedValue.bottomInset = value.bottomInset
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        // A failure after Stop (the turn had begun) crossfades to its screen instead of cutting to it.
        .animation(.easeOut(duration: 0.25), value: isFailed)
        .onAppear { InteractionTrace.shown("transcribe"); InteractionTrace.shown("reopen") }
        .sensoryFeedback(.impact(weight: .light), trigger: stopPresses)   // with the press, not with the state
        // The spinner comes only when preparing takes a noticeable time (the speech model's first load, a slow
        // permission prompt); normally the card opens straight onto the empty transcript.
        .task(id: isPreparing) {
            showsPreparing = false
            guard isPreparing else { return }
            do { try await Task.sleep(for: Self.preparingDelay) } catch { return }
            showsPreparing = true
        }
        .onChange(of: session.state, initial: true) { _, state in
            if case .recording(let since) = state { startedAt = since }
        }
    }

    // MARK: Header

    /// The transcript's title and date line, at the transcript's positions (RecordingDetailView: same top offset,
    /// margin, fonts and spacing; a Text title sat 1 pt higher than the transcript's TextField, so it is one too).
    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField("Title", text: .constant(session.transcriptName))
                .font(.title2.weight(.bold))
                .allowsHitTesting(false)                    // named once it is saved, in the transcript
                .accessibilityRepresentation {
                    Text(session.transcriptName).accessibilityAddTraits(.isHeader)
                }
            TimelineView(.animation(paused: !isMoving)) { context in
                let progress = flightProgress(context.date)
                TranscriptDateLine(date: startedAt ?? .now, duration: turning ? durationSlot(progress) : nil,
                                   place: session.place?.name, reveal: reduceMotion ? 1 : progress)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                // The same line with the duration, where the timer will land, measured all along: the flight's end
                // has to be known when it starts, and stays put during it. Its text is the timer's.
                TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
                    TranscriptDateLine(date: startedAt ?? .now, duration: Text(timerText(at: context.date))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                            // Fixed from Stop on (measured once more if the card came up during the turn).
                            if !turning || timerFrames.slot == nil { timerFrames.slot = frame }
                        }, place: session.place?.name)
                }
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .padding(.top, CardCloseButton.contentTop)
        .padding(.horizontal, TranscriptStyle.margin)
        .frame(maxWidth: TranscriptStyle.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// The duration in the date line: where the timer lands (with Reduce Motion the duration itself fades in).
    private func durationSlot(_ progress: CGFloat) -> some View {
        Text((session.recordedDuration ?? 0).clockFormatted)
            .opacity(reduceMotion ? progress : 0)
    }

    // MARK: Timer and Stop

    nonisolated private static let space = "RecordView"

    // The turn's motion (timer flight, place moving aside, live text and controls fading) is drawn frame by frame
    // (TimelineViews) on the turn's clock (TurnClock: the frames' own time from the first one drawn after Stop), not
    // with SwiftUI animations: right after Stop the main thread is busy for ~0.1 s (saving, inserting the transcript;
    // simulator), and an implicit fade only started after that, over the timer already in flight. Timed from the
    // moment of Stop instead, the first frame drawn already showed the live text half faded and the timer 24 pt up.
    // (A matched geometry effect for the flight also re-placed the timer without animation when the duration's text
    // changed in a later update.)

    /// The timer, ticking once a second: a TimelineView's text, not a timer text (`Text(_:style: .timer)`), which
    /// can't be stopped on the saved duration without becoming another text.
    private func timer(progress: CGFloat) -> some View {
        TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
            FlyingTimer(text: timerText(at: context.date), dimmed: startedAt == nil, progress: progress,
                        smallSize: dateLineSize)
        }
    }

    /// What the timer says at `date`: the time recorded so far (m:ss, h:mm:ss from an hour); from Stop the saved
    /// duration as the transcript shows it (the file's length, rounded: a little longer than the time on screen),
    /// so it lands on the transcript's digits. RecordingSession sets it in the same update as `.finishing`, so the
    /// text is final before the flight begins and never counts on while saving.
    private func timerText(at date: Date) -> String {
        guard let startedAt else { return "0:00" }
        if let duration = session.recordedDuration { return duration.clockFormatted }
        let seconds = max(0, date.timeIntervalSince(startedAt).rounded(.down))
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// Voice Memos' bottom: the big timer (with the level meter) above the large Stop, and what it transcribes.
    @ViewBuilder
    private var controls: some View {
        if !isFailed {
            TimelineView(.animation(paused: !isMoving)) { context in
                controls(fading: remaining(context.date, over: Self.fadeOut))
            }
        }
    }

    private func controls(fading opacity: Double) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    LevelMeter(session: session, isActive: isRecording)
                    timer(progress: 0)
                        .hidden()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                            if !turning || timerFrames.hero == nil { timerFrames.hero = frame }   // fixed from Stop on
                        }
                    LevelMeter(session: session, isActive: false)
                        .hidden()                         // the timer stays centred
                }
                // For VoiceOver one element: "Recording" and the time (the timer drawn is the overlay's).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
                .accessibilityAddTraits([.isStaticText, .updatesFrequently])
                .accessibilityValue(startedAt.map { Text($0, style: .timer) } ?? Text("0:00"))
                Text(localeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(opacity)
            // Melting: gone in the frame the melt's identical glass appears, not faded out over it.
            stopControl
                .opacity(melts ? (turning ? 0 : 1) : opacity)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    /// The large Stop, dimmed with a spinner while discarding (nothing transcribed); while preparing a stand-in of its
    /// size, so the timer doesn't move (the overlay has Cancel).
    @ViewBuilder
    private var stopControl: some View {
        switch session.state {
        case .recording, .finishing, .finished:
            let isBusy = !isRecording
            Button {
                InteractionTrace.begin("stop")
                stopPresses += 1
                Task { await session.stop() }
            } label: {
                // Busy (dimmed, a spinner) while saving or discarding without a turn: during a turn the Stop is
                // replaced by the melt (or fades) as it stands. (Not `text.isEmpty`: a card opened while saving has no
                // turn, and its Stop looked fully active but did nothing.)
                StopButtonLabel(isBusy: isBusy && !turning)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("Stop")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry?.wrappedValue.stop = $0 }
            .allowsHitTesting(!turning)
            .accessibilityHidden(turning)
        default:
            StopButtonLabel()
                .hidden()
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        if showsOverlay {
            Color.clear
        } else if session.text.isEmpty {
            Text("Listening…")
                .foregroundStyle(.tertiary)
        } else {
            LiveTranscriptView(text: session.text)
        }
    }

    // MARK: State overlays

    @ViewBuilder
    private var stateOverlay: some View {
        switch session.state {
        case .idle, .preparing:
            if showsPreparing {
                VStack(spacing: 24) {
                    ProgressView("Preparing…")
                    Button("Cancel") { session.cancel() }
                }
                .transition(.opacity)
            }
        case .downloadingSpeechModel:
            ContentUnavailableView {
                Label("Preparing Speech Recognition", systemImage: "arrow.down.circle")
            } description: {
                Text("Downloads the on-device speech model once. Everything runs on this iPhone afterwards.")
            } actions: {
                if let progress = session.downloadProgress {
                    ProgressView(progress)
                        .frame(maxWidth: 240)
                }
                Button("Cancel") { session.cancel() }
            }
        case .failed(let error):
            failureOverlay(error)
        case .recording, .finishing, .finished, .discarded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func failureOverlay(_ error: RecorderError) -> some View {
        switch error {
        case .microphoneDenied:
            ContentUnavailableView {
                Label("Microphone Access Off", systemImage: "mic.slash")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { onClose() }
            }
        case .transcriberUnavailable:
            ContentUnavailableView {
                Label("Not Available on This Device", systemImage: "iphone.slash")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Close") { onClose() }
            }
        default:
            ContentUnavailableView {
                Label("Can't Record", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try Again") { onRetry() }
                    .buttonStyle(.borderedProminent)
                Button("Close") { onClose() }
            }
        }
    }
}

#if DEBUG
#Preview {
    RecordView(session: AppServices(container: PreviewData.container).makeRecordingSession(),
               onClose: {},
               onRetry: {})
}
#endif
