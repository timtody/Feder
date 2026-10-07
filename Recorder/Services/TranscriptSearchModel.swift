import Foundation
import SwiftData

/// The Transcripts screen's search (`Models/TranscriptSearch.swift` does the matching). It keeps one folded
/// `SearchDocument` per recording, built when search is first presented and afterwards only for recordings whose
/// `searchKey` changed, folds them and runs every query off the main actor, 80 ms after the last keystroke (a newer
/// query cancels the older one), and publishes the results of the latest query.
@Observable
final class TranscriptSearchModel {
    static let debounce: Duration = .milliseconds(80)
    /// Recordings whose segments are read per turn of the main actor while indexing.
    static let batch = 8

    /// Results of `resultsQuery`, by recording id. They lag the typed query by the debounce and the scan.
    private(set) var results: [UUID: SearchResult] = [:]
    private(set) var resultsQuery: SearchQuery?
    /// People and tags for the suggestion section, counted per transcript.
    private(set) var candidates: [SuggestionCandidate] = []

    @ObservationIgnored private var documents: [UUID: SearchDocument] = [:]
    @ObservationIgnored private var building: [UUID: Int] = [:]     // keys of the documents being folded right now
    @ObservationIgnored private var order: [UUID] = []              // newest first, as the list shows them
    @ObservationIgnored private var query = SearchQuery(text: "")
    @ObservationIgnored private var candidatesKey: Int?
    @ObservationIgnored private var indexing: Task<Void, Never>?
    @ObservationIgnored private var searching: Task<Void, Never>?

    /// Call with the current recordings (and their `searchKey`s, which the caller compares already) and query
    /// whenever either changes while search is presented.
    func update(recordings: [Recording], keys: [Int], people: [String], query: SearchQuery) {
        self.query = query
        order = recordings.map(\.id)
        refreshCandidates(recordings, keys: keys, people: people)

        // Documents to (re)build. Reading `segments` is the SwiftData load, on the main actor: in batches of a few
        // recordings per turn of the main actor, so the first presentation of Search (every transcript at once:
        // 300–400 ms on the simulator with 70 transcripts) doesn't hold up the tab's first frame or the keyboard.
        let live = Set(order)
        if documents.count > live.count || documents.keys.contains(where: { !live.contains($0) }) {
            documents = documents.filter { live.contains($0.key) }
        }
        var pending: [(Recording, Int)] = []
        for (recording, key) in zip(recordings, keys)
        where documents[recording.id]?.key != key && building[recording.id] != key {
            building[recording.id] = key
            pending.append((recording, key))
        }
        if !pending.isEmpty {
            let previous = indexing
            indexing = Task {
                await previous?.value
                for batch in stride(from: 0, to: pending.count, by: Self.batch) {
                    let sources = pending[batch..<min(batch + Self.batch, pending.count)].compactMap { recording, key in
                        // Deleted meanwhile: a detached model traps when read; its document is dropped above.
                        recording.isDeleted || recording.modelContext == nil ? nil : recording.searchSource(key: key)
                    }
                    for document in await TranscriptSearch.documentsInBackground(sources) {
                        if building[document.id] == document.key { building[document.id] = nil }
                        documents[document.id] = document
                    }
                    await Task.yield()                        // a frame between the batches
                }
            }
        }

        searching?.cancel()
        guard !query.isEmpty else {
            results = [:]
            resultsQuery = query
            return
        }
        let indexed = indexing
        searching = Task {
            do { try await Task.sleep(for: Self.debounce) } catch { return }
            await indexed?.value
            guard !Task.isCancelled else { return }
            let docs = order.compactMap { documents[$0] }
            guard let found = await TranscriptSearch.searchInBackground(docs, query), !Task.isCancelled else { return }
            results = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            resultsQuery = query
        }
    }

    private func refreshCandidates(_ recordings: [Recording], keys: [Int], people: [String]) {
        var hasher = Hasher()
        hasher.combine(keys)
        hasher.combine(people)
        let key = hasher.finalize()
        guard key != candidatesKey else { return }
        candidatesKey = key
        candidates = SearchSuggestions.candidates(
            speakerNamesPerDoc: recordings.map { Array($0.speakerNames.values) },
            tagsPerDoc: recordings.map(\.tags), people: people)
    }
}

extension Recording {
    /// Changes whenever something search reads changes, without reading the large `segments`/`words`: segments are
    /// only ever written together with one of these fields (RecordingSession: a new recording; SpeakerIdentifier:
    /// `wordsRefined`, `speakerStatusRaw`, `vocabularyPending`). A new writer of segments must
    /// change one of them too.
    var searchKey: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(tags)
        hasher.combine(placeName)
        hasher.combine(summary)
        hasher.combine(speakerStatusRaw)
        hasher.combine(wordsRefined)
        hasher.combine(vocabularyPending)
        hasher.combine(speakerCountOverride)
        hasher.combine(speakerNames)                 // order-independent; the key is only ever compared in memory
        return hasher.finalize()
    }

    fileprivate func searchSource(key: Int) -> SearchDocument.Source {
        SearchDocument.Source(
            id: id, title: name, place: placeName, summary: summary, tags: tags, speakerNames: speakerNames,
            segments: segments.map { .init(id: $0.id, text: $0.text, speakerIndex: $0.speakerIndex) },
            key: key)
    }
}
