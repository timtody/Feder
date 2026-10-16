#if DEBUG
import Foundation
import Network
import Observation
import UIKit
import AVFAudio

/// Feder Link spike (FED-141), Debug builds only: does Feder keep receiving a stream from the Mac while the iPhone is
/// locked? It finds the Mac's test sender (`build/qa/linkspike/sender.swift`, Bonjour `_federlink._tcp`), receives its
/// 10 messages a second and measures what a real Link would suffer: gaps between messages, lag (the two clocks matched by
/// a ping every 2 s, the round trip with the least delay of the last 15 counting), reconnects, the Wi-Fi path, and what
/// the app went through meanwhile (locked, background, a recording, audio interruptions). Everything goes into a log in
/// Documents/maclink/ (shared from Settings › About › Mac Link Test), with a summary line a minute.
///
/// It only receives and measures: the audio isn't transcribed (that is FED-109). Feder stays awake in the background only
/// while a normal recording runs, which is what the spike tests; without one, iOS suspends Feder and the stream stalls
/// (the control run). Wire format: see sender.swift.
@MainActor @Observable
final class MacLinkProbe {
    static let shared = MacLinkProbe()

    private(set) var isRunning = false
    private(set) var snapshot = MacLinkSnapshot()
    private(set) var logURL: URL?

    @ObservationIgnored private var receiver: MacLinkReceiver?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var isRecording: () -> Bool = { false }

    /// Starts browsing for the Mac (the Local Network alert comes now, in the foreground) and logging.
    func start(isRecording: @escaping () -> Bool) {
        guard !isRunning else { return }
        self.isRecording = isRecording
        let receiver = MacLinkReceiver()
        self.receiver = receiver
        logURL = receiver.logURL
        isRunning = true
        receiver.start()
        observeApp()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let receiver = self.receiver else { return }
                let context = self.appContext()
                receiver.snapshot(context: context) { snapshot in
                    Task { @MainActor in self.snapshot = snapshot }
                }
            }
        }
    }

    func stop() {
        refresh?.cancel()
        refresh = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        receiver?.stop(context: appContext())
        receiver = nil
        isRunning = false
    }

    /// What the app is going through, for the log: locked, in the background, recording, background time left.
    private func appContext() -> String {
        let app = UIApplication.shared
        let state = switch app.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let remaining = app.backgroundTimeRemaining
        let left = remaining > 1e6 ? "∞" : String(format: "%.0f s", remaining)
        return "\(state), \(app.isProtectedDataAvailable ? "unlocked" : "locked"), "
            + "\(isRecording() ? "recording" : "not recording"), background time \(left)"
    }

    private func observeApp() {
        let center = NotificationCenter.default
        // The text is made from the notification where it arrives (a Notification isn't Sendable), then logged with the
        // app's state on the main actor.
        func on(_ name: Notification.Name, _ text: @escaping @Sendable (Notification) -> String) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let event = text(note)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.receiver?.log("app: \(event) [\(self.appContext())]")
                }
            })
        }
        on(UIApplication.protectedDataWillBecomeUnavailableNotification) { _ in "locked" }
        on(UIApplication.protectedDataDidBecomeAvailableNotification) { _ in "unlocked" }
        on(UIApplication.didEnterBackgroundNotification) { _ in "entered background" }
        on(UIApplication.willEnterForegroundNotification) { _ in "entering foreground" }
        on(UIApplication.didReceiveMemoryWarningNotification) { _ in "memory warning" }
        on(AVAudioSession.interruptionNotification) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .began ? "began" : "ended"
            return "audio interruption \(type)"
        }
        on(AVAudioSession.routeChangeNotification) { _ in
            "audio route: \(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", "))"
        }
    }
}

/// What the screen shows, built on the receiver's queue.
struct MacLinkSnapshot: Sendable {
    var state = "Not started"
    var mac: String?
    var path = "–"
    var messages = 0
    var kilobytes = 0
    var reconnects = 0
    var lagP50: Double?
    var lagP99: Double?
    var lagMax: Double?
    var longestGap: Double = 0
    var gapsOver1s = 0
    var clockOffset: Double?
    var lastMessageAgo: Double?
    var events: [String] = []
}

