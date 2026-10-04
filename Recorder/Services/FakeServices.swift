#if DEBUG
import Foundation
import AVFoundation
import Speech

/// Simulator stand-in for SpeechTranscriberEngine (SpeechTranscriber.isAvailable is false on every simulator).
/// Emits canned sentences word by word until finish(), and drains (ignores) the audio, so the real MicrophoneCapture
/// still writes a file. Provisional words come lower case without punctuation, like early volatile results; every
/// second sentence is followed by a pause over 2 s, which starts a new paragraph. QA: `-fakeBacklogMinutes 30` starts
/// with 30 minutes of finalized words (FakeLiveDiarizer labels them too), to measure a long live transcript.
/// `-fakeSilence` emits no words at all, as if nothing was said: Stop then discards the recording and the card closes
/// (the UI tests' only way to reach that path; with the canned words the first one comes 0.3 s after the start).
@MainActor
final class FakeTranscriber: Transcriber {
    private var producer: Task<Void, Never>?
    private var drain: Task<Void, Never>?

    /// Seconds of words the recording starts with (`-fakeBacklogMinutes`), 0 normally.
    nonisolated static var backlog: TimeInterval { UserDefaults.standard.double(forKey: "fakeBacklogMinutes") * 60 }
    /// No words (`-fakeSilence`).
    nonisolated static var silent: Bool { ProcessInfo.processInfo.arguments.contains("-fakeSilence") }

    func prepare(locale: Locale, onDownloadProgress: @escaping @MainActor (Progress) -> Void) async throws -> TranscriberSetup {
        // `-fakePrepareSeconds 5`: preparing takes that long, as a slow speech-model load would (the UI tests check
        // that the card is up long before).
        let seconds = UserDefaults.standard.double(forKey: "fakePrepareSeconds")
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        return TranscriberSetup(locale: locale, audioFormat: format)
    }

    func start(input: AsyncStream<AnalyzerInput>, onEvent: @escaping @MainActor (TranscriptionEvent) -> Void) async throws {
        drain = Task { for await _ in input {} }
        guard !Self.silent else { return }              // the audio is drained (and written), nothing is heard
        let sentences = [
            "Okay, let's get started with a quick test of the live transcript.",
            "New words show up at once, and provisional ones stay a little lighter until they're final.",
            "A new speaker starts a new paragraph at once, and the name follows when the label holds.",
            "Scroll up to reread something, and the view stops following until you jump back to live.",
        ].map { $0.split(separator: " ").map(String.init) }
        producer = Task {
            var clock: TimeInterval = 0.3
            var first = 0                                 // first sentence after the backlog
            if Self.backlog > 0 {
                var backlog: [TranscriptWord] = []
                while clock < Self.backlog {
                    for token in sentences[first % sentences.count] {
                        backlog.append(TranscriptWord(text: token, start: clock, end: clock + 0.25))
                        clock += 0.3
                    }
                    if first % 2 == 1 { clock += 2.5 }
                    first += 1
                }
                onEvent(.finalized(backlog))
            }
            var sentence: [TranscriptWord] = []
            loop: for index in first... {
                for token in sentences[index % sentences.count] {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { break loop }
                    sentence.append(TranscriptWord(text: token, start: clock, end: clock + 0.25))
                    clock += 0.3
                    onEvent(.volatile(sentence.map(Self.provisional)))
                }
                onEvent(.finalized(sentence))
                sentence = []
                if index % 2 == 1 {
                    do { try await Task.sleep(for: .milliseconds(2_500)) } catch { break }
                    clock += 2.5
                }
            }
            if !sentence.isEmpty { onEvent(.finalized(sentence)) }
        }
    }

    private static func provisional(_ word: TranscriptWord) -> TranscriptWord {
        TranscriptWord(text: word.text.lowercased().filter { !$0.isPunctuation }, start: word.start, end: word.end)
    }

    func finish() async throws {
        producer?.cancel()
        await producer?.value
        drain?.cancel()
        producer = nil
        drain = nil
    }
}

/// The simulator has no SpeechTranscriber: the full-accuracy pass "finds nothing better", so the live words stay, and
/// the vocabulary pass changes nothing (both after a delay, so their status rows and the background pass show).
final class FakeFileTranscriber: FileTranscriber {
    func transcribe(fileURL: URL, locale: Locale) async throws -> FileTranscript {
        try await Task.sleep(for: .seconds(1))
        return FileTranscript(words: [], confidences: [], alignmentOffset: 0)
    }

