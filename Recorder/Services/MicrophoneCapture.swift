import Foundation
import AVFoundation
import CoreMedia
import Speech
import Synchronization

/// The audio hardware's own executor. Activating or deactivating the AVAudioSession and starting or stopping the
/// AVAudioEngine block the calling thread (Apple: activation is "a synchronous (blocking) operation"; stopping the
/// engine took ~70 ms on the simulator, which held the first frame of the Stop → toolbar turn), so none of it runs
/// on the main actor. One actor for all of it keeps Apple's order even across recordings: a recording's engine
/// stops and its session deactivates before the next recording activates the session.
@globalActor
actor AudioHardware {
    static let shared = AudioHardware()
}

/// AVAudioEngine input tap -> AVAudioConverter (mic format -> analyzer format) -> AVAudioFile + AsyncStream<AnalyzerInput>,
/// plus (live speaker labels) a second persistent converter -> mono Float32 at LiveAudio.sampleRate -> AsyncStream<[Float]>.
@AudioHardware
final class MicrophoneCapture: nonisolated AudioCapture {
    private let engine = AVAudioEngine()
    /// Everything the tap thread touches; the main actor seals it at Stop (seal), this actor replaces and drops it.
    nonisolated private let tap = Mutex<CaptureTap?>(nil)

    nonisolated init() {}

    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // No .allowBluetoothHFP: always record with the iPhone's own microphone. A Bluetooth headset mic (AirPods)
            // runs at telephony quality (24 kHz HFP) and, on device, delivered audio the transcriber never recognized.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)   // else iOS mutes the start/stop haptics
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)       // also overrides a wired headset mic
            }
        } catch {
            throw RecorderError.audioEngineFailed(error.localizedDescription)
        }
    }

    func start(writingTo fileURL: URL, analyzerFormat: AVAudioFormat, liveSamples: AsyncStream<[Float]>.Continuation?,
               levels: AsyncStream<Float>.Continuation?) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        #if DEBUG
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName)
        print("[Scribe] mic input format \(inputFormat), analyzer format \(analyzerFormat), route \(route)")
        #endif
        let converter: AVAudioConverter?
        if inputFormat == analyzerFormat {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                throw RecorderError.audioEngineFailed("Unsupported microphone format \(inputFormat).")
            }
            c.primeMethod = .none          // no priming latency: converted time == file time
            converter = c
        }
        let file: AVAudioFile
        do {
            // Pin the PROCESSING format to the analyzer format: the two-argument initializer always opens with the
            // standard Float32 processing format, while bestAvailableAudioFormat is Int16 16 kHz mono on current OS
            // builds; writing an Int16 buffer to a Float32-processing file traps (CAAssertRtn) on the render thread.
            file = try AVAudioFile(forWriting: fileURL, settings: analyzerFormat.settings,
                                   commonFormat: analyzerFormat.commonFormat, interleaved: analyzerFormat.isInterleaved)
        } catch { throw RecorderError.audioEngineFailed(error.localizedDescription) }
        guard file.processingFormat == analyzerFormat else {   // .otherFormat yields a 0 ch / 0 Hz processing format
            throw RecorderError.audioEngineFailed("Unsupported analyzer format \(analyzerFormat).")
        }
        // Live speaker labels: the frames written to the file, resampled by ONE persistent converter (filter state
        // carries across buffers; FluidAudio's own resampler builds a new converter per call).
        var live: CaptureTap.Live?
        if let liveSamples {
            if let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveAudio.sampleRate,
                                        channels: 1, interleaved: false),
               let down = AVAudioConverter(from: analyzerFormat, to: mono) {
                down.primeMethod = .none   // live-diarizer sample 0 == file frame 0
                live = CaptureTap.Live(converter: down, samples: liveSamples)
            } else {
                liveSamples.finish()       // this recording simply gets no live labels
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let tap = CaptureTap(file: file, converter: converter, analyzer: continuation, live: live, levels: levels)
        do {
            if #available(iOS 27.0, *) {
                try input.installAudioTap(onBus: 0, bufferSize: 4096, format: inputFormat, tapProvider: Self.makeTap(tap))
            } else {
                input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.makeLegacyTap(tap))
            }
            engine.prepare()
            try engine.start()
            #if DEBUG
            print("[Scribe] audio engine running: \(engine.isRunning)")
            #endif
        } catch {
            input.removeTap(onBus: 0)
            _ = tap.close()                // finishes the streams
            throw RecorderError.audioEngineFailed(error.localizedDescription)
        }
        self.tap.withLock { $0 = tap }
        return stream
    }

    nonisolated func seal() -> TimeInterval {
        tap.withLock { $0?.close() ?? 0 }       // finishes the streams, closes the file (flushes the WAV header, iOS 18+)
    }

    func shutDown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap.withLock { $0 = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The tap closures MUST be built in a nonisolated context: a closure literal written inside a @MainActor method
    /// inherits MainActor isolation and Swift 6 inserts a runtime executor check that traps on the audio render
    /// thread (verified in SIL). They capture only the Sendable CaptureTap.
    @available(iOS 27.0, *)
    nonisolated private static func makeTap(_ tap: CaptureTap) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in tap.process(AVAudioPCMBuffer(copying: buffer)) }   // converters need an AVAudioPCMBuffer
    }

    /// iOS 26: installTap(onBus:bufferSize:format:block:), deprecated in iOS 27.
    nonisolated private static func makeLegacyTap(_ tap: CaptureTap) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.process(buffer) }
    }
}

