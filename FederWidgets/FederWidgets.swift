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

/// While recording: the microphone's level, the running time, the newest words and Stop; from Stop until the
/// transcript is saved "Saving…" and no Stop. No title: the activity is the recording itself, and the words say more.
/// Laid out symmetrically: the level and the time on the left, Stop on the right, both centred on one line; the words
/// under them across the whole width.
struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecording(state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LevelMeter(level: context.state.level, isSaving: context.state.isSaving)
                        RecordingTime(state: context.state).font(.title3.weight(.semibold))
                    }
                    .padding(.leading, 6)
                    .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.isSaving {
                        StopButton().padding(.trailing, 6).frame(maxHeight: .infinity)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveWords(state: context.state)
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                LevelMeter(level: context.state.level, isSaving: context.state.isSaving)
            } compactTrailing: {
                RecordingTime(state: context.state)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                LevelMeter(level: context.state.level, isSaving: context.state.isSaving)
            }
            .keylineTint(.red)
        }
    }
}

private struct LockScreenRecording: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LevelMeter(level: state.level, isSaving: state.isSaving)
                    .font(.title3)
                RecordingTime(state: state)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                if !state.isSaving { StopButton() }
            }
            LiveWords(state: state)
        }
    }
}

/// The level as the waveform symbol filled up to it (`variableValue`), red while recording.
private struct LevelMeter: View {
    let level: Double
    let isSaving: Bool

    var body: some View {
        Image(systemName: "waveform", variableValue: isSaving ? 0 : min(1, 0.15 + level * 1.2))
            .foregroundStyle(.red)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !isSaving && level > 0.05)
            .accessibilityLabel(isSaving ? "Saving…" : "Recording")
    }
}

/// The newest words, two lines, or "Saving…" / "Listening…" when there are none.
private struct LiveWords: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isSaving {
                Text("Saving…")
            } else if state.text.isEmpty {
                Text("Listening…")
            } else {
                Text(state.text)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The time since the recording started, counted by the system (no updates from the app).
private struct RecordingTime: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Image(systemName: "stop.fill")
                .font(.title3)
                .frame(width: 26, height: 26)
                .accessibilityLabel("Stop")
        }
        .tint(.red)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
    }
}

// MARK: Control Center and the Action Button

/// "Transcribe" in Control Center (and on the Action Button, which can run any control): opens Feder recording.
struct TranscribeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.timtody.feder.transcribe") {
            // Feder's feather (a custom symbol from the app icon), not a waveform: that is Voice Memos' control.
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Transcribe", image: "feather")
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
                Image("feather").font(.title2.weight(.semibold))
            }
            .accessibilityLabel("Transcribe")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Transcribe", image: "feather").font(.headline)
                Text("Feder").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Label("Transcribe", image: "feather")
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
