import SwiftUI
import SwiftData

/// Which speaker the rename sheet is open for.
struct SpeakerRenameTarget: Identifiable {
    var speaker: Int
    var id: Int { speaker }
}

/// Names one speaker of a transcript, for all of its turns: a large name field (focused, prefilled with the current
/// name and selected, so typing replaces it) and the known people below it, those linked to this speaker or with a
/// similar voice first, filtered as you type. Choosing a person or saving a typed name links the speaker to that person
/// (`PeopleDirectory.name`), so the person's voice fingerprint learns this speaker's voice. "Use Default Name" goes back
/// to "Speaker N". A transcript started during a calendar event (CalendarContext) offers that event's invitees in an
/// "Invitees" section above the people (an invitee who is a person already shows once, there); the person this speaker
/// is linked to and those with a similar voice stay above them, in "Suggestions".
struct SpeakerNameSheet: View {
    let recording: Recording
    let speaker: Int

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Person.name) private var people: [Person]
    @State private var transcriptCounts: [UUID: Int]?   // transcripts per person, read after the first frame (loadCounts)
    @State private var draft: String
    @State private var selection: TextSelection?
    @FocusState private var isFieldFocused: Bool
    private let initialName: String

    init(recording: Recording, speaker: Int) {
        self.recording = recording
        self.speaker = speaker
        let name = recording.speakerNames[speaker] ?? ""
        initialName = name
        _draft = State(initialValue: name)
    }

    private var defaultName: String { String(localized: "Speaker \(speaker + 1)") }

    private var choices: [SpeakerNameChoices.Choice] {
        let candidates = people.map { SpeakerNameChoices.Candidate(id: $0.id, name: $0.name, fingerprint: $0.fingerprint) }
        return SpeakerNameChoices.rank(candidates, invitees: recording.calendarAttendees, voice: recording.speakerVoices[speaker],
                                       current: recording.speakerPeople[speaker],
                                       typed: draft == initialName ? "" : draft)   // the prefilled name filters nothing
    }

    /// How many transcripts are read per turn of the main actor (loadCounts).
    private static let batch = 16

    var body: some View {
        let counts = transcriptCounts
        NavigationStack {
            List {
                Section {
                    nameField
                    if !initialName.isEmpty {
                        Button { name("") } label: {
                            LabeledContent("Use Default Name", value: defaultName)
                        }
                        .accessibilityIdentifier("UseDefaultName")
                    }
                } footer: {
                    Text("Names every turn of this speaker in this transcript.")
                }
                let choices = choices
                // The calendar event's invitees (Calendar's own word), above the people: a tap names the speaker
                // exactly like typing the name (a person is made on first use). Never assigned by itself. The sheet's
                // best guesses, this speaker's person (the user themselves, say, who is never an invitee) and similar
                // voices, would sink below up to 30 invitees, off the half-height sheet: they come first, in
                // Suggestions. Without invitees they lead the people as before.
                let invitees = choices.filter(\.isInvitee)
                let suggested = invitees.isEmpty ? [] : choices.filter { !$0.isInvitee && $0.reason != .other }
                let others = choices.filter { !$0.isInvitee && (invitees.isEmpty || $0.reason == .other) }
                if !suggested.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggested) { choice in choiceButton(choice, counts: counts) }
                    }
                }
                if !invitees.isEmpty {
                    Section {
                        ForEach(invitees) { choice in choiceButton(choice, counts: counts) }
                    } header: {
                        Text("Invitees")
                    } footer: {
                        if let title = recording.calendarEventTitle {
                            Text("From the calendar event “\(title)”.")
                        }
                    }
                }
                if !others.isEmpty {
                    Section("People") {
                        ForEach(others) { choice in choiceButton(choice, counts: counts) }
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 56)
            .navigationTitle("Rename Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }                    // glass xmark
                        .accessibilityIdentifier("CancelRename")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save)                   // prominent glass checkmark
                        .accessibilityLabel("Save")
                        .accessibilityIdentifier("SaveRename")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { InteractionTrace.shown("rename") }        // the sheet starts to rise
        .task { await loadCounts() }
        .task {
            isFieldFocused = true
            // The name gets selected once the field has focus: a selection set before that becomes a caret at the
            // end, and the focus arrives later on iOS 26 than on 27. Stops as soon as the user typed.
            for delay in [150, 300, 600] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard draft == initialName else { return }
                if !isNameSelected { selection = TextSelection(range: draft.startIndex..<draft.endIndex) }
            }
        }
    }

    private var isNameSelected: Bool {
        guard case .selection(let range) = selection?.indices else { return false }
        return range == draft.startIndex..<draft.endIndex
    }

    private var nameField: some View {
        HStack(spacing: 8) {
            TextField(defaultName, text: $draft, selection: $selection)
                .font(.title2.weight(.semibold))
                .foregroundStyle(SpeakerPalette.color(speaker))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFieldFocused)
                .onSubmit(save)
                .accessibilityIdentifier("SpeakerNameField")
            if !draft.isEmpty {
                Button("Clear Name", systemImage: "xmark.circle.fill") { draft = ""; isFieldFocused = true }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 56)
    }

    private func choiceButton(_ choice: SpeakerNameChoices.Choice, counts: [UUID: Int]?) -> some View {
        // Always names (so confirms) the speaker, also with its current name: a recognized speaker's voice then
        // becomes a sample of that person.
        let transcripts = counts.map { counts in choice.personID.flatMap { counts[$0] } ?? 0 }
        return Button { name(choice.name) } label: { row(choice, transcripts: transcripts) }
            .accessibilityIdentifier("PersonChoice.\(choice.name)")
    }

    /// `transcripts`: nil while the counts are read; the caption that needs them keeps its line, empty, meanwhile.
    private func row(_ choice: SpeakerNameChoices.Choice, transcripts: Int?) -> some View {
        let caption = caption(choice, transcripts: transcripts)
        return HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                SearchHighlight.bold(choice.name, choice.matched)
                    .font(.body)
                    .foregroundStyle(Color.primary)                     // not the button's tint
                Text(caption ?? " ")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(caption == nil)
            }
            Spacer(minLength: 0)
            if choice.reason == .current {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(choice.reason == .current ? .isSelected : [])
    }

    private func caption(_ choice: SpeakerNameChoices.Choice, transcripts count: Int?) -> String? {
        switch choice.reason {
        case .current: return String(localized: "This speaker")
        case .similarVoice: return String(localized: "Similar voice")
        case .other:
            guard let id = choice.personID else {
                // An invitee who isn't a person yet: another speaker may have the name (a person deleted since).
                let name = SearchFolding.fold(choice.name)
                if recording.speakerNames.contains(where: { $0.key != speaker && SearchFolding.fold($0.value) == name }) {
                    return String(localized: "Already in this transcript")
                }
                return String(localized: "Invited")
            }
            if recording.speakerPeople.contains(where: { $0.value == id && $0.key != speaker }) {
                return String(localized: "Already in this transcript")
            }
            guard let count else { return nil }
            return count == 1 ? "1 transcript" : "\(count) transcripts"
        }
    }

    /// Transcripts per person, for the people's captions. Read after the sheet's first frame, `batch` transcripts per
    /// turn of the main actor (`Recording` is a main-actor model), as TagEditor reads its suggestions. A `@Query` of
    /// every transcript fetched them in the sheet's first body and decoded their speakers there, 10 ms of the press
    /// with 70 transcripts (Time Profiler, iPhone 17 simulator, FED-9), the decoding again with every keystroke. The
    /// captions come in while the sheet rises.
    private func loadCounts() async {
        var counts: [UUID: Int] = [:]
        var offset = 0
        while true {
            await Task.yield()                    // the sheet's first frame first, then a frame between the batches
            guard !Task.isCancelled else { return }
            var descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batch
            let batch = (try? modelContext.fetch(descriptor)) ?? []
            for recording in batch { for id in Set(recording.speakerPeople.values) { counts[id, default: 0] += 1 } }
            offset += batch.count
            if batch.count < Self.batch { break }
        }
        transcriptCounts = counts
    }

    // MARK: Actions

    /// A typed name: unchanged closes, anything else names the speaker (blank: the default name).
    private func save() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != initialName { services.people.name(typed, speaker: speaker, in: recording) }
        dismiss()
    }

    private func name(_ name: String) {
        services.people.name(name, speaker: speaker, in: recording)
        dismiss()
    }
}

#if DEBUG
#Preview {
    let recording = PreviewData.sample()
    Color.clear
        .sheet(isPresented: .constant(true)) { SpeakerNameSheet(recording: recording, speaker: 0) }
        .modelContainer(PreviewData.container)
        .environment(AppServices(container: PreviewData.container))
}
#endif
