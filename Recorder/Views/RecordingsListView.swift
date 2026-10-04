import SwiftUI
import UIKit
import SwiftData

/// A tab's list of transcripts (newest first). Transcripts tab (`isSearch == false`): the large "Transcripts" heading,
/// pull down to search (opens the Search tab), tag chips filter (Search tab with that tag), Voice Memos' swipe actions.
/// Search tab (`isSearch == true`): our search bar at the top (`TranscriptSearchBar`) with the person/tag tokens as
/// glass chips under it, suggestions as chips, results with highlights. A row opens the transcript card out of itself
/// (MainView's `openTranscript`; no push).
struct RecordingsListView: View {
    let isSearch: Bool
    @Bindable var searchState: SearchState
    var openSearch: (SearchToken?) -> Void
    var closeSearch: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openTranscript) private var openTranscript
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @Query(sort: \Person.name) private var people: [Person]
    @State private var appliedQuery = ""                 // what is searched: the typed text after a typing pause
    @State private var isDraggingList = false            // the finger is on the list
    @State private var pullArmed = false                 // dragging, pulled past the threshold: letting go opens search
    @State private var search = TranscriptSearchModel()

    /// Typing pause before the text is searched: no list or suggestion churn on every keystroke.
    static let typingPause: Duration = .milliseconds(300)
    /// A transcript row's minimum height, insets included. iOS draws the swipe actions by the row's height (measured on
    /// iOS 27): up to 59 pt capsules with the title inside, about 62-70 pt wide pills with the title under them (Voice
    /// Memos), from 76 pt round buttons; the pill's height follows the row's (62 pt: 60 × 34 pt pills, 66 pt: 60 × 38).
    /// Voice Memos' rows are about 62 pt with 60 × 33 pt pills (measured on its screenshot), so rows are two lines (tags
    /// on the date line) and at least 62 pt. Set on the row content, not `defaultMinListRowHeight`, which would make the
    /// caption rows tall too.
    static let minRowHeight: CGFloat = 62
    /// How far the list must be pulled down past its top (rubber-banded: about twice that of finger travel) for
    /// search to open when the finger lifts there.
    static let pullToSearch: CGFloat = 100
    /// The lists' names in the card's zoom source ids (`OpenTranscriptAction.rowSource`).
    static let transcriptsList = "transcripts", searchList = "search"

    private var query: String { searchState.query }
    private var tokens: [SearchToken] { searchState.tokens }

    /// The Transcripts tab never filters (its own search state is the Search tab's).
    private var searchQuery: SearchQuery { isSearch ? SearchQuery(text: appliedQuery, tokens: tokens) : SearchQuery(text: "", tokens: []) }

    /// Everything the search depends on, in the Search tab; nil in the Transcripts tab, so nothing is indexed there.
    private var searchInput: SearchInput? {
        guard isSearch else { return nil }
        return SearchInput(keys: recordings.map(\.searchKey), people: people.map(\.name), query: searchQuery)
    }

    /// While a query is active: the matching recordings (of the latest finished search), newest first.
    private var shown: [Recording] {
        searchQuery.isEmpty ? recordings : recordings.filter { search.results[$0.id] != nil }
    }

    /// Also with tokens and no text: after one suggestion is chosen the others stay (the chosen ones excluded).
    private var suggestions: [Suggestion] {
        guard isSearch else { return [] }
        return SearchSuggestions.suggest(text: appliedQuery, candidates: search.candidates, excluding: tokens, limit: 8)
    }

    var body: some View {
        transcripts
        #if DEBUG
            .task { await applyLaunchArguments() }
        #endif
    }

    private var transcripts: some View {
        NavigationStack {
            let visible = shown                            // both filter or sort everything: once per update
            let suggested = suggestions
            List {
                if !isSearch {
                    // The heading as the first row: it scrolls away with the list (not pinned in a navigation bar).
                    Text("Transcripts")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if !suggested.isEmpty { suggestionSection(suggested) }
                Section {
                    // The result count as a caption row, not a section header: a plain list puts a header ~22 pt below
                    // the top, which left a white band under the status bar while searching.
                    if !searchQuery.isEmpty, search.resultsQuery == searchQuery {
                        listCaption("^[\(visible.count) Transcript](inflect: true)")
                    }
                    ForEach(visible) { recording in
                        // A button, not a NavigationLink: the transcript opens as the card, zooming out of the row.
                        Button {
                            open(recording)
                        } label: {
                            row(recording, result: searchQuery.isEmpty ? nil : search.results[recording.id])
                                .frame(minHeight: Self.minRowHeight - 16, alignment: .leading)   // with the insets
                                .contentShape(Rectangle())
                                .cardSource(OpenTranscriptAction.rowSource(listName, recording))
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)        // the row is the list's own colour: no edge when swiped
                        // Like Voice Memos: Delete outermost, then Share; a full swipe deletes (no confirmation).
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                delete(recording)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                ShareSheet.present(text: recording.plainText, title: recording.name)   // at once
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listSectionSeparator(.hidden, edges: .top)    // no line under the top buttons
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)   // > 0 while pulled past the top
            } action: { _, pull in
                pullArmed = canPullToSearch && isDraggingList && pull >= Self.pullToSearch   // pushed back: disarmed
            }
            .background {
                // Search opens only when the finger lifts while the list is pulled past the threshold: not on a bounce
                // after a fling, not after pulling down and pushing back up while holding.
                ScrollDragObserver {
                    isDraggingList = true
                } onEnd: { pull in
                    isDraggingList = false
                    pullArmed = false
                    if canPullToSearch, pull >= Self.pullToSearch { openSearch(nil) }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: pullArmed) { _, armed in armed }
            .listStyle(.plain)                                 // Voice Memos: rows on the screen's own background
            .scrollDismissesKeyboard(.immediately)             // Search: scrolling the results puts the keyboard away (Music)
            .navigationTitle(isSearch ? "Search" : "Transcripts")   // for VoiceOver only
            // No top bar (the tab bar shows where one is), so the list starts right under the status bar.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top, spacing: 0) {             // a bar: the list fades out under it
                if isSearch {
                    // Our own field at the top of the Search tab, like Apple Music's; the tokens float under it as
                    // glass chips.
                    TranscriptSearchBar(query: $searchState.query, tokens: $searchState.tokens,
                                        focusRequest: searchState.focusRequest, close: closeSearch)
                }
            }
            .task(id: query) {                                 // debounce: search once typing pauses
                guard !query.isEmpty else { appliedQuery = ""; return }   // cleared: at once
                try? await Task.sleep(for: Self.typingPause)
                guard !Task.isCancelled else { return }        // typed again meanwhile
                appliedQuery = query
            }
            .onChange(of: searchInput, initial: true) { _, input in
                guard let input else { return }
                search.update(recordings: recordings, people: input.people, query: input.query)
            }
            .overlay {
                if recordings.isEmpty {
                    ContentUnavailableView("No Transcripts", systemImage: "waveform",
                                           description: Text("Tap Transcribe to start."))
                } else if visible.isEmpty, suggested.isEmpty, search.resultsQuery == searchQuery {
                    ContentUnavailableView.search(text: appliedQuery)
                }
            }
        }
    }

    // MARK: Suggestions

    /// People and tags matching what is typed (the most used ones of each while the field is empty) as compact chips
    /// that wrap into lines, the matched part bold. Choosing one turns the typed fragment into a token.
    private func suggestionSection(_ suggestions: [Suggestion]) -> some View {
        Section {
            listCaption(appliedQuery.isEmpty ? "Suggested" : "Suggestions")
            WrappingLayout(spacing: 6, lineSpacing: 6) {
                ForEach(suggestions) { suggestion in
                    Button {
                        let accepted = SearchSuggestions.accept(suggestion, text: query, tokens: tokens)   // what is typed now
                        searchState.tokens = accepted.tokens
                        searchState.query = accepted.text
                        appliedQuery = accepted.text           // a chosen suggestion applies at once
                    } label: {
                        suggestionChip(suggestion)
                    }
                    .buttonStyle(.borderless)                  // each chip its own button inside the one list row
                }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// A small heading as its own list row ("Suggested", "2 Transcripts"): section headers in a plain list sit ~22 pt
    /// lower and left a white band at the top of the search view.
    private func listCaption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }

    private func suggestionChip(_ suggestion: Suggestion) -> some View {
        let isPerson = suggestion.token.kind == .person
        let count = suggestion.count
        return HStack(spacing: 4) {
            Image(systemName: isPerson ? "person.fill" : "number")
                .imageScale(.small)
                .foregroundStyle(.tint)
            SearchHighlight.bold(suggestion.token.value, suggestion.matched)
                .lineLimit(1)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suggestion.token.value), \(isPerson ? "Person" : "Tag")")
        .accessibilityValue(count > 0 ? "^[\(count) transcript](inflect: true)" : "")
        .accessibilityHint("Adds this \(isPerson ? "person" : "tag") to the search")
    }

    private var listName: String { isSearch ? Self.searchList : Self.transcriptsList }

    /// The transcript card, out of this row; from a search result with its highlights and "n of m".
    private func open(_ recording: Recording) {
        openTranscript?(recording, search: searchContext(for: recording),
                        sourceID: OpenTranscriptAction.rowSource(listName, recording))
    }

    /// What the transcript card highlights when a result is opened; nil outside a search.
    private func searchContext(for recording: Recording) -> TranscriptSearchContext? {
        guard !searchQuery.isEmpty, let result = search.results[recording.id] else { return nil }
        return TranscriptSearchContext(terms: searchQuery.highlightTerms, speakers: Set(result.matchedSpeakers),
                                       firstHit: result.snippet?.segmentID)
    }

    /// A tag chip: in the Search tab it becomes a token; in the Transcripts tab it opens the Search tab with it.
    private func addTagToken(_ tag: String) {
        let token = SearchToken(kind: .tag, value: tag)
        if isSearch { searchState.add(token) } else { openSearch(token) }
    }

    // MARK: Row

    /// One transcript. With a search result: the title's hits highlighted, the matched people, the tags (matched ones
    /// filled) and a two-line excerpt around the hit with its speaker's name.
    private func row(_ recording: Recording, result: SearchResult?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                SearchHighlight.text(recording.name, result?.title == recording.name ? result?.titleHighlights ?? [] : [])
                    .font(.headline)
                    .foregroundStyle(Color.primary)            // a button's label: not the accent colour
                    .lineLimit(1)                              // two-line rows keep Voice Memos' swipe pills
                // One line: date · duration (· place) and the people/tag chips that fit, "+n" for the rest. Keeps a row
                // two lines tall, so iOS draws the swipe actions as Voice Memos' pills (see `minRowHeight`).
                metaLine(recording, result: result)
                if let snippet = result?.snippet {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if recording.speakerStatus == .done, let speaker = snippet.speakerIndex {
                            Text(recording.speakerName(speaker))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        SearchHighlight.text(snippet.text, snippet.highlights)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                } else if let excerpt = result?.summaryExcerpt {
                    SearchHighlight.text(excerpt, result?.summaryHighlights ?? [])
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            if recording.speakerStatus != .done {
                Spacer()
                Image(systemName: "person.2.wave.2")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Speakers not identified yet")
            }
        }
    }

    /// Date · duration, the place, the people/tag chips and "+n" counters for `MetaLineLayout`, which shows what fits.
    /// (Not ViewThatFits: iOS 26 measures its candidates on SwiftUI's async render thread, and their main-actor
    /// ForEach closures trapped in Swift 6's isolation check when the rows re-laid out.)
    /// VoiceOver reads the line as one element with all of it (date, duration, place, people, tags) and offers a
    /// "Filter by tag" action per tag: the layout parks what doesn't fit off-screen, where it stayed in the
    /// accessibility tree ("1 more, 2 more…") and hidden chips could not be reached anyway.
    private func metaLine(_ recording: Recording, result: SearchResult?) -> some View {
        var seen = Set<String>()                           // two speakers may share a name: one chip
        let people = (result?.matchedSpeakers ?? []).compactMap { recording.speakerNames[$0] }.filter { seen.insert($0).inserted }
        let tags = recording.tags
        let chipCount = people.count + tags.count
        return MetaLineLayout(chips: chipCount, hasPlace: recording.placeName != nil) {
            HStack(spacing: 4) {
                Text(recording.createdAt.relativeDayText())
                Text("·").accessibilityHidden(true)            // VoiceOver: "Today at 9:41, 0:42", not "·"
                Text(recording.duration.clockFormatted)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let place = recording.placeName {
                HStack(spacing: 4) {
                    Text("·").accessibilityHidden(true)
                    Text(place)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            ForEach(people, id: \.self) { name in
                chip(Label(name, systemImage: "person.fill").labelStyle(ChipLabelStyle()), matched: true)
                    .accessibilityLabel("Speaker \(name)")
            }
            ForEach(tags, id: \.self) { tag in
                Button {
                    addTagToken(tag)
                } label: {
                    chip(Text(tag), matched: result?.matchedTags.contains(tag) ?? false)
                }
                .buttonStyle(.borderless)                      // inside a List row: tapping the chip does not open the row
                .accessibilityLabel("Filter by tag \(tag)")
            }
            ForEach(Array(stride(from: 1, through: max(1, chipCount), by: 1)), id: \.self) { hidden in
                Text("+\(hidden)")                            // one counter per possible number of hidden chips
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metaAccessibilityLabel(recording, people: people))
        .accessibilityActions {
            ForEach(tags, id: \.self) { tag in
                Button("Filter by tag \(tag)") { addTagToken(tag) }
            }
        }
    }

    /// The meta line for VoiceOver: "Today at 9:41, 0:42, Berlin, Speaker Jonas Weber, Tags: work, planning".
    private func metaAccessibilityLabel(_ recording: Recording, people: [String]) -> String {
        var parts = [recording.createdAt.relativeDayText(), recording.duration.clockFormatted]
        if let place = recording.placeName { parts.append(place) }
        parts += people.map { "Speaker \($0)" }
        if !recording.tags.isEmpty {
            parts.append((recording.tags.count == 1 ? "Tag: " : "Tags: ") + recording.tags.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }

    private func chip(_ content: some View, matched: Bool) -> some View {
        content
            .font(.caption.weight(matched ? .semibold : .regular))
            .foregroundStyle(matched ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(matched ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.12)), in: Capsule())   // no glass
    }

    // MARK: Actions

    private func delete(_ recording: Recording) {
        services.people.forget(recording)
        AudioFileStore.delete(fileName: recording.audioFileName)
        modelContext.delete(recording)
        try? modelContext.save()
    }

    #if DEBUG
    /// `-openFirstResult` (MainView's other hooks open the Search tab): opens the first result's card once the search
    /// has finished, with its highlights and "n of m".
    private func applyLaunchArguments() async {
        guard isSearch, ProcessInfo.processInfo.arguments.contains("-openFirstResult") else { return }
        for _ in 0..<50 where search.resultsQuery != searchQuery || searchQuery.isEmpty {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }   // the search presentation settles first
        if let first = shown.first { open(first) }
    }
    #endif
}

/// The search's inputs, compared to re-run it only when one changed.
private struct SearchInput: Equatable {
    var keys: [Int]
    var people: [String]
    var query: SearchQuery
}

/// Icon and title close together, for chips.
private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

#if DEBUG
#Preview("With Recordings") {
    let _ = PreviewData.sample()
    RecordingsListView(isSearch: false, searchState: SearchState(), openSearch: { _ in }, closeSearch: {})
        .modelContainer(PreviewData.container)
        .environment(AppServices(container: PreviewData.container))
}
#endif


extension RecordingsListView {
    /// Pull-to-search works on the Transcripts tab's plain list, also during a recording: minimized into the
    /// accessory it leaves the list visible and usable (and while the card is up, the list can't be pulled anyway).
    var canPullToSearch: Bool { !isSearch }
}
