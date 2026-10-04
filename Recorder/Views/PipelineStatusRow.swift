import SwiftUI

/// The transcript's row under the tags while work is still being done on it: the steps after Stop (Words · Speakers ·
/// Vocabulary · Summary, `PipelineProgress`), the one running with Apple's colour wave over its symbol, the finished
/// ones with a drawn checkmark and the time they took; it goes away by itself a moment after the last one. Before the
/// speakers are final it also shows what can't go on: the download note with "Try Again" when the speaker model isn't
/// there, or the failure with "Try Again". Replaces the earlier three status strings, which hid the vocabulary pass and
/// the summary.
struct PipelineStatusRow: View {
    let recording: Recording

    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The box is drawn only around something: a `.processing` transcript without a record (between a launch and
    /// its re-queue) shows nothing, not an empty grey box.
    @ViewBuilder
    private var content: some View {
        let preliminary = recording.speakerCount > 0     // live labels saved at Stop
        let progress = services.identifier.progress[recording.id]
        switch recording.speakerStatus {
        case .pending where progress == nil && !services.identifier.inFlight.contains(recording.id) || services.identifier.modelError != nil:
            VStack(alignment: .leading, spacing: 8) {
                Label(services.identifier.modelError == nil
                      ? (preliminary ? "Speaker labels are preliminary and will be refined shortly."
                                     : "Speakers will be identified shortly.")
                      : (preliminary ? "Speaker labels are preliminary. They'll be refined once the speaker model (21 MB) has downloaded. Connect to the internet and try again."
                                     : "Speakers will be identified once the speaker model (21 MB) has downloaded. Connect to the internet and try again."),
                      systemImage: "person.2.wave.2")
                Button("Try Again") { services.identifier.enqueue(recording) }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label(preliminary ? "Couldn't refine speakers. The labels shown are preliminary." : "Couldn't identify speakers.",
                      systemImage: "exclamationmark.triangle")
                Button("Try Again") { services.identifier.enqueue(recording) }
            }
        default:
            if let progress {
                steps(progress)
            }
        }
    }

    /// One mark per step, left to right. The running step's symbol carries the colour wave (static with Reduce
    /// Motion); a finished step shows a checkmark that draws itself and its time; a waiting one is dimmed.
    private func steps(_ progress: PipelineProgress) -> some View {
        // Fixed spacing, no spacers, no `maxWidth: .infinity`: a row that shared its width out flexibly scrolled the
        // whole content by 10 pt whenever a step changed while the transcript below grew (the refined speakers
        // inserting a turn; pixel track on the iPhone 17 simulator). 10 pt apart the four marks fit a 402 pt
        // iPhone; on a narrower one the labels shrink a little.
        HStack(spacing: 10) {
            ForEach(progress.steps, id: \.self) { step in
                let state = progress.state(of: step) ?? .waiting
                HStack(spacing: 5) {
                    // One image whose symbol changes, not branches: a view swapped inside the row at the moment the
                    // transcript below grew scrolled the whole content by 10 pt (measured on the iPhone 17 simulator).
                    Image(systemName: isDone(state) ? "checkmark.circle.fill" : isFailed(state) ? "xmark.circle" : step.symbol)
                        .foregroundStyle(isDone(state) || isRunning(state) ? AnyShapeStyle(.tint)
                                         : isFailed(state) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing,
                                      options: .repeating, isActive: isRunning(state) && !reduceMotion)
                        .font(.subheadline)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(isRunning(state) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        // Always there, empty until the step is done: the row keeps its height. Growing by a line
                        // when the first step finished, it moved the card's whole content by 4-6 pt (the scroll
                        // view keeps its centre anchored), title and date included.
                        Text(Self.timeText(seconds(of: state)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .opacity(isDone(state) ? 1 : 0)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .animation(.snappy, value: state)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(progress))
        .accessibilityIdentifier("PipelineSteps")
    }

    private func isFailed(_ state: PipelineProgress.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func isDone(_ state: PipelineProgress.State) -> Bool {
        if case .done = state { return true }
        return false
    }

    private func seconds(of state: PipelineProgress.State) -> TimeInterval {
        if case .done(let seconds) = state { return seconds }
        return 0
    }

    private func isRunning(_ state: PipelineProgress.State) -> Bool {
        if case .running = state { return true }
        return false
    }

    /// "3 s", "0.4 s", "1:05".
    private static func timeText(_ seconds: TimeInterval) -> String {
        if seconds >= 60 { return seconds.clockFormatted }
        if seconds >= 10 { return "\(Int(seconds.rounded())) s" }
        return String(format: "%.1f s", seconds)
    }

    private func accessibilityText(_ progress: PipelineProgress) -> String {
        progress.steps.map { step in
            switch progress.state(of: step) ?? .waiting {
            case .waiting: "\(step.title) waiting"
            case .running: "\(step.title) in progress"
            case .done(let seconds): "\(step.title) done in \(Self.timeText(seconds))"
            case .failed: "\(step.title) failed"
            }
        }
        .joined(separator: ", ")
    }
}