    func applyVocabulary(to words: [TranscriptWord], confidences: [Double]?, fileURL: URL,
                         locale: Locale) async -> [TranscriptWord] {
        try? await Task.sleep(for: .seconds(2))
        return words
    }
}

/// Two speakers alternating every 4 s over the file's duration (or as many as asked for with `.exactly(n)`), after a
/// 1 s "identifying" delay; 4 s on purpose, so they visibly replace FakeLiveDiarizer's 5 s live labels. Reported as
/// Nemotron's, the app's main path.
/// QA: `-fakeDiarizeSeconds 600` makes the delay that long, so a transcript's speakers stay preliminary;
/// `-fakeVoicesSeconds 2` makes every voices call take 2 s (default 0), so the voice migration's order can be watched.
nonisolated struct FakeDiarizer: SpeakerDiarizer {
    private static var delay: TimeInterval {
        let seconds = UserDefaults.standard.double(forKey: "fakeDiarizeSeconds")
        return seconds > 0 ? seconds : 1
    }

    func prepare() async throws {}

    func diarization(fileURL: URL, speakers: SpeakerCount) async throws -> Diarization {
        let count = if case .exactly(let n) = speakers { n } else { 2 }
        try await Task.sleep(for: .seconds(Self.delay))
        let duration = (try? AVAudioFile(forReading: fileURL)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 12
        var turns: [SpeakerTurn] = []
        var t: TimeInterval = 0
        while t < duration {
            turns.append(SpeakerTurn(speakerIndex: turns.count % count, start: t, end: min(t + 4, duration)))
            t += 4
        }
        return Diarization(turns: turns, diarizer: .nemotron)
    }

    /// A fixed fake voice per speaker index, so naming "Speaker 1" once recognizes "Speaker 1" in later fakes.
    func voices(fileURL: URL, windows: [Int: [VoiceWindows.Window]]) async throws -> [Int: SpeakerVoice] {
        let delay = UserDefaults.standard.double(forKey: "fakeVoicesSeconds")
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        var voices: [Int: SpeakerVoice] = [:]
        for (index, speakerWindows) in windows {
            voices[index] = SpeakerVoice(embedding: VoiceMatch.unit((0..<256).map { Float(($0 * (index + 3)) % 17) - 8 }),
                                         seconds: speakerWindows.reduce(0) { $0 + $1.speech })
        }
        return voices
    }
}

/// Simulator stand-in for LSEENDLiveDiarizer: alternates two speakers every 5 s of RECEIVED audio (so it follows the
/// real microphone stream, after FakeTranscriber's backlog), ~1 s behind like LS-EEND, one snapshot per 0.5 s of audio.
/// 5 s on purpose: FakeDiarizer's 4 s turns then visibly replace the live labels after Stop.
nonisolated struct FakeLiveDiarizer: LiveDiarizer {
    func prepare() async throws {}

    func start(samples: AsyncStream<[Float]>) -> AsyncStream<LiveSpeakerTurns> {
        let (snapshots, out) = AsyncStream<LiveSpeakerTurns>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let offset = FakeTranscriber.backlog
        Task {
            var fed = 0
            var publishedAt: TimeInterval = 0
            for await chunk in samples {
                fed += chunk.count
                let processed = offset + Double(fed) / LiveAudio.sampleRate - 1
                guard processed - publishedAt >= 0.5 else { continue }
                publishedAt = processed
                out.yield(Self.snapshot(until: processed))
            }
            var last = Self.snapshot(until: offset + Double(fed) / LiveAudio.sampleRate)
            last.processedUntil = .infinity
            out.yield(last)
            out.finish()
        }
        return snapshots
    }

    private static func snapshot(until end: TimeInterval) -> LiveSpeakerTurns {
        var turns: [SpeakerTurn] = []
        var t: TimeInterval = 0
        while t < end {
            turns.append(SpeakerTurn(speakerIndex: turns.count % 2, start: t, end: min(t + 5, end)))
            t += 5
        }
        return LiveSpeakerTurns(turns: turns, processedUntil: end)
    }
}
#endif
