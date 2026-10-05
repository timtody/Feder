import SwiftUI

/// One line under the date while work is still being done on the transcript, the way Mail reports "Checking for
/// Mail…": the step that is running now ("Transcribing…", "Identifying speakers…", "Checking vocabulary…", "Correcting
/// text…", "Writing summary…"), in the date line's secondary type, no spinner, no times (those are in the DEBUG log). A
/// band in the label colour sweeps across the words while the step runs, like the status line of the Claude app (`ShimmerText`;
/// still with Reduce Motion), and three bodies on the three-body problem's figure-eight orbit circle in front of them
/// (`ThreeBodyIcon`). It is gone the moment the last step ends. Replaces a row of four marks with checkmarks
/// and seconds, which read as a progress panel in a place that should look like a document.
struct PipelineStatusLine: View {
    let recording: Recording

    @Environment(AppServices.self) private var services

    /// The line's text for `recording`, nil when there is nothing running (no record, or all steps have ended).
    static func text(for recording: Recording, identifier: SpeakerIdentifier) -> String? {
        guard let progress = identifier.progress[recording.id], !progress.isComplete else { return nil }
        let preliminary = recording.speakerCount > 0     // live labels saved at Stop: they are refined, not found
        // The running step, else the next one to come (the gaps between steps are milliseconds; the summary can wait
        // longer, for Gemma to load).
        let running = progress.steps.first { if case .running = progress.state(of: $0) { true } else { false } }
        let waiting = progress.steps.first { progress.state(of: $0) == .waiting }
        switch (running, waiting) {
        case (.words, _), (nil, .words): return "Transcribing…"
        case (.speakers, _), (nil, .speakers): return preliminary ? "Refining speakers…" : "Identifying speakers…"
        case (.vocabulary, _), (nil, .vocabulary): return "Checking vocabulary…"
        case (.corrections, _), (nil, .corrections): return "Correcting text…"
        case (.summary, _): return "Writing summary…"
        case (nil, .summary): return "Loading the summary model…"
        case (nil, nil): return nil
        }
    }

    /// The step running now (nil: none), for the icon's bursts.
    static func runningStep(for recording: Recording, identifier: SpeakerIdentifier) -> PipelineProgress.Step? {
        guard let progress = identifier.progress[recording.id] else { return nil }
        return progress.steps.first { if case .running = progress.state(of: $0) { true } else { false } }
    }

    var body: some View {
        if let text = Self.text(for: recording, identifier: services.identifier) {
            HStack(spacing: 6) {
                ThreeBodyIcon(step: Self.runningStep(for: recording, identifier: services.identifier))
                                                          // lower than the text: the line keeps its height
                ShimmerText(text: text)
                    .lineLimit(1)
                    // The words change in place with a short crossfade; the line itself never changes height.
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: text)
                    .accessibilityIdentifier("PipelineStatus")
            }
            .font(.subheadline)
        }
    }
}

/// A line of secondary text with a band in the label colour sweeping across it, left to right, every `period` seconds: the
/// Claude app's "working" status. The band is the label colour over the secondary one (darker in light mode, brighter
/// in dark mode), drawn as the text's own gradient fill, so nothing is layered over it and the text stays one `Text`
/// (VoiceOver reads it once). With Reduce Motion the text is plain secondary.
struct ShimmerText: View {
    let text: String
    /// One sweep and the pause after it.
    var period: TimeInterval = 1.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(.secondary)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                Text(text).foregroundStyle(Self.fill(at: context.date, period: period))
            }
        }
    }

    /// The band's centre runs from before the text's start to past its end in 75 % of the period (eased), then the
    /// text rests plain for the rest. In unit points of the text's frame, so a short line and a long one take as long.
    nonisolated static func fill(at date: Date, period: TimeInterval) -> LinearGradient {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let sweep = min(t / 0.75, 1)
        let eased = sweep * sweep * (3 - 2 * sweep)
        let halfWidth = 0.25
        let centre = -halfWidth + (1 + 2 * halfWidth) * eased
        let base = Color(uiColor: .secondaryLabel), band = Color(uiColor: .label)
        return LinearGradient(colors: [base, band, base],
                              startPoint: UnitPoint(x: centre - halfWidth, y: 0.5),
                              endPoint: UnitPoint(x: centre + halfWidth, y: 0.5))
    }
}
