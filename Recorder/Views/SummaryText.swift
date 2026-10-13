import SwiftUI

/// The automatic summary under the date line, folded away: one "Summary" row (the system's `DisclosureGroup`) that a
/// tap opens and closes. It takes the place of the status line once the pipeline is done (RecordingDetailView), so the
/// summary comes up where "Writing summary…" stood. Until October 2026 the summary stood open (three lines and
/// "More"), and while Gemma wrote it the header grew and shrank above the transcript (three shimmering lines, then the
/// text line by line, then the final three lines), so the whole transcript moved four times in about 3 s (iPhone 17
/// simulator, frame by frame); a folded row of its own under the status line then showed two shimmering lines at
/// once. Opened from a search with hits in the summary, it starts open, so a transcript found only by its summary
/// shows why. VoiceOver reads the summary as the row's value, also while it is folded.
/// Opened, where Gemma can write (FED-15): the summary's style under it, the system's pop-up menu of the five styles;
/// choosing another writes the summary again (SpeakerIdentifier.rewriteSummary). Meanwhile the old text stays, dimmed,
/// and the menu's place says "Writing summary…", so the row keeps its height until the new text replaces the old; the
/// row stays open (the rewrite is not a pipeline step: the status line would take its place). A rewrite that didn't
/// finish (the app left the foreground) says so, with Try Again. Without Gemma nothing about styles shows.
struct SummaryDisclosure: View {
    let recording: Recording
    let summary: String
    let search: TranscriptSearchContext?

    @Environment(AppServices.self) private var services
    @State private var isExpanded: Bool

    init(recording: Recording, summary: String, search: TranscriptSearchContext?) {
        self.recording = recording
        self.summary = summary
        self.search = search
        _isExpanded = State(initialValue: !(search?.highlights(in: summary).isEmpty ?? true))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Text("Summary")
                .fontWeight(.semibold)
                .accessibilityLabel("Summary")
                .accessibilityValue(summary)
                .accessibilityIdentifier("Summary")
        }
        .font(.subheadline)
    }

    /// The open row: the summary in its style, then (with Gemma) its style.
    private var content: some View {
        let written = recording.summaryWrittenStyle
        let rewrite = services.identifier.summaryRewrites[recording.id]
        let canChoose = services.betterSummaries.activeModel != nil
        return VStack(alignment: .leading, spacing: 12) {
            Group {
                if written == .brief {
                    SearchHighlight.text(summary, search?.highlights(in: summary) ?? [])
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    StyledSummaryText(summary: summary, search: search)
                }
            }
            .foregroundStyle(rewrite == .running ? HierarchicalShapeStyle.tertiary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .contentTransition(.opacity)
            if canChoose {
                styleRow(rewrite: rewrite, written: written)
            }
        }
        .padding(.top, 6)
        .animation(.snappy, value: summary)
        .animation(.snappy, value: rewrite)
    }

    /// "Style" and the menu; while a rewrite is queued or running "Writing summary…" in its place (the menu stays
    /// laid out under it, so nothing moves), while recording a line that it follows after Stop. Not finished (the
    /// chosen style isn't the written one and nothing is on its way): that line with Try Again under it.
    private func styleRow(rewrite: SpeakerIdentifier.SummaryRewrite?, written: SummaryStyle) -> some View {
        let chosen = recording.summaryStyle ?? written
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                LabeledContent("Style") {
                    Picker("Summary Style", selection: Binding(get: { chosen }, set: choose)) {
                        ForEach(SummaryStyle.allCases) { style in
                            Label {
                                Text(style.name)
                                Text(style.detail)
                            } icon: {
                                Image(systemName: style.symbol)
                            }
                            .tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .menuOrder(.fixed)
                    .accessibilityIdentifier("SummaryStyle")
                }
                .opacity(rewrite == nil ? 1 : 0)
                .disabled(rewrite != nil)
                .accessibilityHidden(rewrite != nil)
                switch rewrite {
                case .running:
                    ShimmerText(text: String(localized: "Writing summary…"))
                        .lineLimit(1)
                        .accessibilityIdentifier("SummaryRewriting")
                        .onAppear { InteractionTrace.shown("style") }
                case .afterRecording:
                    Text("Written again once the recording has ended.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("SummaryRewriting")
                case nil:
                    EmptyView()
                }
            }
            if rewrite == nil, chosen != written {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Not Finished")
                            .fontWeight(.semibold)
                        Spacer()
                        Button("Try Again") { services.identifier.rewriteSummary(of: recording) }
                            .buttonStyle(.borderless)
                    }
                    Text("Feder didn't finish writing the summary in this style.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SummaryNotFinished")
                .transition(.opacity)
            }
        }
    }

    /// The menu's choice: stored on the transcript, and written again unless it is the style it is in (chosen back).
    /// Only a property and a queue entry in the press: the paragraphs are read in the pass.
    private func choose(_ style: SummaryStyle) {
        InteractionTrace.begin("style")
        recording.summaryStyle = style
        if style != recording.summaryWrittenStyle { services.identifier.rewriteSummary(of: recording) }
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

/// A styled summary's stored lines (TranscriptTitler.parseStyled), as the card draws them: a heading (Meeting's
/// "Decisions"), a "• " bullet, a question ("Q: ", German "F: ") or an answer ("A: "). Pure: the card's body only
/// splits the string.
nonisolated enum SummaryLines {
    enum Kind: Equatable {
        case heading, bullet, question, answer
    }

    struct Line: Equatable {
        var kind: Kind
        var label: String           // "Q:", "F:" or "A:"; empty otherwise
        var text: String
    }

    static func parse(_ summary: String) -> [Line] {
        summary.split(separator: "\n").map { raw in
            let line = String(raw)
            if line.hasPrefix("• ") { return Line(kind: .bullet, label: "", text: String(line.dropFirst(2))) }
            if line.hasPrefix("Q: ") || line.hasPrefix("F: ") {
                return Line(kind: .question, label: String(line.prefix(2)), text: String(line.dropFirst(3)))
            }
            if line.hasPrefix("A: ") { return Line(kind: .answer, label: "A:", text: String(line.dropFirst(3))) }
            return Line(kind: .heading, label: "", text: line)
        }
    }
}

/// A styled summary in the card: headings semibold, bullets with a hanging indent (a first-baseline bullet beside
/// the text: `Text` draws no Markdown lists), questions semibold with their answers under them. Search hits are
/// highlighted line by line.
private struct StyledSummaryText: View {
    let summary: String
    let search: TranscriptSearchContext?

    var body: some View {
        let lines = SummaryLines.parse(summary)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                row(line)
                    // A heading and a question start a group: a little more room above them.
                    .padding(.top, index > 0 && (line.kind == .heading || line.kind == .question) ? 6 : 0)
            }
        }
    }

    @ViewBuilder
    private func row(_ line: SummaryLines.Line) -> some View {
        let text = SearchHighlight.text(line.text, search?.highlights(in: line.text) ?? [])
            .fixedSize(horizontal: false, vertical: true)
        switch line.kind {
        case .heading:
            text.fontWeight(.semibold)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•")
                text
            }
        case .question, .answer:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: line.label)
                    .fontWeight(.semibold)
                text.fontWeight(line.kind == .question ? .semibold : .regular)
            }
        }
    }
}
