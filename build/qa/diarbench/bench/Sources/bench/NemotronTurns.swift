import Foundation
// NemotronDiarizer's pure part, verbatim.
enum NemotronTurns {
    static let presetName = "c128-split-w8a8"
    static let activityThreshold: Float = 0.5
    static let joinGap: TimeInterval = 0.1
    static let minSpeakerSeconds: TimeInterval = 2.0

    struct Run: Equatable {
        var slot: Int
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Exclusive turns from per-frame probabilities (`frames` x `slots`, row-major): exclusive runs, slots with less
    /// than `minSpeakerSeconds` dropped (smallest first, while more than one remains), renumbered by first appearance.
    static func turns(probabilities: [Float], frames: Int, slots: Int, frameSeconds: Double) -> [SpeakerTurn] {
        var dropped = Set<Int>()
        var runs = exclusiveRuns(probabilities: probabilities, frames: frames, slots: slots, frameSeconds: frameSeconds)
        while true {
            var total: [Int: Double] = [:]
            for run in runs { total[run.slot, default: 0] += run.end - run.start }
            guard total.count > 1,
                  let weakest = total.filter({ $0.value < minSpeakerSeconds })
                      .min(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }) else { break }
            dropped.insert(weakest.key)
            runs = exclusiveRuns(probabilities: probabilities, frames: frames, slots: slots, frameSeconds: frameSeconds,
                                 excluding: dropped)
        }
        var number: [Int: Int] = [:]
        return runs.map { run in
            let index = number[run.slot] ?? { let n = number.count; number[run.slot] = n; return n }()
            return SpeakerTurn(speakerIndex: index, start: run.start, end: run.end)
        }
    }

    /// Runs of the most probable slot (> activityThreshold) per frame, same-slot gaps <= joinGap closed. Seconds.
    static func exclusiveRuns(probabilities p: [Float], frames: Int, slots: Int, frameSeconds: Double,
                              excluding dropped: Set<Int> = []) -> [Run] {
        var runs: [Run] = []
        var current: (slot: Int, start: Int)?
        func close(at frame: Int) {
            guard let c = current else { return }
            let run = Run(slot: c.slot, start: Double(c.start) * frameSeconds, end: Double(frame) * frameSeconds)
            if let last = runs.last, last.slot == run.slot, run.start - last.end <= joinGap + 1e-9 {
                runs[runs.count - 1].end = run.end
            } else {
                runs.append(run)
            }
            current = nil
        }
        for f in 0..<frames {
            var best = -1, bestP = activityThreshold
            for s in 0..<slots where !dropped.contains(s) && p[f * slots + s] > bestP { best = s; bestP = p[f * slots + s] }
            if best != current?.slot {
                close(at: f)
                if best >= 0 { current = (best, f) }
            }
        }
        close(at: frames)
        return runs
    }
}
