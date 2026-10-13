import SwiftUI
import UIKit

/// The lock's white status bar on its blue, also in Light Mode (where the default is dark text).
private final class AppLockHost: UIHostingController<AppLockView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

/// App Lock's window (AppLock): its own UIWindow above everything Feder shows (the card's full-screen cover, sheets,
/// alerts, the file picker, TipKit's popovers, the share sheet), which all stay alive underneath. Built when the scene
/// connects, before its first frame, so covering is only `isHidden = false`, drawn before iOS takes the app switcher's
/// snapshot. While it is up it is the key window (a hardware keyboard can't type into a field underneath), and Feder's
/// own window is hidden from VoiceOver and the UI tests; unlocked, that window is key again (ShareSheet presents on the
/// key window).
@MainActor
final class AppLockWindow {
    private static var current: AppLockWindow?
    private let window: UIWindow

    private init(scene: UIWindowScene, lock: AppLock) {
        window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = AppLockHost(rootView: AppLockView(lock: lock))
        host.view.backgroundColor = UIColor(resource: .appLockBackground)
        window.rootViewController = host
        window.isHidden = true
    }

    /// RecorderApp.init: whether Feder starts locked is decided now, and the window comes with the scene. With every
    /// new app scene: UIKit may disconnect a background scene to reclaim its memory while the process lives on (a long
    /// recording keeps it running) and connect a new one at the return, whose SwiftUI window would otherwise have no
    /// lock above it. Not reproduced: on an iPhone `requestSceneSessionDestruction` refuses ("The current device does
    /// not support multiple scenes"), so this may never happen there. Only the app's own role: an external display's
    /// scene (mirroring the screen, lock included) must not take the lock's window away.
    static func install(_ lock: AppLock) {
        lock.install()
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                guard let scene, scene.session.role == .windowApplication, current?.window.windowScene !== scene else {
                    return
                }
                current?.window.isHidden = true             // a scene gone without a disconnect seen
                let cover = AppLockWindow(scene: scene, lock: lock)
                current = cover
                lock.present = { cover.show($0) }
                if lock.isCovered { cover.show(true) }
            }
        }
        _ = center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                guard let cover = current, cover.window.windowScene === scene || cover.window.windowScene == nil else {
                    return
                }
                cover.window.isHidden = true
                current = nil
                lock.present = nil                          // the cover state stays in AppLock for the next scene
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

/// The lock, like a launch screen and banking apps' privacy screens: Feder's feather in white in the middle of one
/// colour, the icon's own deep blue (the bottom stop of its gradient, light and dark: AppLockBackground), with no
/// blurred snapshot of what is underneath (titles and shapes survive a blur). It was the lock symbol on the plain
/// background, like Notes' locked note; the user asked for a coloured screen with the app's icon, then for the feather
/// alone, without the icon's squircle. While only covering (the app switcher's snapshot, a return, the automatic
/// prompt) just the feather, exactly in the middle of the screen, where a launch screen puts an app's image; after a
/// cancel "Feder Is Locked", the method and Unlock fade in below it, and the feather doesn't move: the two flexible
/// halves around it split the height, and only text too large for its half (the largest text sizes) pushes it up. The
/// feather is the icon's own (AppIcon.icon's body.svg, cropped by `build/qa/icon/lock-icon.sh`, a vector template);
/// rerun it when the icon's feather changes.
struct AppLockView: View {
    let lock: AppLock
    /// The bottom safe area, which the layout ignores to centre the icon on the whole screen: the prompt keeps clear of
    /// the home indicator.
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
            Image(.appLockFeather)
                .resizable()
                .scaledToFit()
                .frame(height: 80)                  // as tall as the feather in the 100 pt icon it replaced
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            prompt
                .fixedSize(horizontal: false, vertical: true)   // wrapped, not truncated to its half at large sizes
                .padding(.top, 28)
                .padding(.bottom, bottomInset + 16)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        .background(Color(.appLockBackground))
        .overlay(alignment: .bottom) {
            // Only while covering: the window exists, hidden, whether App Lock is on or not, and the bar's level meter
            // and timer would update with every reading of every recording.
            if lock.isCovered, let session = lock.session, session.isOngoing {
                LockRecordingBar(session: session)
                    .environment(\.colorScheme, .dark)     // white on the blue, as the prompt
            }
        }
    }

    /// White text on the blue in both appearances: the dark scheme for the prompt only, not for the background, which
    /// keeps its light and dark variants.
    private var prompt: some View {
        let prompts = lock.showsPrompt
        return VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Feder Is Locked")
                    .font(.title2.bold())
                Text(description)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .opacity(prompts ? 1 : 0)
            Button {
                Task { await lock.unlock() }
            } label: {
                Text("Unlock")
                    .foregroundStyle(Color(.appLockBackground))   // its dark variant here, navy on the white
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(.white)                               // the accent's blue barely stood out on the blue
            // Dimmed while only covering, still in the accessibility tree: VoiceOver can read "Feder Is Locked" under
            // the Face ID sheet, which is true, and Unlock waits.
            .disabled(lock.isAuthenticating || !prompts)
            .opacity(prompts ? 1 : 0)
        }
        // Fades in after a cancel; gone at once when covering for the snapshot.
        .animation(prompts ? .easeOut(duration: 0.2) : nil, value: prompts)
        .environment(\.colorScheme, .dark)
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
