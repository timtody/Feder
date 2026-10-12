import Foundation

// The few app types the symlinked sources need, copied from Recorder/Models/Recording.swift (value types only) or
// stubbed (nothing here takes part in the measurement).

nonisolated struct TranscriptWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated struct SpeakerTurn: Codable, Hashable, Sendable {
    var speakerIndex: Int
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var speakerIndex: Int?
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated enum DiarizerKind: String, Codable, Sendable {
    case nemotron, pyannote
}

nonisolated enum VoiceWindows {
    nonisolated struct Window: Codable, Hashable, Sendable {}
}

nonisolated enum FluidAudioDiarizer {
    static func excludeModelsFromBackup() {}
}
