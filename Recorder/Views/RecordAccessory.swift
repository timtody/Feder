import SwiftUI

/// The tab bar's bottom accessory (Music's mini player spot; the system draws the glass capsule): the record control,
/// in the mini player's sizes (subheadline semibold, a small mark).
/// Without a recording: a red dot, "Transcribe" and under it the language ("German · On device"; "Preparing speaker
/// model…" or Gemma's download, "Downloading Gemma · 42 %", while those run), and at the end a
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
    @Environment(AppServices.self) private var services
    @State private var presses = 0                     // Transcribe and Stop: the haptic comes with the press
    /// TranscriptionLanguage.key: the next recording's language, "" = the standard one (German on a German iPhone,
    /// English otherwise).
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
        .padding(.leading, inline ? 2 : 4)
        .padding(.trailing, inline ? 12 : 14)
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
                HStack(spacing: 0) {
                    markSlot { RecordDot(size: inline ? 14 : 18) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Transcribe")
                            .font(.subheadline.weight(.semibold))
                        if !inline {
                            if services.identifier.isPreparingSpeakerModel {
                                // After a new build or update the speaker model is compiled at launch (about 35 s):
                                // said here, where it is seen without a recording, as the status line says it after Stop.
                                ShimmerText(text: String(localized: "Preparing speaker model…"))
                                    .font(.caption)
                            } else if let download = gemmaDownload {
                                download
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            } else {
                                Text("\(TranscriptionLanguage.name(locale)) · On device")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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

    /// Gemma's background download while it runs (started from the onboarding sheet or Settings): said here, where it
    /// is seen without opening Settings, as Music's mini player shows what is going on. nil otherwise.
    private var gemmaDownload: Text? {
        switch services.betterSummaries.state {
        case .downloading(let fraction):
            Text("Downloading Gemma · \(fraction, format: .percent.precision(.fractionLength(0)))")
        case .waitingForWiFi:
            Text("Gemma · Waiting for Wi-Fi")
        default:
            nil
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

    /// Stop takes the record dot's place, so the control stays under the finger; the rest reads like the idle
    /// state: the time over the language and, once found, the place, and at the end the microphone level.
    private func recording(_ session: RecordingSession, since: Date) -> some View {
        HStack(spacing: 0) {
            Button {
                InteractionTrace.begin("stop")
                presses += 1
                Task { await session.stop() }
            } label: {
                markSlot {
                    RoundedRectangle(cornerRadius: inline ? 3 : 4, style: .continuous)
                        .fill(.red)
                        .frame(width: inline ? 13 : 16, height: inline ? 13 : 16)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(since, style: .timer)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if !inline {
                        Text(recordingDetails(session))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !inline {
                    LevelMeter(session: session, isActive: true)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording")
            .accessibilityValue(Text(since, style: .timer))   // the label replaces the combined time: read it too
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
        }
    }

    /// "German · Mitte, Berlin": the recording's language and, once PlaceLocator has it, where it started.
    private func recordingDetails(_ session: RecordingSession) -> String {
        let language = TranscriptionLanguage.name(session.locale ?? RecordingSession.transcriptionLocale)
        guard let place = session.place?.name, !place.isEmpty else { return language }
        return "\(language) · \(place)"
    }

    /// The leading mark's place, the same in every state (the dot, Stop, the progress spinner), a full touch target
    /// wide, so Stop appears exactly where the record dot was.
    private func markSlot<Mark: View>(@ViewBuilder _ mark: () -> Mark) -> some View {
        mark()
            .frame(width: inline ? 36 : 44, height: 44)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private func status(_ title: Text, busy: Bool, symbol: String? = nil) -> some View {
        Button(action: open) {
            HStack(spacing: 0) {
                markSlot {
                    if busy {
                        ProgressView()
                    } else if let symbol {
                        Image(systemName: symbol).foregroundStyle(.orange)
                    }
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
