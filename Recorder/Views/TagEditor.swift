import SwiftUI
import SwiftData

/// The transcript's tags, under the summary. Not there at all while a transcript has no tags; the bottom toolbar's
/// Add Tag inserts it (`isEditing`) with a focused field after the pills. Typing a comma turns what comes before it into
/// a pill (pasted "a, b, c" makes three), Return adds the rest and ends; so does leaving the field (the title field
/// focused, or the keyboard dragged away with the transcript), and a line left without tags goes away again. While
/// editing, the tags of the other transcripts are suggested under it, the most used first, then those matching what is
/// typed (SearchSuggestions, the same ranking as the search's suggestions); a tap adds one. Edits the recording in
/// place. Earlier versions showed an "Add Tag" field under every transcript, tags or not, and suggested nothing.
struct TagEditor: View {
    @Bindable var recording: Recording
    @Binding var isEditing: Bool
    /// Counts the toolbar's Add Tag presses: each one focuses the field, also when the line is already there (a focus
    /// request can be lost, e.g. while the More menu it came from is still closing).
    var focusRequest = 0

    @Environment(\.modelContext) private var modelContext
    @State private var draft = ""
    /// The other transcripts' tags, read at the start of each edit; nil until they were read once.
    @State private var candidates: [SuggestionCandidate]?
    @FocusState private var fieldFocused: Bool

    /// The scroll id of the tag line (the toolbar's Add Tag scrolls it into view).
    static let scrollID = "TagLine"
    /// Suggestions shown at once: one line of chips on an iPhone, scrolled sideways when they are wider.
    static let suggestionLimit = 8
    /// Transcripts read per turn of the main actor for the suggestions.
    static let batch = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Pills and the field wrap into lines like Mail's recipients: every tag stays visible while editing (a
            // sideways-scrolling line hid the first pills behind the field as more were added).
            WrappingLayout(spacing: 6, lineSpacing: 6) {
                ForEach(recording.tags, id: \.self) { tag in
                    chip(tag)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                if isEditing {
                    field
                }
            }
            // There for the whole edit (unless no other transcript has tags), with a chip's height even while nothing
            // matches or the tags are still being read: a row that came and went with the matches moved the
            // transcript below by 42 pt on keystrokes.
            if isEditing, candidates?.isEmpty != true {
                suggestionRow
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: recording.tags)
        .animation(.snappy(duration: 0.2), value: suggestions.map(\.id))
        .task(id: isEditing) {
            guard isEditing else { return }
            await loadCandidates()
        }
    }

    // MARK: Field

