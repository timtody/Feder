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
/// to "Speaker N".
struct SpeakerNameSheet: View {
    let recording: Recording
    let speaker: Int

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var recordings: [Recording]
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
        return SpeakerNameChoices.rank(candidates, voice: recording.speakerVoices[speaker],
                                       current: recording.speakerPeople[speaker],
                                       typed: draft == initialName ? "" : draft)   // the prefilled name filters nothing
    }

    /// Transcripts per person, counted once per body (not once per row per keystroke).
    private var transcriptCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for recording in recordings { for id in Set(recording.speakerPeople.values) { counts[id, default: 0] += 1 } }
        return counts
    }

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
                if !choices.isEmpty {
                    Section("People") {
                        ForEach(choices) { choice in
                            // Always names (so confirms) the speaker, also with its current name: a recognized
                            // speaker's voice then becomes a sample of that person.
                            Button { name(choice.name) } label: { row(choice, transcripts: counts[choice.id] ?? 0) }
                                .accessibilityIdentifier("PersonChoice.\(choice.name)")
                        }
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

    private func row(_ choice: SpeakerNameChoices.Choice, transcripts: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                SearchHighlight.bold(choice.name, choice.matched)
                    .font(.body)
                    .foregroundStyle(Color.primary)                     // not the button's tint
                Text(caption(choice, transcripts: transcripts))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
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

    private func caption(_ choice: SpeakerNameChoices.Choice, transcripts count: Int) -> String {
        switch choice.reason {
        case .current: return String(localized: "This speaker")
        case .similarVoice: return String(localized: "Similar voice")
        case .other:
            if recording.speakerPeople.contains(where: { $0.value == choice.id && $0.key != speaker }) {
                return String(localized: "Already in this transcript")
            }
            return count == 1 ? "1 transcript" : "\(count) transcripts"
        }
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
