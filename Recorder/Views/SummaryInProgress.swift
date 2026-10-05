import SwiftUI

/// The summary's place while the model writes it (PipelineProgress.summary running): three shimmering lines until the
/// first words arrive, then the text as far as it is written, new words fading in (WordFadeRenderer, as on the live
/// screen). With Reduce Motion the lines are still and the words just appear. (An Apple Intelligence glyph with the
/// colour wave stood in front of it at first; the status line above already says the summary is being written.)
struct SummaryInProgress: View {
    let recordingID: UUID

    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var births: [Date] = []           // when each word first appeared

    /// Read here, not in the detail view: every streamed piece re-evaluates only this view, not the transcript.
    private var partial: String { services.identifier.partialSummaries[recordingID] ?? "" }

    var body: some View {
        Group {
            if partial.isEmpty {
                ShimmerLines()
            } else {
                streamed
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: partial.isEmpty)
        .onChange(of: partial, initial: true) { _, text in
            let count = text.split(separator: " ", omittingEmptySubsequences: false).count
            if count > births.count { births += Array(repeating: .now, count: count - births.count) }
            else if count < births.count { births.removeLast(births.count - count) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Summary being written")
        .accessibilityValue(partial)
    }

    private var streamed: some View {
        let words = partial.split(separator: " ", omittingEmptySubsequences: false)
        var text = Text(verbatim: "")
        let now = Date.now
        for (i, word) in words.enumerated() {
            var run = Text(verbatim: (i == 0 ? "" : " ") + word)
            let born = i < births.count ? births[i] : now          // not booked yet (onChange follows the body): new
            if !reduceMotion, now.timeIntervalSince(born) < WordFadeRenderer.duration + 0.05 {
                run = run.customAttribute(WordBirth(date: born))
            }
            text = Text("\(text)\(run)")
        }
        let fading = !reduceMotion && (words.count > births.count
                                       || births.contains { now.timeIntervalSince($0) < WordFadeRenderer.duration + 0.05 })
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !fading)) { context in
            text.textRenderer(WordFadeRenderer(now: context.date))
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Three grey lines of a summary's shape with a soft highlight sweeping across them, like a text placeholder before
/// Mail's summary arrives; still with Reduce Motion.
struct ShimmerLines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach([1.0, 0.92, 0.55], id: \.self) { width in
                        Capsule()
                            .fill(.quaternary)
                            .frame(width: proxy.size.width * width, height: 11)
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, Color.primary.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.5)
                        .offset(x: -proxy.size.width * 0.75 + proxy.size.width * 1.75 * phase)
                        .allowsHitTesting(false)
                }
                .clipped()
            }
            .frame(height: 3 * 11 + 2 * 7)
            .padding(.vertical, 4)
        }
        .accessibilityHidden(true)
    }
}
