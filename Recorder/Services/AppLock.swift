import Foundation
import LocalAuthentication
import Observation
import UIKit
#if DEBUG && targetEnvironment(simulator)
import notify
#endif

/// App Lock (Settings › App Lock, off by default): Face ID, Touch ID or the iPhone's passcode before Feder shows a
/// transcript again (LocalAuthentication's `deviceOwnerAuthentication`: Face ID, the passcode after it fails or when
/// Face ID is denied for Feder). It locks at every launch, when the iPhone locks (as far as Feder hears of it:
/// `iPhoneLocked`), and after Feder was left: at once by default, or after 1, 5 or 15 minutes (Journal's choices). The
/// lock is drawn in its own window above everything (AppLockWindow, Views/AppLockView.swift), so the card, sheets,
/// alerts, Edit Text's drafts and a running recording stay alive underneath and come back as they were; an overlay on
/// the tabs would sit under the card's full-screen cover, the sheets and the share sheet.
///
/// Events come from UIKit's notifications, which are synchronous: the cover goes up in `didEnterBackground`, before iOS
/// takes the app switcher's snapshot (SwiftUI's `.background` phase can arrive after it). Nothing happens on
/// `willResignActive`: the Face ID sheet itself, the microphone and location alerts, Control Center and Notification
/// Center all make the app inactive, so covering there would flash over the card at every system alert and loop with
/// the lock's own prompt. The prompt comes by itself once per return (like Journal and banking apps); after a cancel
/// the Unlock button stays, and nothing asks again by itself.
///
/// A recording started from outside while locked (Control Center, the Action Button, Siri, the Lock Screen widget)
/// starts at once behind the lock, whose view shows its time, level and Stop; Face ID is asked once it records, so the
/// microphone alert and the audio session's start never meet the Face ID sheet.
@MainActor @Observable
final class AppLock {
    /// UserDefaults: App Lock is on; absent means off.
    nonisolated static let enabledKey = "appLock"
    /// UserDefaults: seconds away from Feder before it locks (0 "Immediately", 60, 300, 900); absent means 0.
    nonisolated static let graceKey = "appLockGrace"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    nonisolated static var grace: Duration { .seconds(UserDefaults.standard.integer(forKey: graceKey)) }

    /// What unlocks Feder on this iPhone: the switch's and the lock view's wording.
    nonisolated enum Method: Sendable {
        case faceID, touchID, passcode
    }

    /// Feder must be unlocked before it shows anything.
    private(set) var isLocked = false
    /// The lock's window is up (locked, or only covering the app switcher's snapshot within the grace period).
    private(set) var isCovered = false
    /// The whole lock view ("Feder Is Locked", Unlock), not only the lock symbol: after a cancel or a failure. While
    /// the automatic prompt runs, and in the snapshot, only the symbol shows, so the text doesn't flash as the cover
    /// drops.
    private(set) var showsPrompt = false
    private(set) var isAuthenticating = false
    private(set) var method = Method.faceID
    /// A passcode is set: without one nothing can authenticate, so the switch is off and disabled (`passcodeRemoved`).
    private(set) var canLock = true
    /// The recording (MainView's), for the lock view's bar while Feder is locked.
    var session: RecordingSession?

    /// Shows or hides the lock's window at once (AppLockWindow).
    @ObservationIgnored var present: ((Bool) -> Void)?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// When Feder was left: ContinuousClock counts the time asleep and ignores the clock being set back.
    @ObservationIgnored private var leftAt: ContinuousClock.Instant?
    /// The automatic prompt is due at the next activation (launch, return).
    @ObservationIgnored private var promptDue = false
    /// The automatic prompt waits for a recording that is starting (`recordingChanged`).
    @ObservationIgnored private var waitsForRecording = false
    /// A recording is starting (from `.idle` until it records, fails or ends; `recordingChanged`).
    @ObservationIgnored private var recordingStarts = false
    /// Face ID was asked while this recording was starting (by itself, or with Unlock and then cancelled): it isn't
    /// asked again by itself once the recording runs.
    @ObservationIgnored private var askedWhileStarting = false
    /// Within a grace period, Feder kept running after it was left (`stayAwake`), and when that ends.
    @ObservationIgnored private var awake = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var awakeEnds: Task<Void, Never>?
    /// The prompt was interrupted by the system once in this foreground (another alert, Feder left): asked once more.
    @ObservationIgnored private var retriedAfterInterruption = false
    /// Unlock requests so far: the automatic prompt, due a moment after the activation, checks nobody asked meanwhile.
    @ObservationIgnored private var requests = 0
    #if DEBUG && targetEnvironment(simulator)
    /// `-fakeAuthentication success,cancel,…`: the answers in order (the last one repeats), without LocalAuthentication.
    @ObservationIgnored private var fakeOutcomes: [Outcome]?
    #endif

