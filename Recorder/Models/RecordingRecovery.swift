import Foundation

/// A recording the app didn't get to save (a crash, a force quit, iOS killing it mid-way) leaves its WAV in
/// AudioFileStore without a `Recording` row: the row is created at Stop. The launch sweep turns such a file into a
/// "Recovered Recording" instead of deleting it (FED-169); the steps after Stop then write its words, as for an import.
nonisolated enum RecordingRecovery {
    struct Recovered: Sendable {
        var fileName: String
        var duration: TimeInterval
        /// When the file was started, as far as the file system knows.
        var started: Date
    }

    /// 16 kHz mono 16-bit, what the recorder writes.
    private static let bytesPerSecond = 32_000.0

    /// Fixes the header of a WAV whose writer never closed it (AVAudioFile writes the lengths on close) and returns
    /// its duration; nil when there is no audio in it. A file closed properly is left as it is.
    static func repairedDuration(of url: URL) -> TimeInterval? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 44,
              let head = try? { try handle.seek(toOffset: 0); return try handle.read(upToCount: 4096) }(),
              head.count >= 12, head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return nil }
        // Walk the chunks to "data": other chunks (fmt, FLLR padding, fact) vary in size.
        var offset = 12
        var dataStart: Int?
        while offset + 8 <= head.count {
            let id = head[offset..<offset + 4]
            let length = Int(head.loadLE32(at: offset + 4))
            if id == Data("data".utf8) { dataStart = offset + 8; break }
            offset += 8 + length + (length & 1)
        }
        guard let dataStart, UInt64(dataStart) < size else { return nil }
        let actual = Int(size) - dataStart
        guard actual > 0 else { return nil }
        let declared = Int(head.loadLE32(at: dataStart - 4))
        // A closed file declares exactly what it holds; after a kill the field is 0 or 0xFFFFFFFF.
        if declared != actual {
            var riff = UInt32(truncatingIfNeeded: Int(size) - 8).littleEndian
            var data = UInt32(truncatingIfNeeded: actual).littleEndian
            try? handle.seek(toOffset: 4)
            try? handle.write(contentsOf: Data(bytes: &riff, count: 4))
            try? handle.seek(toOffset: UInt64(dataStart - 4))
            try? handle.write(contentsOf: Data(bytes: &data, count: 4))
        }
        return Double(actual) / bytesPerSecond
    }

    /// The WAVs no row references: repaired ones with audio come back as `Recovered`, empty or unreadable ones are
    /// deleted (a recording stopped before the first buffer). Call once at launch, before any session exists.
    static func recoverOrphans(keeping referenced: Set<String>) -> [Recovered] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AudioFileStore.directory,
                                                                 includingPropertiesForKeys: [.creationDateKey])) ?? []
        var recovered: [Recovered] = []
        for url in urls where url.pathExtension == "wav" && !referenced.contains(url.lastPathComponent) {
            guard let duration = repairedDuration(of: url), duration >= 1 else {
                AudioFileStore.delete(fileName: url.lastPathComponent)
                continue
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
            recovered.append(Recovered(fileName: url.lastPathComponent, duration: duration, started: created))
        }
        return recovered
    }
}

private extension Data {
    nonisolated func loadLE32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}
