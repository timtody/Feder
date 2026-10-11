import SwiftUI
import UIKit

/// Name Transcripts from Your Calendar (CalendarContext): off until chosen, like voice profiles and iPhone Search. The
/// calendar holds other people's names, and iOS's full calendar access (iOS 17) reads, changes and deletes all events,
/// which its alert says: so the page says what Feder takes from it and that it stays on the iPhone, and two large
/// buttons decide it. "Name from Calendar" asks for access (the system alert, on that tap only; Settings' switch is the
/// other place) and turns it on when given; answered no, the page goes on with it off. Denied earlier, iOS shows no
/// alert, so the page offers the iPhone's Settings instead of a button that seems to do nothing. "No Thanks" leaves it
/// off. Laid out like the iPhone Search page (Onboarding.swift).
struct CalendarOnboardingPage: View {
    let onDone: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @State private var isAsking = false
    @State private var asksForSettings = false

    var body: some View {
        OnboardingLayout(title: "Name Transcripts from Your Calendar") {
            OnboardingRow(symbol: "calendar", title: "Named After the Meeting",
                          text: "Start a transcript during a calendar event, and it gets the event's name.")
            OnboardingRow(symbol: "person.2", title: "Invitees as Speaker Names",
                          text: "When you name a speaker, the people invited to the event are offered first.")
            OnboardingRow(symbol: "lock.fill", title: "Stays on This iPhone",
                          text: "Feder reads your calendar only on this iPhone and keeps just the event's name and its invitees' names with the transcript. We never upload them.")
        } footnote: {
            Text("You can change this any time in Settings.")
        } buttons: {
            ProminentButton("Name from Calendar") {
                isAsking = true
                Task {
                    let result = await services.calendar.enable()
                    isAsking = false
                    if result == .needsSettings { asksForSettings = true } else { onDone() }
                }
            }
            .disabled(isAsking)
            Button {
                services.calendar.disable()
                onDone()
            } label: {
                Text("No Thanks")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(isAsking)
        }
        .alert("Allow Calendar Access", isPresented: $asksForSettings) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                onDone()
            }
            Button("Cancel", role: .cancel) { onDone() }
        } message: {
            Text("Feder can't read your calendar. You can allow it in the iPhone's Settings under Apps › Feder › Calendars.")
        }
    }
}
