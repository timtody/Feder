// Feder Link spike (FED-141), the Mac side: advertises `_federlink._tcp` on Bonjour and, to each iPhone that connects,
// sends 16 kHz mono Int16 test audio (a 440 Hz tone) as one message per 100 ms, with a sequence number and the Mac's
// clock, the way the real Mac app would stream. It answers the iPhone's pings with its clock, so the iPhone can match the
// two clocks and measure lag. Plain TCP, no encryption: the spike measures whether a locked iPhone keeps receiving.
//
//   swiftc -O build/qa/linkspike/sender.swift -o build/qa/linkspike/sender && build/qa/linkspike/sender
//
// Run it from Terminal.app on the Mac (a command-line tool gets local network access without a prompt). It keeps the
// Mac from idle sleep while it runs, logs connections and throughput, and stops with Ctrl-C.
//
// Wire format, big-endian, both directions: [type u8][length u32][payload]. Types:
//   1 audio  Mac → iPhone  [seq u64][macNanos u64][pcm Int16 little-endian, 1,600 samples]
//   2 ping   iPhone → Mac  [phoneNanos u64]
//   3 pong   Mac → iPhone  [phoneNanos u64][macNanos u64]
// Nanos: wall clock (Unix epoch) in nanoseconds.

import Foundation
import Network

let serviceType = "_federlink._tcp"
let sampleRate = 16_000
let samplesPerMessage = 1_600                       // 100 ms
let queue = DispatchQueue(label: "linkspike")

func nowNanos() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1e9) }

func log(_ text: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("\(stamp) \(text)")
    fflush(stdout)
}

extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)) }
        return T(bigEndian: value)
    }
}

func message(type: UInt8, payload: Data) -> Data {
    var data = Data([type])
    data.append(bigEndian: UInt32(payload.count))
    data.append(payload)
    return data
}

/// One 100 ms block of the tone, continuing its phase.
final class Tone {
    private var phase = 0.0
    func next() -> Data {
        var pcm = Data(capacity: samplesPerMessage * 2)
        for _ in 0..<samplesPerMessage {
            let sample = Int16(sin(phase) * 8_000)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            phase += 2 * .pi * 440 / Double(sampleRate)
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        return pcm
    }
}

/// One connected iPhone: sends a message whenever 100 ms of audio is due by the clock (so a slow send never lets the
/// stream fall behind real time), reads pings and answers them.
final class Peer {
    let connection: NWConnection
    let id: Int
    private var seq: UInt64 = 0
    private var started = DispatchTime.now()
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var sentBytes = 0
    private let tone = Tone()
    var onEnd: (() -> Void)?

    init(_ connection: NWConnection, id: Int) {
        self.connection = connection
        self.id = id
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("peer \(self.id) ready: \(self.connection.endpoint)")
                self.started = .now()
                self.startSending()
                self.receive()
            case .failed(let error):
                log("peer \(self.id) failed: \(error)")
                self.stop()
            case .cancelled:
                log("peer \(self.id) cancelled after \(self.seq) messages")
                self.stop()
            case .waiting(let error):
                log("peer \(self.id) waiting: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startSending() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sendDue() }
        timer.resume()
        self.timer = timer
    }

    private func sendDue() {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        let due = UInt64(elapsed * 10) + 1
        while seq < due {
            var payload = Data()
            payload.append(bigEndian: seq)
            payload.append(bigEndian: nowNanos())
            payload.append(tone.next())
            let data = message(type: 1, payload: payload)
            sentBytes += data.count
            connection.send(content: data, completion: .contentProcessed { _ in })
            seq += 1
            if seq % 600 == 0 {                      // every minute
                log("peer \(id): \(seq) messages, \(sentBytes / 1024) KB sent")
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.parse() }
            if isComplete || error != nil { self.connection.cancel(); return }
            self.receive()
        }
    }

    private func parse() {
        while buffer.count >= 5 {
            let type = buffer[buffer.startIndex]
            let length = Int(buffer.read(UInt32.self, at: 1))
            guard buffer.count >= 5 + length else { return }
            let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 5 + length))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 5 + length))
            if type == 2, payload.count >= 8 {
                var pong = Data()
                pong.append(bigEndian: payload.read(UInt64.self, at: 0))
                pong.append(bigEndian: nowNanos())
                connection.send(content: message(type: 3, payload: pong), completion: .contentProcessed { _ in })
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onEnd?()
        onEnd = nil
    }
}

let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                     reason: "Feder Link spike: streaming to the iPhone")
let parameters = NWParameters.tcp
(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
let listener = try NWListener(using: parameters)
listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: serviceType)
var peers: [Int: Peer] = [:]
var nextID = 1
listener.stateUpdateHandler = { state in log("listener: \(state)") }
listener.serviceRegistrationUpdateHandler = { change in log("bonjour: \(change)") }
listener.newConnectionHandler = { connection in
    let peer = Peer(connection, id: nextID)
    peers[nextID] = peer
    let id = nextID
    peer.onEnd = { peers[id] = nil }
    nextID += 1
    log("peer \(id) connecting from \(connection.endpoint)")
    peer.start()
}
listener.start(queue: queue)
log("advertising \(serviceType) as \"\(listener.service?.name ?? "")\"; Ctrl-C to stop")
withExtendedLifetime(activity) { dispatchMain() }
