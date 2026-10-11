#if DEBUG
import Foundation
import SwiftData

/// Sample transcripts: in an in-memory store for `#Preview`, and seeded into the app's own store for UI tests and
/// screenshots (`-seedSamples`, simulator only: it must never touch an iPhone's real transcripts and people). Previews:
/// `.modelContainer(PreviewData.container).environment(AppServices(container: PreviewData.container))`.
@MainActor
enum PreviewData {
    static let container: ModelContainer = try! ModelContainer(
        for: Recording.self, Person.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    /// A diarized two-speaker "Kickoff" recording, inserted into `container.mainContext`.
    static func sample() -> Recording {
        let recording = transcript(name: "Kickoff", lines: kickoffLines)
        recording.tags = ["work", "planning"]
        container.mainContext.insert(recording)
        return recording
    }

    // MARK: Seeding the app's store (`-seedSamples`, `-seedPendingSample`): simulator only

    #if targetEnvironment(simulator)
    static let kickoffID = UUID(uuidString: "5C0FFEE0-0000-4000-8000-000000000001")!
    static let budgetID = UUID(uuidString: "5C0FFEE0-0000-4000-8000-000000000002")!
    static let pendingID = UUID(uuidString: "5C0FFEE0-0000-4000-8000-000000000003")!
    static let licenceID = UUID(uuidString: "5C0FFEE0-0000-4000-8000-000000000004")!
    static let maxFiller = 30

    /// Filler transcript `index`'s fixed id, so the next launch replaces it.
    static func fillerID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "5C0FFEE0-0000-4000-8000-0000000001%02d", index))!
    }

    /// Deterministic transcripts in the app's own store, replacing those an earlier launch seeded (and the people only
    /// they used); everything else in the store stays. "Project Kickoff" (now; Anna Schmidt and Jonas Weber, two turns
    /// each) and "Budget Review" (a day earlier; Lena Vogel and Anna Schmidt), their speakers named as if typed, so the
    /// people and their voice fingerprints exist. The voices are made up: Anna's two are alike (cosine about 0.93),
    /// all others unlike each other and unlike FakeDiarizer's, so nothing else in the store is recognized as them.
    /// Budget Review has a summary of five lines (Project Kickoff none).
    /// With `pending`, also "Weekly Sync" (newest, live labels only), queued for speaker identification: combine it
    /// with `-fakeDiarizeSeconds` to keep its speakers preliminary. `filler` older transcripts ("Archive 1"…, no tags,
    /// unnamed speakers) make the list long enough to scroll: the UI tests of the headings and the minimized tab bar.
    /// With `personTopics`, also "Licence Planning" (two days old; Anna Schmidt and Jonas Weber, tagged "finance", with
    /// Gemma's topics), and Budget Review gets topics too, so Anna's page has recurring topics: the tag "finance", then
    /// "travel", "licences" and "forecast" (a separate flag: the other tests' lists and counts stay as they are).
    static func seed(into context: ModelContext, people: PeopleDirectory, identifier: SpeakerIdentifier, pending: Bool,
                     filler: Int = 0, personTopics: Bool = false) {
        let seeded = Set([kickoffID, budgetID, pendingID, licenceID] + (0..<maxFiller).map(fillerID))
        for recording in (try? context.fetch(FetchDescriptor<Recording>())) ?? [] where seeded.contains(recording.id) {
            people.forget(recording)
            context.delete(recording)
        }
        try? context.save()

        let anna = voice(seed: 1)
        let budget = transcript(name: "Budget Review", lines: budgetLines, id: budgetID, createdAt: .now.addingTimeInterval(-86_400))
        budget.tags = ["finance"]
        budget.summary = budgetSummary                                   // longer than three lines: "More"
        budget.speakerVoices = [0: voice(seed: 3), 1: VoiceMatch.unit(zip(anna, voice(seed: 4)).map { $0 + 0.4 * $1 })]
        let kickoff = transcript(name: "Project Kickoff", lines: kickoffLines, id: kickoffID, createdAt: .now)
        kickoff.tags = ["work", "planning"]
        kickoff.speakerVoices = [0: anna, 1: voice(seed: 2)]
        for recording in [budget, kickoff] {
            recording.voicesVersion = SpeakerIdentifier.voicesVersion     // nothing left to do after Stop
            recording.summaryVersion = TranscriptTitler.version
            recording.diarizer = .nemotron
            context.insert(recording)
        }
        for index in 0..<min(filler, maxFiller) {
            let old = transcript(name: "Archive \(index + 1)", lines: kickoffLines, id: fillerID(index),
                                 createdAt: .now.addingTimeInterval(-86_400 * Double(index + 2)))
            old.voicesVersion = SpeakerIdentifier.voicesVersion
            old.summaryVersion = TranscriptTitler.version
            old.diarizer = .nemotron
            context.insert(old)
        }
        try? context.save()
        people.name("Anna Schmidt", speaker: 0, in: kickoff)
        people.name("Jonas Weber", speaker: 1, in: kickoff)
        people.name("Lena Vogel", speaker: 0, in: budget)
        people.name("Anna Schmidt", speaker: 1, in: budget)

        if personTopics {
            budget.topics = ["travel", "licences", "forecast"]
            let licence = transcript(name: "Licence Planning", lines: licenceLines, id: licenceID,
                                     createdAt: .now.addingTimeInterval(-2 * 86_400))
            licence.tags = ["finance"]
            licence.topics = ["licences", "travel", "forecast"]
            licence.summary = "Anna renews the design licences before the end of the month and Jonas checks their "
                + "prices. Travel to the workshops is booked early, so it stays within the forecast."
            licence.speakerVoices = [0: VoiceMatch.unit(zip(anna, voice(seed: 5)).map { $0 + 0.4 * $1 }), 1: voice(seed: 2)]
            licence.voicesVersion = SpeakerIdentifier.voicesVersion
            licence.summaryVersion = TranscriptTitler.version
            licence.diarizer = .nemotron
            context.insert(licence)
            try? context.save()
            people.name("Anna Schmidt", speaker: 0, in: licence)
            people.name("Jonas Weber", speaker: 1, in: licence)
        }

        guard pending else { return }
        let sync = transcript(name: "Weekly Sync", lines: kickoffLines, id: pendingID, createdAt: .now.addingTimeInterval(1))
        sync.speakerStatus = .pending                                    // the live labels saved at Stop
        sync.placeName = "Frankfurt Ostend"                              // a place and no tags (one meta layout only)
        sync.speakerTurns = []
        context.insert(sync)
        try? context.save()
        identifier.enqueue(sync)
    }

    /// Budget Review's summary, as the language model would write it (the UI tests read it back).
    static let budgetSummary = "Travel for the two customer workshops is over plan and licences are under, so part of the "
        + "licence budget moves to travel once finance agrees. The numbers go to finance by Friday, together with the "
        + "third-quarter forecast for the whole year."

    /// A made-up unit "voice" of 256 values (a linear congruential sequence): different seeds are nearly orthogonal.
    private static func voice(seed: UInt64) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        return VoiceMatch.unit((0..<256).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 23) - 1                // -1 ..< 1
        })
    }
    #endif

    // MARK: Building

    private static let kickoffLines: [(speaker: Int, text: String)] = [
        (0, "Okay, let's get started. The goal for today is to agree on the scope for the first release and figure out who owns what."),
        (1, "Sounds good. I'd like to keep the first version small: recording, live transcription, and speaker names. Tags and search can follow right after."),
        (0, "Agreed. If we cut playback for now we should still keep the audio file around so we can add it later without changing the data model."),
        (1, "Yes, and everything stays on the phone. No accounts, no uploads. I'll write that down as the one promise we make to users."),
    ]

    private static let budgetLines: [(speaker: Int, text: String)] = [
        (0, "Let's go through the budget for the second quarter. Travel is over plan, licences are under."),
        (1, "The travel overrun comes from the two customer workshops. I'd move part of the licence budget to cover it."),
        (0, "Fine with me if finance agrees. Can you send them the numbers by Friday?"),
        (1, "Will do. I'll also add the forecast for the third quarter so they see the whole year."),
    ]

    private static let licenceLines: [(speaker: Int, text: String)] = [
        (0, "We need to renew the design licences before the end of the month, and the travel plan for the workshops is still open."),
        (1, "I can check the licence prices this week. For travel, the forecast says we stay within budget if we book early."),
        (0, "Then let's book the trains now and put both into the forecast for finance."),
    ]

    /// A finished transcript of `lines`: words 0.38 s apart, 1.1 s between turns, diarized and aligned.
    private static func transcript(name: String, lines: [(speaker: Int, text: String)], id: UUID? = nil,
                                   createdAt: Date = .now) -> Recording {
        var words: [TranscriptWord] = []
        var turns: [SpeakerTurn] = []
        var clock: TimeInterval = 0.8
        for line in lines {
            let start = clock
            for token in line.text.split(separator: " ") {
                words.append(TranscriptWord(text: String(token), start: clock, end: clock + 0.32))
                clock += 0.38
            }
            turns.append(SpeakerTurn(speakerIndex: line.speaker, start: start, end: clock))
            clock += 1.1
        }

        let recording = Recording(name: name, audioFileName: AudioFileStore.newFileName(), localeIdentifier: "en-US")
        if let id { recording.id = id }
        recording.createdAt = createdAt
        recording.duration = clock
        recording.words = words
        recording.speakerTurns = turns
        recording.segments = TranscriptAligner.finalSegments(words: words, turns: turns, offset: 0)
        recording.speakerStatus = .done
        recording.wordsRefined = true
        return recording
    }
}
#endif
