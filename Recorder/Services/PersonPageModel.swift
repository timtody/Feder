import Foundation
import SwiftData

/// What a person's page shows beyond the store's cheap attributes (`PersonView`): one quote per transcript
/// (`PersonDigest`), newest transcript first. Their `segments` are the SwiftData load, read 8 transcripts per turn of
/// the main actor with a frame between the batches, as the search index does (TranscriptSearchModel), and cut off it.
/// The quotes are cached for the process (static) by the transcript's `searchKey` (which changes whenever the segments
/// are rewritten) and the person's speakers there, so another person's page reads only what is new. A person's page as
/// last shown is kept too and is the next page's start, so a second visit draws its quotes in its first frame (each
/// page has its own model), then the update brings it up to date.
@MainActor @Observable
final class PersonPageModel {
    /// Recordings whose segments are read per turn of the main actor.
    static let batch = 8

    /// The quote per transcript of theirs, once read (nil inside: they have no turn there).
    private(set) var quotes: [UUID: PersonQuote?] = [:]

    private let personID: UUID

    /// Starts as the person's page was last shown (a dictionary lookup: PersonView makes one per init).
    init(personID: UUID) {
        self.personID = personID
        if let shown = Self.lastShown[personID] { quotes = shown }
    }

    /// What the page depends on, compared to run `update` again only when one changed (`PersonView`'s task id).
    struct Input: Equatable {
        var personID: UUID
        var keys: [Int]                   // every transcript's `personPageKey`
    }

    private struct QuoteEntry {
        var key: Int
        var speakers: Set<Int>
        var quote: PersonQuote?
    }

    @ObservationIgnored private static var quoteCache: [UUID: QuoteEntry] = [:]
    @ObservationIgnored private static var lastShown: [UUID: [UUID: PersonQuote?]] = [:]

    private func remember() {
        Self.lastShown[personID] = quotes
    }

    /// The person's speakers in `recording` (usually one; two when they were split).
    static func speakers(of personID: UUID, in recording: Recording) -> Set<Int> {
        Set(recording.speakerPeople.compactMap { $0.value == personID ? $0.key : nil })
    }

    /// Call from the view's task whenever `Input` changes; returns early when cancelled (a newer input).
    func update(recordings: [Recording]) async {
        #if DEBUG
        let started = ContinuousClock.now
        #endif
        let live = recordings.filter { !($0.isDeleted || $0.modelContext == nil) && $0.speakerStatus == .done }
        let theirs = live.filter { $0.speakerPeople.values.contains(personID) }

        // What is cached already shows at once (no placeholders for transcripts read on an earlier visit).
        var known: [UUID: PersonQuote?] = [:]
        var pending: [(Recording, Set<Int>, Int)] = []
        for recording in theirs {
            let speakers = Self.speakers(of: personID, in: recording)
            let key = recording.searchKey
            if let entry = Self.quoteCache[recording.id], entry.key == key, entry.speakers == speakers {
                known[recording.id] = .some(entry.quote)
            } else {
                if let shown = quotes[recording.id] { known[recording.id] = .some(shown) }   // the older one meanwhile
                pending.append((recording, speakers, key))
            }
        }
        quotes = known
        remember()

        // The rest, newest first, a batch per turn of the main actor.
        let keys = Dictionary(pending.map { ($0.0.id, ($0.1, $0.2)) }, uniquingKeysWith: { first, _ in first })
        for start in stride(from: 0, to: pending.count, by: Self.batch) {
            guard !Task.isCancelled else { return }
            let sources = pending[start..<min(start + Self.batch, pending.count)].compactMap { recording, speakers, _ in
                // Deleted meanwhile: a detached model traps when read.
                recording.isDeleted || recording.modelContext == nil ? nil : PersonDigest.QuoteSource(
                    id: recording.id, speakers: speakers,
                    segments: recording.segments.map { .init(id: $0.id, text: $0.text, speakerIndex: $0.speakerIndex) })
            }
            for (id, quote) in await PersonDigest.quotesInBackground(sources) {
                if let (speakers, key) = keys[id] { Self.quoteCache[id] = QuoteEntry(key: key, speakers: speakers, quote: quote) }
                guard !Task.isCancelled else { return }
                quotes[id] = .some(quote)
            }
            remember()
            await Task.yield()                                // a frame between the batches
        }
        #if DEBUG
        print("[Scribe] person page: \(live.count) transcripts, \(pending.count) quotes read in \(ContinuousClock.now - started)")
        #endif
    }
}

extension Recording {
    /// Changes whenever something a person's page reads changes: the segments (`searchKey`, which changes whenever
    /// they are rewritten) and the links to people.
    var personPageKey: Int {
        var hasher = Hasher()
        hasher.combine(searchKey)
        hasher.combine(speakerPeople)
        return hasher.finalize()
    }
}
