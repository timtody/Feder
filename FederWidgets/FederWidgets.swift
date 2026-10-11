import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Feder's widget extension: the recording's Live Activity (lock screen and Dynamic Island), the Control Center
/// control that starts a transcript (also for the Action Button), and the lock screen widget that does the same.
/// Everything that acts runs in the app (Shared/RecordingIntents.swift); the extension only draws.
@main
struct FederWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
        TranscribeControl()
        TranscribeLockScreenWidget()
    }
}

// MARK: Live Activity

/// While recording, like Voice Memos': a red dot, the transcript's name, the running time and Stop. From Stop until
/// the transcript is saved: "Saving…" and no Stop.
struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecording(name: context.attributes.name, state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                // The dot in the leading corner and the name under the island in the middle: in the leading region
                // the timer's region squeezed it to "New Tran…".
                DynamicIslandExpandedRegion(.leading) {
                    RecordingDot().padding(.leading, 8).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTime(state: context.state)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isSaving {
                        Text("Saving…").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        StopButton(wide: true)
                    }
                }
            } compactLeading: {
                RecordingDot()
            } compactTrailing: {
                RecordingTime(state: context.state)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                RecordingDot()
            }
            .keylineTint(.red)
        }
    }
}

private struct LockScreenRecording: View {
    let name: String
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(name).lineLimit(1)
                } icon: {
                    RecordingDot()
                }
                .font(.subheadline.weight(.semibold))
                if state.isSaving {
                    Text("Saving…").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    RecordingTime(state: state).font(.title2.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
            if !state.isSaving { StopButton(wide: false) }
        }
    }
}

private struct RecordingDot: View {
    var body: some View {
        Circle().fill(.red).frame(width: 10, height: 10)
            .accessibilityLabel("Recording")
    }
}

/// The time since the recording started, counted by the system (no updates from the app).
private struct RecordingTime: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct StopButton: View {
    let wide: Bool

    var body: some View {
        Button(intent: StopRecordingIntent()) {
            if wide {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            } else {
                Image(systemName: "stop.fill").font(.title2)
                    .accessibilityLabel("Stop")
            }
        }
        .tint(.red)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(wide ? .capsule : .circle)
    }
}

// MARK: Control Center and the Action Button

/// "Transcribe" in Control Center (and on the Action Button, which can run any control): opens Feder recording.
struct TranscribeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.timtody.feder.transcribe") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Transcribe", systemImage: "waveform")
            }
        }
        .displayName("Transcribe")
        .description("Starts a new transcript in Feder.")
    }
}

// MARK: Lock screen widget

struct TranscribeLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.timtody.feder.transcribe.widget", provider: StaticProvider()) { _ in
            TranscribeWidgetView()
                .widgetURL(FederURL.record)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Transcribe")
        .description("Starts a new transcript in Feder.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct TranscribeWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform").font(.title2.weight(.semibold))
            }
            .accessibilityLabel("Transcribe")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Transcribe", systemImage: "waveform").font(.headline)
                Text("Feder").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Label("Transcribe", systemImage: "waveform")
        }
    }
}

private struct StaticProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }

    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
