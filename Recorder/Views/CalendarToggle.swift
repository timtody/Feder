import SwiftUI
import UIKit

/// Settings › Recording › "Name from Calendar" (CalendarContext), right above Save Location, which names transcripts
/// after where they were made as this names them after when. Off until turned on. Turning it on asks for calendar access
/// (the system alert, once), after the tap's frame (the status is read off the main actor); the switch stays on
/// meanwhile instead of springing back under the alert. Denied before, it offers the iPhone's Settings ("Allow Calendar
/// Access") rather than being a switch that does nothing; Open Settings stores it on, so it is on when the user comes
/// back having allowed it (`enableWhenAllowed`). On only while access is given: taken back in the iPhone's Settings, it
/// shows off. Off: nothing is read; transcripts keep the names and invitees they have. The only place that asks for
/// calendar access (not the onboarding: CalendarContext).
///
/// While it is on, "Preferred Calendar" sits below it: the calendar whose events win when several run at a press (the
/// work meeting over the private block in the same hour; `CalendarRules.pick`), None by default. iOS Settings' own
/// Calendar › Default Calendar page: the system's navigation-link picker, the calendars by account with their colours
/// and a checkmark, plus None. It lists every calendar but Birthdays, those subscribed on this iPhone last under
/// "Subscribed Calendars" (an Outlook calendar published as a link): a subscribed calendar's events, and someone else's
/// in a calendar the user can only read, count only while it is chosen here (`CalendarRules.event`). The list comes
/// from the cache's last read (no EventKit call in the tap or the body).
struct CalendarToggle: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @AppStorage(CalendarContext.enabledKey) private var isStoredOn = false
    @State private var isAsking = false
    @State private var asksForSettings = false

    var body: some View {
        let isOn = isAsking || (isStoredOn && services.calendar.isUsable)
        Toggle("Name from Calendar", isOn: Binding(get: { isOn }, set: { on in set(on) }))
            .alert("Allow Calendar Access", isPresented: $asksForSettings) {
                Button("Open Settings") {
                    services.calendar.enableWhenAllowed()
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Feder can't read your calendar. You can allow it in the iPhone's Settings under Apps › Feder › Calendars.")
            }
        if isOn && !isAsking {
            preferredCalendar
        }
    }

    private var preferredCalendar: some View {
        let calendar = services.calendar
        return Picker("Preferred Calendar", selection: Binding(get: { calendar.preferred?.id }, set: { id in
            calendar.prefer(calendar.calendars.first { $0.id == id })
        })) {
            Text("None").tag(String?.none)
            ForEach(CalendarChoice.byAccount(calendar.calendars), id: \.account) { group in
                Section(group.account) {
                    ForEach(group.calendars) { choice in
                        Label {
                            Text(verbatim: choice.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(.sRGB, red: choice.red, green: choice.green, blue: choice.blue))
                        }
                        .tag(Optional(choice.id))
                    }
                }
            }
        }
        .pickerStyle(.navigationLink)
        // The row shows the chosen option's own view as its value, and a Label in a row moves the row's separator to
        // its title: once a calendar was chosen on the page, the divider below began under "Work" instead of at the
        // row's text like the others (FED-64; at launch with one already chosen it didn't). The page's rows keep their
        // separators after the dots, as on iOS's Default Calendar page.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private func set(_ on: Bool) {
        guard on else {
            services.calendar.disable()
            return
        }
        isAsking = true
        Task {
            if await services.calendar.enable() == .needsSettings { asksForSettings = true }
            isAsking = false
        }
    }
}
