import SwiftUI

/// The card's player: play or pause, the playhead's time, a slider to move it, and the time left, in a glass capsule
/// above the bottom toolbar (RecordingDetailView's bottom safe-area bar, so the transcript scrolls under it). The
/// transcript highlights the spoken word and plays from a tapped word (WordParagraph). Only this view reads the
/// player's `time`, which changes 20 times a second while playing.
struct PlayerBar: View {
    let player: TranscriptPlayer
    let recording: Recording
    /// No playback while a recording is being made (one audio session; it would stop the recording).
    let isDisabled: Bool

    /// The slider's value while it is dragged; the player seeks once it is let go.
    @State private var scrub: TimeInterval?

    private var isMine: Bool { player.recordingID == recording.id }
    private var time: TimeInterval { scrub ?? (isMine ? player.time : 0) }
    private var duration: TimeInterval { max(isMine ? player.duration : recording.duration, 0.1) }

    var body: some View {
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
        .padding(.horizontal, 16)
        .frame(height: 48)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, TranscriptStyle.margin)
        .padding(.bottom, 6)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .overlay(alignment: .top) {
            if isMine, player.failed {
                Text("This recording's audio can't be played.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .offset(y: -18)
            }
        }
    }
}
