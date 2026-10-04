import SwiftUI
import SwiftData

/// "People" (a row in Settings, pushed inside its navigation stack): everyone named in a transcript, searchable, swipe to delete. A person
/// opens the list of transcripts they speak in; a transcript there opens as the transcript card. Deleting a person removes their voice fingerprint and links; the names
/// already written in transcripts stay.
struct PeopleView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var query = ""
    @State private var pendingDelete: Person?

    private var filtered: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? people : people.filter { $0.name.localizedStandardContains(q) }
    }

    var body: some View {
        List(filtered) { person in
            NavigationLink(value: person) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name)
                        .font(.headline)
                    Text(summary(person))
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
                                       description: Text("Name a speaker in a transcript to add them here. Their voice is then recognized in new recordings."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Name")
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Person.self) { person in
            PersonView(person: person)
        }
        .confirmationDialog(pendingDelete.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let person = pendingDelete { services.people.delete(person) }
            }
        } message: {
            Text("Their voice will no longer be recognized. Names already in transcripts stay.")
        }
    }

    private func summary(_ person: Person) -> String {
        let count = recordings.filter { $0.speakerPeople.values.contains(person.id) }.count
        let transcripts = count == 1 ? "1 transcript" : "\(count) transcripts"
        return person.fingerprint.isEmpty ? "\(transcripts) · voice not known yet" : transcripts
    }
}

/// One person: the transcripts they speak in, newest first. A tap opens the transcript card out of the row (MainView's
/// `openTranscript`), as in the Transcripts list: no push.
struct PersonView: View {
    let person: Person
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openTranscript) private var openTranscript
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var confirmDelete = false

    private var transcripts: [Recording] {
        recordings.filter { $0.speakerPeople.values.contains(person.id) }
    }

    var body: some View {
        List(transcripts) { recording in
            let sourceID = OpenTranscriptAction.rowSource("person", recording)
            Button {
                openTranscript?(recording, sourceID: sourceID)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.name)
                        .font(.headline)
                        .foregroundStyle(Color.primary)        // a button's label: not the accent colour
                    Text("\(recording.createdAt.relativeDayText()) · \(recording.duration.clockFormatted)")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)      // `.secondary` in a button's label is the light tint
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .cardSource(sourceID)
            }
        }
        .overlay {
            if transcripts.isEmpty {
                ContentUnavailableView("No Transcripts", systemImage: "waveform",
                                       description: Text("\(person.name) isn't in any transcript right now."))
            }
        }
        .navigationTitle(person.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete Person", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog("Delete \(person.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                services.people.delete(person)
            }
        } message: {
            Text("Their voice will no longer be recognized. Names already in transcripts stay.")
        }
    }
}
