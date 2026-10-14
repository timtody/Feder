import SwiftUI
import SwiftData

/// One person, laid out like a contact the Phone app opens from Recents (ⓘ): their name as the large title (it
/// collapses into the bar on scroll), when you last spoke with them, and their transcripts, newest first, each the
/// app's own row with a two-line quote of what they said there (their longest turn). Only system parts: no monogram
/// header (Feder has no photos, and a drawn avatar is a custom version of something iOS draws). The recurring topics
/// it showed were removed in FED-12 ("remove the topics for now"; README › People).
/// A row opens the transcript card out of itself at that turn, in the person's context: their name rows marked and
/// "n of m" through everything they said there (MainView's `openTranscript`, a person token's search context). A
/// row's tag opens a fresh search in the Search tab: the person and the tag.
/// Pushed by id (`PersonRoute`) in Settings › People and, through "Go to Person" in a card's name row, onto whichever
/// tab is under the card; the person is looked up here, and a person deleted meanwhile shows "Person Deleted" (reading
/// a deleted @Model traps).
/// Every press answers in its frame: the body reads only the store's cheap attributes; the quotes come
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
    @AppStorage(PeopleDirectory.recognitionKey) private var recognizesVoices = false
    @State private var model: PersonPageModel
    /// This page, apart from another page of the same person in the same stack (see `stack`).
    @State private var instance = UUID()
    @State private var confirmDelete = false
    @State private var confirmDeleteVoice = false
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
                page(name: person.name, hasVoiceProfile: !person.fingerprint.isEmpty)
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

    private func page(name: String, hasVoiceProfile: Bool) -> some View {
        let mine = recordings.filter { $0.speakerPeople.values.contains(personID) }   // once per body, newest first
        return List {
            if let newest = mine.first {
                Section {
                    LabeledContent("Last Conversation", value: newest.createdAt.relativeDayText())
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("LastConversation")
                }
            }
            if recognizesVoices {                         // off: nobody has a profile (People hides it too)
                voiceProfile(name: name, saved: hasVoiceProfile)
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
        .task(id: PersonPageModel.Input(personID: personID, keys: recordings.map(\.personPageKey))) {
            await model.update(recordings: recordings)
        }
    }

    // MARK: Voice profile

    /// Whether Feder keeps their voice profile, and its Delete, in one row: the fingerprint (`touchid`, Touch ID's; SF
    /// Symbols has no "fingerprint") once, saying biometric data; saved, it is in the accent and a red Delete is the
    /// only thing trailing (Delete says there is one); not saved, it is grey with "Not Saved". A second row with the
    /// same fingerprint for the button, and "Saved" beside Delete, looked doubled and cluttered (the user's review,
    /// FED-12). `saved` is the fingerprint's presence, a cheap attribute People's rows read too; the
    /// delete fetches every transcript, so it runs after the press (a Task), and the @Query redraws the row.
    private func voiceProfile(name: String, saved: Bool) -> some View {
        Section {
            HStack {
                HStack {
                    Label {
                        Text("Voice Profile")
                    } icon: {
                        Image(systemName: "touchid")
                            .foregroundStyle(saved ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    Spacer()
                    if !saved {
                        Text("Not Saved")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(saved ? Text("Saved") : Text(verbatim: ""))   // shown by Delete, said aloud
                .accessibilityIdentifier("VoiceProfile")
                if saved {
                    Button("Delete", role: .destructive) { confirmDeleteVoice = true }
                        .buttonStyle(.borderless)                     // the row itself isn't tappable, only Delete
                        .padding(.leading, 8)
                        .accessibilityLabel("Delete Voice Profile")
                        .accessibilityIdentifier("DeleteVoiceProfile")
                        .confirmationDialog("Delete Voice Profile of \(name)?", isPresented: $confirmDeleteVoice,
                                            titleVisibility: .visible) {
                            Button("Delete Voice Profile", role: .destructive) {
                                guard let person else { return }
                                Task { services.people.deleteVoiceProfile(of: person) }
                            }
                        } message: {
                            Text("Feder will no longer recognize \(name) by voice, and their voice is removed from your transcripts. Names stay.")
                        }
                }
            }
        } footer: {
            if saved {
                Text("A voice profile is biometric data. Feder uses it only on this iPhone to recognize \(name) in new recordings.")
            } else {
                Text("Name \(name) in a new transcript to save their voice and recognize them in later recordings.")
            }
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
}
