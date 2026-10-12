import Foundation
import AVFoundation
import CoreML
import FluidAudio   // v0.17.4

/// WeSpeaker embeddings (256 values) with the offline diarizer's own FBank + embedding Core ML models
/// (`OfflineDiarizerModels.fbankModel` / `.embeddingModel`, the pyannote community-1 bundle FluidAudioDiarizer loads):
/// - `voices`: each speaker's voice for recognition across transcripts, from VoiceWindows (the final labels' words).
/// - `embeddings`: time spans inside their real 10 s of surrounding audio, for SpeakerClustering.
///
/// The models take exactly 10 s (160 000 samples), and the FBank model subtracts the mean over all 998 frames of its
/// input (`centered` / `features` in FBank.mlmodelc/model.mil). Shorter audio is therefore REPEATED to fill the input,
/// never zero padded: padding shifts every feature and makes different speakers alike (voicerec study: different-speaker
/// cosine p50 0.92 with 3 s windows padded, 0.14 repeated; recall at <= 1 % strangers named 69 % -> 80 %). The frame
/// weights (589 per input) are 1 where the words or the span are, 0 elsewhere.
///
/// Not Sendable (MLModel): create and use it inside the task that owns the loaded models (FluidAudioDiarizer's worker).
/// Reads only the audio it needs (AVAudioFile seeks), so long recordings are never loaded whole.
nonisolated struct VoiceEmbedder {
    static let sampleRate = 16_000.0
    static let inputSamples = 160_000          // FBank input: 10 s
    static let weightFrames = 589              // embedding `weights` input: pyannote frames per 10 s
    static let twoVoices: Float = 0.6          // 2-means group means less similar than this: keep the larger group
    static let batchSize = 16

    private let fbank: MLModel
    private let embedding: MLModel

    init(models: OfflineDiarizerModels) {
        fbank = models.fbankModel
        embedding = models.embeddingModel
    }

    /// Unit embedding of each span inside the 10 s of real audio around it (clamped to the file; a file shorter than
    /// 10 s is repeated), with the frame weights on the span only. Context outside the span keeps short spans stable:
    /// on DiarBench turns this embedding found the right speaker for 99.5 % of turns of 0.8 s or more.
    /// The audio is read one Core ML batch at a time: every input holds 10 s (640 KB), and an hour-long meeting has more
    /// than 1,000 spans (same batches, so the same embeddings as reading them all first).
    func embeddings(fileURL: URL, spans: [VoiceWindows.Span]) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: fileURL)
        let length = Double(file.length) / file.processingFormat.sampleRate
        let window = Double(Self.inputSamples) / Self.sampleRate
        var out: [[Float]] = []
        out.reserveCapacity(spans.count)
        for first in stride(from: 0, to: spans.count, by: Self.batchSize) {
            let inputs = try spans[first..<min(spans.count, first + Self.batchSize)].map { span in
                let start = length <= window ? 0 : min(max(0, (span.start + span.end) / 2 - window / 2), length - window)
                let audio = try Self.samples(of: [VoiceWindows.Span(start: start, end: min(length, start + window))],
                                             in: file, fade: false)
                return Input(audio: audio, mask: [VoiceWindows.Span(start: max(0, span.start - start),
                                                                    end: min(window, span.end - start))])
            }
            out += try embed(inputs).map(VoiceMatch.unit)
        }
        return out
    }

    // MARK: Model input

    /// Up to 10 s of 16 kHz mono audio and where the speech lies in it (seconds of `audio`).
    private struct Input {
        var audio: [Float]
        var mask: [VoiceWindows.Span]
    }

    /// Raw embeddings in input order, `batchSize` inputs per Core ML call.
    private func embed(_ inputs: [Input]) throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(inputs.count)
        for first in stride(from: 0, to: inputs.count, by: Self.batchSize) {
            let batch = inputs[first..<min(inputs.count, first + Self.batchSize)]
            try autoreleasepool {                      // Core ML outputs are IOSurface-backed: drain per batch
                let audio: [MLFeatureProvider] = try batch.map {
                    try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: try Self.audioArray($0.audio))])
                }
                let features = try fbank.predictions(from: MLArrayBatchProvider(array: audio), options: MLPredictionOptions())
                var weighted: [MLFeatureProvider] = []
                for (k, input) in batch.enumerated() {
                    guard let f = features.features(at: k).featureValue(for: "fbank_features")?.multiArrayValue else {
                        throw RecorderError.diarizationFailed("FBank output")
                    }
                    weighted.append(try MLDictionaryFeatureProvider(dictionary: [
                        "fbank_features": MLFeatureValue(multiArray: f),
                        "weights": MLFeatureValue(multiArray: try Self.weightArray(input))]))
                }
                let embeddings = try embedding.predictions(from: MLArrayBatchProvider(array: weighted),
                                                           options: MLPredictionOptions())
                for k in 0..<embeddings.count {
                    guard let e = embeddings.features(at: k).featureValue(for: "embedding")?.multiArrayValue else {
                        throw RecorderError.diarizationFailed("Embedding output")
                    }
                    let p = e.dataPointer.assumingMemoryBound(to: Float.self)
                    out.append(Array(UnsafeBufferPointer(start: p, count: e.count)))
                }
            }
        }
        return out
    }

    /// The FBank input: `audio` repeated to fill 10 s.
    private static func audioArray(_ audio: [Float]) throws -> MLMultiArray {
        let n = min(audio.count, inputSamples)
        guard n > 0 else { throw RecorderError.diarizationFailed("empty voice window") }
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: inputSamples)], dataType: .float32)
        let p = array.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<inputSamples { p[i] = audio[i % n] }
        return array
    }

    /// The embedding model's frame weights: the mask repeats with the audio, and frame f counts when its midpoint lies in
    /// a masked span of some copy. Never all zero.
    private static func weightArray(_ input: Input) throws -> MLMultiArray {
        let period = Double(min(input.audio.count, inputSamples)) / sampleRate
        let copies = Int((Double(inputSamples) / sampleRate / period).rounded(.up))
        let tiled = (0..<copies).flatMap { k in
            input.mask.map { (Double(k) * period + $0.start, Double(k) * period + $0.end) }
        }
        let array = try MLMultiArray(shape: [1, NSNumber(value: weightFrames)], dataType: .float32)
        let w = array.dataPointer.assumingMemoryBound(to: Float.self)
        let frame = Double(inputSamples) / sampleRate / Double(weightFrames)
        var on = 0
        for f in 0..<weightFrames {
            let mid = (Double(f) + 0.5) * frame
            w[f] = tiled.contains { mid >= $0.0 && mid < $0.1 } ? 1 : 0
            if w[f] > 0 { on += 1 }
        }
        if on == 0 { for f in 0..<weightFrames { w[f] = 1 } }
        return array
    }

    /// The spans' 16 kHz mono samples back to back, at most 10 s; with `fade`, 5 ms raised-cosine fades at both ends of
    /// every span, so the seams where `audioArray` repeats a short window to fill 10 s do not click. Recordings are
    /// 16 kHz mono already (MicrophoneCapture); any other file format is converted per span.
    private static func samples(of spans: [VoiceWindows.Span], in file: AVAudioFile, fade: Bool = true) throws -> [Float] {
        let format = file.processingFormat
        let converter = AudioConverter(sampleRate: sampleRate)
        var out: [Float] = []
        out.reserveCapacity(inputSamples)
        for span in spans {
            let a = max(0, min(file.length, AVAudioFramePosition((span.start * format.sampleRate).rounded())))
            let b = max(a, min(file.length, AVAudioFramePosition((span.end * format.sampleRate).rounded())))
            guard b > a, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(b - a)) else {
                continue
            }
            file.framePosition = a
            try file.read(into: buffer, frameCount: AVAudioFrameCount(b - a))
            var piece = try converter.resampleBuffer(buffer)
            if fade {
                let length = min(80, piece.count / 4)
                for i in 0..<length {
                    let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(length)))
                    piece[i] *= g
                    piece[piece.count - 1 - i] *= g
                }
            }
            out.append(contentsOf: piece)
            if out.count >= inputSamples { break }
        }
        return Array(out.prefix(inputSamples))
    }
}

enum VoiceMatch { static func unit(_ v: [Float]) -> [Float] { let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); return n > 0 ? v.map { $0 / n } : v } }
