import Foundation
import SwiftData
import Observation

/// Voice fingerprints across transcripts.
/// - Naming a speaker (transcript card) links it to the Person of that name (created on first use) and stores that
///   speaker's voice as a sample of the person; clearing the name unlinks it.
/// - After diarization, unnamed speakers whose voice matches a person's fingerprint get that person's name
///   (VoiceMatch). Recognition never adds samples: only names the user gave do, so a wrong match cannot drift a
///   fingerprint. Naming a person also recognizes them in older transcripts where their speaker is still unnamed.
/// - Deleting a person removes its fingerprint and links; the names already in transcripts stay as plain text.
/// - "Recognize People by Voice" (Settings › People and the onboarding, off until the user turns it on) gates all of it: no speaker's voice is computed
///   or kept (SpeakerIdentifier), naming a speaker stores no sample, and nobody is recognized. Turning it off deletes
///   every voice profile there is (`deleteAllVoiceProfiles`, after a confirmation); the names stay. Turned on again, it
///   works from the next recording; the transcripts made meanwhile get no voices afterwards (they were made with it off).
@MainActor @Observable
final class PeopleDirectory {
    private let modelContext: ModelContext

    /// UserDefaults key of "Recognize People by Voice"; absent means off (opt-in since October 2026: voice profiles are
    /// biometric data; the onboarding asks, AppServices keeps it on for someone who already has profiles).
    nonisolated static let recognitionKey = "voiceRecognition"
    nonisolated static var isRecognitionEnabled: Bool {
        UserDefaults.standard.object(forKey: recognitionKey) as? Bool ?? false
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// The user named (or cleared) speaker `index` in `recording`.
    func name(_ rawName: String, speaker index: Int, in recording: Recording) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = recording.speakerPeople[index]
        for person in allPeople() {                           // this speaker's earlier sample, wherever it went
            person.removeSamples { $0.recordingID == recording.id && $0.speakerIndex == index }
        }
        recording.setSpeakerName(name, for: index)
        recording.speakerPeople[index] = nil
        if !name.isEmpty {
            let person = person(named: name) ?? insertPerson(named: name)
            if Self.isRecognitionEnabled, let voice = recording.speakerVoices[index] {
                person.setSample(VoiceSample(recordingID: recording.id, speakerIndex: index, embedding: voice))
            }
            recording.speakerPeople[index] = person.id
        }
        if let previous { removeIfUnused(previous) }
        try? modelContext.save()
        if !name.isEmpty { recognizeEverywhere() }
    }

    /// Names unnamed speakers of `recording` whose voice matches a known person. Called after diarization. Stricter for
    /// speakers from pyannote (VoiceMatch.threshold(for:)). `save`: false when the caller saves right after.
    func recognize(_ recording: Recording, save: Bool = true) {
        recognize(recording, among: allPeople().filter { !$0.fingerprint.isEmpty }, save: save)
    }

    private func recognize(_ recording: Recording, among people: [Person], save: Bool) {
        guard Self.isRecognitionEnabled, !people.isEmpty else { return }
        let unnamed = recording.speakerVoices.filter { recording.speakerNames[$0.key] == nil }
        guard !unnamed.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let alreadyThere = Set(recording.speakerPeople.values)
        let fingerprints = Dictionary(uniqueKeysWithValues: people.filter { !alreadyThere.contains($0.id) }
                                                                  .map { ($0.id, $0.fingerprint) })
        for (index, id) in VoiceMatch.assign(voices: unnamed, fingerprints: fingerprints,
                                             threshold: VoiceMatch.threshold(for: recording.diarizer)) {
            guard let person = byID[id] else { continue }
            recording.setSpeakerName(person.name, for: index)
            recording.speakerPeople[index] = id
        }
        if save { try? modelContext.save() }
    }

