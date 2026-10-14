import SwiftUI

/// The automatic summary under the date line, folded away: one "Summary" row (the system's `DisclosureGroup`) that a
/// tap opens and closes. It takes the place of the status line once the pipeline is done (RecordingDetailView), so the
/// summary comes up where "Writing summary…" stood. Until October 2026 the summary stood open (three lines and
/// "More"), and while Gemma wrote it the header grew and shrank above the transcript (three shimmering lines, then the
/// text line by line, then the final three lines), so the whole transcript moved four times in about 3 s (iPhone 17
/// simulator, frame by frame); a folded row of its own under the status line then showed two shimmering lines at
/// once. Opened from a search with hits in the summary, it starts open, so a transcript found only by its summary
/// shows why. VoiceOver reads the summary as the row's value, also while it is folded.
struct SummaryDisclosure: View {
    let summary: String
    let highlights: [Range<String.Index>]

    @State private var isExpanded: Bool

    init(summary: String, highlights: [Range<String.Index>]) {
        self.summary = summary
        self.highlights = highlights
        _isExpanded = State(initialValue: !highlights.isEmpty)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            SearchHighlight.text(summary, highlights)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.top, 6)
        } label: {
            Text("Summary")
                .fontWeight(.semibold)
                .accessibilityLabel("Summary")
                .accessibilityValue(summary)
                .accessibilityIdentifier("Summary")
        }
        .font(.subheadline)
    }

    /// A hidden folded row: what holds the summary's place in the same height before there is one.
    static var standIn: some View {
        DisclosureGroup(isExpanded: .constant(false)) {
            EmptyView()
        } label: {
            Text("Summary").fontWeight(.semibold)
        }
        .font(.subheadline)
        .hidden()
        .accessibilityHidden(true)
    }
}
