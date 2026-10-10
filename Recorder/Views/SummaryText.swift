import SwiftUI

/// The automatic summary under the date line, folded away: one "Summary" row (the system's `DisclosureGroup`) that
/// opens it. Until October 2026 the summary stood open (three lines and "More"), and while Gemma wrote it the header
/// grew and shrank above the transcript (three shimmering lines, then the text line by line, then the final three
/// lines), so the whole transcript moved four times in about 3 s (iPhone 17 simulator, frame by frame). The row is
/// there from the first frame whenever a summary is coming (RecordingDetailView), keeps its height while it is
/// written, and only a tap opens it: open, it shows the text as far as it is written (`SummaryInProgress`), then all
/// of it. Opened from a search with hits in the summary, it starts open, so a transcript found only by its summary
/// shows why. VoiceOver reads the summary as the row's value, also while it is folded.
struct SummaryDisclosure: View {
    let recordingID: UUID
    /// The summary, nil while it is being written.
    let summary: String?
    let highlights: [Range<String.Index>]

    @State private var isExpanded: Bool

    init(recordingID: UUID, summary: String?, highlights: [Range<String.Index>]) {
        self.recordingID = recordingID
        self.summary = summary
        self.highlights = highlights
        _isExpanded = State(initialValue: !highlights.isEmpty)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if let summary {
                    SearchHighlight.text(summary, highlights)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    SummaryInProgress(recordingID: recordingID)
                }
            }
            .padding(.top, 6)
        } label: {
            Group {
                if summary == nil {
                    ShimmerText(text: String(localized: "Summary"))      // being written: the row says so in place
                } else {
                    Text("Summary")
                }
            }
            .fontWeight(.semibold)
            .accessibilityLabel("Summary")
            .accessibilityValue(summary ?? String(localized: "Being written"))
            .accessibilityIdentifier("Summary")
        }
        .font(.subheadline)
    }
}
