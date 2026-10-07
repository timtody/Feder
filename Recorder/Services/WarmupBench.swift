#if DEBUG
import Foundation
import AVFoundation

/// QA: `-warmupBench` times the post-Stop models' first and second use on this device, without touching the store:
/// a synthesized two-voice German clip (AVSpeechSynthesizer, written to tmp) goes through Nemotron (load, then
/// diarization twice) and pyannote/WeSpeaker (load, diarization twice, embeddings twice). (Parakeet, the optional
/// fallback, is left out.) Fresh worker instances, and RecorderApp skips its launch tasks meanwhile, so nothing
/// else warms the models first. Results in the console as `[Scribe] bench:` lines. Run it once right after an install
/// and once on a later launch: the difference is what a new build costs.
enum WarmupBench {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-warmupBench") }

    @MainActor private static var started = false

    @MainActor
    static func run() async {
        guard !started else { return }                 // once per launch (scenePhase turns active more than once)
        started = true
        log("start")
        guard let clip = await speechClip() else { log("no clip"); return }
        log("clip \(clip.lastPathComponent)")

        let nemotron = NemotronDiarizer()
        await time("nemotron load") { try await nemotron.download { _ in } }
        await time("nemotron diarize 1") { _ = try await nemotron.diarize(fileURL: clip) }
        await time("nemotron diarize 2") { _ = try await nemotron.diarize(fileURL: clip) }

        let pyannote = FluidAudioDiarizer()
        await time("pyannote load") { try await pyannote.prepare() }
        let spans = [VoiceWindows.Span(start: 0.5, end: 4.5), VoiceWindows.Span(start: 6, end: 10)]
        await time("wespeaker embed 1") { _ = try await pyannote.embeddings(fileURL: clip, spans: spans) }
        await time("wespeaker embed 2") { _ = try await pyannote.embeddings(fileURL: clip, spans: spans) }
        await time("pyannote diarize 1") { _ = try await pyannote.diarize(fileURL: clip, speakers: .automatic) }
        await time("pyannote diarize 2") { _ = try await pyannote.diarize(fileURL: clip, speakers: .automatic) }

        log("done")
    }

    private static func time(_ name: String, _ work: () async throws -> Void) async {
        let start = ContinuousClock.now
        do {
            try await work()
            log("\(name): \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
        } catch {
            log("\(name): failed after \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))): \(error)")
        }
    }

    private static func log(_ text: String) { print("[Scribe] bench: \(text)") }

    /// About 20 s of German from two system voices, alternating, as a 16 kHz-or-native WAV in tmp.
    @MainActor
    private static func speechClip() async -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "warmup-bench-\(UUID().uuidString).caf")
        try? FileManager.default.removeItem(at: url)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
        let a = voices.first, b = voices.dropFirst().first ?? voices.first
        let lines = [(a, "Guten Morgen, wir besprechen heute den Stand der Testphase und die nächsten Schritte."),
                     (b, "Danke. Die Fehlerliste ist kürzer geworden, aber zwei Punkte sind noch offen."),
                     (a, "Welche sind das genau, und wer kümmert sich bis Freitag darum?"),
                     (b, "Das Scoring und die Schnittstelle zur Abnahme. Ich übernehme beides.")]
        let synthesizer = AVSpeechSynthesizer()
        var file: AVAudioFile?
        for (voice, text) in lines {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            let done: Bool = await withCheckedContinuation { continuation in
                var finished = false
                synthesizer.write(utterance) { buffer in
                    guard !finished else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        finished = true
                        continuation.resume(returning: true)
                        return
                    }
                    do {
                        if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                        try file?.write(from: pcm)
                    } catch {
                        finished = true
                        continuation.resume(returning: false)
                    }
                }
            }
            guard done else { return nil }
        }
        file = nil
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