    private enum Outcome {
        case success
        /// Cancelled or not recognized: stays locked, with Unlock.
        case refused
        /// The system took the prompt away (another alert, Feder left): asked again at the next activation.
        case interrupted
        /// No passcode on the iPhone.
        case unavailable
    }

    /// RecorderApp.init, before the scene connects: locked at launch whenever App Lock is on, decided here so the first
    /// frame never shows a transcript.
    func install() {
        #if DEBUG && targetEnvironment(simulator)
        applyTestHooks()
        #endif
        isLocked = Self.isEnabled
        isCovered = isLocked
        promptDue = isLocked
        observe(UIScene.didEnterBackgroundNotification) { $0.enteredBackground() }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { $0.iPhoneLocked() }
        observe(UIApplication.protectedDataDidBecomeAvailableNotification) { $0.iPhoneLocked() }
        observe(UIScene.willEnterForegroundNotification) { $0.enteringForeground() }
        observe(UIScene.didActivateNotification) { $0.activated() }
        Task { await refreshMethod() }
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (AppLock) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        })
    }

    // MARK: Events

    /// Covered before the app switcher's snapshot; locked at once unless a grace period was chosen. The keyboard goes:
    /// its window sits above the lock's, and its suggestions can show typed words.
    private func enteredBackground() {
        guard Self.isEnabled else { return }
        leftAt = .now
        if Self.grace == .zero { isLocked = true } else if !isLocked { stayAwake() }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        showsPrompt = false
        cover()
    }

    /// The iPhone locked: Feder locks whatever the grace period (it is for switching apps, not for a phone left on a
    /// table). iOS posts `protectedDataWillBecomeUnavailable` 10 s after the iPhone locked, to a Feder that is still
    /// running: recording, or kept awake for it within a grace period (`stayAwake`). A suspended app hears nothing at
    /// the time; Apple lists both protected-data notifications among those queued for an app's return, coalesced to the
    /// net change, and after a lock and an unlock that is `protectedDataDidBecomeAvailable` at most (or nothing: then
    /// only the grace period counts; unverified on an iPhone). So that one counts too: data becomes available only
    /// after the iPhone was locked. Arriving after the return's activation (which found Feder unlocked, within the grace
    /// period), it covers again and asks as an activation does, so a recording that is starting still comes first.
    private func iPhoneLocked() {
        endStayingAwake()
        guard Self.isEnabled, !isLocked else { return }
        isLocked = true
        promptDue = true
        cover()
        if UIApplication.shared.applicationState == .active { promptIfDue() }
    }

    /// With a grace period the iPhone locking must still lock Feder, but iOS suspends an app it left a few seconds
    /// after `didEnterBackground`, before the protected-data notification (10 s after the lock) could reach it. A
    /// background task keeps Feder running meanwhile (iOS grants about 30 s), so the common case, the side button
    /// pressed in Feder or soon after leaving it, locks it. It ends at the lock, at the return, when the grace period
    /// is over (it locks at the return anyway) or when iOS takes the time back.
    private func stayAwake() {
        guard awake == .invalid else { return }
        awake = UIApplication.shared.beginBackgroundTask(withName: "App Lock") { [weak self] in
            self?.endStayingAwake()
        }
        let grace = Self.grace
        awakeEnds = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.endStayingAwake()
        }
    }

    private func endStayingAwake() {
        awakeEnds?.cancel()
        awakeEnds = nil
        guard awake != .invalid else { return }
        UIApplication.shared.endBackgroundTask(awake)
        awake = .invalid
    }

    private func enteringForeground() {
        retriedAfterInterruption = false
        endStayingAwake()
        // Also with App Lock off: a passcode set in the iPhone's Settings meanwhile (where the disabled switch's footer
        // sends the user) enables the switch at once, or one removed.
        Task { await refreshMethod() }
        guard isCovered else { return }                 // App Lock was off when Feder was left
        InteractionTrace.begin("return")                // until the cover's gone (`uncover`)
        if !isLocked, let leftAt, ContinuousClock.now - leftAt >= Self.grace { isLocked = true }
        if isLocked {
            promptDue = true
            showsPrompt = false                         // a prompt interrupted by leaving set it meanwhile
        }
    }

    /// Unlocked (within the grace period): the cover goes. Locked: the prompt.
    private func activated() {
        guard isLocked else { uncover(); return }
        promptIfDue()
    }

    /// The prompt, once per return, on a later turn: a start from outside (an App Intent, the widget's link) arrives
    /// after the activation, and its recording comes first.
    private func promptIfDue() {
        guard promptDue else { return }
        promptDue = false
        let asked = requests
        Task {
            // Control Center's and the Action Button's intent is performed after Feder came to the foreground; unverified
            // how long after on an iPhone (README › App Lock).
            try? await Task.sleep(for: .milliseconds(300))
            // Not if a recording that reached `.recording` meanwhile has already asked (and was perhaps cancelled).
            guard isLocked, !isAuthenticating, requests == asked else { return }
            guard UIApplication.shared.applicationState == .active else { promptDue = true; return }
            if isRecordingStarting {
                // Unlock meanwhile, should preparing take long (a speech model's first download).
                waitsForRecording = true
                showsPrompt = true
                return
            }
            await authenticate()
        }
    }

    private var isRecordingStarting: Bool {
        if RecordingControl.shared.pendingStart { return true }
        switch session?.state {
        case .idle, .preparing, .downloadingSpeechModel: return true
        default: return false
        }
    }

    /// MainView, whenever the recording's state changes. A recording started while Feder is locked asks for Face ID
    /// once it records (or failed), not before: the microphone alert and the audio session's start come first. Once
    /// per recording: after Unlock was tapped and cancelled while it prepared (a speech model's first download can take
    /// minutes), nothing asks again by itself when it starts recording.
    func recordingChanged(_ state: RecordingSession.State) {
        switch state {
        case .idle, .preparing, .downloadingSpeechModel:
            if !recordingStarts {                       // its first state (each later change comes here too)
                recordingStarts = true
                askedWhileStarting = isAuthenticating
            }
            if isLocked, !isAuthenticating, !askedWhileStarting { waitsForRecording = true }
        case .recording, .failed:
            recordingStarts = false
            guard isLocked, waitsForRecording else { waitsForRecording = false; return }
            waitsForRecording = false
            Task { await authenticate() }
        case .finishing, .finished, .discarded:
            recordingStarts = false
        }
    }

    // MARK: Unlocking

    /// The lock view's Unlock.
    func unlock() async {
        await authenticate()
    }

    private func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        requests += 1
        // This return's prompt: a recording started from outside can reach `.recording` before the activation (seen
        // on the simulator with a cold start from the link), and the activation must not ask a second time. Nor does
        // a starting recording, once it records.
        promptDue = false
        waitsForRecording = false
        if recordingStarts { askedWhileStarting = true }
        let outcome = await evaluate(reason: String(localized: "Unlock your transcripts."))
        isAuthenticating = false
        switch outcome {
        case .success:
            open()
        case .unavailable:
            passcodeRemoved()
        case .refused:
            showsPrompt = true                          // never asked again by itself: no loop
        case .interrupted:
            showsPrompt = true                          // Unlock, should no activation follow
            if !retriedAfterInterruption {
                retriedAfterInterruption = true
                promptDue = true
            }
        }
    }

    /// The switch in Settings: Face ID (or the passcode) first, so the lock is on only for someone who can open it. This
    /// also brings up iOS's one-time question whether Feder may use Face ID, in context.
    func enable() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        let outcome = await evaluate(reason: String(localized: "Turn on App Lock."))
        isAuthenticating = false
        if outcome == .unavailable { canLock = false }
        return outcome == .success
    }

    private func open() {
        isLocked = false
        showsPrompt = false
        waitsForRecording = false
        uncover()
    }

    /// No passcode on the iPhone any more (removed after App Lock was turned on, which itself needed the passcode):
    /// nothing could unlock Feder, so it opens, and App Lock is turned off, as Settings then shows it (off and
    /// disabled). Off for good, not only shown off: the Live Activity's words, the cover at every return and the
    /// iPhone Search footer all follow the stored setting. With a passcode again, the user turns it on again.
    private func passcodeRemoved() {
        canLock = false
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        open()
    }

    private func cover() {
        guard !isCovered else { return }
        isCovered = true
        present?(true)
    }

    private func uncover() {
        guard isCovered else { return }
        isCovered = false
        present?(false)
        InteractionTrace.shown("return")
    }

    // MARK: LocalAuthentication

    /// One evaluation in a fresh context. A Face ID or Touch ID unlock of the iPhone's Lock Screen within the last 10 s
    /// counts (`touchIDAuthenticationAllowableReuseDuration`, which covers Face ID too), so a recording started from a
    /// locked iPhone (Control Center, the Action Button, the Lock Screen widget, the Live Activity) needs one scan, not
    /// two. 0 would be the strictest; someone handed the phone within those 10 s gets in without a scan.
    private func evaluate(reason: String) async -> Outcome {
        #if DEBUG && targetEnvironment(simulator)
        if var fakes = fakeOutcomes, let next = fakes.first {
            if fakes.count > 1 { fakes.removeFirst() }
            fakeOutcomes = fakes
            try? await Task.sleep(for: .milliseconds(300))
            return next
        }
        #endif
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 10
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return success ? .success : .refused
        } catch let error as LAError {
            switch error.code {
            case .systemCancel, .appCancel, .notInteractive: return .interrupted
            case .passcodeNotSet: return .unavailable
            default: return .refused                       // userCancel, authenticationFailed, userFallback, …
            }
        } catch {
            return .refused
        }
    }

    /// Launch and every return: Face ID, Touch ID or only the passcode, and whether a passcode is set. Without one
    /// Feder opens and App Lock goes off (`passcodeRemoved`); any other answer leaves the lock as it is.
    private func refreshMethod() async {
        #if DEBUG && targetEnvironment(simulator)
        if fakeOutcomes != nil {                       // as on the iPhone 17
            method = .faceID
            canLock = true
            return
        }
        #endif
        let (method, hasPasscode) = await Self.capability()
        self.method = method
        switch hasPasscode {
        case true?:
            canLock = true
        // While the iPhone is locked (a background launch, Gemma's download waking Feder) a passcode is set by
        // definition, whatever LocalAuthentication answers then.
        case false? where UIApplication.shared.isProtectedDataAvailable:
            passcodeRemoved()
        default:
            break
        }
    }

    /// `canEvaluatePolicy` is a synchronous call to the system's authentication daemon: off the main actor. The
    /// biometrics policy first, only for `biometryType` (set by the call whatever it answers). Whether a passcode is
    /// set: nil when the device-owner policy is refused for another reason (the daemon, a background launch, Stolen
    /// Device Protection away from familiar places, …): that must not open Feder, so only `passcodeNotSet` says no.
    @concurrent
    nonisolated private static func capability() async -> (Method, hasPasscode: Bool?) {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let method: Method = switch context.biometryType {
        case .faceID: .faceID
        case .touchID: .touchID
        default: .passcode
        }
        error = nil                                     // the biometrics policy's answer isn't this one's
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return (method, true) }
        let noPasscode = error?.domain == LAErrorDomain && error?.code == LAError.Code.passcodeNotSet.rawValue
        return (method, noPasscode ? false : nil)
    }

    // MARK: UI tests

    #if DEBUG && targetEnvironment(simulator)
    /// `-appLockOn` stores App Lock on (locking Immediately), `-resetAppLock` removes it and the grace period (as on a
    /// new install); written, not passed as an argument value, so a test can still flip the switch.
    /// `-appLockGrace <seconds>` (the argument domain) sets any grace period. `-fakeAuthentication
    /// success|failure|cancel|nopasscode[,…]`: the answers, 0.3 s each, instead of LocalAuthentication, whose sheets a
    /// test can't answer predictably (the iOS 27 simulator has real ones: Face ID once enrolled in Features › Face ID,
    /// otherwise a passcode sheet); `nopasscode` as if the passcode had been removed, while each return's check finds
    /// one again (as after setting a new one).
    private func applyTestHooks() {
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        if arguments.contains("-appLockOn") {
            defaults.set(true, forKey: Self.enabledKey)
            defaults.removeObject(forKey: Self.graceKey)    // a test's grace period comes as `-appLockGrace`
        } else if arguments.contains("-resetAppLock") {
            defaults.removeObject(forKey: Self.enabledKey)
            defaults.removeObject(forKey: Self.graceKey)
        }
        if let list = defaults.string(forKey: "fakeAuthentication") {
            fakeOutcomes = list.split(separator: ",").map {
                switch $0 {
                case "success": .success
                case "nopasscode": .unavailable
                default: .refused
                }
            }
        }
        // The iPhone locking and being unlocked, which the simulator (no passcode) never reports: a UI test posts these
        // Darwin notifications (`notify_post`), reposted here as UIKit's, so the observers above run as on an iPhone.
        // A suspended Feder gets them at its return, coalesced, much as UIKit queues its own.
        let fakes = ["de.timtody.feder.test.iPhoneLocked": UIApplication.protectedDataWillBecomeUnavailableNotification,
                     "de.timtody.feder.test.iPhoneUnlocked": UIApplication.protectedDataDidBecomeAvailableNotification]
        for (name, notification) in fakes {
            var token: Int32 = 0
            notify_register_dispatch(name, &token, .main) { _ in
                NotificationCenter.default.post(name: notification, object: nil)
            }
        }
    }
    #endif
}
