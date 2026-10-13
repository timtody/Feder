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

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            label
                .lineLimit(stacked ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                // Taken, it fades out where it stands: removed, the row lost height (the pill is taller than the ⊗)
                // and everything below moved up.
                let isOffer = offer != .taken
                Button("Use as Title", action: onUse)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
                    .opacity(isOffer ? 1 : 0)
                    .disabled(!isOffer)
                    .accessibilityHidden(!isOffer)
                    .accessibilityIdentifier("UseCalendarTitle")
                dismissButton
            }
        }
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
