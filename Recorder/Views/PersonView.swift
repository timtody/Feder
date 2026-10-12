import SwiftUI
import SwiftData

/// One person, laid out like a contact the Phone app opens from Recents (ⓘ): their name as the large title (it
/// collapses into the bar on scroll), when you last spoke with them, the topics that keep coming up in their
/// transcripts, and their transcripts, newest first, each the app's own row with a two-line quote of what they said
/// there (their longest turn). Only system parts: no monogram header (Feder has no photos, and a drawn avatar is a
/// custom version of something iOS draws).
/// A row opens the transcript card out of itself at that turn, in the person's context: their name rows marked and
/// "n of m" through everything they said there (MainView's `openTranscript`, a person token's search context). A
/// topic opens a fresh search in the Search tab: the person and the word (or the tag).
/// Pushed by id (`PersonRoute`) in Settings › People and, through "Go to Person" in a card's name row, onto whichever
/// tab is under the card; the person is looked up here, and a person deleted meanwhile shows "Person Deleted" (reading
/// a deleted @Model traps).
/// Every press answers in its frame: the body reads only the store's cheap attributes; the topics and quotes come
/// from `PersonPageModel` after the push (placeholders meanwhile, the size of the quote they stand for; on a second
/// visit the page as last shown, brought up to date).
struct PersonView: View {
    let personID: UUID
    /// The stack it is in ("settings", "transcripts", "search"): the rows' zoom source ids include it, the person and
    /// `instance`, since every tab stays alive and the same transcript can be a row on two person pages, on one in two
    /// tabs, or on the same person's page twice in one stack (Go to Person from a card opened on another person's page
    /// pushes, as Music's Go to Artist does: Anna, Lena, Anna). A source id shared by two rows zoomed the card out of a
    /// hidden one (`OpenTranscriptAction.rowSource`).
    let stack: String

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openTranscript) private var openTranscript
    @Environment(\.searchActions) private var searchActions
    @Query private var found: [Person]
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @Query(sort: \Person.name) private var people: [Person]
    @State private var model: PersonPageModel
    /// This page, apart from another page of the same person in the same stack (see `stack`).
    @State private var instance = UUID()
    @State private var confirmDelete = false
    /// Delete Person on this page: done once the page has gone (onDisappear). Deleted while it slid away, the page turned
    /// into "Person Deleted" (the id-filtered @Query emptied) in the middle of the pop.
    @State private var deletesOnDisappear = false

    init(personID: UUID, stack: String) {
        self.personID = personID
        self.stack = stack
        _found = Query(filter: #Predicate<Person> { $0.id == personID })
        _model = State(initialValue: PersonPageModel(personID: personID))
    }

    /// The person, unless deleted meanwhile (never read a deleted model).
    private var person: Person? {
        found.first.flatMap { $0.isDeleted || $0.modelContext == nil ? nil : $0 }
    }

    var body: some View {
        Group {
            if let person {
                page(name: person.name)
            } else {
                ContentUnavailableView("Person Deleted", systemImage: "person.slash")
            }
        }
        .toolbar(.visible, for: .navigationBar)             // the Transcripts and Search roots hide theirs
        .onAppear { InteractionTrace.shown("person") }
        .onDisappear {
            guard deletesOnDisappear else { return }
            deletesOnDisappear = false
            if let person { services.people.delete(person) }
        }
    }

    private func page(name: String) -> some View {
        let mine = recordings.filter { $0.speakerPeople.values.contains(personID) }   // once per body, newest first
        return List {
            if let newest = mine.first {
                Section {
                    LabeledContent("Last Conversation", value: newest.createdAt.relativeDayText())
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("LastConversation")
                }
            }
            if !model.topics.isEmpty {
                Section {
                    topicChips(name: name)
                } header: {
                    Text("Topics")
                } footer: {
                    Text("Topics that come up in more than one transcript with \(name).")
                }
            }
            if !mine.isEmpty {
                Section {
                    ForEach(mine) { recording in
                        row(recording, name: name)
                    }
                } header: {
                    Text("^[\(mine.count) Transcript](inflect: true)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if mine.isEmpty {
                ContentUnavailableView("No Transcripts", systemImage: "waveform",
                                       description: Text("\(name) isn't in any transcript right now."))
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete Person", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deletesOnDisappear = true
                dismiss()
            }
        } message: {
            Text("Their voice will no longer be recognized. Names already in transcripts stay.")
        }
        .task(id: PersonPageModel.Input(personID: personID, keys: recordings.map(\.personPageKey),
                                        names: people.map(\.name))) {
            await model.update(recordings: recordings, people: people.map(\.name))
        }
    }

    // MARK: Transcripts

    private func row(_ recording: Recording, name: String) -> some View {
        let sourceID = OpenTranscriptAction.rowSource("person.\(stack).\(personID).\(instance)", recording)
        let quote = model.quotes[recording.id]                // nil: not read yet; .some(nil): no turn of theirs
        return Button {
            open(recording, at: quote ?? nil, sourceID: sourceID)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                TranscriptRow(recording: recording, result: nil, addTagToken: { tag in
                    searchActions.search([SearchToken(kind: .person, value: name), SearchToken(kind: .tag, value: tag)], "")
                })
                if recording.speakerStatus == .done { quoteLine(quote) }
            }
            // A button's label is tinted: the row's secondary texts grey, as in the lists, not a light accent.
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .cardSource(sourceID)
        }
    }

    /// What they said there, at most two lines; while it is read, a placeholder of two lines, so the rows don't grow
    /// when it comes (the longest turn's excerpt is up to 120 characters: nearly always two lines).
    @ViewBuilder
    private func quoteLine(_ quote: PersonQuote??) -> some View {
        switch quote {
        case .none:
            Text(verbatim: Self.placeholder)
                .modifier(QuoteStyle(reservesSpace: true))
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
        case .some(.some(let quote)):
            Text(verbatim: quote.text)
                .modifier(QuoteStyle(reservesSpace: false))
        case .some(.none):
            EmptyView()
        }
    }

    private static let placeholder = String(repeating: "Placeholder words ", count: 9)

    private struct QuoteStyle: ViewModifier {
        let reservesSpace: Bool

        func body(content: Content) -> some View {
            content
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: reservesSpace)
                .padding(.top, 2)
        }
    }

    /// The card at their quoted turn, with their name rows marked and "n of m" through their turns (as a person token's
    /// result opens); while the speakers are still being identified, plainly.
    private func open(_ recording: Recording, at quote: PersonQuote?, sourceID: String) {
        let speakers = PersonPageModel.speakers(of: personID, in: recording)
        let context = recording.speakerStatus == .done && !speakers.isEmpty
            ? TranscriptSearchContext(terms: [], speakers: speakers, firstHit: quote?.turnStart) : nil
        openTranscript?(recording, search: context, sourceID: sourceID)
    }

    // MARK: Topics

    /// The search chips' look (the Search tab's suggestions): tags with their "number" symbol, then words, each with
    /// the number of their transcripts it comes up in; wrapping into lines.
    private func topicChips(name: String) -> some View {
        WrappingLayout(spacing: 6, lineSpacing: 6) {
            ForEach(model.topics) { topic in
                Button {
                    search(topic, name: name)
                } label: {
                    topicChip(topic, name: name)
                }
                .buttonStyle(.borderless)                     // each chip its own button inside the one list row
                .accessibilityIdentifier("PersonTopic.\(topic.name)")
            }
        }
        .padding(.vertical, 4)
    }

    private func topicChip(_ topic: PersonTopic, name: String) -> some View {
        HStack(spacing: 4) {
            if topic.kind == .tag {
                Image(systemName: "number")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }
            Text(verbatim: topic.name)
                .lineLimit(1)
            Text("\(topic.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(topic.kind == .tag ? Text("\(topic.name), Tag") : Text("\(topic.name), Topic"))
        .accessibilityValue("^[\(topic.count) transcript](inflect: true)")
        .accessibilityHint("Searches your transcripts with \(name) for this topic.")
    }

    /// A fresh search in the Search tab (its close button comes back here): the person and the tag, or the person and
    /// the word (the search reads the topics, summaries and titles the words came from).
    private func search(_ topic: PersonTopic, name: String) {
        let person = SearchToken(kind: .person, value: name)
        switch topic.kind {
        case .tag: searchActions.search([person, SearchToken(kind: .tag, value: topic.name)], "")
        case .word: searchActions.search([person], topic.query)
        }
    }
}
