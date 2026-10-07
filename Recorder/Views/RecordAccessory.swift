import SwiftUI

/// The tab bar's bottom accessory (Music's mini player spot; the system draws the glass capsule): the record control,
/// in the mini player's sizes (subheadline semibold, a small mark).
/// Without a recording: a red dot, "Transcribe" and under it the language ("German · On device"), and at the end a
/// button with the language's code ("DE ⌄") that picks the next recording's language; a tap on the rest starts a
/// recording and opens the transcript card on it out of this accessory (zoom transition, like Music's mini player). While recording: a pulsing red dot, the time, the
/// microphone level and Stop; a tap elsewhere opens the card again.
struct RecordAccessory: View {
    let session: RecordingSession?
    let start: () -> Void
    let open: () -> Void
    /// Reports whether the bar is minimized (the accessory inline), for MainView's Search tab.
    @Binding var isInline: Bool

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var presses = 0                     // Transcribe and Stop: the haptic comes with the press
    /// TranscriptionLanguage.key: the next recording's language, "" = the phone's.
    @AppStorage(TranscriptionLanguage.key) private var language = ""

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
        .sensoryFeedback(trigger: presses) { _, _ in session == nil ? .impact(weight: .medium) : .impact(weight: .light) }
        .onChange(of: inline, initial: true) { _, value in
            if isInline != value { isInline = value }
        }
    }

    /// Like Music's mini player: the title with a line under it ("German · On device") and one control at the end,
    /// here the language of the next recording. Minimized (inline) only the dot and the title, as Music shows only
    /// the title and play there.
    private var idle: some View {
        let locale = TranscriptionLanguage.locale(stored: language)
        return HStack(spacing: 8) {
            Button {
                presses += 1
                start()
            } label: {
                HStack(spacing: 10) {
                    RecordDot(size: inline ? 12 : 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Transcribe")
                            .font(.subheadline.weight(.semibold))
                        if !inline {
                            Text("\(TranscriptionLanguage.name(locale)) · On device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transcribe")                // what it says
            .accessibilityHint("Starts a new recording and its live transcript")
            if !inline {
                languageMenu(locale)
            }
        }
    }

    /// The language of the next recording: the phone's languages first, then the common European ones.
    private func languageMenu(_ current: Locale) -> some View {
        Menu {
            Picker("Language", selection: $language) {
                ForEach(TranscriptionLanguage.choices, id: \.identifier) { locale in
                    Text(TranscriptionLanguage.name(locale)).tag(TranscriptionLanguage.stored(for: locale))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(TranscriptionLanguage.code(current))
                    .font(.subheadline.weight(.semibold))
                    .monospaced()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Language")
        .accessibilityValue(TranscriptionLanguage.name(current))
        .accessibilityHint("The language the next recording is transcribed in")
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
                InteractionTrace.begin("stop")
                presses += 1
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
    let size: CGFloat

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
