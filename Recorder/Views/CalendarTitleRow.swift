import SwiftUI

/// The row under a transcript's date line when it was started during a calendar event (Name from Calendar), on the
/// recording card and on the saved transcript at the same place, so it stays put when one turns into the other:
/// "📅 Design Review  [Use as Title]  ⊗" (`CalendarTitleOffer.offer`). The event never names the transcript by itself
/// (FED-11, the user's decision): the name stays the app's own, "New Transcript N" and later Gemma's title, until Use as
/// Title. ⊗ hides the offer for good (RecordingSession, Recording.dismissCalendarTitle); typing a title takes it away
/// too. Once taken the row goes (FED-135, the user's decision): the title can be renamed like any other, so no
/// "From your calendar" and no ⊗ back to the app's name.
///
/// In the date line's style (subheadline, secondary), the button the system's small bordered capsule, the look of an
/// action within content (the App Store's GET); Liquid Glass is for the navigation layer floating over it. At
/// accessibility sizes the buttons go under the event's name, which then gets up to three lines (AnyLayout: a value, no
/// main-actor closure; not `ViewThatFits`, whose candidates iOS 26 measures off the main thread, see MetaLineLayout).
struct CalendarTitleRow: View {
    /// The event's title.
    let title: String
    let onUse: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void
    /// False on the recording card while it turns into the transcript, whose own row takes over: no taps, and nothing
    /// for VoiceOver.
    var isActive = true

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            label
                .lineLimit(stacked ? 3 : 1)                // the event keeps to one line beside the pill
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                useButton
                dismissButton
            }
        }
        .allowsHitTesting(isActive)
    }

    private var useButton: some View {
        Button("Use as Title", action: onUse)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .font(.subheadline.weight(.semibold))
            .fixedSize()
            .accessibilityHidden(!isActive)
            .accessibilityIdentifier("UseCalendarTitle")
    }

    private var label: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "calendar")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Calendar event “\(title)”"))
        .accessibilityIdentifier("CalendarTitle")
        .accessibilityHidden(!isActive)
    }

    /// The system's clear-button look (a filled circle in a muted grey, as in a search field), on a 44 pt target that
    /// doesn't make the row taller (the padding is taken back outside the button).
    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-10)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("DismissCalendarTitle")
        .accessibilityHidden(!isActive)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 24) {
        CalendarTitleRow(title: "Design Review", onUse: {}, onDismiss: {})
        CalendarTitleRow(title: "Quarterly planning with the whole product and design team", onUse: {},
                         onDismiss: {})
    }
    .padding()
}
#endif