/// The network side, on its own serial queue: every property is touched only there.
nonisolated final class MacLinkReceiver: @unchecked Sendable {
    static let serviceType = "_federlink._tcp"

    let logURL: URL
    private let queue = DispatchQueue(label: "de.timtody.feder.maclink")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var connectedMac: String?
    private let pathMonitor = NWPathMonitor()
    private var pathText = "–"
    private var state = "Starting"
    private var stopped = false
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var file: FileHandle?

    // Measurements (the whole run) and the minute's (reset by each summary line).
    private var messages = 0, bytes = 0, reconnects = 0, gapsOver1s = 0
    private var lagBuckets = [Int](repeating: 0, count: MacLinkReceiver.buckets)    // 1 ms each, the last one 10 s and more
    private var minuteBuckets = [Int](repeating: 0, count: MacLinkReceiver.buckets)
    private static let buckets = 10_001
    private var minuteStarted = MacLinkReceiver.monotonicNanos()
    private var lagMax = 0.0, minuteLagMax = 0.0, longestGap = 0.0, minuteGap = 0.0, minuteMessages = 0
    private var lastArrival: UInt64?                               // monotonicNanos
    private var lastSeq: UInt64?
    private var pongs: [(rtt: Double, offset: Double)] = []        // offset = Mac clock − iPhone clock, seconds
    private var events: [String] = []
    private var minuteNegativeLags = 0
    private var silenceLogged = 0                                  // seconds of the current silence already logged

    init() {
        let folder = URL.documentsDirectory.appending(path: "maclink")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Local time, as the Mac's sender logs it and the lock screen shows it (ISO 8601's default is UTC).
        let name = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .time(includingFractionalSeconds: false).timeSeparator(.omitted).dateTimeSeparator(.standard))
        logURL = folder.appending(path: "maclink-\(name).log")
        // Written while locked: the default class (until first unlock), stated so a later default can't change it.
        FileManager.default.createFile(atPath: logURL.path(), contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        file = try? FileHandle(forWritingTo: logURL)
    }

    func start() {
        queue.async { [self] in
            write("probe started (local time, \(TimeZone.current.identifier))")
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let kinds = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
                    .filter { path.usesInterfaceType($0) }.map { "\($0)" }
                self.pathText = "\(path.status) via \(kinds.joined(separator: "+"))\(path.isConstrained ? ", low data" : "")"
                self.log("path: \(self.pathText)")
            }
            pathMonitor.start(queue: queue)
            browse()
        }
    }

    func stop(context: String) {
        queue.async { [self] in
            log("probe stopped [\(context)]")
            summary(context: context)
            stopped = true
            pingTimer?.cancel()
            browser?.cancel()
            connection?.cancel()
            pathMonitor.cancel()
            try? file?.close()
            file = nil
        }
    }

    nonisolated func log(_ text: String) {
        queue.async { [self] in write(text) }
    }

    /// On the queue: one line in the file, and the screen's last few.
    private func write(_ text: String) {
        let line = "\(Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: true))) \(text)"
        events.append(line)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        if let data = (line + "\n").data(using: .utf8) { try? file?.write(contentsOf: data) }
    }

    // MARK: Finding and connecting

    private func browse() {
        guard !stopped else { return }
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        let id = ObjectIdentifier(browser)              // not the browser itself: a weak capture is a var to Swift 6
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.write("browser: \(state)")
            switch state {
            case .waiting: self.state = "Waiting for Local Network access"
            case .failed:                              // mDNSResponder restarted, or Feder came back from suspension
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, !self.stopped, self.browser.map(ObjectIdentifier.init) == id else { return }
                    self.browse()
                }
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let result = results.first else { return }
            self.connect(to: result.endpoint)
        }
        state = "Looking for the Mac"
        self.browser = browser
        browser.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint) {
        guard !stopped else { return }
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            // A Mac that vanished without a FIN (lid closed, off Wi-Fi) fails the connection in ~10 s, not after TCP's
            // minutes of retransmits. Not a stricter watchdog of our own: a locked iPhone's Wi-Fi power save pauses
            // delivery for seconds, and reconnecting on that would turn a slow stream into fake drops.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 4
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        if case .service(let name, _, _, _) = endpoint { connectedMac = name }
        self.connection = connection
        buffer = Data()
        lastSeq = nil
        state = "Connecting"
        write("connecting to \(endpoint)")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, connection === self.connection else { return }
            switch state {
            case .ready:
                self.state = "Receiving"
                let interface = connection.currentPath?.availableInterfaces.first.map { "\($0.type) \($0.name)" } ?? "?"
                self.write("connected via \(interface)")
                self.receive(on: connection)
                self.startPings(on: connection)
            case .waiting(let error):
                self.state = "Waiting: \(error)"
                self.write("connection waiting: \(error)")
            case .failed(let error):
                self.write("connection failed: \(error)")
                self.reconnect()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A refused or unreachable connect waits (TCP's ECONNREFUSED is .waiting, not .failed) and retries only on a
        // path change: a stale Bonjour result (the sender restarted on a new port) would hold the probe forever.
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection else { return }
            if case .ready = connection.state { return }
            self.write("connect timed out in \(connection.state)")
            self.reconnect()
        }
    }

    /// After a drop: the next result of a fresh browse, a second later.
    private func reconnect() {
        pingTimer?.cancel()
        connection?.cancel()
        connection = nil
        guard !stopped else { return }
        reconnects += 1
        state = "Reconnecting"
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.browse() }
    }

    // MARK: Receiving

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection else { return }
            if let data { self.buffer.append(data); self.parse() }
            if isComplete || error != nil {
                self.write("stream ended: \(error.map { "\($0)" } ?? "closed by the Mac")")
                self.reconnect()
                return
            }
            self.receive(on: connection)
        }
    }

    private func parse() {
        while buffer.count >= 5 {
            let type = buffer[buffer.startIndex]
            let length = Int(buffer.bigEndian(UInt32.self, at: 1))
            guard buffer.count >= 5 + length else { return }
            let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 5 + length))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 5 + length))
            switch type {
            case 1 where payload.count >= 16: audio(seq: payload.bigEndian(UInt64.self, at: 0),
                                                    macNanos: payload.bigEndian(UInt64.self, at: 8), bytes: 5 + length)
            case 3 where payload.count >= 16: pong(phoneNanos: payload.bigEndian(UInt64.self, at: 0),
                                                   macNanos: payload.bigEndian(UInt64.self, at: 8))
            default: break
            }
        }
    }

    private func audio(seq: UInt64, macNanos: UInt64, bytes count: Int) {
        let arrival = Self.monotonicNanos()
        messages += 1
        minuteMessages += 1
        bytes += count
        if let lastSeq, seq != lastSeq + 1 { write("sequence jumped \(lastSeq) → \(seq)") }
        lastSeq = seq
        if let lastArrival {
            let gap = Double(arrival - lastArrival) / 1e9
            longestGap = max(longestGap, gap)
            minuteGap = max(minuteGap, gap)
            if gap > 1 {
                gapsOver1s += 1
                write(String(format: "gap of %.1f s before message %llu", gap, seq))
            }
        }
        lastArrival = arrival
        silenceLogged = 0
        if let offset = clockOffset {
            let lag = Self.seconds(Self.nowNanos()) - (Self.seconds(macNanos) - offset)
            if lag < -0.005 { minuteNegativeLags += 1 }               // the offset is off by at least this much
            let bucket = min(Self.buckets - 1, max(0, Int(lag * 1000)))
            lagBuckets[bucket] += 1
            minuteBuckets[bucket] += 1
            lagMax = max(lagMax, lag)
            minuteLagMax = max(minuteLagMax, lag)
        }
    }

    private func startPings(on connection: NWConnection) {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self, weak connection] in
            var payload = Data()
            payload.appendBigEndian(Self.nowNanos())
            connection?.send(content: Self.message(type: 2, payload: payload), completion: .idempotent)
            self?.noteSilence()
        }
        timer.resume()
        pingTimer = timer
    }

    /// A silence is logged as it lasts (at 5 s, then every 10 s), not only once the next message ends it: a stream that
    /// never comes back would otherwise leave no line.
    private func noteSilence() {
        guard let lastArrival else { return }
        let silent = Int(Double(Self.monotonicNanos() - lastArrival) / 1e9)
        guard silent >= 5, silent >= silenceLogged + (silenceLogged == 0 ? 5 : 10) else { return }
        silenceLogged = silent
        write("no data for \(silent) s")
    }

    private func pong(phoneNanos: UInt64, macNanos: UInt64) {
        let sent = Self.seconds(phoneNanos), back = Self.seconds(Self.nowNanos())
        let rtt = back - sent
        pongs.append((rtt, Self.seconds(macNanos) - (sent + back) / 2))
        if pongs.count > 15 { pongs.removeFirst() }
    }

    /// From the quickest of the recent round trips: the one least skewed by Wi-Fi delay.
    private var clockOffset: Double? { pongs.min { $0.rtt < $1.rtt }?.offset }

    // MARK: Reporting

    /// The screen's numbers, and the summary line once a minute has passed by the clock (a loop of 1 s sleeps drifted
    /// to 62 s "minutes").
    func snapshot(context: String, deliver: @escaping @Sendable (MacLinkSnapshot) -> Void) {
        queue.async { [self] in
            if Self.monotonicNanos() - minuteStarted >= 60_000_000_000 {
                summary(context: context)
            }
            var snapshot = MacLinkSnapshot()
            snapshot.state = state
            snapshot.mac = connectedMac
            snapshot.path = pathText
            snapshot.messages = messages
            snapshot.kilobytes = bytes / 1024
            snapshot.reconnects = reconnects
            snapshot.lagP50 = Self.percentile(0.5, lagBuckets)
            snapshot.lagP99 = Self.percentile(0.99, lagBuckets)
            snapshot.lagMax = lagBuckets.contains { $0 > 0 } ? lagMax : nil
            snapshot.longestGap = longestGap
            snapshot.gapsOver1s = gapsOver1s
            snapshot.clockOffset = clockOffset
            snapshot.lastMessageAgo = lastArrival.map { Double(Self.monotonicNanos() - $0) / 1e9 }
            snapshot.events = events.suffix(12)
            deliver(snapshot)
        }
    }

    /// The minute's line: messages (10 a second expected) in how many seconds, lag, longest gap, and the app's state.
    /// Lag is the arrival minus the Mac's send time on the iPhone's clock, so it includes the Mac's own send delay.
    private func summary(context: String) {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0 * 1000) } ?? "–" }
        let window = Double(Self.monotonicNanos() - minuteStarted) / 1e9
        let best = pongs.min { $0.rtt < $1.rtt }
        write(String(format: "minute: %d msgs in %.0f s, ", minuteMessages, window) + "lag p50 \(ms(Self.percentile(0.5, minuteBuckets))) "
              + "p99 \(ms(Self.percentile(0.99, minuteBuckets))) max \(ms(minuteBuckets.contains { $0 > 0 } ? minuteLagMax : nil)), "
              + String(format: "longest gap %.2f s", minuteGap) + "; total \(messages) msgs, \(reconnects) reconnects, "
              + "\(gapsOver1s) gaps > 1 s; offset \(ms(best?.offset)) from min rtt \(ms(best?.rtt)) of \(pongs.count) pongs "
              + "(lag error ≤ rtt/2), \(minuteNegativeLags) lags < −5 ms; \(pathText) [\(context)]")
        minuteBuckets = [Int](repeating: 0, count: Self.buckets)
        minuteStarted = Self.monotonicNanos()
        minuteNegativeLags = 0
        minuteLagMax = 0
        minuteGap = 0
        minuteMessages = 0
    }

    private static func percentile(_ p: Double, _ buckets: [Int]) -> Double? {
        let total = buckets.reduce(0, +)
        guard total > 0 else { return nil }
        var seen = 0
        for (index, count) in buckets.enumerated() {
            seen += count
            if Double(seen) >= p * Double(total) { return Double(index) / 1000 }   // the bucket's lower edge
        }
        return 10
    }

    // MARK: Wire format (sender.swift)

    static func message(type: UInt8, payload: Data) -> Data {
        var data = Data([type])
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func nowNanos() -> UInt64 { UInt64(Date.now.timeIntervalSince1970 * 1e9) }
    /// A clock that keeps running while the iPhone sleeps (Darwin's CLOCK_MONOTONIC, mach_continuous_time): uptime
    /// (DispatchTime) stops then, and a gap while Feder was suspended and the iPhone asleep would have looked short.
    static func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
    static func seconds(_ nanos: UInt64) -> Double { Double(nanos) / 1e9 }
}

nonisolated private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) {
            copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size))
        }
        return T(bigEndian: value)
    }
}
#endif
