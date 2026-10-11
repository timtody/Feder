import SwiftUI
import SwiftData

/// "People" (a row in Settings, pushed inside its navigation stack): everyone named in a transcript, searchable, swipe to delete. A person
/// opens their page (`PersonView`, pushed by id: `PersonRoute`, registered at the root of Settings' stack). Deleting a person removes their voice fingerprint and links; the names
/// already written in transcripts stay.
struct PeopleView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var query = ""
    @State private var pendingDelete: Person?
    /// "Recognize People by Voice" (Settings): off, nobody has a voice profile, so rows don't say "voice not known yet".
    @AppStorage(PeopleDirectory.recognitionKey) private var recognizesVoices = false

    private var filtered: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? people : people.filter { $0.name.localizedStandardContains(q) }
    }

    /// Transcripts per person, counted once per body (not once per row).
    private var transcriptCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for recording in recordings { for id in Set(recording.speakerPeople.values) { counts[id, default: 0] += 1 } }
        return counts
    }

    var body: some View {
        let counts = transcriptCounts
        List(filtered) { person in
            NavigationLink(value: PersonRoute(id: person.id)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name)
                        .font(.headline)
                    Text(summary(person, transcripts: counts[person.id] ?? 0))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = person }
            }
        }
        .overlay {
            if people.isEmpty {
                ContentUnavailableView("No People", systemImage: "person.2",
                                       description: Text(recognizesVoices
                                                         ? "Name a speaker in a transcript to add them here. Their voice is then recognized in new recordings."
                                                         : "Name a speaker in a transcript to add them here."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Name")
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(pendingDelete.map { String(localized: "Delete \($0.name)?") } ?? "", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let person = pendingDelete { services.people.delete(person) }
            }
        } message: {
            Text("Their voice will no longer be recognized. Names already in transcripts stay.")
        }
    }

    private func summary(_ person: Person, transcripts count: Int) -> String {
        // AttributedString applies the inflection ("1 transcript", "2 transcripts"); a String(localized:) of the same key
        // showed the markup itself ("^[2 transcript](inflect: true)").
        let transcripts = String(AttributedString(localized: "^[\(count) transcript](inflect: true)").characters)
        return person.fingerprint.isEmpty && recognizesVoices ? String(localized: "\(transcripts) · voice not known yet") : transcripts
    }
}
