import SwiftUI
import TipKit

/// The transcript card's transcript: each speaker turn opens with a name row (the speaker's name in its colour, grey while
/// speakers are preliminary, and the turn's start time), followed by the turn's paragraphs.
/// With `renameSpeaker`, the name row is a button at least 56 pt tall, from the paragraph above (the gap above the name
/// belongs to it) down to the text below, and as wide as the name and its time plus 16 pt: it was the full width until
/// October 2026, so a tap at the right edge renamed a speaker too, and the naming tip's arrow pointed at the middle of
/// the screen instead of the name. It shows a band behind the name while pressed and gives a light haptic. A tap, or "Rename Speaker…" in its long-press menu, calls `renameSpeaker`; while speakers are
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
    var preliminaryNotice = String(localized: "Speakers are still being identified — you can name them in a moment")
    var renameSpeaker: ((Int) -> Void)? = nil      // nil → names are plain text
    var search: TranscriptSearchContext? = nil
    var currentHit: UUID? = nil
    /// Gets each paragraph's frame in `contentSpace` (set by the card opened from a search, to reveal a hit only when
    /// it is off screen).
    var hitFrame: ((UUID, CGRect) -> Void)? = nil
    /// The stretches of a paragraph whose words a pass just replaced (RecordingDetailView, from
    /// SpeakerIdentifier.recentChanges): shown with a tint that fades (ChangeFlash); nil: none.
    var flashes: ((TranscriptSegment) -> [ChangeFlash])? = nil
    /// Shows NameSpeakersTip on the first name row (RecordingDetailView: final speakers, none named yet).
    var showsNameTip = false
    /// Hand corrections from a name row's long-press menu (SpeakerCorrection): its turn to another speaker, or the
    /// speaker merged into another. nil: no such items (live labels, a transcript still being worked on).
    var correctSpeaker: ((SpeakerEdit) -> Void)? = nil
    /// Edit Text: each paragraph is a text field writing into these drafts (by segment id; a paragraph not touched has
    /// none). nil: the paragraphs are text with the system's selection.
    var edits: Binding<[UUID: String]>? = nil
    /// Edit Text's speaker chips: a paragraph moved to another speaker (segment id → speaker index; an index past the
    /// transcript's speakers is a new speaker). Set with `edits`: each paragraph then has a chip above it instead of the
    /// turns' name rows, so one paragraph can go to another speaker (the name row's menu moves a whole turn).
    var speakerEdits: Binding<[UUID: Int]>? = nil
    /// The word being played in a paragraph (the indices of its tokens, counted as WordText splits it), highlighted;
    /// read by the paragraphs themselves (WordParagraph), so the spoken word moving doesn't build the transcript again.
    var playing: ((UUID) -> Range<Int>?)? = nil
    /// A tap on a word (its paragraph and index as WordText splits it): RecordingDetailView plays from it. nil: the
    /// paragraphs are plain text (no audio, editing).
    var onWordTap: ((TranscriptSegment, Int) -> Void)? = nil
    /// The speakers linked to a person (named, or recognized by voice): their name rows' long-press menu has "Go to
    /// Person", which calls `showPerson` with the speaker (RecordingDetailView: the person's page, Apple Music's Go to
    /// Artist). nil: no such item.
    var people: Set<Int> = []
    var showPerson: ((Int) -> Void)? = nil
    /// The bookmarks set while recording, by paragraph (Bookmarks.byParagraph): a line above each paragraph that has
    /// any ("Bookmark · 3:21").
    var bookmarks: [UUID: [TimeInterval]] = [:]

    enum SpeakerEdit {
        case assign(turnStartingAt: UUID, to: Int?)       // nil: a new speaker
        case merge(Int, into: Int)
    }

    /// The coordinate space of the scroll view's content the paragraph frames are in.
    nonisolated static let contentSpace = "TranscriptContent"

    /// The speakers in the transcript, in index order (the correction menus' choices).
    private var speakers: [Int] { Array(Set(segments.compactMap(\.speakerIndex))).sorted() }

    @Environment(\.colorScheme) private var colorScheme
    @State private var noticeRow: UUID?            // the name row showing the preliminary notice
    @State private var headerTaps = 0              // haptic trigger

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let startsTurn = index == 0 || segments[index - 1].speakerIndex != segment.speakerIndex
                let chips = speakerEdits != nil && segment.speakerIndex != nil && speakerName != nil
                let showsHeader = startsTurn && segment.speakerIndex != nil && speakerName != nil && !chips
                VStack(alignment: .leading, spacing: 0) {
                    if chips, let speaker = segment.speakerIndex, let speakerEdits {
                        speakerChip(index: index, segment: segment.id, speaker: speaker, edits: speakerEdits)
                            .padding(.top, startsTurn ? TranscriptStyle.turnSpacing - 8 : 4)
                            .padding(.bottom, TranscriptStyle.nameToText + 2)
                    }
                    if showsHeader, let speaker = segment.speakerIndex, let speakerName {
                        header(index: index, segment: segment.id, speaker: speaker, name: speakerName(speaker),
                               start: segment.start, showsTip: index == 0 && showsNameTip && !preliminary)
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
                    if let times = bookmarks[segment.id] {
                        BookmarkLine(times: times)
                    }
                    paragraph(index: index, segment: segment)
                }
                .id(segment.id)
                // A name row brings the space above its name itself (it is part of the tap target).
                .padding(.top, startsTurn ? (showsHeader ? 0 : TranscriptStyle.turnSpacing) : TranscriptStyle.paragraphSpacing)
            }
        }
        // A pass after Stop (Parakeet's words, the final speakers, the vocabulary) swaps the words in place in one
        // frame, whatever animation the change came with: animated, the re-split paragraphs crossfaded with the old
        // ones and slid up from the bottom of the screen, once per pass. Only the changed words show (ChangeFlash).
        .transaction(value: segments) { $0.animation = nil }
        .transcriptText()
        .sensoryFeedback(.impact(weight: .light), trigger: headerTaps)
        .task(id: noticeRow) {
            guard noticeRow != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation { noticeRow = nil }
        }
    }

    /// Edit Text: the paragraph's speaker (as chosen so far) as a menu of the transcript's speakers, the new ones chosen
    /// for other paragraphs, and New Speaker.
    private func speakerChip(index: Int, segment: UUID, speaker: Int, edits: Binding<[UUID: Int]>) -> some View {
        let chosen = edits.wrappedValue[segment] ?? speaker
        let existing = speakers
        let added = Set(edits.wrappedValue.values).subtracting(existing).sorted()
        let next = max(existing.max() ?? -1, added.max() ?? -1) + 1
        let name = { (index: Int) in speakerName?(index) ?? String(localized: "Speaker \(index + 1)") }
        return Menu {
            ForEach(existing + added, id: \.self) { choice in
                Button {
                    edits.wrappedValue[segment] = choice == speaker ? nil : choice
                } label: {
                    if choice == chosen { Label(name(choice), systemImage: "checkmark") } else { Text(name(choice)) }
                }
            }
            Divider()
            Button("New Speaker", systemImage: "plus") { edits.wrappedValue[segment] = next }
        } label: {
            HStack(spacing: 4) {
                Text(name(chosen))
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(SpeakerPalette.color(chosen))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(SpeakerPalette.color(chosen).opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel(name(chosen))
        .accessibilityHint("Changes the speaker of this paragraph.")
        .accessibilityIdentifier("SpeakerChip.\(index)")
    }

    @ViewBuilder
    private func paragraph(index: Int, segment: TranscriptSegment) -> some View {
        if let edits {
            // The same font and line spacing as the text, so nothing moves when editing starts.
            TextField("", text: Binding(get: { edits.wrappedValue[segment.id] ?? segment.text },
                                        set: { edits.wrappedValue[segment.id] = $0 }), axis: .vertical)
                .accessibilityLabel(segment.speakerIndex.flatMap { speakerName?($0) } ?? String(localized: "Paragraph"))
                .accessibilityIdentifier("ParagraphField.\(index)")
        } else {
            displayedParagraph(index: index, segment: segment)
        }
    }

    private func displayedParagraph(index: Int, segment: TranscriptSegment) -> some View {
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
    /// those flashing (not both: a card opened from a search shows the hits). With audio its words can be tapped and the
    /// spoken one is highlighted (WordParagraph); not while words flash (a few seconds after a pass).
    @ViewBuilder
    private func paragraphText(_ segment: TranscriptSegment) -> some View {
        if search == nil, let flashes = flashes?(segment), !flashes.isEmpty {
            ChangeFlashText(text: segment.text, flashes: flashes)
        } else if let onWordTap {
            WordParagraph(text: segment.text, highlights: search?.highlights(in: segment.text) ?? [],
                          playing: { [playing] in playing?(segment.id) }, onTap: { onWordTap(segment, $0) })
                .equatable()
        } else {
            SearchHighlight.text(segment.text, search?.highlights(in: segment.text) ?? [])
        }
    }

    @ViewBuilder
    private func header(index: Int, segment: UUID, speaker: Int, name: String, start: TimeInterval,
                        showsTip: Bool) -> some View {
        let line = SpeakerNameLine(name: name, color: preliminary ? .secondary : SpeakerPalette.color(speaker),
                                   start: start, matched: search?.speakers.contains(speaker) == true, showsTip: showsTip)
            .padding(.top, TranscriptStyle.turnSpacing)
            .padding(.bottom, TranscriptStyle.nameToText)
            .padding(.trailing, 16)                               // a little room after the time, not the whole width
            .frame(minHeight: TranscriptStyle.headerHeight, alignment: .bottomLeading)
        if let renameSpeaker {
            Button {
                headerTaps += 1
                if preliminary {
                    withAnimation(.snappy) { noticeRow = segment }
                    AccessibilityNotification.Announcement(preliminaryNotice).post()
                } else {
                    NameSpeakersTip().invalidate(reason: .actionPerformed)   // they found it
                    renameSpeaker(speaker)
                }
            } label: {
                line.contentShape(Rectangle())                    // the whole row is the target
            }
            .buttonStyle(SpeakerHeaderButtonStyle())
            .contextMenu {
                if !preliminary {
                    Button("Rename Speaker…", systemImage: "pencil") {
                        NameSpeakersTip().invalidate(reason: .actionPerformed)
                        renameSpeaker(speaker)
                    }
                    if let correctSpeaker {
                        let others = speakers.filter { $0 != speaker }
                        Menu("Assign This Part To", systemImage: "person.crop.circle.badge.checkmark") {
                            ForEach(others, id: \.self) { other in
                                Button(speakerName?(other) ?? "") { correctSpeaker(.assign(turnStartingAt: segment, to: other)) }
                            }
                            Button("New Speaker", systemImage: "plus") {
                                correctSpeaker(.assign(turnStartingAt: segment, to: nil))
                            }
                        }
                        if !others.isEmpty {
                            Menu("Merge Into", systemImage: "arrow.triangle.merge") {
                                ForEach(others, id: \.self) { other in
                                    Button(speakerName?(other) ?? "") { correctSpeaker(.merge(speaker, into: other)) }
                                }
                            }
                        }
                    }
                    if let showPerson, people.contains(speaker) {
                        Section {
                            Button("Go to Person", systemImage: "person.crop.circle") { showPerson(speaker) }
                        }
                    }
                }
            }
            .accessibilityLabel(name)
            .accessibilityHint(preliminary ? "Speakers are still being identified."
                                           : "Renames this speaker everywhere in this transcript.")
            .accessibilityIdentifier("SpeakerHeader.\(index)")
            .frame(maxWidth: .infinity, alignment: .leading)      // the row keeps its place; only the button is narrow
        } else {
            line.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A speaker's name and the turn's start time. A name the search matched sits on a capsule of the speaker's colour
/// (the name keeps its x position); while the row is pressed a band of that colour lies behind the line. The naming tip
/// hangs on the name itself, so its arrow points at the name.
/// A paragraph's bookmarks, above it in the tint ("Bookmark · 3:21"): the moments marked while recording (FED-14). A
/// row rather than a `Label`: on iOS 27 a Label's symbol stayed an element of its own ("Bookmark") even with the
/// children ignored or the symbol hidden, so VoiceOver read the line twice.
private struct BookmarkLine: View {
    let times: [TimeInterval]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "bookmark.fill")
                .accessibilityHidden(true)
            Text(Bookmarks.line(times))
                .accessibilityIdentifier("Bookmark")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.tint)
        .padding(.bottom, 4)
    }
}

private struct SpeakerNameLine: View {
    let name: String
    let color: Color
    let start: TimeInterval
    let matched: Bool
    var showsTip = false

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
                .popoverTip(showsTip ? NameSpeakersTip() : nil, arrowEdge: .top)
                // The page behind the tip stays live (iOS 26): the first tap on the name renames at once. Without it
                // the popover took that tap to close itself, and naming took two taps the first time.
                .tipBackgroundInteraction(.enabled)
            Text(start.clockFormatted)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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

