import SwiftUI
import UIKit

/// Settings › Recording › "Name from Calendar" (CalendarContext), right above Save Location, which names transcripts
/// after where they were made as this names them after when. Off until turned on. Turning it on asks for calendar access
/// (the system alert, once), after the tap's frame (the status is read off the main actor); the switch stays on
/// meanwhile instead of springing back under the alert. Denied before, it offers the iPhone's Settings ("Allow Calendar
/// Access") rather than being a switch that does nothing. On only while access is given: taken back in the iPhone's
/// Settings, it shows off. Off: nothing is read; transcripts keep the names and invitees they have.
struct CalendarToggle: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @AppStorage(CalendarContext.enabledKey) private var isStoredOn = false
    @State private var isAsking = false
    @State private var asksForSettings = false

    var body: some View {
        Toggle("Name from Calendar", isOn: Binding(get: { isAsking || (isStoredOn && services.calendar.isUsable) },
                                                   set: { on in set(on) }))
            .alert("Allow Calendar Access", isPresented: $asksForSettings) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Feder can't read your calendar. You can allow it in the iPhone's Settings under Apps › Feder › Calendars.")
            }
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
