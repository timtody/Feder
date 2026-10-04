import SwiftUI

/// One line under the date while work is still being done on the transcript, the way Mail reports "Checking for
/// Mail…": the step that is running now ("Transcribing…", "Identifying speakers…", "Checking vocabulary…", "Writing
/// summary…"), in the date line's secondary type, no symbol, no spinner, no times (those are in the DEBUG log). It is
/// gone the moment the last step ends. Replaces a row of four marks with checkmarks and seconds, which read as a
/// progress panel in a place that should look like a document.
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
        case (.summary, _): return "Writing summary…"
        case (nil, .summary): return "Loading the summary model…"
        case (nil, nil): return nil
        }
    }

    var body: some View {
        if let text = Self.text(for: recording, identifier: services.identifier) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The words change in place with a short crossfade; the line itself never changes height.
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: text)
                .accessibilityIdentifier("PipelineStatus")
        }
    }
}
