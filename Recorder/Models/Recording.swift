import Foundation
import SwiftData

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

@Model
final class Recording {
    #Unique<Recording>([\.id])
    #Index<Recording>([\.createdAt], [\.name])

    var id: UUID
    var name: String
    var createdAt: Date                  // when recording started (RecordingSession sets it; older ones: when saved)
    var duration: TimeInterval           // seconds, from the written file's length
    var audioFileName: String            // "<UUID>.wav" inside AudioFileStore.directory
    var localeIdentifier: String         // BCP-47 identifier of the transcriber locale actually used, e.g. "en-US"
    var tags: [String]                   // trimmed, case-insensitively unique, insertion order
    var speakerNames: [Int: String]      // per-recording overrides of "Speaker N", keyed by speakerIndex
    var speakerVoices: [Int: [Float]] = [:]   // voice embeddings (unit length) from the final labels, keyed by speakerIndex
    var speakerPeople: [Int: UUID] = [:]      // speakerIndex -> Person.id, named by the user or recognized
    var speakerStatusRaw: String         // SpeakerStatus.rawValue; a String so #Predicate can filter on it
    var words: [TranscriptWord]          // source of truth; lets diarization be re-run without re-transcribing
    var segments: [TranscriptSegment]    // what the UI shows; rebuilt by TranscriptAligner
    var latitude: Double? = nil          // where the recording started (nil: no permission, no fix, or older transcripts)
    var longitude: Double? = nil
    var placeName: String? = nil         // e.g. "Mitte, Berlin" (reverse geocoded)
    var speakerCountOverride: Int? = nil // the user's "Speakers" choice; nil = automatic
    var wordsRefined: Bool = false       // the full-accuracy pass after Stop ran (words are from it, or it found nothing better)
    var vocabularyPending: Bool = false  // the vocabulary pass (vocabulary terms) still has to run on `words`
    // Smart Corrections (Gemma proposing text fixes to review) were removed in October 2026. Their four properties stay
    // so the store's schema does not change (SwiftData changes are additive only); nothing reads or writes them.
    var correctionsPending: Bool = false
    var correctedUntil: TimeInterval = 0
    var proposedCorrections: [CorrectionMerge.Paragraph]? = nil
    var correctionsAccepted: Int = 0
    var speakerTurns: [SpeakerTurn] = [] // the final diarization (empty before it, and for transcripts diarized before it was kept)
    var alignmentOffset: TimeInterval = 0 // added to speakerTurns' times when aligning them with `words` (FileTranscript)
    var voicesVersion: Int = 0           // SpeakerIdentifier.voicesVersion of speakerVoices (0: diarizer centroids, or none)
    var summary: String? = nil           // 1-2 sentences by the on-device language model (TranscriptTitler); nil: none yet
    var summaryVersion: Int = 0          // TranscriptTitler.version once title and summary were attempted with a model
    var nameIsUserSet: Bool = false      // the user edited the title; automatic titles never replace it
    var automaticTitle: String? = nil    // the last title TranscriptTitler gave it: a better model may replace that one
    var diarizerRaw: String? = nil       // DiarizerKind.rawValue of speakerTurns' model; nil: diarized before it was kept
                                         // (the app before Scribe: pyannote, or the live labels)
    var editCount: Int = 0               // the user corrected words or speakers this often (search and Spotlight re-read)

    init(name: String, audioFileName: String, localeIdentifier: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.duration = 0
        self.audioFileName = audioFileName
        self.localeIdentifier = localeIdentifier
        self.tags = []
        self.speakerNames = [:]
        self.speakerStatusRaw = SpeakerStatus.pending.rawValue
        self.words = []
        self.segments = []
    }

    var speakerStatus: SpeakerStatus {
        get { SpeakerStatus(rawValue: speakerStatusRaw) ?? .failed }
        set { speakerStatusRaw = newValue.rawValue }
    }

    /// nil: diarized before this was kept (pyannote or live labels then), or not diarized yet.
    var diarizer: DiarizerKind? {
        get { diarizerRaw.flatMap(DiarizerKind.init(rawValue:)) }
        set { diarizerRaw = newValue?.rawValue }
    }

    var audioURL: URL { AudioFileStore.url(for: audioFileName) }

    /// Number of distinct speakers labelled (0 when unlabelled). Before `.done` these are the live, preliminary labels.
    var speakerCount: Int { (segments.compactMap(\.speakerIndex).max() ?? -1) + 1 }

    /// The user's name for the speaker, else the default in the app's language ("Speaker 2", "Sprecher 2"): the default is
    /// never stored, so it follows the language.
    func speakerName(_ index: Int) -> String { speakerNames[index] ?? String(localized: "Speaker \(index + 1)") }

    /// A blank name resets to the default "Speaker N".
    func setSpeakerName(_ name: String, for index: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerNames[index] = trimmed.isEmpty ? nil : trimmed
    }

    /// Trims, strips a leading "#", rejects blanks and case-insensitive duplicates. Returns whether it was added.
    @discardableResult
    func addTag(_ raw: String) -> Bool {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "#" in front (the search's tag syntax) is dropped, and the space after it: "# work" is "work", not " work".
        if tag.hasPrefix("#") { tag = String(tag.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return false }
        tags.append(tag)
        return true
    }

    func removeTag(_ tag: String) { tags.removeAll { $0 == tag } }
}
