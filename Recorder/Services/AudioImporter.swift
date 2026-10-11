import Accelerate
import AVFoundation
import Foundation

/// Audio from elsewhere becomes a transcript (the record accessory's Import button, or "Feder" in the share sheet of
/// Voice Memos, Files and other apps): the file is converted into a recording's own format, a 16 kHz mono 16-bit WAV
/// in AudioFileStore (what the recorder writes: the same file transcriber, diarizer and player work on it), and the
/// transcript then goes through the steps after Stop, from the words on (SpeakerIdentifier: it has no words yet, so
/// the full-accuracy pass writes them). The original file is not kept (a share sheet's copy in Documents/Inbox is
/// deleted). Nothing leaves the iPhone.
nonisolated enum AudioImporter {
    struct Converted: Sendable {
        var fileName: String
        var duration: TimeInterval
        /// When the audio was recorded, if the file says (its metadata, else the file's creation date).
        var created: Date?
        /// The file's name without its extension, as the transcript's name.
        var name: String
    }

    enum ImportError: LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "This file can't be read as audio.")
            case .empty: String(localized: "This file has no audio.")
            }
        }
    }

    /// The audio types offered in the file picker and handled when opened from another app.
    static let fileTypes = ["public.audio"]

    /// The recorder's file format: 16 kHz mono 16-bit PCM.
    static let sampleRate: Double = 16_000

    /// Reads `source` (any audio iOS decodes: m4a/AAC, MP3, WAV, AIFF, CAF…) and writes it into AudioFileStore in the
    /// recorder's format, off the main actor (a long file takes seconds). Throws when it isn't audio or is empty.
    @concurrent
    static func convert(_ source: URL) async throws -> Converted {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let input = try? AVAudioFile(forReading: source) else { throw ImportError.unreadable }
        guard input.length > 0 else { throw ImportError.empty }
        // Every channel mixed into one first: converting to mono, AVAudioConverter keeps only the first channel (a guest
        // on the right channel of a two-microphone interview was lost), and its `downmix` doesn't mix files with
        // discrete channels (a 4-channel WAV with speech in channel 4 came out silent; review, macOS harness).
        let format = input.processingFormat                 // AVAudioFile: deinterleaved Float32
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
                                       interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: output) else { throw ImportError.unreadable }
        let fileName = AudioFileStore.newFileName()
        let url = AudioFileStore.url(for: fileName)
        do {
            let file = try AVAudioFile(forWriting: url, settings: output.settings, commonFormat: .pcmFormatInt16,
                                       interleaved: true)
            let chunk: AVAudioFrameCount = 32_768
            let outCapacity = AVAudioFrameCount(Double(chunk) * sampleRate / format.sampleRate) + 1_024
            var finished = false
            while !finished {
                guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity) else { break }
                var readError: (any Error)?
                let status = converter.convert(to: out, error: nil) { _, inputStatus in
                    // At the end before reading: AVAudioFile throws eofErr (-39) for a read past its last frame.
                    guard input.framePosition < input.length,
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                          let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk) else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try input.read(into: buffer, frameCount: chunk)
                    } catch {
                        readError = error
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    if buffer.frameLength == 0 {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    mix(buffer, into: mixed)
                    inputStatus.pointee = .haveData
                    return mixed
                }
                if let readError { throw readError }
                if out.frameLength > 0 { try file.write(from: out) }
                finished = status == .endOfStream || status == .error || out.frameLength == 0
                try Task.checkCancellation()
            }
            let duration = Double(file.length) / sampleRate
            guard duration > 0 else { throw ImportError.empty }
            return Converted(fileName: fileName, duration: duration, created: await recordedDate(of: source),
                             name: source.deletingPathExtension().lastPathComponent)
        } catch {
            #if DEBUG
            print("[Scribe] import: \(error)")
            #endif
            AudioFileStore.delete(fileName: fileName)
            throw error is ImportError ? error : ImportError.unreadable
        }
    }

    /// The mean of `buffer`'s channels (deinterleaved Float32) into the mono `target`.
    private static func mix(_ buffer: AVAudioPCMBuffer, into target: AVAudioPCMBuffer) {
        target.frameLength = buffer.frameLength
        guard let channels = buffer.floatChannelData, let out = target.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let total = Int(buffer.format.channelCount)
        out.update(from: channels[0], count: count)
        guard total > 1 else { return }
        for channel in 1..<total {
            vDSP_vadd(out, 1, channels[channel], 1, out, 1, vDSP_Length(count))
        }
        var scale = 1 / Float(total)
        vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(count))
    }

    /// When the audio was recorded: the file's creation-date metadata (Voice Memos' m4a has it), else the file's own
    /// creation date (a share sheet's copy is made at the share, so it is the last resort).
    private static func recordedDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) { return date }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// A share sheet's copy in Documents/Inbox: removed once imported (the transcript has its own file).
    static func removeInboxCopy(_ url: URL) {
        guard url.pathComponents.contains("Inbox") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