/// Everything the tap thread touches. The tap thread calls process(_:), the main actor calls close() (stop); one Mutex
/// serializes them, so a tap call still in flight after removeTap can never write to a closed file. Sendable without
/// unchecked code: AVAudioFile, AVAudioConverter and the continuations are Sendable; the mutable part is in the Mutex.
nonisolated private final class CaptureTap: Sendable {
    struct Live: Sendable {
        let converter: AVAudioConverter                  // analyzer format -> mono Float32 at LiveAudio.sampleRate
        let samples: AsyncStream<[Float]>.Continuation
    }

    private struct State {
        var nextFrame: AVAudioFramePosition = 0
        var duration: TimeInterval?                      // set by close(); nil while open
        var buffers = 0                                  // DEBUG diagnostics only
    }

    private let file: AVAudioFile                        // processingFormat == analyzer format
    private let converter: AVAudioConverter?             // mic format -> analyzer format; nil when they match
    private let timescale: CMTimeScale
    private let analyzer: AsyncStream<AnalyzerInput>.Continuation
    private let live: Live?
    private let levels: AsyncStream<Float>.Continuation?
    private let state = Mutex(State())

    init(file: AVAudioFile, converter: AVAudioConverter?, analyzer: AsyncStream<AnalyzerInput>.Continuation, live: Live?,
         levels: AsyncStream<Float>.Continuation?) {
        self.file = file
        self.converter = converter
        self.timescale = CMTimeScale(file.processingFormat.sampleRate)
        self.analyzer = analyzer
        self.live = live
        self.levels = levels
    }

    /// A capture released without stop() must still finish its streams, or their consumers (the live diarizer's
    /// serial worker in particular) would wait forever.
    deinit { _ = close() }

    func process(_ buffer: AVAudioPCMBuffer) {
        state.withLock { state in
            guard state.duration == nil else { return }
            let out: AVAudioPCMBuffer
            if let converter {
                guard let converted = Self.convert(buffer, with: converter) else {
                    #if DEBUG
                    print("[Scribe] conversion produced no frames for a \(buffer.frameLength)-frame buffer")
                    #endif
                    return
                }
                out = converted
            } else {
                out = buffer
            }
            #if DEBUG
            state.buffers += 1
            if state.buffers == 1 || state.buffers % 50 == 0 {
                print("[Scribe] tap buffer \(state.buffers): \(buffer.frameLength) frames in, \(out.frameLength) out, file frame \(state.nextFrame), peak \(Self.peak(out))")
            }
            #endif
            let start = CMTime(value: state.nextFrame, timescale: timescale)
            state.nextFrame += AVAudioFramePosition(out.frameLength)
            do { try file.write(from: out) } catch { }       // keep streaming even if the disk write fails
            // The live copy is made first: `out` is handed to the analyzer below and must not be touched after that.
            if let live, let mono = Self.convert(out, with: live.converter), let channel = mono.floatChannelData {
                live.samples.yield(Array(UnsafeBufferPointer(start: channel[0], count: Int(mono.frameLength))))
            }
            levels?.yield(Self.level(of: out))
            analyzer.yield(AnalyzerInput(buffer: out, bufferStartTime: start))
        }
    }

    /// Finishes the streams and closes the file. Returns the recorded duration in seconds. Idempotent.
    func close() -> TimeInterval {
        state.withLock { state in
            if let duration = state.duration { return duration }
            let duration = Double(file.length) / file.fileFormat.sampleRate
            state.duration = duration
            analyzer.finish()
            live?.samples.finish()
            levels?.finish()
            file.close()                                     // flushes the WAV header (iOS 18+)
            return duration
        }
    }

    /// Level meter input: the buffer's RMS in dBFS, mapped linearly from -50 dB (0) to -10 dB (1). One pass over the
    /// analyzer-format samples (mono 16 kHz: about 1,600 per 0.1 s tap buffer), no allocation.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            for i in 0..<n { sum += data[0][i] * data[0][i] }
        } else if let data = buffer.int16ChannelData {
            for i in 0..<n { let sample = Float(data[0][i]) / 32_768; sum += sample * sample }
        } else {
            return 0
        }
        let decibels = 10 * log10(max(sum / Float(n), 1e-10))   // 10 log10(mean square) == 20 log10(RMS)
        return min(max((decibels + 50) / 40, 0), 1)
    }

    #if DEBUG
    /// Loudest sample as a fraction of full scale (0 = digital silence, 1 = clipping). Diagnostics only.
    private static func peak(_ buffer: AVAudioPCMBuffer) -> String {
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        if let data = buffer.int16ChannelData {
            for i in 0..<n { peak = max(peak, abs(Float(data[0][i])) / Float(Int16.max)) }
        } else if let data = buffer.floatChannelData {
            for i in 0..<n { peak = max(peak, abs(data[0][i])) }
        } else {
            return "n/a"
        }
        return String(format: "%.4f", peak)
    }
    #endif

    /// One-shot conversion with a persistent converter: the input block hands over `buffer` once, then reports
    /// .noDataNow, so the converter keeps its filter state for the next buffer (Apple's BufferConversion pattern).
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let format = converter.outputFormat
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }
}
