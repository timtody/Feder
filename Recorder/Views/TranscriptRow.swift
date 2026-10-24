import SwiftUI

/// One transcript in a list (the Transcripts tab and the Search results): the title, then one line with date · duration
/// (· place) and the people/tag chips that fit (`MetaLineLayout`), which keeps a row two lines tall, so iOS draws the
/// swipe actions as Voice Memos' pills (`RecordingsListView.minRowHeight`). With a search result: the title's hits
/// highlighted, the matched people, the tags (matched ones filled) and a two-line excerpt around the hit with its
/// speaker's name. A tag chip calls `addTagToken` (a token in the Search tab; the Search tab with it elsewhere).
struct TranscriptRow: View {
    let recording: Recording
    let result: SearchResult?
    let addTagToken: (String) -> Void

    @Environment(AppServices.self) private var services

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                SearchHighlight.text(recording.name, result?.title == recording.name ? result?.titleHighlights ?? [] : [])
                    .font(.headline)
                    .foregroundStyle(Color.primary)            // a button's label: not the accent colour
                    .lineLimit(1)                              // two-line rows keep Voice Memos' swipe pills
                // One line: date · duration (· place) and the people/tag chips that fit, "+n" for the rest. Keeps a row
                // two lines tall, so iOS draws the swipe actions as Voice Memos' pills (see `minRowHeight`).
                // While any step after Stop runs (words, speakers, vocabulary, summary; also queued behind another
                // transcript), the card's shimmering status line takes its place: "Transcribing…", "Identifying
                // speakers…", "Writing summary…" (PipelineStatusLine). It replaced a pulsing people symbol at the row's
                // end, which only covered the speakers and read as a random badge (the user's call); the date line
                // comes back when the last step ends.
                if let status = PipelineStatusLine.text(for: recording, identifier: services.identifier) {
                    ShimmerText(text: status)
                        .font(.subheadline)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: status)
                        .transition(.opacity)
                        .accessibilityIdentifier("RowPipelineStatus")
                } else {
                    metaLine
                        .transition(.opacity)
                }
                if let snippet = result?.snippet {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if recording.speakerStatus == .done, let speaker = snippet.speakerIndex {
                            Text(recording.speakerName(speaker))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        SearchHighlight.text(snippet.text, snippet.highlights)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                } else if let excerpt = result?.summaryExcerpt {
                    SearchHighlight.text(excerpt, result?.summaryHighlights ?? [])
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25),
                   value: PipelineStatusLine.text(for: recording, identifier: services.identifier) == nil)
    }

    /// Date · duration, the place, the people/tag chips and "+n" counters for `MetaLineLayout`, which shows what fits.
    /// (Not ViewThatFits: iOS 26 measures its candidates on SwiftUI's async render thread, and their main-actor
    /// ForEach closures trapped in Swift 6's isolation check when the rows re-laid out.)
    /// VoiceOver reads the line as one element with all of it (date, duration, place, people, tags) and offers a
    /// "Filter by tag" action per tag: the layout parks what doesn't fit off-screen, where it stayed in the
    /// accessibility tree ("1 more, 2 more…") and hidden chips could not be reached anyway.
    private var metaLine: some View {
        var seen = Set<String>()                           // two speakers may share a name: one chip
        let people = (result?.matchedSpeakers ?? []).compactMap { recording.speakerNames[$0] }.filter { seen.insert($0).inserted }
        let tags = recording.tags
        let chipCount = people.count + tags.count
        return MetaLineLayout(chips: chipCount, hasPlace: recording.placeName != nil) {
            HStack(spacing: 4) {
                Text(recording.createdAt.relativeDayText())
                Text("·").accessibilityHidden(true)            // VoiceOver: "Today at 9:41, 0:42", not "·"
                Text(recording.duration.clockFormatted)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let place = recording.placeName {
                HStack(spacing: 4) {
                    Text("·").accessibilityHidden(true)
                    Text(place)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            ForEach(people, id: \.self) { name in
                chip(Label(name, systemImage: "person.fill").labelStyle(ChipLabelStyle()), matched: true)
                    .accessibilityLabel("Speaker \(name)")
            }
            ForEach(tags, id: \.self) { tag in
                Button {
                    addTagToken(tag)
                } label: {
                    chip(Text(tag), matched: result?.matchedTags.contains(tag) ?? false)
                }
                .buttonStyle(.borderless)                      // inside a List row: tapping the chip does not open the row
                .accessibilityLabel("Filter by tag \(tag)")
            }
            ForEach(Array(stride(from: 1, through: max(1, chipCount), by: 1)), id: \.self) { hidden in
                Text("+\(hidden)")                            // one counter per possible number of hidden chips
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // The list's separator starts at the text, as in Voice Memos and Settings. Without this it followed the hidden
        // "+n" counters (FED-74): the layout parks what doesn't fit 10 000 pt to the left, and a Layout without
        // `explicitAlignment` merges its subviews' guides, `listRowSeparatorLeading` too (parked at -10 pt instead, the
        // separator started 10 pt left of the text). So the person page's separators ran from off-screen across its
        // card's edge, and the Transcripts and Search lists' from the screen's edge. Parking elsewhere would only move
        // the problem (to the right, onto the trailing guide; at the origin they are drawn). The closure captures
        // nothing: SwiftUI may lay out off the main thread.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metaAccessibilityLabel(people: people))
        .accessibilityActions {
            ForEach(tags, id: \.self) { tag in
                Button("Filter by tag \(tag)") { addTagToken(tag) }
            }
        }
    }

    /// The meta line for VoiceOver: "Today at 9:41, 0:42, Berlin, Speaker Jonas Weber, Tags: work, planning".
    private func metaAccessibilityLabel(people: [String]) -> String {
        var parts = [recording.createdAt.relativeDayText(), recording.duration.clockFormatted]
        if let place = recording.placeName { parts.append(place) }
        parts += people.map { String(localized: "Speaker \($0)") }
        if !recording.tags.isEmpty {
            let tags = recording.tags.joined(separator: ", ")
            parts.append(recording.tags.count == 1 ? String(localized: "Tag: \(tags)") : String(localized: "Tags: \(tags)"))
        }
        return parts.joined(separator: ", ")
    }

    private func chip(_ content: some View, matched: Bool) -> some View {
        content
            .font(.caption.weight(matched ? .semibold : .regular))
            .foregroundStyle(matched ? AnyShapeStyle(.white) : AnyShapeStyle(Color(.accentOnTint)))   // 5.4:1 on the 12 % tint (the accent 4.2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(matched ? AnyShapeStyle(Color.accentFill) : AnyShapeStyle(.tint.opacity(0.12)), in: Capsule())   // no glass
    }
}

/// Icon and title close together, for chips.
private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
