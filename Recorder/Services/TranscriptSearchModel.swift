import Foundation

/// The Transcripts screen's search (`Models/TranscriptSearch.swift` does the matching). It keeps one folded
/// `SearchDocument` per recording, built when search is first presented and afterwards only for recordings whose
/// `searchKey` changed, folds them and runs every query off the main actor, 80 ms after the last keystroke (a newer
/// query cancels the older one), and publishes the results of the latest query.
@Observable
final class TranscriptSearchModel {
    static let debounce: Duration = .milliseconds(80)

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

    /// Call with the current recordings and query whenever either changes while search is presented.
    func update(recordings: [Recording], people: [String], query: SearchQuery) {
        self.query = query
        order = recordings.map(\.id)
        let keys = recordings.map(\.searchKey)
        refreshCandidates(recordings, keys: keys, people: people)

        // Documents to (re)build; reading `segments` here, on the main actor, is the SwiftData load.
        let live = Set(order)
        documents = documents.filter { live.contains($0.key) }
        var sources: [SearchDocument.Source] = []
        for (recording, key) in zip(recordings, keys)
        where documents[recording.id]?.key != key && building[recording.id] != key {
            building[recording.id] = key
            sources.append(recording.searchSource(key: key))
        }
        if !sources.isEmpty {
            let previous = indexing
            indexing = Task {
                await previous?.value
                for document in await TranscriptSearch.documentsInBackground(sources) {
                    if building[document.id] == document.key { building[document.id] = nil }
                    documents[document.id] = document
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
    /// `wordsRefined`, `speakerStatusRaw`, `vocabularyPending`). A new writer of segments must change one of them too.
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
        for (index, name) in speakerNames.sorted(by: { $0.key < $1.key }) {
            hasher.combine(index)
            hasher.combine(name)
        }
        return hasher.finalize()
    }

    fileprivate func searchSource(key: Int) -> SearchDocument.Source {
        SearchDocument.Source(
            id: id, title: name, place: placeName, summary: summary, tags: tags, speakerNames: speakerNames,
            segments: segments.map { .init(id: $0.id, text: $0.text, start: $0.start, speakerIndex: $0.speakerIndex) },
            key: key)
    }
}
