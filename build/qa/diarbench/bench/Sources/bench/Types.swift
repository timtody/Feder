import Foundation

// MARK: - Value types
// `nonisolated` is required: the project uses MainActor default isolation, and these values are created on the
// transcriber's results loop, stored by SwiftData, consumed by the diarizer worker and by the pure aligner.

/// One recognized token. Times are seconds from the first audio frame written to the recording's file.
nonisolated struct TranscriptWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// One speaker turn from the diarizer: exclusive (non-overlapping), sorted by `start`.
nonisolated struct SpeakerTurn: Codable, Hashable, Sendable {
    var speakerIndex: Int          // 0-based, numbered by first appearance in the recording
    var start: TimeInterval
    var end: TimeInterval
}

/// A displayable paragraph: consecutive words of one speaker (or of no speaker before diarization).
nonisolated struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var speakerIndex: Int?         // nil = no label (yet); 0 displays as "Speaker 1". Preliminary (live) until .done
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated enum SpeakerStatus: String, Codable, Sendable {
    case pending      // saved; diarization not run yet (model not ready / offline). Retried by SpeakerIdentifier.
    case processing   // diarization running. A crash leaves this behind; the launch sweep treats it like pending.
    case done
    case failed       // the diarizer threw although the model was ready. Detail view offers "Try Again".
}

/// The model that made a recording's speaker turns. Recognition is stricter for pyannote's less pure speakers
/// (VoiceMatch.threshold(for:)).
nonisolated enum DiarizerKind: String, Codable, Sendable {
    case nemotron     // NVIDIA Nemotron 3, once its model is downloaded (DiarizerSelector)
    case pyannote     // FluidAudio's pyannote pipeline: the fallback until then (and the diarizer of the app before Scribe)
}

// MARK: - SwiftData model (main context only)

