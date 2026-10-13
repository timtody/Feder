import Foundation
import Network
import Observation

/// The network the automatic model downloads depend on, watched for the app's lifetime (one NWPathMonitor). Replaced
/// a one-shot check at launch and foreground (`ModelDownload.isExpensiveNetwork`), which treated "no network" as
/// Wi-Fi (an unsatisfied path is neither expensive nor constrained: Nemotron tried, failed and said "Download
/// Failed"), never noticed Wi-Fi arriving while the app was open, and called Low Data Mode or a hotspot "Waiting for
/// Wi-Fi" while the status bar showed Wi-Fi. `kind` names the reason; listeners (AppServices) start waiting downloads
/// when it turns `.wifi` and retry the speaker model when a connection comes back.
@MainActor @Observable
final class NetworkPath {
    enum Kind: Equatable, Sendable {
        case wifi          // Wi-Fi or Ethernet, not in Low Data Mode
        case cellular      // cellular or a Personal Hotspot (NWPath.isExpensive)
        case lowData       // Low Data Mode, on any network (NWPath.isConstrained)
        case offline       // no usable path
    }

    /// nil until the monitor's first update (it comes right after start).
    private(set) var kind: Kind?
    @ObservationIgnored private var listeners: [(Kind) -> Void] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Kind, Never>] = []
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if let fake = Self.fakeKind {
            kind = fake
            scheduleFakeWiFi()
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = Self.kind(of: path)
            Task { @MainActor in self?.update(kind) }
        }
        monitor.start(queue: DispatchQueue(label: "Feder.network"))
    }

    nonisolated static func kind(of path: NWPath) -> Kind {
        guard path.status == .satisfied else { return .offline }
        if path.isConstrained { return .lowData }
        if path.isExpensive { return .cellular }
        return .wifi
    }

    /// The current kind, waiting for the monitor's first update if needed.
    func current() async -> Kind {
        if let kind { return kind }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Called on every change (not for the first value), on the main actor.
    func onChange(_ listener: @escaping (Kind) -> Void) {
        listeners.append(listener)
    }

    private func update(_ new: Kind) {
        let old = kind
        guard new != old else { return }
        kind = new
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume(returning: new) }
        if old != nil { listeners.forEach { $0(new) } }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator QA: `-fakeNoWiFi` (cellular), `-fakeLowData`, `-fakeOffline`; `-fakeWiFiAfter <s>` then switches to
    /// Wi-Fi after that many seconds, as if the phone joined a Wi-Fi network while the app is open. `-fakeWiFi` (the UI
    /// tests' default, the others win over it): Wi-Fi whatever the Mac is on. The simulator shares the Mac's network, and
    /// a Mac on an iPhone's Personal Hotspot (expensive, and constrained with Low Data Mode) kept every fake download
    /// "Waiting for Wi-Fi" or "Low Data Mode", so the tests expecting one to run failed (2026-10-13).
    private static var fakeKind: Kind? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-fakeOffline") { return .offline }
        if arguments.contains("-fakeLowData") { return .lowData }
        if arguments.contains("-fakeNoWiFi") { return .cellular }
        if arguments.contains("-fakeWiFi") { return .wifi }
        return nil
    }

    private func scheduleFakeWiFi() {
        let seconds = UserDefaults.standard.double(forKey: "fakeWiFiAfter")
        guard seconds > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.update(.wifi)
        }
    }
    #endif
}
