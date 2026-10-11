import SwiftUI

/// The card's player in Listen (the toolbar's headphones): play or pause, the playhead's time, a slider to move it,
/// the time left and a close button that ends Listen, in a glass capsule above the bottom toolbar (RecordingDetailView's
/// bottom safe-area bar, so the transcript scrolls under it). Meanwhile the transcript highlights the spoken word and
/// plays from a tapped word (WordParagraph). Only this view reads the player's `time`, which changes 20 times a second
/// while playing.
struct PlayerBar: View {
    let player: TranscriptPlayer
    let recording: Recording
    /// No playback while a recording is being made (one audio session; it would stop the recording).
    let isDisabled: Bool
    /// Ends Listen (the bar goes, playback stops).
    let onClose: () -> Void

    /// The slider's value while it is dragged; the player seeks once it is let go.
    @State private var scrub: TimeInterval?

    private var isMine: Bool { player.recordingID == recording.id }
    private var time: TimeInterval { scrub ?? (isMine ? player.time : 0) }
    private var duration: TimeInterval { max(isMine ? player.duration : recording.duration, 0.1) }

    var body: some View {
        HStack(spacing: 12) {
            controls
                // While a recording is being made, greyed out; the close button stays.
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.5 : 1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Player")
            .accessibilityIdentifier("ClosePlayer")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 48)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, TranscriptStyle.margin)
        .padding(.bottom, 6)
        .onAppear { InteractionTrace.shown("listen") }
        .onChange(of: isMine && player.failed) { _, failed in
            if failed { AccessibilityNotification.Announcement(String(localized: "This recording's audio can't be played.")).post() }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if !isMine { player.load(recording) }
                player.toggle()
            } label: {
                Image(systemName: isMine && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMine && player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("PlayPause")
            Text(time.clockFormatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("PlaybackTime")
            if isMine, player.failed {
                // In the bar, not over the transcript: the slider and times have nothing to show.
                Text("This recording's audio can't be played.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Slider(value: Binding(get: { time }, set: { scrub = $0 }), in: 0...duration) { editing in
                    if !editing, let scrub {
                        if !isMine { player.load(recording) }
                        player.seek(to: scrub)
                        self.scrub = nil
                    }
                }
                .accessibilityLabel("Playback Position")
                Text("-" + max(0, duration - time).clockFormatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