    /// New voices for a transcript (SpeakerIdentifier.refreshVoices): each sample from it gets the new voice of the same
    /// speaker; a named speaker without one (none of its runs of words lasts 1 s, VoiceWindows: someone who only said
    /// "Ja." or spoke in fast exchanges) keeps its sample and its old voice, which is in the same space (old pyannote
    /// centroid vs new voice of the same speaker: cosine p50 0.98), so a person named only there stays recognizable and
    /// a later rename finds the voice again. Unnamed speakers without a new voice lose their old one: old pyannote
    /// centroids are less pure, and recognition never starts from them. A person linked to a speaker that had no voice
    /// gets a sample: such a link can only come from a name the user typed, because recognition needs a voice. Links
    /// recognized from a voice never become samples.
    func replaceVoices(of recording: Recording, with new: [Int: [Float]]) {
        let old = recording.speakerVoices
        var voices = new
        let people = allPeople()
        for person in people {
            for sample in person.samples where sample.recordingID == recording.id {
                if let voice = new[sample.speakerIndex] {
                    person.setSample(VoiceSample(recordingID: recording.id, speakerIndex: sample.speakerIndex, embedding: voice))
                } else if voices[sample.speakerIndex] == nil {
                    voices[sample.speakerIndex] = old[sample.speakerIndex] ?? sample.embedding   // sample kept as it is
                }
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        for (index, id) in recording.speakerPeople where old[index] == nil {
            guard let person = byID[id], let voice = new[index] else { continue }
            person.setSample(VoiceSample(recordingID: recording.id, speakerIndex: index, embedding: voice))
        }
        recording.speakerVoices = voices                      // the caller saves (SpeakerIdentifier.refreshVoices)
    }

    /// The transcripts people's fingerprints come from: those of their samples, and those with a name the user typed for
    /// a speaker without a voice (replaceVoices gives it a sample).
    func fingerprintSources() -> Set<UUID> {
        var ids = Set(allPeople().flatMap { $0.samples.map(\.recordingID) })
        for recording in allRecordings()
        where recording.speakerPeople.keys.contains(where: { recording.speakerVoices[$0] == nil }) {
            ids.insert(recording.id)
        }
        return ids
    }


    /// Diarization ran again (new speaker numbers): drop this transcript's links and samples, keep the people.
    func resetSpeakers(of recording: Recording) {
        let linked = Set(recording.speakerPeople.values)
        for person in allPeople() { person.removeSamples { $0.recordingID == recording.id } }
        recording.speakerPeople = [:]
        recording.speakerVoices = [:]
        linked.forEach(removeIfUnused)
        try? modelContext.save()
    }

    /// A hand correction renumbered the speakers of `recording` (SpeakerIdentifier.apply): names, links, voices and
    /// this transcript's voice samples follow `mapping` (old → new); those of speakers that are gone go, and a person
    /// left with neither samples nor transcripts goes too. Two old speakers never map to one new one (a merge moves the
    /// turns first; the merged-away speaker is then unused).
    func renumberSpeakers(of recording: Recording, _ mapping: [Int: Int]) {
        let linked = Set(recording.speakerPeople.values)
        recording.speakerNames = SpeakerCorrection.remapped(recording.speakerNames, mapping)
        recording.speakerPeople = SpeakerCorrection.remapped(recording.speakerPeople, mapping)
        recording.speakerVoices = SpeakerCorrection.remapped(recording.speakerVoices, mapping)
        for person in allPeople() where person.samples.contains(where: { $0.recordingID == recording.id }) {
            let kept = person.samples.filter { $0.recordingID != recording.id }
            let moved = person.samples.compactMap { sample -> VoiceSample? in
                guard sample.recordingID == recording.id, let index = mapping[sample.speakerIndex] else { return nil }
                return VoiceSample(recordingID: recording.id, speakerIndex: index, embedding: sample.embedding)
            }
            person.removeSamples { _ in true }
            for sample in kept + moved { person.setSample(sample) }
        }
        linked.subtracting(recording.speakerPeople.values).forEach(removeIfUnused)
    }

    /// Before a transcript is deleted: its samples go, people left with neither samples nor transcripts go too.
    func forget(_ recording: Recording) {
        let linked = Set(recording.speakerPeople.values)
        for person in allPeople() { person.removeSamples { $0.recordingID == recording.id } }
        recording.speakerPeople = [:]
        linked.forEach(removeIfUnused)
    }

    func delete(_ person: Person) {
        for recording in allRecordings() where recording.speakerPeople.values.contains(person.id) {
            recording.speakerPeople = recording.speakerPeople.filter { $0.value != person.id }
        }
        modelContext.delete(person)
        try? modelContext.save()
    }

    /// Some voice profile is stored: a person's fingerprint or a transcript's speaker voices (Settings asks before
    /// turning recognition off deletes them).
    func hasVoiceProfiles() -> Bool {
        allPeople().contains { !$0.samples.isEmpty } || allRecordings().contains { !$0.speakerVoices.isEmpty }
    }

    /// "Recognize People by Voice" turned off: every person's samples and fingerprint, and every transcript's speaker
    /// voices, are deleted. People and the names in transcripts stay (a person without samples is listed and
    /// searchable, never recognized). `voicesVersion` stays, so the voice migration (refreshVoices) doesn't compute
    /// them again.
    func deleteAllVoiceProfiles() {
        for person in allPeople() where !person.samples.isEmpty || !person.fingerprint.isEmpty {
            person.samples = []
            person.fingerprint = []
        }
        for recording in allRecordings() where !recording.speakerVoices.isEmpty {
            recording.speakerVoices = [:]
        }
        try? modelContext.save()
    }

    // MARK: Private

    /// Recognition in every finished transcript with unnamed speakers that have a voice: the people are fetched once
    /// and everything is saved once (each save re-runs every list's @Query).
    func recognizeEverywhere() {
        guard Self.isRecognitionEnabled else { return }
        let people = allPeople().filter { !$0.fingerprint.isEmpty }
        guard !people.isEmpty else { return }
        for recording in allRecordings() where recording.speakerStatus == .done
            && recording.speakerVoices.keys.contains(where: { recording.speakerNames[$0] == nil }) {
            recognize(recording, among: people, save: false)
        }
        try? modelContext.save()
    }

    private func person(named name: String) -> Person? {
        allPeople().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func insertPerson(named name: String) -> Person {
        let person = Person(name: name)
        modelContext.insert(person)
        return person
    }

    /// A person nobody refers to any more and without a voice sample is just a stale name: remove it.
    private func removeIfUnused(_ id: UUID) {
        guard let person = allPeople().first(where: { $0.id == id }), person.samples.isEmpty,
              !allRecordings().contains(where: { $0.speakerPeople.values.contains(id) }) else { return }
        modelContext.delete(person)
    }

    private func allPeople() -> [Person] {
        (try? modelContext.fetch(FetchDescriptor<Person>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    private func allRecordings() -> [Recording] {
        (try? modelContext.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }
}
