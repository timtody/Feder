import Foundation
import SwiftData

/// What a person's page shows beyond the store's cheap attributes (`PersonView`): the recurring topics and one quote
/// per transcript (`PersonDigest`). Topics first (strings only: every finished transcript's topic text, tags and
/// names, read on the main actor; the words found off it), then the quotes, newest transcript first: their `segments`
/// are the SwiftData load, read 8 transcripts per turn of the main actor with a frame between the batches, as the
/// search index does (TranscriptSearchModel), and cut off it. Both are cached for the process (static): a transcript's
/// words by its topic text, its quote by its `searchKey` (which changes whenever the segments are rewritten) and the
/// person's speakers there, so a second visit, or another person's page, shows them at once.
@MainActor @Observable
final class PersonPageModel {
    /// Recordings whose segments are read per turn of the main actor.
    static let batch = 8

    private(set) var topics: [PersonTopic] = []
    /// The quote per transcript of theirs, once read (nil inside: they have no turn there).
    private(set) var quotes: [UUID: PersonQuote?] = [:]

    /// What the page depends on, compared to run `update` again only when one changed (`PersonView`'s task id).
    struct Input: Equatable {
        var personID: UUID
        var keys: [Int]                   // every transcript's `personPageKey`
        var names: [String]               // every person's name
    }

    private struct QuoteEntry {
        var key: Int
        var speakers: Set<Int>
        var quote: PersonQuote?
    }

    private struct TermEntry {
        var key: Int
        var terms: [PersonDigest.Term]
    }

    @ObservationIgnored private static var quoteCache: [UUID: QuoteEntry] = [:]
    @ObservationIgnored private static var termCache: [UUID: TermEntry] = [:]

    /// The person's speakers in `recording` (usually one; two when they were split).
    static func speakers(of personID: UUID, in recording: Recording) -> Set<Int> {
        Set(recording.speakerPeople.compactMap { $0.value == personID ? $0.key : nil })
    }

    /// Call from the view's task whenever `Input` changes; returns early when cancelled (a newer input).
    func update(personID: UUID, recordings: [Recording], people: [String]) async {
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

        // 1. Topics: strings only.
        let ids = Set(theirs.map(\.id))
        var sources: [(id: UUID, isTheirs: Bool, tags: [String], names: Set<String>)] = []
        var missing: [PersonDigest.TermSource] = []
        var topicKeys: [UUID: Int] = [:]
        for recording in live {
            let source = Self.termSource(recording)
            var hasher = Hasher()
            hasher.combine(source.topics)
            hasher.combine(source.summary)
            hasher.combine(source.title)
            let key = hasher.finalize()
            topicKeys[recording.id] = key
            if Self.termCache[recording.id]?.key != key { missing.append(source) }
            sources.append((recording.id, ids.contains(recording.id), recording.tags,
                            PersonDigest.nameWords(recording.speakerNames.values)))
        }
        if !missing.isEmpty {
            for (id, terms) in await PersonDigest.termsInBackground(missing) {
                if let key = topicKeys[id] { Self.termCache[id] = TermEntry(key: key, terms: terms) }
            }
        }
        guard !Task.isCancelled else { return }
        let ranked = sources.map { source in
            PersonDigest.TopicSource(isTheirs: source.isTheirs, terms: Self.termCache[source.id]?.terms ?? [],
                                     tags: source.tags, names: source.names)
        }
        let found = await PersonDigest.topicsInBackground(ranked, excluding: PersonDigest.nameWords(people))
        guard !Task.isCancelled else { return }
        if found != topics { topics = found }
        #if DEBUG
        let topicsDone = ContinuousClock.now
        #endif

        // 2. Quotes, newest first, a batch per turn of the main actor.
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
            await Task.yield()                                // a frame between the batches
        }
        #if DEBUG
        print("[Scribe] person page: \(live.count) transcripts, \(missing.count) topic texts read, topics in "
              + "\(topicsDone - started), \(pending.count) quotes read in \(ContinuousClock.now - topicsDone)")
        #endif
    }

    /// A transcript's topic text: Gemma's Topics line, else (described before it was kept) its summary, and its title
    /// unless it is still a name the app gave it.
    static func termSource(_ recording: Recording) -> PersonDigest.TermSource {
        PersonDigest.TermSource(id: recording.id, topics: recording.topics,
                                summary: recording.topics.isEmpty ? recording.summary : nil,
                                title: TranscriptTitler.isDefaultName(recording.name) ? nil : recording.name)
    }
}

extension Recording {
    /// Changes whenever something a person's page reads changes: what search reads (`searchKey`, which changes with
    /// the segments), the topics and the links to people.
    var personPageKey: Int {
        var hasher = Hasher()
        hasher.combine(searchKey)
        hasher.combine(topics)
        hasher.combine(speakerPeople)
        return hasher.finalize()
    }
}
