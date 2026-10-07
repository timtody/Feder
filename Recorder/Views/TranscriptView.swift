import SwiftUI

/// The transcript card's transcript: each speaker turn opens with a name row (the speaker's name in its colour, grey while
/// speakers are preliminary, and the turn's start time), followed by the turn's paragraphs.
/// With `renameSpeaker`, the whole name row is a button at least 56 pt tall: full width, from the paragraph above (the
/// gap above the name belongs to it) down to the text below. It shows a band behind the name while pressed and gives a
/// light haptic. A tap, or "Rename Speaker…" in its long-press menu, calls `renameSpeaker`; while speakers are
/// preliminary a tap shows a short notice under the name instead (live labels are not the final speakers, so a name
/// given now could land on someone else).
/// The paragraphs keep the system's text selection (iOS 27: words and ranges, Copy, Look Up, Translate; iOS 26: the
/// whole paragraph, Copy, Share), so they get no menu of their own: a long-press menu there replaces the selection.
/// Opened from a search result, it highlights the search's words and matched speaker names, and marks `currentHit`.
/// Every paragraph has its segment id as view id, so a `ScrollPosition` can scroll to it.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    var speakerName: ((Int) -> String)? = nil      // nil → never show names
    var preliminary = false                        // speaker labels not final yet (live labels until the offline pass)
    var preliminaryNotice = "Speakers are still being identified — you can name them in a moment"
    var renameSpeaker: ((Int) -> Void)? = nil      // nil → names are plain text
    var search: TranscriptSearchContext? = nil
    var currentHit: UUID? = nil
    /// Gets each paragraph's frame in `contentSpace` (set by the card opened from a search, to reveal a hit only when
    /// it is off screen).
    var hitFrame: ((UUID, CGRect) -> Void)? = nil
    /// The stretches of a paragraph whose words a pass just replaced (RecordingDetailView, from
    /// SpeakerIdentifier.recentChanges): shown with a tint that fades (ChangeFlash); nil: none.
    var flashes: ((TranscriptSegment) -> [ChangeFlash])? = nil

    /// The coordinate space of the scroll view's content the paragraph frames are in.
    nonisolated static let contentSpace = "TranscriptContent"

    @Environment(\.colorScheme) private var colorScheme
    @State private var noticeRow: UUID?            // the name row showing the preliminary notice
    @State private var headerTaps = 0              // haptic trigger

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let startsTurn = index == 0 || segments[index - 1].speakerIndex != segment.speakerIndex
                let showsHeader = startsTurn && segment.speakerIndex != nil && speakerName != nil
                VStack(alignment: .leading, spacing: 0) {
                    if showsHeader, let speaker = segment.speakerIndex, let speakerName {
                        header(index: index, segment: segment.id, speaker: speaker, name: speakerName(speaker),
                               start: segment.start)
                            .zIndex(1)   // above the text's selection area, which reaches 16 pt above it on iOS 27
                        if preliminary, noticeRow == segment.id {
                            Label(preliminaryNotice, systemImage: "hourglass")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                                .transition(.opacity)
                                .accessibilityIdentifier("SpeakerNotice")
                        }
                    }
                    paragraph(index: index, segment: segment)
                }
                .id(segment.id)
                // A name row brings the space above its name itself (it is part of the tap target).
                .padding(.top, startsTurn ? (showsHeader ? 0 : TranscriptStyle.turnSpacing) : TranscriptStyle.paragraphSpacing)
            }
        }
        .transcriptText()
        .sensoryFeedback(.impact(weight: .light), trigger: headerTaps)
        .task(id: noticeRow) {
            guard noticeRow != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation { noticeRow = nil }
        }
    }

    private func paragraph(index: Int, segment: TranscriptSegment) -> some View {
        paragraphText(segment)
            .textSelection(.enabled)
            .background {
                if segment.id == currentHit {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.tint.opacity(colorScheme == .dark ? 0.2 : 0.08))
                        .padding(-6)                               // around the text, without moving it
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.contentSpace)) }) { frame in
                hitFrame?(segment.id, frame)
            }
            .accessibilityValue(segment.id == currentHit ? "Current match" : "")
            .accessibilityIdentifier("Paragraph.\(index)")
    }

    /// The paragraph's text: with its search hits highlighted, or, right after a pass replaced some of its words, with
    /// those flashing (not both: a card opened from a search shows the hits).
    @ViewBuilder
    private func paragraphText(_ segment: TranscriptSegment) -> some View {
        if search == nil, let flashes = flashes?(segment), !flashes.isEmpty {
            ChangeFlashText(text: segment.text, flashes: flashes)
        } else {
            SearchHighlight.text(segment.text, search?.highlights(in: segment.text) ?? [])
        }
    }

    @ViewBuilder
    private func header(index: Int, segment: UUID, speaker: Int, name: String, start: TimeInterval) -> some View {
        let line = SpeakerNameLine(name: name, color: preliminary ? .secondary : SpeakerPalette.color(speaker),
                                   start: start, matched: search?.speakers.contains(speaker) == true)
            .padding(.top, TranscriptStyle.turnSpacing)
            .padding(.bottom, TranscriptStyle.nameToText)
            .frame(maxWidth: .infinity, minHeight: TranscriptStyle.headerHeight, alignment: .bottomLeading)
        if let renameSpeaker {
            Button {
                headerTaps += 1
                if preliminary {
                    withAnimation(.snappy) { noticeRow = segment }
                    AccessibilityNotification.Announcement(preliminaryNotice).post()
                } else {
                    renameSpeaker(speaker)
                }
            } label: {
                line.contentShape(Rectangle())                    // the whole row is the target
            }
            .buttonStyle(SpeakerHeaderButtonStyle())
            .contextMenu {
                if !preliminary {
                    Button("Rename Speaker…", systemImage: "pencil") { renameSpeaker(speaker) }
                }
            }
            .accessibilityLabel(name)
            .accessibilityHint(preliminary ? "Speakers are still being identified."
                                           : "Renames this speaker everywhere in this transcript.")
            .accessibilityIdentifier("SpeakerHeader.\(index)")
        } else {
            line
        }
    }
}

