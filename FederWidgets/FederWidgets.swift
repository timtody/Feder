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

/// While recording. Lock screen: one row, the running time, the newest words running from right to left, and Stop at
/// the right end; no meter and no title. Dynamic Island: the level meter and the time (compact), the meter (minimal);
/// expanded the meter and the time, Stop, and the words under them. From Stop until the transcript is saved "Saving…"
/// and no Stop.
struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecording(state: context.state)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                // The bookmark on the left next to the time, away from Stop (FED-14); the level meter moves to Stop's side.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        if !context.state.isSaving { BookmarkButton(count: context.state.bookmarks ?? 0) }
                        RecordingTime(state: context.state).font(.title3.weight(.semibold))
                    }
                    .padding(.leading, 6)
                    .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        LevelMeter(level: context.state.level, isSaving: context.state.isSaving)
                        if !context.state.isSaving { StopButton() }
                    }
                    .padding(.trailing, 6)
                    .frame(maxHeight: .infinity)
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
        HStack(spacing: 12) {
            // The bookmark on the left next to the time, away from Stop (FED-14).
            if !state.isSaving { BookmarkButton(count: state.bookmarks ?? 0) }
            RecordingTime(state: state)
                .font(.title3.weight(.semibold))
            LiveWords(state: state)
            if !state.isSaving { StopButton() }
        }
    }
}

/// The level as bars that start small and grow to the right (`cellularbars`), lit up to the loudest level since the
/// last update: the waveform symbol it replaced lit from left to right too, but its bars are tall in the middle, so a
/// louder voice lit smaller bars and it didn't read as a meter.
private struct LevelMeter: View {
    let level: Double
    let isSaving: Bool

    var body: some View {
        Image(systemName: "cellularbars", variableValue: isSaving ? 0 : min(1, level * 1.4))
            .foregroundStyle(.red)
            .accessibilityLabel(isSaving ? "Saving…" : "Recording")
    }
}

/// The newest words in one line, running from right to left: the newest at the right end, older ones moving left at
/// each update and fading out at the left edge (each word keeps its id, so the system animates its move; a new one
/// comes in from the right). "Listening…" before the first word, "Saving…" from Stop; "Recording" while App Lock is on
/// (the app then sends no words).
private struct LiveWords: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isSaving {
                Text("Saving…").frame(maxWidth: .infinity, alignment: .leading)
            } else if state.hidesWords == true {
                Text("Recording").frame(maxWidth: .infinity, alignment: .leading)
            } else if state.words.isEmpty {
                Text("Listening…").frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // A one-line box as wide as the space, the words hung from its right edge (an overlay places a wider
                // view by its alignment; in a frame the row came out centred and was cut at both ends).
                Text(verbatim: " ")
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 4) {
                            ForEach(state.words) { word in
                                Text(word.text).transition(.push(from: .trailing))
                            }
                        }
                        .fixedSize()
                    }
                    .clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The time since the recording started, counted by the system (no updates from the app). Sized by a stand-in of
/// its width ("00:00", "0:00:00" after an hour): a timer text's own ideal width is that of its longest value, and with
/// it the lock screen's row came out empty.
private struct RecordingTime: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(verbatim: Date.now.timeIntervalSince(state.since) >= 3_000 ? "0:00:00" : "00:00")
            .monospacedDigit()
            .hidden()
            .overlay(alignment: .leading) {
                Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .lineLimit(1)
            }
    }
}

/// Adds a bookmark at this moment (AddBookmarkIntent, in the recording app's process: no unlock, Feder stays in the
/// background). Filled, with the count beside it, once there is one: the press's only feedback on the Lock Screen.
private struct BookmarkButton: View {
    let count: Int

    var body: some View {
        Button(intent: AddBookmarkIntent()) {
            HStack(spacing: 3) {
                Image(systemName: count > 0 ? "bookmark.fill" : "bookmark")
                if count > 0 { Text(verbatim: "\(count)").monospacedDigit() }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 26, minHeight: 26)
        }
        .tint(.white)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Add Bookmark")
        .accessibilityValue(count > 0 ? Text("^[\(count) bookmark](inflect: true)") : Text(verbatim: ""))
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
