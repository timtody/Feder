import Foundation
import SwiftData

/// One voice sample: a speaker's embedding in one transcript, added when the user names that speaker.
nonisolated struct VoiceSample: Codable, Hashable, Sendable {
    var recordingID: UUID
    var speakerIndex: Int
    var embedding: [Float]                       // unit length, 256 values (WeSpeaker, VoiceEmbedder)
}

/// A named person across transcripts. Its fingerprint is the normalized mean of the voice samples the user confirmed
/// by naming a speaker; recognition compares new speakers against it (VoiceMatch).
@Model
final class Person {
    #Unique<Person>([\.id])

    var id: UUID
    var name: String
    var createdAt: Date
    var samples: [VoiceSample]
    var fingerprint: [Float]                     // empty without samples: listed and searchable, never recognized
    /// The user deleted this person's voice profile on their page (PeopleDirectory.deleteVoiceProfile): no voice of
    /// theirs is taken again until they name them in a transcript (a new consent). Additive with a default: the
    /// store migrates lightweight.
    var voiceProfileDeleted: Bool = false
    /// The transcripts whose voices of this person that deletion removed. They stay withheld after the flag is cleared:
    /// naming them in a new transcript is consent for that one, not for the old audio again (a hand correction or the
    /// voice migration there would otherwise recompute their voice from it and add it as a sample). Additive, default
    /// empty.
    var voiceWithheldIn: [UUID] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.samples = []
        self.fingerprint = []
        self.voiceProfileDeleted = false
        self.voiceWithheldIn = []
    }

    /// Replaces the sample for (recording, speaker) and recomputes the fingerprint.
    func setSample(_ sample: VoiceSample) {
        samples.removeAll { $0.recordingID == sample.recordingID && $0.speakerIndex == sample.speakerIndex }
        samples.append(sample)
        fingerprint = VoiceMatch.mean(samples.map(\.embedding))
    }

    func removeSamples(where shouldRemove: (VoiceSample) -> Bool) {
        let before = samples.count
        samples.removeAll(where: shouldRemove)
        if samples.count != before { fingerprint = VoiceMatch.mean(samples.map(\.embedding)) }
    }
}

/// Voice comparison, calibrated on the app's own post-stop path (DiarBench + voicerec: 162 synthetic German meetings of
/// 2-4 people from 30 real Multilingual LibriSpeech voices, clean and simulated room; Nemotron turns, final alignment,
/// VoiceWindows/VoiceEmbedder voices; each person named once and recognized in up to 12 later meetings, 5 rotating
/// holdout groups). At 0.68 with a 0.05 lead: 94.5-96.2 % of enrolled people named correctly, 0 % someone else's name,
/// 0 of 2,904 strangers named (with up to 24 known people). 0.60 names more (96.3-97.8 %) but already 0.6-0.9 % of
/// strangers, and strangers were still named at 0.66, so 0.68 keeps a cushion for real meetings and for longer people
/// lists (per-pair false accepts 0.0095 %: extrapolated 0.24 % strangers named with 25 known people, 0.5 % with 50). The
/// margin barely matters here (0.03 and 0.05 gave identical results). The pyannote fallback's less pure speakers get the
/// stricter `fallbackThreshold`.
nonisolated enum VoiceMatch {
    static let threshold: Float = 0.68
    /// For speakers from pyannote (the fallback until Nemotron is downloaded, and the app before Scribe): its merged and
    /// mixed speakers named 2.1-3.4 % of strangers at 0.68 and stayed above 1 % at every threshold up to 0.80 on the 36
    /// meetings. At 0.75: 1.6 / 0.9 % strangers named, 0.7 / 0.8 % someone else's name, 74 / 66 % of enrolled people
    /// named correctly (82 / 76 % at 0.68).
    static let fallbackThreshold: Float = 0.75
    static let margin: Float = 0.05
    /// Only an ordering hint in the rename sheet ("Similar voice" first), never applied automatically: at 0.60 the
    /// calibration named 96-98 % of enrolled people correctly but also about 1 % of strangers.
    static let suggestion: Float = 0.60

    static func unit(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in sum.indices { sum[i] += v[i] } }
        return unit(sum)
    }

    /// The recognition threshold for a transcript's speakers: Nemotron's, or the stricter one for pyannote's (also for
    /// transcripts diarized before the diarizer was kept, `nil`: the app before Scribe used pyannote or live labels).
    static func threshold(for diarizer: DiarizerKind?) -> Float {
        diarizer == .nemotron ? threshold : fallbackThreshold
    }

    /// Speaker index -> fingerprint key for the best one-to-one matches above `threshold` with a clear lead.
    static func assign<Key: Hashable>(voices: [Int: [Float]], fingerprints: [Key: [Float]],
                                      threshold: Float = VoiceMatch.threshold) -> [Int: Key] {
        var candidates: [(index: Int, key: Key, score: Float)] = []
        for (index, voice) in voices {
            let scores = fingerprints.map { (key: $0.key, score: similarity(voice, $0.value)) }.sorted { $0.score > $1.score }
            guard let best = scores.first, best.score >= threshold,
                  scores.count < 2 || best.score - scores[1].score >= margin else { continue }
            candidates.append((index, best.key, best.score))
        }
        var result: [Int: Key] = [:]
        var taken = Set<Key>()
        for c in candidates.sorted(by: { $0.score > $1.score }) where !taken.contains(c.key) && result[c.index] == nil {
            result[c.index] = c.key
            taken.insert(c.key)
        }
        return result
    }
}
