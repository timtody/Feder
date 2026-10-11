import Foundation
import FluidAudio   // v0.17.4: the Diarizer protocol of its streaming models, DiarizerTimeline

/// The recording loop of both live diarizers (LSEENDLiveDiarizer, SortformerLiveDiarizer), run on their worker task.
/// FluidAudio's streaming models share one protocol (`Diarizer`: process, numFramesProcessed, finalizeSession,
/// timeline), so feeding them, the snapshot cadence and the speaker numbering are one piece of code: the two models
/// differ only in what they are given, never in how their output reaches the transcript.
nonisolated enum LiveDiarizerStream {
    /// One recording, with a fresh diarizer (the streaming state lives in the diarizer, not in the model). Feeds every
    /// chunk in order: time is the count of fed samples, so nothing may be dropped. A snapshot goes out whenever
    /// `publishInterval` more seconds were diarized (one model step). Once nobody listens any more (or inference
    /// failed) it only drains, so capture is never blocked and the worker becomes free again.
    static func run(_ diarizer: some Diarizer, samples: AsyncStream<[Float]>, publishInterval: TimeInterval,
                    out: AsyncStream<LiveSpeakerTurns>.Continuation) async {
        defer { out.finish() }
        guard let frameHz = diarizer.modelFrameHz else {   // set by every initialized model
            for await _ in samples {}
            return
        }
        let publishFrames = Int((publishInterval * frameHz).rounded())   // counted in frames: no rounding drift
        var numbering: [Int: Int] = [:]                     // model slot -> speakerIndex, for this recording
        var publishedFrames = 0
        var listening = true
        for await chunk in samples {
            guard listening else { continue }
            do {
                // nil until a model step is full (LS-EEND 0.5 s; Sortformer 0.48 s plus its 0.56 s right context)
                guard try diarizer.process(samples: chunk, sourceSampleRate: nil) != nil else { continue }
            } catch {
                listening = false                           // live labels end for this recording only
                continue
            }
            let frames = diarizer.numFramesProcessed
            guard frames - publishedFrames >= publishFrames else { continue }
            publishedFrames = frames
            let processed = Double(frames) / frameHz
            if case .terminated = out.yield(snapshot(of: diarizer.timeline, until: processed, numbering: &numbering)) {
                listening = false
            }
        }
        guard listening else { return }
        _ = try? diarizer.finalizeSession()                 // flushes the right context and closes open segments
        out.yield(snapshot(of: diarizer.timeline, until: .infinity, numbering: &numbering))
    }

    /// Every segment so far (closed + still open, read from the timeline itself, so segments closed by finalize() are
    /// included), with the model's slots (LS-EEND 0..<10, Sortformer 0..<4, possibly sparse) renumbered 0, 1, 2 ... by
    /// first appearance. The mapping persists for the recording, so a number once shown never moves to another slot.
    private static func snapshot(of timeline: DiarizerTimeline, until processedUntil: TimeInterval,
                                 numbering: inout [Int: Int]) -> LiveSpeakerTurns {
        let segments = timeline.speakers.values
            .flatMap { $0.finalizedSegments + $0.tentativeSegments }
            .sorted { ($0.startFrame, $0.speakerIndex) < ($1.startFrame, $1.speakerIndex) }
        var turns: [SpeakerTurn] = []
        turns.reserveCapacity(segments.count)
        for segment in segments {
            let index: Int
            if let known = numbering[segment.speakerIndex] {
                index = known
            } else {
                index = numbering.count
                numbering[segment.speakerIndex] = index
            }
            turns.append(SpeakerTurn(speakerIndex: index, start: TimeInterval(segment.startTime),
                                     end: TimeInterval(segment.endTime)))
        }
        return LiveSpeakerTurns(turns: turns, processedUntil: processedUntil)
    }
}
