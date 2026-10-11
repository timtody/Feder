import SwiftUI
import UIKit

/// App Lock's window (AppLock): its own UIWindow above everything Feder shows (the card's full-screen cover, sheets,
/// alerts, the file picker, TipKit's popovers, the share sheet), which all stay alive underneath. Built once when the
/// scene connects, before its first frame, so covering is only `isHidden = false`, drawn before iOS takes the app
/// switcher's snapshot. While it is up it is the key window (a hardware keyboard can't type into a field underneath),
/// and Feder's own window is hidden from VoiceOver and the UI tests; unlocked, that window is key again (ShareSheet
/// presents on the key window).
@MainActor
final class AppLockWindow {
    private static var current: AppLockWindow?
    private let window: UIWindow

    private init(scene: UIWindowScene, lock: AppLock) {
        window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AppLockView(lock: lock))
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.isHidden = true
    }

    /// RecorderApp.init: whether Feder starts locked is decided now, and the window comes with the scene.
    static func install(_ lock: AppLock) {
        lock.install()
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                guard current == nil, let scene else { return }
                let cover = AppLockWindow(scene: scene, lock: lock)
                current = cover
                lock.present = { cover.show($0) }
                if lock.isCovered { cover.show(true) }
            }
        }
        // At launch SwiftUI makes its window key after the lock's is up: hidden from accessibility too, and the lock
        // takes the keys back on the next turn.
        _ = center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? UIWindow
            MainActor.assumeIsolated {
                guard lock.isCovered, let cover = current, let window, window !== cover.window else { return }
                window.accessibilityElementsHidden = true
                Task { if lock.isCovered { cover.window.makeKey() } }
            }
        }
    }

    private func show(_ shown: Bool) {
        let appWindows = (window.windowScene?.windows ?? []).filter { $0 !== window && $0.windowLevel == .normal }
        if shown {
            window.isHidden = false
            window.makeKey()
            for other in appWindows { other.accessibilityElementsHidden = true }
            window.rootViewController?.view.layoutIfNeeded()   // drawn in this turn, before the snapshot
        } else {
            window.isHidden = true
            for other in appWindows { other.accessibilityElementsHidden = false }
            appWindows.first { !$0.isHidden }?.makeKey()
        }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

/// The lock, like Notes' locked note and Photos' Hidden album: the lock symbol, one line and Unlock on the plain
/// background; no blurred snapshot of what is underneath (titles and shapes survive a blur). While only covering (the
/// app switcher's snapshot, a return within the grace period, the automatic prompt) just the symbol, in the same place,
/// so "Feder Is Locked" doesn't flash as the cover drops.
struct AppLockView: View {
    let lock: AppLock

    var body: some View {
        let prompts = lock.showsPrompt
        ContentUnavailableView {
            Label {
                Text("Feder Is Locked")
                    .opacity(prompts ? 1 : 0)
                    .accessibilityHidden(!prompts)
            } icon: {
                Image(systemName: "lock.fill")
                    .accessibilityHidden(true)
            }
        } description: {
            Text(description)
                .opacity(prompts ? 1 : 0)
                .accessibilityHidden(!prompts)
        } actions: {
            Button("Unlock") {
                Task { await lock.unlock() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(lock.isAuthenticating || !prompts)
            .opacity(prompts ? 1 : 0)
            .accessibilityHidden(!prompts)
        }
        // Fades in after a cancel; gone at once when covering for the snapshot.
        .animation(prompts ? .easeOut(duration: 0.2) : nil, value: prompts)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            if let session = lock.session, session.isOngoing {
                LockRecordingBar(session: session)
            }
        }
    }

    private var description: LocalizedStringKey {
        switch lock.method {
        case .faceID: "Use Face ID to see your transcripts."
        case .touchID: "Use Touch ID to see your transcripts."
        case .passcode: "Enter your passcode to see your transcripts."
        }
    }
}

/// A recording while Feder is locked (started from Control Center, the Action Button, Siri or the widget, or running
/// when Feder was left): its time, level and Stop in a glass capsule at the bottom, laid out like the record
/// accessory's recording state, without its place and without words. Stop without Face ID allows nothing the Live
/// Activity's Stop on the iPhone's Lock Screen doesn't already.
private struct LockRecordingBar: View {
    let session: RecordingSession

    var body: some View {
        HStack(spacing: 0) {
            switch session.state {
            case .recording(let since):
                Button {
                    Task { await session.stop() }
                } label: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.red)
                        .frame(width: 16, height: 16)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("LockStop")
                VStack(alignment: .leading, spacing: 0) {
                    Text(since, style: .timer)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("Recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                LevelMeter(session: session, isActive: true)
            case .finishing, .finished:
                status("Saving…")
            default:
                status("Preparing…")
            }
        }
        .lineLimit(1)
        .padding(.leading, 6)
        .padding(.trailing, 20)
        .frame(height: 56)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func status(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 0) {
            ProgressView()
                .frame(width: 44, height: 44)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
    }
}