    private var field: some View {
        TextField("Add Tag", text: $draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($fieldFocused)
            .font(.subheadline)
            .padding(.vertical, 6)                // a pill's height, so a line of pills and the field doesn't jump
            // As wide as its text (WrappingLayout measures it unproposed; at least room for the placeholder and a short
            // word), so it follows the last pill and moves to its own line when it no longer fits there; a longer
            // draft gets the line's width and scrolls inside the field. Not `fixedSize`: that ignored the line's
            // width, and a long draft ran off the screen with the caret.
            .frame(minWidth: 120, alignment: .leading)
            .onChange(of: draft) { _, text in splitAtCommas(text) }
            .onSubmit {
                commitDraft()
                fieldFocused = false
            }
            .onChange(of: fieldFocused) { _, focused in
                guard !focused else { return }
                commitDraft()
                isEditing = false                 // a line left without tags goes away (RecordingDetailView)
            }
            .onAppear {
                InteractionTrace.shown("tag")
                // Focused on the next turn, after the line is on screen: becoming first responder sets up the keyboard
                // (75 ms+ of UIKit's work the first time in a session, Time Profiler on the iPhone 17 simulator), and
                // done in this turn it held back the frame with the line: 313-648 ms from the press to the line.
                DispatchQueue.main.async { fieldFocused = true }
            }
            .onChange(of: focusRequest) {
                InteractionTrace.shown("tag")                // the line was there already
                DispatchQueue.main.async { fieldFocused = true }
            }
            .onDisappear { commitDraft() }        // the card closed while typing: the word isn't lost
    }

    /// Everything before the last comma becomes tags; the rest (without the space after the comma) stays in the field.
    private func splitAtCommas(_ text: String) {
        guard text.contains(",") || text.first?.isWhitespace == true else { return }
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let rest = parts.removeLast()
        for part in parts { _ = recording.addTag(part) }      // a duplicate or an empty part is dropped
        let trimmed = String(rest.drop { $0.isWhitespace })
        if trimmed != text { draft = trimmed }
    }

    private func commitDraft() {
        let text = draft
        draft = ""
        _ = recording.addTag(text)
    }

    // MARK: Pills

    /// The chip's padding sits inside the button label on the trailing side, so the remove button's hit area is the
    /// whole trailing part of the capsule (~23x25 pt) rather than the bare ~10 pt glyph; the chip looks the same.
    private func chip(_ tag: String) -> some View {
        HStack(spacing: 0) {
            Text(tag)
                .lineLimit(1)
                .padding(.leading, 10)
                .padding(.vertical, 6)
            Button {
                recording.removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove \(tag)")
        }
        .font(.subheadline)
        .background(.tint.opacity(0.12), in: Capsule())
    }

    // MARK: Suggestions

    /// The other transcripts' tags not on this one: with an empty field the most used, otherwise those matching the
    /// text (equal, prefix, word prefix, then substring from three letters; "#" in front is ignored).
    private var suggestions: [Suggestion] {
        guard isEditing, let candidates, !candidates.isEmpty else { return [] }
        let taken = recording.tags.map { SearchToken(kind: .tag, value: $0) }
        return SearchSuggestions.suggest(text: draft, candidates: candidates, excluding: taken,
                                         limit: Self.suggestionLimit)
    }

    /// One line, scrolled sideways: suggestions are filtered on every keystroke, and a wrapping block would change the
    /// card's height as they come and go.
    private var suggestionRow: some View {
        ZStack(alignment: .leading) {
            // Holds the row's height (a chip's, at any text size) while no chip is shown.
            suggestionChip(Suggestion(token: SearchToken(kind: .tag, value: "tag"), matched: nil, replacing: "",
                                      tier: 9, count: 0))
                .hidden()
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            _ = recording.addTag(suggestion.token.value)
                            draft = ""
                        } label: {
                            suggestionChip(suggestion)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("TagSuggestion")
                    }
                }
            }
            .scrollClipDisabled()                 // chips run out to the screen's edge, not the text margin
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested Tags")
    }

    /// The search's suggestion chip (RecordingsListView): "#" glyph in the tint, the typed part in bold, on a grey
    /// capsule, so a suggestion reads differently from a tag the transcript has (tinted, with ×).
    private func suggestionChip(_ suggestion: Suggestion) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "number")
                .imageScale(.small)
                .foregroundStyle(.tint)
            SearchHighlight.bold(suggestion.token.value, suggestion.matched)
                .lineLimit(1)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(suggestion.token.value)
        .accessibilityHint("Adds this tag")
    }

    /// Every transcript's tags, counted per transcript, newest transcripts first. Recording is a main-actor model, so
    /// this reads on the main actor: in batches of `batch` transcripts, one per turn of the main actor (as the search
    /// index does), starting after the press's frame. Measured with 103 transcripts on the iPhone 17 simulator: one
    /// fetch of all of them took 13 ms the first time in a session (3 ms afterwards); in batches, each takes under 1 ms
    /// except the session's first, 9 ms even for a single row (Time Profiler: SwiftData translating the descriptor the
    /// first time, Swift conformance lookups and SQLite preparing the statement), which no batch size avoids.
    /// `propertiesToFetch: [\.tags]` made the first fetch slower (33 ms), not faster.
    /// The previous edit's candidates stay until the new ones are read (resetting them made the chips flicker), and the
    /// new ones come in animated: when no other transcript has tags, the row reserved while reading goes away softly.
    private func loadCandidates() async {
        let own = recording.id                    // this transcript's tags aren't suggestions (a removed pill isn't
        var tagsPerDoc: [[String]] = []           // suggested back), nor counted
        var offset = 0
        while true {
            await Task.yield()                    // the press's frame first, then a frame between the batches
            guard !Task.isCancelled else { return }
            var descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batch
            let batch = (try? modelContext.fetch(descriptor)) ?? []
            tagsPerDoc += batch.lazy.filter { $0.id != own }.map(\.tags)
            offset += batch.count
            if batch.count < Self.batch { break }
        }
        let loaded = SearchSuggestions.candidates(speakerNamesPerDoc: [], tagsPerDoc: tagsPerDoc, people: [])
        withAnimation(.snappy) { candidates = loaded }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var editing = true
    TagEditor(recording: PreviewData.sample(), isEditing: $editing)
        .padding()
        .modelContainer(PreviewData.container)
}
#endif
