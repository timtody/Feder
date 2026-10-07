import SwiftUI

/// The automatic summary under the date line: secondary text, at most three lines; a longer one shows "More" and the
/// whole summary is the button that expands it (and collapses it again). Opened from a search, its hits are highlighted,
/// so a transcript found only by its summary shows why. VoiceOver reads all of it either way.
/// A caption under it says it is generated and can be wrong (HIG › Generative AI: identify where AI is used and that
/// its output can contain mistakes). "Automatic", not "by Gemma": summaries Apple's model wrote before October 2026
/// stay until Gemma rewrites them.
struct SummaryText: View {
    let summary: String
    let highlights: [Range<String.Index>]

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0           // of the whole summary at this width
    @State private var clippedHeight: CGFloat = 0        // of its first three lines

    private static let lines = 3

    private var isLong: Bool { fullHeight > clippedHeight + 1 }

    var body: some View {
        if isLong {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Automatic Summary")
            .accessibilityIdentifier("Summary")
            .accessibilityValue(summary)
            .accessibilityHint(isExpanded ? "Can contain mistakes. Shows only its first lines." : "Can contain mistakes. Shows all of it.")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Automatic Summary")
                .accessibilityIdentifier("Summary")
                .accessibilityValue(summary)
                .accessibilityHint("Can contain mistakes.")
        }
    }

    private var content: some View {
        let text = SearchHighlight.text(summary, highlights)
        return VStack(alignment: .leading, spacing: 2) {
            text
                .lineLimit(isExpanded ? nil : Self.lines)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .background(alignment: .topLeading) {      // invisible copies: is there more than three lines' worth?
                    ZStack(alignment: .topLeading) {
                        text.fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        text.lineLimit(Self.lines).fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { clippedHeight = $0 }
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
            if isLong {
                Text(isExpanded ? "Less" : "More")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
            Text("Automatic summary · can contain mistakes")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