/// A speaker's name and the turn's start time. A name the search matched sits on a capsule of the speaker's colour
/// (the name keeps its x position); while the row is pressed a band of that colour lies behind the whole line.
private struct SpeakerNameLine: View {
    let name: String
    let color: Color
    let start: TimeInterval
    let matched: Bool

    @Environment(\.isSpeakerHeaderPressed) private var isPressed

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, matched ? 7 : 0)
                .padding(.vertical, matched ? 2 : 0)
                .background(matched ? color.opacity(0.16) : .clear, in: Capsule())
                .padding(.leading, matched ? -7 : 0)
            Text(start.clockFormatted)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isPressed ? 0.14 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -TranscriptStyle.nameToText)          // down to the text, not over it
        }
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

/// Hands the pressed state to the label (SpeakerNameLine draws it behind the name line only, not the whole tall row).
private struct SpeakerHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.isSpeakerHeaderPressed, configuration.isPressed)
    }
}

private extension EnvironmentValues {
    @Entry var isSpeakerHeaderPressed = false
}

/// Typography and spacing shared by the live and the detail transcript.
enum TranscriptStyle {
    static let textSize: CGFloat = 19              // body is 17; scales with Dynamic Type like body
    static let lineSpacing: CGFloat = 0.3          // extra space between lines, as a fraction of the text size
    static let maxWidth: CGFloat = 600             // comfortable line length where the screen is wider
    static let margin: CGFloat = 20
    static let paragraphSpacing: CGFloat = 14      // same speaker, after a pause
    static let turnSpacing: CGFloat = 30           // a different speaker (above its name)
    static let nameToText: CGFloat = 4             // a speaker's name to the turn's text
    static let headerHeight: CGFloat = 56          // the detail's name row (tap target): turn spacing + name + nameToText
}

extension View {
    /// The transcript's text: slightly larger than body, with more space between lines.
    func transcriptText() -> some View {
        modifier(TranscriptText())
    }
}

private struct TranscriptText: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = TranscriptStyle.textSize

    func body(content: Content) -> some View {
        content
            .font(.system(size: size))
            .lineSpacing(size * TranscriptStyle.lineSpacing)
    }
}

/// One system colour per speaker index, cycling after six.
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    static func color(_ index: Int) -> Color {
        colors[index % colors.count]
    }
}

extension TimeInterval {
    /// Minutes and seconds, e.g. `0:07`, `12:34`, `65:00`. Non-finite or negative values format as `0:00`.
    nonisolated var clockFormatted: String {
        let seconds = isFinite ? Swift.max(0, self) : 0
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

#if DEBUG
#Preview("Final") {
    let recording = PreviewData.sample()
    ScrollView {
        TranscriptView(segments: recording.segments, speakerName: recording.speakerName(_:), renameSpeaker: { _ in })
            .padding(.horizontal, TranscriptStyle.margin)
    }
}

#Preview("Preliminary") {
    let recording = PreviewData.sample()
    ScrollView {
        TranscriptView(segments: recording.segments, speakerName: recording.speakerName(_:), preliminary: true,
                       renameSpeaker: { _ in })
            .padding(.horizontal, TranscriptStyle.margin)
    }
}
#endif

