import Foundation

/// Where recordings live: <Documents>/Recordings/<UUID>.wav (16 kHz mono WAV in the transcriber's sample format).
nonisolated enum AudioFileStore {
    static var directory: URL {
        let dir = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func newFileName() -> String { UUID().uuidString + ".wav" }
    static func url(for fileName: String) -> URL { directory.appending(path: fileName) }
    static func delete(fileName: String) { try? FileManager.default.removeItem(at: url(for: fileName)) }

    /// Removes `.wav` files no `Recording` row references (left behind by a crash or force-quit mid-recording).
    /// Call once at launch, before any `RecordingSession` exists.
    static func removeOrphans(keeping referenced: Set<String>) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for name in urls.map(\.lastPathComponent) where name.hasSuffix(".wav") && !referenced.contains(name) {
            delete(fileName: name)
        }
    }
}
