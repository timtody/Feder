import SwiftUI

/// Settings › App Lock, between Vocabulary and iPhone Search (both are about who sees the transcripts). The switch is
/// named as iOS names its own app lock ("Require Face ID", "Require Touch ID", "Require Passcode"). Turning it on asks
/// for Face ID first: the switch moves at once and springs back if that fails, so it is never on for someone who can't
/// open Feder. Turning it off asks nothing (Settings is reachable only while Feder is unlocked). Without a passcode on
/// the iPhone it is off and disabled. On, "Lock" picks when leaving Feder locks it (Journal's choices).
///
/// iPhone Search gets no switch of its own here: turning App Lock on while Show in iPhone Search is on asks whether to
/// remove the transcripts from it, which turns that setting off (SpotlightIndex deletes the index). Feder is locked
/// whenever Spotlight can be used, so hiding results "while locked" would mean removing them for good anyway, and
/// rebuilding the index at every unlock costs a full pass for nothing.
struct AppLockSection: View {
    @Environment(AppServices.self) private var services
    @AppStorage(AppLock.enabledKey) private var isOn = false
    @AppStorage(AppLock.graceKey) private var grace = 0
    @AppStorage(SpotlightIndex.enabledKey) private var showsInSearch = false
    /// Face ID is being asked for: the switch shows on meanwhile.
    @State private var turningOn = false
    @State private var asksAboutSearch = false

    var body: some View {
        let lock = services.appLock
        Section {
            Toggle(label(lock.method), isOn: lockSwitch)
                .disabled(!lock.canLock)
                .accessibilityIdentifier("AppLock")
                .alert("Hide Transcripts from iPhone Search?", isPresented: $asksAboutSearch) {
                    Button("Remove from iPhone Search") { showsInSearch = false }
                    Button("Keep in iPhone Search", role: .cancel) {}
                } message: {
                    Text("iPhone Search can show their titles, summaries and words while Feder is locked.")
                }
            if isOn && lock.canLock {
                Picker("Lock", selection: $grace) {
                    Text("Immediately").tag(0)
                    Text("After 1 Minute").tag(60)
                    Text("After 5 Minutes").tag(300)
                    Text("After 15 Minutes").tag(900)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("AppLockGrace")
            }
        } header: {
            Text("App Lock")
        } footer: {
            footer(lock)
        }
    }

    /// On at once, then Face ID (AppLock.enable, off the tap's frame); off at once.
    private var lockSwitch: Binding<Bool> {
        Binding(get: { turningOn || (isOn && services.appLock.canLock) }, set: { on in
            guard on else { isOn = false; return }
            guard !turningOn else { return }
            turningOn = true
            Task {
                let enabled = await services.appLock.enable()
                if enabled { isOn = true }
                turningOn = false
                if enabled, showsInSearch { asksAboutSearch = true }
            }
        })
    }

    private func label(_ method: AppLock.Method) -> LocalizedStringKey {
        switch method {
        case .faceID: "Require Face ID"
        case .touchID: "Require Touch ID"
        case .passcode: "Require Passcode"
        }
    }

    @ViewBuilder
    private func footer(_ lock: AppLock) -> some View {
        if !lock.canLock {
            Text("Set a passcode in the iPhone's Settings to lock Feder.")
        } else if isOn {
            switch lock.method {
            case .faceID:
                Text("Feder asks for Face ID when it opens and when you come back. Recording from Control Center, the Action Button or Siri starts at once, and the Live Activity shows no words.")
            case .touchID:
                Text("Feder asks for Touch ID when it opens and when you come back. Recording from Control Center, the Action Button or Siri starts at once, and the Live Activity shows no words.")
            case .passcode:
                Text("Feder asks for your passcode when it opens and when you come back. Recording from Control Center, the Action Button or Siri starts at once, and the Live Activity shows no words.")
            }
        } else {
            Text("Off: anyone using this iPhone can open Feder.")
        }
    }
}
