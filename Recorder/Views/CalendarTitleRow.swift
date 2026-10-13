import SwiftUI

/// The row under a transcript's date line when it was started during a calendar event (Name from Calendar), on the
/// recording card and on the saved transcript at the same place, so it stays put when one turns into the other:
/// "📅 Design Review  [Use as Title]  ⊗", and once taken "📅 From your calendar  ⊗" (`CalendarTitleOffer`). The event
/// never names the transcript by itself (FED-11, the user's decision): the name stays the app's own, "New Transcript N"
/// and later Gemma's title, until Use as Title. ⊗ hides the offer for good, and after Use as Title gives the app's name
/// back (RecordingSession, Recording.dismissCalendarTitle). Typing a title takes it away too.
///
/// In the date line's style (subheadline, secondary), the button the system's small bordered capsule, the look of an
/// action within content (the App Store's GET); Liquid Glass is for the navigation layer floating over it. At
/// accessibility sizes the buttons go under the event's name, which then gets up to three lines (AnyLayout: a value, no
/// main-actor closure; not `ViewThatFits`, whose candidates iOS 26 measures off the main thread, see MetaLineLayout).
struct CalendarTitleRow: View {
    let offer: CalendarTitleOffer
    let onUse: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void
    /// False on the recording card while it turns into the transcript, whose own row takes over: no taps, and nothing
    /// for VoiceOver.
    var isActive = true

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        // Taken, beside the label, the pill's place gives its width to the label, which then reaches the ⊗. Under it
        // (accessibility sizes) the label has its own line anyway, and the ⊗ stays where it was.
        let freesWidth = offer == .taken && !stacked
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            label
                // The offer's event keeps to one line beside the pill; "From your calendar" may take a second one
                // should a narrow screen or a large size still not fit it.
                .lineLimit(stacked ? 3 : offer == .taken ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: freesWidth ? 0 : 10) {
                // A hidden stand-in keeps the pill's height once it is gone: removed, the row lost height (the pill is
                // taller than the ⊗) and everything below moved up. Beside the label its height only, not its width:
                // kept, that width cut "Aus deinem Kalender" to "Aus deinem Kale…" (FED-11). Not the pill itself kept
                // at opacity 0 with `accessibilityHidden`: on the recording card it stayed in the accessibility tree,
                // a dimmed "Use as Title" (CalendarTests).
                ZStack {
                    useButton(action: {})
                        .hidden()
                        .frame(width: freesWidth ? 0 : nil)
                    if case .offer = offer {
                        useButton(action: onUse)
                            .accessibilityHidden(!isActive)
                            .accessibilityIdentifier("UseCalendarTitle")
                            .transition(.opacity)
                    }
                }
                dismissButton
            }
        }
        .allowsHitTesting(isActive)
    }

    private func useButton(action: @escaping @MainActor () -> Void) -> some View {
        Button("Use as Title", action: action)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .font(.subheadline.weight(.semibold))
            .fixedSize()
    }

    private var label: some View {
        Label {
            switch offer {
            case .offer(let title): Text(title)
            case .taken: Text("From your calendar")
            }
        } icon: {
            Image(systemName: "calendar")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("CalendarTitle")
        .accessibilityHidden(!isActive)
    }

    private var accessibilityText: Text {
        switch offer {
        case .offer(let title): Text("Calendar event “\(title)”")
        case .taken: Text("From your calendar")
        }
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
        .accessibilityHint(offer == .taken ? Text("Gives the transcript back the name Feder gave it") : Text(verbatim: ""))
        .accessibilityIdentifier("DismissCalendarTitle")
        .accessibilityHidden(!isActive)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 24) {
        CalendarTitleRow(offer: .offer("Design Review"), onUse: {}, onDismiss: {})
        CalendarTitleRow(offer: .offer("Quarterly planning with the whole product and design team"), onUse: {},
                         onDismiss: {})
        CalendarTitleRow(offer: .taken, onUse: {}, onDismiss: {})
    }
    .padding()
}
#endif
