import Foundation
import AVFoundation
import Speech

// MARK: - Errors

nonisolated enum RecorderError: LocalizedError, Equatable, Sendable {
    case microphoneDenied
    case transcriberUnavailable            // SpeechTranscriber.isAvailable == false (simulator, iPhone 11/SE 2)
    case localeUnsupported(String)         // Locale.identifier
    case speechModelDownloadFailed(String) // AssetInventory download failed (usually: offline)
    case audioEngineFailed(String)
    case transcriptionFailed(String)
    case diarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Allow it in Settings to record."
        case .transcriberUnavailable: "On-device transcription isn't available on this device."
        case .localeUnsupported(let id): "Transcription isn't available for \(id) yet."
        case .speechModelDownloadFailed(let why): "The speech model couldn't be downloaded. \(why)"
        case .audioEngineFailed(let why): "The microphone couldn't be started. \(why)"
        case .transcriptionFailed(let why): "Transcription stopped. \(why)"
        case .diarizationFailed(let why): "Speakers couldn't be identified. \(why)"
        }
    }
}

// MARK: - Transcription

/// Emitted on the main actor by a Transcriber while a recording is in progress.
nonisolated enum TranscriptionEvent: Sendable {
    case volatile([TranscriptWord])     // replaces the current volatile tail; timed like finalized words
    case finalized([TranscriptWord])    // append; file-relative times
    case failed(RecorderError)          // the engine died mid-session; no further events follow
}

/// What the capture must feed the transcriber (AVAudioFormat is Sendable since the iOS 26 SDK).
nonisolated struct TranscriberSetup: Sendable {
    let locale: Locale
    let audioFormat: AVAudioFormat
}

/// Microphone -> file + analyzer stream (+ live-diarizer samples). One instance per recording. The blocking calls
/// (activating the session, starting and stopping the engine) run on the audio hardware's own actor, never on the
/// main actor (MicrophoneCapture); only `seal()` is synchronous, for the main actor at Stop.
nonisolated protocol AudioCapture: AnyObject, Sendable {
    /// Configures and activates the AVAudioSession for recording. Called BEFORE the transcriber is prepared: Apple's
    /// sample sets the session up first, and a SpeechAnalyzer prepared before the session switches to .playAndRecord
    /// may never deliver results on iOS. shutDown() deactivates it.
    func activateSession() async throws
    /// Opens `fileURL` for writing in `analyzerFormat`, installs the input tap, starts the engine.
    /// Every converted buffer is written to the file AND yielded as AnalyzerInput(buffer:, bufferStartTime:) with the
    /// cumulative frame position, so file time == transcript time. Single consumer.
    /// With `liveSamples`, the same frames are also resampled (one persistent converter) to mono Float32 at
    /// `LiveAudio.sampleRate` and yielded there in order, never dropped, so live-diarizer sample 0 == file frame 0.
    /// `liveSamples` is finished by seal(), or at once when the resampler can't be built (no live labels then). When
    /// start throws, nothing was yielded to it and the caller just drops its stream.
    /// With `levels`, every buffer's input level is yielded there too (0 at -50 dBFS or quieter ... 1 at -10 dBFS or
    /// louder, RMS), for the level meter; finished by seal().
    func start(writingTo fileURL: URL, analyzerFormat: AVAudioFormat, liveSamples: AsyncStream<[Float]>.Continuation?,
               levels: AsyncStream<Float>.Continuation?) async throws -> AsyncStream<AnalyzerInput>
    /// Stop's first step, synchronous: finishes the streams and closes the file (later buffers are dropped), and
    /// returns the recorded duration in seconds (from the file length). Safe to call when not started. The engine
    /// keeps running until shutDown().
    func seal() -> TimeInterval
    /// Removes the tap, stops the engine and deactivates the session, in that order (Apple: stop the IO before
    /// deactivating), off the main actor. Safe to call when not started.
    func shutDown() async
}

/// Live speech-to-text. One instance per recording; prepare -> start -> finish, in that order.
@MainActor
protocol Transcriber: AnyObject {
    /// Checks availability, resolves `locale`, installs the speech asset if missing (reporting its Progress once, when
    /// a download starts), and returns the locale used plus the audio format to feed.
    func prepare(locale: Locale, onDownloadProgress: @escaping @MainActor (Progress) -> Void) async throws -> TranscriberSetup
    /// Starts consuming `input`; `onEvent` is called on the main actor until `finish()` returns or `.failed` is sent.
    func start(input: AsyncStream<AnalyzerInput>, onEvent: @escaping @MainActor (TranscriptionEvent) -> Void) async throws
    /// Call after the input stream was finished (AudioCapture.stop()). Returns once the last words were delivered.
    func finish() async throws
}

// MARK: - Full-accuracy pass

