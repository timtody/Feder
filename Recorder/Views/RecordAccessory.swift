import SwiftUI

/// The tab bar's bottom accessory (Music's mini player spot; the system draws the glass capsule): the record control,
/// in the mini player's sizes (subheadline semibold, a small mark).
/// Without a recording: a red dot and "Transcribe", a tap starts one and opens the transcript card on it out of this
/// accessory (zoom transition, like Music's mini player). While recording: a pulsing red dot, the time, the
/// microphone level and Stop; a tap elsewhere opens the card again.
struct RecordAccessory: View {
    let session: RecordingSession?
    let start: () -> Void
    let open: () -> Void
    /// Reports whether the bar is minimized (the accessory inline), for MainView's Search tab.
    @Binding var isInline: Bool

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var inline: Bool { placement == .inline }

    var body: some View {
        Group {
            switch session?.state {
            case nil, .discarded:
                idle
            case .idle, .preparing, .downloadingSpeechModel:
                status(Text("Preparing…"), busy: true)
            case .recording(let since):
                recording(session!, since: since)
            case .finishing, .finished:
                status(Text("Saving…"), busy: true)
            case .failed:
                status(Text("Can't Record"), busy: false, symbol: "exclamationmark.triangle.fill")
            }
        }
        .padding(.horizontal, inline ? 12 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onChange(of: inline, initial: true) { _, value in
            if isInline != value { isInline = value }
        }
    }

    private var idle: some View {
        Button(action: start) {
            HStack(spacing: 10) {
                RecordDot(size: inline ? 12 : 14)
                Text("Transcribe")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transcribe")                // what it says
        .accessibilityHint("Starts a new recording and its live transcript")
    }

    private func recording(_ session: RecordingSession, since: Date) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                PulsingDot()
                Text(since, style: .timer)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if !inline {
                    LevelMeter(session: session, isActive: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording")
            .accessibilityValue(Text(since, style: .timer))   // the label replaces the combined time: read it too
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            Button {
                #if DEBUG
                InteractionTrace.begin("stop")
                #endif
                Task { await session.stop() }
            } label: {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.red)
                    .frame(width: 13, height: 13)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        }
    }

    private func status(_ title: Text, busy: Bool, symbol: String? = nil) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                } else if let symbol {
                    Image(systemName: symbol).foregroundStyle(.orange)
                }
                title
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The solid red record mark (Voice Memos' red), opaque so it reads on the glass in light and dark mode.
struct RecordDot: View {
    var size: CGFloat = 20

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The record mark pulsing while recording (steady with Reduce Motion).
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RecordDot(size: 10)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