/// Re-transcribes a saved recording after Stop with a more accurate model than the live one, in two steps: the words
/// (before speakers are identified) and the vocabulary pass (after, in the background). Times are seconds from the
/// file's first frame, the same timeline as the live words.
@MainActor
protocol FileTranscriber: AnyObject {
    /// The words, without the vocabulary: Parakeet when it is chosen and downloaded, otherwise Apple's recognizer.
    func transcribe(fileURL: URL, locale: Locale) async throws -> FileTranscript
    /// Vocabulary terms (DictationTranscriber, VocabularyMerge) and the optional smart corrections on `words`
    /// (confidences per word, nil when unknown). Every word keeps its times; returns `words` when nothing changed or a
    /// step failed.
    func applyVocabulary(to words: [TranscriptWord], confidences: [Double]?, fileURL: URL,
                         locale: Locale) async -> [TranscriptWord]
}

nonisolated struct FileTranscript: Sendable {
    var words: [TranscriptWord]
    var confidences: [Double]                  // per word, 0...1
    /// Seconds added to the diarizer's turn times when they are aligned with these words (the word times themselves are
    /// stored unchanged): ParakeetTranscriber.alignmentOffset for Parakeet's words, 0 for Apple's.
    var alignmentOffset: TimeInterval
}

// MARK: - Diarization

/// Post-recording speaker diarization on the saved file. Implementations must be Sendable (used from the main actor,
/// work happens off it); `nonisolated` keeps the requirements out of MainActor default isolation.
nonisolated protocol SpeakerDiarizer: Sendable {
    /// Idempotent. Downloads/compiles models when missing (network needed once). Throws when that is impossible.
    func prepare() async throws
    /// Exclusive speaker turns in seconds, sorted by start, speakerIndex 0-based in first-appearance order, and the model
    /// that made them.
    func diarization(fileURL: URL, speakers: SpeakerCount) async throws -> Diarization
    /// Each speaker's voice for recognition across transcripts, embedded from that speaker's audio in `windows`
    /// (VoiceWindows, built from the transcript's final labels). Speakers without usable audio are missing.
    func voices(fileURL: URL, windows: [Int: [VoiceWindows.Window]]) async throws -> [Int: SpeakerVoice]
}

extension SpeakerDiarizer {
    /// The turns alone.
    nonisolated func diarize(fileURL: URL, speakers: SpeakerCount) async throws -> [SpeakerTurn] {
        try await diarization(fileURL: fileURL, speakers: speakers).turns
    }
}

/// A diarizer's result: the speaker turns and which model made them (recognition is stricter for pyannote's speakers).
nonisolated struct Diarization: Sendable, Equatable {
    var turns: [SpeakerTurn]
    var diarizer: DiarizerKind
}

/// A speaker's voice: unit-length WeSpeaker embedding (256 values) and the seconds of speech it was made from.
nonisolated struct SpeakerVoice: Codable, Hashable, Sendable {
    var embedding: [Float]
    var seconds: TimeInterval
}

/// How many speakers the offline pass should find.
nonisolated enum SpeakerCount: Sendable, Equatable {
    case automatic                 // estimate freely
    case exactly(Int)              // the user's choice ("Speakers" in the detail menu). Not a hard guarantee: a speaker
                                   // whose voice never dominates a moment can still disappear in the final assignment.
}

// MARK: - Live diarization

/// The audio format between AudioCapture and LiveDiarizer: mono Float32 at LS-EEND's model rate.
nonisolated enum LiveAudio {
    static let sampleRate: Double = 8_000
}

/// One live-diarization snapshot: the full state so far, not a delta. Times are seconds from file frame 0.
nonisolated struct LiveSpeakerTurns: Sendable, Equatable {
    /// Sorted by start, may overlap. speakerIndex is 0-based by first appearance and stable for the session, but
    /// unrelated to the offline indices that replace these turns after Stop (offline is the source of truth).
    var turns: [SpeakerTurn] = []
    /// End of the audio diarized so far; words ending later stay unlabelled until a later snapshot covers them.
    var processedUntil: TimeInterval = 0
}

/// Streaming speaker diarization DURING a recording: the live, provisional counterpart of SpeakerDiarizer.
/// Strictly best effort: a recording never waits for it and never fails because of it.
nonisolated protocol LiveDiarizer: Sendable {
    /// Idempotent. Downloads (network needed once) and loads the model. Never awaited on the recording path.
    func prepare() async throws
    /// Consumes `samples` (mono Float32 at LiveAudio.sampleRate, sample 0 == file frame 0) off the main actor and yields
    /// snapshots, at most one per 0.5 s of audio, plus a last one with `processedUntil == .infinity` once `samples`
    /// finished and everything was diarized. The stream then finishes; it also finishes early (without that last
    /// snapshot) when the model isn't loaded, inference fails, or the consumer stops listening.
    func start(samples: AsyncStream<[Float]>) -> AsyncStream<LiveSpeakerTurns>
}
