import SwiftUI
import SwiftData

/// One saved recording, the transcript card's content (`TranscriptCard`; Music's "Now Playing" for a transcript): the
/// back button at the top left, inline-editable title, date and duration, the automatic summary, tags, speaker-identification
/// status and the transcript grouped by speaker; its actions in the system's bottom toolbar (Liquid Glass): Share,
/// Add Tag, Edit Text, Action Items, Listen and Delete. No top bar. Tapping a speaker's name row (or "Rename Speaker…" in its long-press menu) opens
/// the rename sheet for that speaker, once speakers are final.
/// Opened from a search result (`search`), the transcript highlights the hits, starts at the result's paragraph and
/// steps through the paragraphs with hits from the bottom toolbar ("2 of 5"), between a More menu (Share, Add Tag, Edit
/// Text, Action Items and Listen) and Delete.
/// Turned from the recording (TranscriptCard), its title and date line lie exactly where the recording had them, what
/// the recording didn't have fades in below them, and its toolbar takes over from the melted Stop.
struct RecordingDetailView: View {
    @Bindable var recording: Recording
    var search: TranscriptSearchContext? = nil
    /// Turned from the recording: everything below the date line fades in, once `holdsBody` is false (the recording's
    /// live text has faded out; TranscriptCard). Otherwise shown at once.
    var fadesInBody = false
    var holdsBody = false
    /// The card is still turning from the recording (TranscriptCard), whose title, date line and flying timer show
    /// until then: this view's own title and date line are hidden under them, and its toolbar under the melted
    /// Stop's replicas (with a stand-in for its scroll edge effect).
    var turning = false
    /// The back button and Delete: MainView closes the card (back to the list).
    let onClose: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openPerson) private var openPerson     // a name row's "Go to Person"

    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool
    @State private var deleteOnDisappear = false
    @State private var hits: [UUID] = []             // paragraphs with search hits, in transcript order
    @State private var hitIndex = 0
    @State private var scroller: ScrollViewProxy?    // scrolls to a search hit (reveal)
    @State private var renaming: SpeakerRenameTarget?
    @State private var editingTags = false           // the toolbar's Add Tag: the tag line is there with its field
    @State private var tagFocusRequest = 0           // each Add Tag press: focus the tag field (TagEditor)
    @State private var bodyShown: Bool
    @State private var hitGeometry = HitGeometry()
    @AppStorage(TranscriptExport.namesKey) private var exportNames = true
    @AppStorage(TranscriptExport.timestampsKey) private var exportTimestamps = false
    @State private var keepsStatusRow = false           // the status line was shown: its place stays (see body)
    @State private var showsActionItems = false         // the toolbar's Action Items: Gemma's to-dos in a sheet
    @State private var actionItemUndo = ActionItemUndo()   // Undo of an item removed in that sheet: toast and shake
    /// The bookmarked sentences (Bookmarks.places), found once the paragraphs are final (Bookmarks.paragraphsAreFinal),
    /// after the first frame (it reads the words), and again when the vocabulary pass or a correction rewrites them; none
    /// before (FED-73).
    @State private var bookmarkPlaces: [Bookmarks.Place] = []
    @State private var pendingMerge: SpeakerMerge?
    /// Edit Text: the paragraphs' text and speaker-chip drafts while editing (by segment id), nil otherwise.
    @State private var textEdits: [UUID: String]?
    @State private var speakerEdits: [UUID: Int] = [:]
    /// Words typed in place of others, offered for Your Words after Done.
    @State private var vocabularyOffer: [String]?
    /// The Undo toast for the last correction, until it times out (shake to undo works on).
    @State private var undoToast: UUID?
    /// The correction whose Undo is on offer here (toast or shake), until withdrawn: shake comes back after the
    /// vocabulary pass only for it.
    @State private var offeredUndo: UUID?
    /// The recording's audio file is there (the player bar and tapping a word to hear it).
    @State fileprivate var hasAudio = false
    /// Words ↔ paragraphs for the playback highlight and taps (rebuilt off the main actor when the paragraphs change).
    /// In a box: the paragraphs read it in their own bodies (WordParagraph's `playing`), and a @State of this view read
    /// there through a closure gave its value from when the closure was made (the empty map from before Listen built
    /// it: nothing was highlighted).
    @State private var playback = PlaybackMapBox()
    /// Listen (the toolbar's headphones): the player bar is shown, the spoken word highlighted and a tapped word
    /// played, until the bar's close button. Off, the card is as without audio: the paragraphs are plain text with the
    /// system's selection (a tap selects nothing and plays nothing), and the card opens without drawing its paragraphs
    /// word by word (iPhone 17 simulator, an 8-minute transcript: first frame 293 ms with word paragraphs, 243 ms
    /// without).
    @State fileprivate var listening = false
    /// Listen's paragraphs are word paragraphs, from a moment after Listen (once the bar is up): drawn word by word,
    /// the visible paragraphs held the press's turn 45–86 ms (iPhone 17 simulator, an 8-minute transcript); the bar
    /// alone answers in its frame.
    @State fileprivate var wordsShown = false
    @Environment(\.undoManager) private var undoManager

    init(recording: Recording, search: TranscriptSearchContext? = nil, fadesInBody: Bool = false, holdsBody: Bool = false,
         turning: Bool = false, onClose: @escaping () -> Void) {
        self.recording = recording
        self.search = search
        self.fadesInBody = fadesInBody
        self.holdsBody = holdsBody
        self.turning = turning
        self.onClose = onClose
        _bodyShown = State(initialValue: !fadesInBody)
    }

    var body: some View {
        let segments = recording.segments                 // read once per body (the SwiftData array is decoded on access)
        let statusText = PipelineStatusLine.text(for: recording, identifier: services.identifier)
        let showsNote = SpeakerStatusNote.applies(to: recording, identifier: services.identifier)
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    // Tap the title to rename: a plain text field, no menu. A blank title falls back to "Untitled
                    // Transcript". Any edit marks the name as the user's, so an automatic title never replaces it.
                    TextField("Title", text: titleText)
                        .font(.title2.weight(.bold))
                        .submitLabel(.done)
                        .onSubmit(normalizeTitle)
                        .onChange(of: titleFocused) { _, focused in if !focused { normalizeTitle() } }
                        .focused($titleFocused)
                        .accessibilityLabel("Title")
                        .opacity(turning ? 0 : 1)
                        .animation(nil, value: turning)            // takes over from the recording's in one frame

                    VStack(alignment: .leading, spacing: 8) {
                        // Date, duration and place on one line when they fit, otherwise the place moves to a second line.
                        TranscriptDateLine(date: recording.createdAt, duration: Text(recording.duration.clockFormatted),
                                           place: recording.placeName)
                            .opacity(turning ? 0 : 1)
                            .animation(nil, value: turning)
                        // One line under the date: what is being done to the transcript right now while the
                        // pipeline runs ("Writing summary…" too), then in the same place the automatic summary
                        // (TranscriptTitler), folded into a "Summary" row. Two lines at once (the status and the
                        // summary row, both shimmering) read as two things going on. Once shown, the place stays
                        // while the card is open, an empty line when there is no summary: a line going away moved
                        // the whole transcript up. The status line and the empty line stand on a hidden folded
                        // Summary row, so all three are as tall as it (the row is ~4 pt taller than the line; the swap
                        // moved the transcript), and the status crossfades into the summary where it stands.
                        if statusText != nil || hasSummary || keepsStatusRow {
                            ZStack(alignment: .leading) {
                                if statusText != nil || (keepsStatusRow && !hasSummary) {
                                    SummaryDisclosure.standIn
                                }
                                if statusText != nil {
                                    PipelineStatusLine(recording: recording)
                                } else if let summary = recording.summary, !summary.isEmpty {
                                    SummaryDisclosure(summary: summary, highlights: search?.highlights(in: summary) ?? [])
                                }
                            }
                            .animation(.easeInOut(duration: 0.25), value: statusText == nil)
                            .opacity(bodyShown ? 1 : 0)
                        }
                        // The bookmarks under the summary: a tap scrolls to the highlighted sentence (FED-14).
                        if !bookmarkPlaces.isEmpty {
                            BookmarksDisclosure(places: bookmarkPlaces, onSelect: reveal)
                                .opacity(bodyShown ? 1 : 0)
                        }
                        // HIG › Generative AI: say that AI made it and can be wrong. For the whole transcript, not only
                        // the summary: the words, the speakers and the names recognized by voice are all generated (a
                        // caption under the summary alone implied the rest was not).
                        Text("AI-generated content can contain mistakes.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .opacity(bodyShown ? 1 : 0)
                            .accessibilityIdentifier("AINotice")
                    }

                    // Only with tags, or while adding them (the toolbar's Add Tag): no empty "Add Tag" line under
                    // every transcript.
                    if !recording.tags.isEmpty || editingTags {
                        TagEditor(recording: recording, isEditing: $editingTags, focusRequest: tagFocusRequest)
                            .id(TagEditor.scrollID)
                            .opacity(bodyShown ? 1 : 0)
                            .transition(.opacity)
                    }

                    if showsNote {
                        SpeakerStatusNote(recording: recording)
                            .opacity(bodyShown ? 1 : 0)
                            .transition(.opacity)
                    }
                }
                .animation(.snappy, value: showsNote)
                .animation(.snappy, value: !recording.tags.isEmpty || editingTags)   // the tag line comes and goes
                // No spacing above: the first name row brings its own (the space above a name is part of its target).
                transcript(segments)
                    .opacity(bodyShown ? 1 : 0)
                    .task(id: BookmarkSource(segments: segments, isFinal: Bookmarks.paragraphsAreFinal(recording))) {
                        guard !recording.bookmarks.isEmpty, !recording.isDeleted else { return }
                        // Not on paragraphs the steps after Stop still rewrite: placed on the live words, then on each
                        // pass's, the highlights vanished and came back on other words until the end (FED-73).
                        guard Bookmarks.paragraphsAreFinal(recording) else { bookmarkPlaces = []; return }
                        bookmarkPlaces = Bookmarks.places(recording.bookmarks, words: recording.words, segments: segments)
                    }
                // An imported file in which the transcriber found no words (a recording without any is discarded
                // at Stop instead); while its steps run the status line says what is being done.
                if segments.isEmpty, statusText == nil, recording.wordsRefined {
                    Text("No speech was found in this recording.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, TranscriptStyle.turnSpacing)
                }
            }
            .coordinateSpace(.named(TranscriptView.contentSpace))
            .padding(.horizontal, TranscriptStyle.margin)
            .padding(.bottom, 24)
            .frame(maxWidth: TranscriptStyle.maxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)        // swiping the transcript ends (and saves) an edit
        // A ScrollViewReader, not a `scrollPosition` binding, for the search hits: the binding tracked the paragraph
        // near the anchor and kept it in place when the content changed (the steps row making the content taller
        // than the screen, then the refined speakers inserting a turn), which moved the title and date line 10 pt
        // (pixel track on the iPhone 17 simulator; testRecordAccessoryFlow measured 4-23 pt).
        // The soft edge under the bottom toolbar, as in Notes and Mail (and as the live view has under its Stop).
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .modifier(undoOffer)
        .safeAreaBar(edge: .bottom) {
            // While the toolbar is hidden under the melt's replicas: a stand-in of its height (52 pt, the inset the bar
            // adds), so the soft edge is already there and doesn't switch on at once when the real bar takes over.
            // Its content must be real: Color.clear (or an empty but visible bar) gave no edge effect.
            if turning {
                Rectangle()
                    .fill(Color(uiColor: .systemBackground).opacity(0.001))
                    .frame(height: 52)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if listening, hasAudio, !isEditingText {
                // Listen: the player above the bottom toolbar; its close button ends Listen.
                PlayerBar(player: services.player, recording: recording, isDisabled: services.identifier.isRecording,
                          onClose: endListening)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onScrollGeometryChange(for: CGRect.self, of: { geometry in   // what is visible between the band and the bar
            CGRect(x: 0, y: geometry.visibleRect.minY + geometry.contentInsets.top, width: geometry.visibleRect.width,
                   height: geometry.visibleRect.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
        }, action: { _, visible in hitGeometry.visible = visible })
        // The back button floats over the top left: the content starts below it and scrolls under its glass.
        .contentMargins(.top, CardCloseButton.contentTop, for: .scrollContent)
        .cardCloseButton(hint: "Back to the transcripts", action: onClose)
        .task(id: search) { await showFirstHit() }
        .onAppear { InteractionTrace.shown("open") }
        .onChange(of: segments) { findHits() }              // the vocabulary pass or a correction rewrote them
        .modifier(PlaybackFollowing(card: self, segments: segments))
        .onChange(of: statusText != nil, initial: true) { _, shown in if shown { keepsStatusRow = true } }
        .onChange(of: recording.speakerStatusRaw) {        // Try Again re-runs identification: numbers change
            if recording.speakerStatus != .done { renaming = nil }
        }
        .sheet(item: $renaming) { target in
            SpeakerNameSheet(recording: recording, speaker: target.speaker)
        }
        .sheet(isPresented: $showsActionItems) {
            ActionItemsSheet(recording: recording, undo: actionItemUndo)
        }
        #if DEBUG
        .task { await renameFirstSpeakerForQA() }
        #endif
        // Like Photos, Mail and Notes: the transcript's actions in the system's bottom toolbar (Liquid Glass), within
        // thumb reach, where the recording had its large Stop.
        .toolbar { bottomBar }
        // The bottom bar sits under the keyboard while a paragraph is edited: Cancel and Done above the keyboard too,
        // at the bar's ends (a lone item there is centred, over the text).
        .toolbar {
            if isEditingText {
                ToolbarItemGroup(placement: .keyboard) {
                    Button(role: .cancel) { cancelEditingText() }
                        .accessibilityLabel("Cancel Editing")
                    Spacer()
                    Button(role: .confirm, action: finishEditingText)
                        .accessibilityLabel("Done Editing")
                }
            }
        }
        .alert("Add to Your Words?", isPresented: Binding(get: { vocabularyOffer != nil },
                                                          set: { if !$0 { vocabularyOffer = nil } })) {
            Button("Add") {
                Vocabulary.custom += vocabularyOffer ?? []
                vocabularyOffer = nil
            }
            Button("Not Now", role: .cancel) { vocabularyOffer = nil }
        } message: {
            Text("Feder then expects \((vocabularyOffer ?? []).formatted(.list(type: .and))) in your next transcripts.")
        }
        .toolbar(turning ? .hidden : .visible, for: .bottomBar)
        .task(id: holdsBody) {
            // Started when it is let go rather than with a `.delay`: with a delay the value is already set, and a part
            // re-made in the meantime (the speaker status row, as identification starts) appeared at once. A task, so
            // a transcript inserted after the live text was gone still fades in rather than appearing with its view.
            guard !holdsBody, !bodyShown else { return }
            withAnimation(.easeOut(duration: 0.25)) { bodyShown = true }
        }
        .confirmationDialog(pendingMerge.map { String(localized: "Merge \(recording.speakerName($0.from)) into \(recording.speakerName($0.into))?") } ?? "",
                            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
                            titleVisibility: .visible) {
            Button("Merge") {
                if let merge = pendingMerge {
                    services.identifier.merge(merge.from, into: merge.into, in: recording)
                    offerUndo()
                }
            }
        } message: {
            Text("Everything they said is then one speaker's.")
        }
        .onDisappear {
            if services.player.recordingID == recording.id { services.player.unload() } // the card closed
            if isEditingText { services.identifier.endEditingText(recording) }           // its drafts are gone
            undoManager?.removeAllActions(withTarget: services.identifier)                // no shake-undo of an unseen card
            actionItemUndo.withdraw(from: undoManager)
            // Delete only once the card has closed: this view keeps re-reading the model while the card shrinks away,
            // and reading a deleted-and-saved (detached) @Model traps.
            guard deleteOnDisappear, !recording.isDeleted else { return }
            services.people.forget(recording)
            SpotlightIndex.remove(recording.id)
            AudioFileStore.delete(fileName: recording.audioFileName)
            modelContext.delete(recording)
            try? modelContext.save()
        }
        .onAppear { scroller = proxy }
        }
    }

    // MARK: Bottom toolbar

    /// Share, Add Tag, Edit Text, Action Items and Listen on the left (one glass group), Delete on the right; opened from a
    /// search, the hits' "n of m" with previous/next between them (like Safari's Find on Page).
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if isEditingText {
            ToolbarItem(placement: .bottomBar) {
                Button(role: .cancel) { cancelEditingText() }          // glass xmark
                    .accessibilityLabel("Cancel Editing")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(role: .confirm, action: finishEditingText)                 // prominent glass checkmark
                    .accessibilityLabel("Done Editing")
            }
        } else {
            regularBar
        }
    }

    @ToolbarContentBuilder
    private var regularBar: some ToolbarContent {
        if combinesActions {
            // With the hit navigator the bar would have seven items, which fit no iPhone: iOS moved Next Match (and
            // Previous Match) into an overflow menu on the iPhone 17, the iPhone Air and the iPhone 18 Pro Max alike
            // (iOS 27 simulators). Share, Add Tag, Edit Text, Action Items and Listen share one menu instead, so the
            // navigator and Delete stay visible. (Before Add Tag, six items fit from 402 pt on.)
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    shareButton
                    addTagButton
                    editTextButton
                    if BetterSummaries.isSupported { actionItemsButton }
                    listenButton
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        } else {
            ToolbarItem(placement: .bottomBar) { shareButton }
            ToolbarItem(placement: .bottomBar) { addTagButton }
            ToolbarItem(placement: .bottomBar) { editTextButton }
            if BetterSummaries.isSupported {
                ToolbarItem(placement: .bottomBar) { actionItemsButton }
            }
            ToolbarItem(placement: .bottomBar) { listenButton }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if !hits.isEmpty {
            ToolbarItem(placement: .bottomBar) {
                Text("\(hitIndex + 1) of \(hits.count)")
                    .monospacedDigit()
                    .fixedSize()                        // iOS 26.5 truncated it to "1…" otherwise
                    .padding(.leading, 6)
                    .accessibilityLabel("Match \(hitIndex + 1) of \(hits.count)")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Previous Match", systemImage: "chevron.up") { step(-1) }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Next Match", systemImage: "chevron.down") { step(1) }
            }
            // Only a small gap to Delete: with a second flexible spacer the bar no longer fit an iPhone 17 and moved
            // Next and Delete into an overflow menu.
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Delete Transcript", systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
            // On the button, not the view: iOS anchors the confirmation to its source, so it comes out of the trash
            // button as in Photos and Notes (on the whole view it floated mid-card, pointing at the text).
            .confirmationDialog("Delete this transcript?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    deleteOnDisappear = true
                    onClose()
                }
            }
        }
    }

    /// Share: a menu of formats (TranscriptExport) and the two options, remembered for the next time. Text goes to
    /// the same system share sheet as the list's Share swipe action (title and app symbol in its header; ShareLink of
    /// the plain text showed a generic text icon and the first line instead); the others as a file, written off the
    /// main actor first.
    private var shareButton: some View {
        Menu {
            Section("Share As") {
                Button("Text", systemImage: "doc.plaintext") { share(.text) }
                Button("PDF", systemImage: "doc.richtext") { share(.pdf) }
                Button("Word Document", systemImage: "doc.text") { share(.word) }
                Button("Markdown", systemImage: "number") { share(.markdown) }
                Menu("Subtitles", systemImage: "captions.bubble") {
                    Button("SRT") { share(.srt) }
                    Button("WebVTT") { share(.vtt) }
                }
            }
            // The options keep the menu open (a menu closes after any item by default): set them, then pick a format.
            Section {
                Toggle("Speaker Names", isOn: $exportNames)
                    .menuActionDismissBehavior(.disabled)
                Toggle("Timestamps", isOn: $exportTimestamps)
                    .menuActionDismissBehavior(.disabled)
            }
        } label: {
            Label("Share Transcript", systemImage: "square.and.arrow.up")
        }
    }

    private func share(_ format: TranscriptExport.Format) {
        // The bookmarked sentences the card has found: the words aren't read again in the press.
        let snapshot = recording.exportSnapshot(names: exportNames, timestamps: exportTimestamps,
                                                withWords: format.isSubtitles,
                                                places: bookmarkPlaces.isEmpty ? nil : bookmarkPlaces)
        guard format != .text else {
            ShareSheet.present(text: TranscriptExport.plainText(snapshot), title: recording.name)
            return
        }
        Task {
            guard let url = try? await TranscriptExport.file(format, of: snapshot) else { return }
            ShareSheet.present(file: url)
        }
    }

    /// Inserts the tag line with its field focused (TagEditor); the line is scrolled into view once it is laid out,
    /// for a card scrolled down into the transcript.
    private var addTagButton: some View {
        Button("Add Tag", systemImage: "tag") {
            InteractionTrace.begin("tag")
            hitGeometry.userScrolled = .now                 // Listen's following waits: the user went there
            titleFocused = false
            editingTags = true
            tagFocusRequest += 1
            Task {
                await Task.yield()                          // the line exists from the next layout on
                withAnimation(.snappy) { scroller?.scrollTo(TagEditor.scrollID, anchor: .center) }
            }
        }
    }

    /// Action Items (ActionItemsSheet): Gemma lists the transcript's to-dos when asked, where the speaker-count menu was
    /// until October 2026 (Automatic, 2–6 Speakers: the user never found it useful; a wrong grouping is fixed per
    /// paragraph). Once the speakers are final (the paragraphs carry their names). Not there at all on an iPhone that
    /// can't run Gemma (under 8 GB: BetterSummaries.isSupported; the user's decision, not a greyed button that never
    /// works; the melt has a layout without it); there while Gemma isn't downloaded yet, whose sheet says where to get it.
    private var actionItemsButton: some View {
        Button("Action Items", systemImage: "checklist") {
            InteractionTrace.begin("actions")
            titleFocused = false
            showsActionItems = true
        }
        .disabled(recording.speakerStatus != .done)
    }

    /// Listen: shows the player bar (pressed again, or the bar's close button: ends it). Last in the group, so the
    /// other buttons stay where they were; greyed out without the recording's audio (the samples have none).
    private var listenButton: some View {
        Button(listening ? "Stop Listening" : "Listen", systemImage: "headphones") {
            if listening { endListening() } else { startListening() }
        }
        .disabled(!hasAudio)
        .accessibilityIdentifier("Listen")
    }

    /// With the hit navigator (opened from a search result), on every iPhone.
    private var combinesActions: Bool { !hits.isEmpty }

    private var hasSummary: Bool { recording.summary?.isEmpty == false }

    // MARK: Edit Text

    fileprivate var isEditingText: Bool { textEdits != nil }

    private var textEditsBinding: Binding<[UUID: String]>? {
        guard textEdits != nil else { return nil }
        // Only while editing: a field resigning after Done or Cancel writes once more, which must not start it again.
        return Binding(get: { textEdits ?? [:] }, set: { if textEdits != nil { textEdits = $0 } })
    }

    /// The name rows rename, except while the text is edited (then they are plain names).
    private var renameAction: ((Int) -> Void)? {
        guard !isEditingText else { return nil }
        // Undo goes when the sheet opens: shaken under it, it renumbered the speakers, and the sheet named the wrong one.
        return {
            withdrawUndo()
            renaming = SpeakerRenameTarget(speaker: $0)
        }
    }

    private var editTextButton: some View {
        Button("Edit Text", systemImage: "pencil") {
            titleFocused = false
            // No Undo while editing: it would change the paragraphs under the open drafts (keyed by their ids).
            withdrawUndo()
            speakerEdits = [:]
            textEdits = [:]
        }
        .disabled(!services.identifier.canCorrectSpeakers(of: recording))
    }

    /// Done: the edited paragraphs into the words (Recording.applyTextEdits); words typed in place of others are
    /// offered for Your Words, so the next transcripts get them right.
    /// Done: the text and the speaker chips in one correction (SpeakerIdentifier.applyEdits, one step for Undo); words
    /// typed in place of others are offered for Your Words.
    private func finishEditingText() {
        guard let drafts = textEdits else { return }
        let speakers = speakerEdits
        textEdits = nil
        speakerEdits = [:]
        endEditing()
        guard !drafts.isEmpty || !speakers.isEmpty else { return }
        let result = services.identifier.applyEdits(text: drafts, speakers: speakers, in: recording)
        if result.changed { offerUndo() }                  // a Done that changed nothing offers no older Undo
        let candidates = TextCorrection.vocabularyCandidates(result.replacements, known: Vocabulary.custom)
        if !candidates.isEmpty { vocabularyOffer = Array(candidates.prefix(5)) }
    }

    private func cancelEditingText() {
        textEdits = nil
        speakerEdits = [:]
        endEditing()
    }

    /// The transcript with everything the card hands it (split out of `body`: one expression was too much for the type
    /// checker).
    private func transcript(_ segments: [TranscriptSegment]) -> TranscriptView {
        let currentHit: UUID? = hits.indices.contains(hitIndex) ? hits[hitIndex] : nil
        // The paragraphs' frames: for revealing a search hit, and the spoken word while the audio plays (from the
        // first layout: the paragraphs on the first screen are laid out once).
        let tracksFrames = search != nil || hasAudio
        let hitFrame: ((UUID, CGRect) -> Void)? = tracksFrames ? { id, frame in hitGeometry.frames[id] = frame } : nil
        let changes: ((TranscriptSegment) -> [ChangeFlash])? = isEditingText ? nil : flashes
        let showsTip = search == nil && recording.speakerNames.isEmpty && !isEditingText
        let speakerEdits: Binding<[UUID: Int]>? = isEditingText ? $speakerEdits : nil
        let words = listening && wordsShown && hasAudio && !isEditingText
        let onWordTap: ((TranscriptSegment, Int) -> Void)? = words ? { playWord($0, $1) } : nil
        let playing: ((UUID) -> Range<Int>?)? = words ? { playingTokens(in: $0) } : nil
        let people = Set(recording.speakerPeople.keys)
        let showPerson: ((Int) -> Void)? = openPerson.map { open in
            { [recording] speaker in if let id = recording.speakerPeople[speaker] { open(id) } }
        }
        return TranscriptView(segments: segments, speakerName: recording.speakerName(_:),
                              preliminary: recording.speakerStatus != .done, preliminaryNotice: preliminaryNotice,
                              renameSpeaker: renameAction, search: search, currentHit: currentHit, hitFrame: hitFrame,
                              flashes: changes, showsNameTip: showsTip, correctSpeaker: speakerCorrection,
                              edits: textEditsBinding, speakerEdits: speakerEdits, playing: playing,
                              onWordTap: onWordTap, people: people, showPerson: showPerson,
                              bookmarks: Self.bookmarkRanges(bookmarkPlaces, in: segments))
    }

    // MARK: Playback

    /// The spoken word's place in the transcript (its paragraph, its tokens there), nil when none or not this one's.
    fileprivate var playingPlace: PlaybackMap.Place? {
        guard services.player.recordingID == recording.id, let word = services.player.word else { return nil }
        return playback.map.place(of: word)
    }

    /// A paragraph's spoken tokens: read by the paragraph (WordParagraph), so only the paragraphs follow the word.
    private func playingTokens(in segment: UUID) -> Range<Int>? {
        guard let place = playingPlace, place.segment == segment else { return nil }
        return place.tokens
    }

    /// A tapped word: playback from it (a moment before, so its start isn't clipped), highlighted from the tap on.
    private func playWord(_ segment: TranscriptSegment, _ token: Int) {
        guard !services.identifier.isRecording, let word = playback.map.word(at: token, in: segment.id) else { return }
        let player = services.player
        if player.recordingID != recording.id { player.load(recording, words: playback.map.words) }
        player.play(from: max(0, player.audioTime(ofWordAt: word.start) - 0.1), word: word.index)
    }

    fileprivate func checkAudio() async {
        hasAudio = await Self.fileExists(recording.audioURL)
    }

    /// The word map for the paragraphs, built off the main actor once Listen starts; the player gets the same words
    /// (loaded here, not on the first tap: reading the words is a SwiftData decode, which a press mustn't wait for).
    fileprivate func refreshPlaybackMap(_ segments: [TranscriptSegment]) async {
        let words = recording.words
        let map = await PlaybackMap.build(words: words, segments: segments)
        guard !Task.isCancelled else { return }
        playback.map = map
        let player = services.player
        if player.recordingID == recording.id {
            player.setWords(words, offset: recording.alignmentOffset)
        } else {
            player.load(recording, words: words)
        }
    }

    private func startListening() {
        InteractionTrace.begin("listen")
        withAnimation(.snappy) { listening = true }
    }

    /// Word paragraphs once the bar has come up (its animation), plain text again when Listen ends.
    fileprivate func showWords() async {
        guard listening, !isEditingText else {           // after Edit Text too: back a moment after Done or Cancel
            wordsShown = false
            return
        }
        guard (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
        wordsShown = true
    }

    /// The bar's close button (or Listen again): playback stops, Now Playing goes, the paragraphs are plain text again.
    private func endListening() {
        if services.player.recordingID == recording.id { services.player.unload() }
        withAnimation(.snappy) { listening = false }
    }

    /// Keeps the spoken word on screen while playing: when its line has left the visible part, a paragraph that fits
    /// is centred (like a search hit), a taller one scrolled so the word's line stands as far down the screen as it
    /// stands in the paragraph (on screen either way). Not while the user scrolls, nor for a few seconds after: they
    /// are reading elsewhere.
    fileprivate func follow(_ place: PlaybackMap.Place?) {
        // Nor while a field is being typed in (the title, a tag, Edit Text): scrolled away under the typing.
        guard let place, services.player.isPlaying, !hitGeometry.userScrolledRecently, !isEditingText, !titleFocused,
              !editingTags else { return }
        guard let frame = hitGeometry.frames[place.segment] else {
            withAnimation(.snappy) { scroller?.scrollTo(place.segment, anchor: .center) }   // not laid out yet
            return
        }
        let visible = hitGeometry.visible.insetBy(dx: 0, dy: 24)    // a line's margin: the estimate is per line
        let line = frame.minY + place.fraction * frame.height
        guard !visible.isNull, !(visible.minY...visible.maxY).contains(line) else { return }
        let anchor = frame.height <= visible.height ? UnitPoint.center : UnitPoint(x: 0.5, y: place.fraction)
        withAnimation(.snappy) { scroller?.scrollTo(place.segment, anchor: anchor) }
    }

    /// Edit Text: the vocabulary pass waits until it ends (SpeakerIdentifier.beginEditingText), and Listen's playback
    /// stops (the bar is hidden meanwhile, so the AirPods or the lock screen mustn't start it again unseen).
    fileprivate func editingChanged(_ editing: Bool) {
        if editing {
            services.identifier.beginEditingText(recording)
            if services.player.recordingID == recording.id { services.player.stop() }
        } else {
            services.identifier.endEditingText(recording)
        }
    }

    /// The user's own scrolling: following waits while it lasts and for 3 s after it ends (a slow drag or a held
    /// finger lasts longer than 3 s).
    fileprivate func scrollPhaseChanged(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            hitGeometry.userScrolling = true
            hitGeometry.userScrolled = .now
        case .idle, .animating:
            if hitGeometry.userScrolling { hitGeometry.userScrolled = .now }
            hitGeometry.userScrolling = false
        @unknown default: break
        }
    }

    @concurrent
    nonisolated private static func fileExists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: Undo

    /// After a correction of this transcript: the Undo toast for a few seconds, and Undo for shaking the iPhone (the
    /// system's shake-to-undo, through the window's UndoManager) until the next correction, Edit Text, the card closing,
    /// or the correction's Undo going (SpeakerIdentifier.lastCorrection: the transcript changed in another way).
    private func offerUndo() {
        guard let correction = services.identifier.lastCorrection, correction.recordingID == recording.id else { return }
        undoToast = correction.id
        offeredUndo = correction.id
        registerShakeUndo(correction)
    }

    /// The Undo toast and its upkeep, with what the card reads for it (out of `body`: the type checker gave up on one
    /// modifier chain; values rather than the card itself, so the card's own body reads its state).
    private var undoOffer: UndoOffer {
        let correction = services.identifier.lastCorrection
        let shown = undoToast.flatMap { toast in correction.flatMap { $0.id == toast ? $0.kind : nil } }
        return UndoOffer(toast: undoToast, shownKind: shown, correctionID: correction?.id,
                         correctionHere: correction?.recordingID == recording.id,
                         passRunning: services.identifier.vocabularyRunning.contains(recording.id),
                         alert: vocabularyOffer != nil, undo: undoCorrection, timedOut: { undoToast = nil },
                         withdraw: withdrawUndo, passChanged: vocabularyPassChanged)
    }

    private func registerShakeUndo(_ correction: SpeakerIdentifier.UndoableCorrection) {
        let identifier = services.identifier
        let recording = recording
        undoManager?.removeAllActions(withTarget: identifier)
        undoManager?.registerUndo(withTarget: identifier) { identifier in
            MainActor.assumeIsolated { identifier.undoLastCorrection(of: recording) }
        }
        undoManager?.setActionName(Self.undoTitle(correction.kind))
    }

    /// While the transcript's vocabulary pass runs, Undo waits (SpeakerIdentifier.undoLastCorrection refuses): the
    /// shake action goes, since UndoManager drops an action once it has run, refused or not (a shake meanwhile used the
    /// Undo up), and comes back when the pass is over and the correction is still the one on offer (it ends it if the
    /// pass wrote words).
    private func vocabularyPassChanged(_ running: Bool) {
        if running {
            undoManager?.removeAllActions(withTarget: services.identifier)
        } else if let correction = services.identifier.lastCorrection, correction.id == offeredUndo,
                  correction.recordingID == recording.id {
            registerShakeUndo(correction)
        }
    }

    private func undoCorrection() {
        withdrawUndo()
        services.identifier.undoLastCorrection(of: recording)
    }

    /// The toast and the shake action go (the correction itself stays until something replaces it).
    fileprivate func withdrawUndo() {
        undoToast = nil
        offeredUndo = nil
        undoManager?.removeAllActions(withTarget: services.identifier)
    }

    /// What the toast says was done, and the shake alert's "Undo …".
    fileprivate static func undoTitle(_ kind: SpeakerIdentifier.UndoableCorrection.Kind) -> String {
        switch kind {
        case .assign: String(localized: "Speaker Changed")
        case .merge: String(localized: "Speakers Merged")
        case .edit: String(localized: "Transcript Edited")
        }
    }

    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The name rows' correction menus, once the speakers are final and nothing runs on the transcript.
    private var speakerCorrection: ((TranscriptView.SpeakerEdit) -> Void)? {
        guard !isEditingText, services.identifier.canCorrectSpeakers(of: recording) else { return nil }
        return { correctSpeaker($0) }
    }

    /// A name row's correction: a turn to another speaker at once; a merge asks first (it can't be undone, and the
    /// merged speaker's name goes).
    private func correctSpeaker(_ edit: TranscriptView.SpeakerEdit) {
        switch edit {
        case .assign(let id, let speaker):
            services.identifier.assign(recording.turnSegments(startingAt: id), to: speaker, in: recording)
            offerUndo()
        case .merge(let from, let into):
            withdrawUndo()                                  // under the question, an Undo would renumber the two
            pendingMerge = SpeakerMerge(from: from, into: into)
        }
    }

    private struct SpeakerMerge: Equatable {
        var from: Int
        var into: Int
    }

    // MARK: Search hits

    private func findHits() {
        guard let search else { hits = []; return }
        let current = hits.indices.contains(hitIndex) ? hits[hitIndex] : search.firstHit
        hits = search.hits(in: recording.segments)
        hitIndex = current.flatMap { hits.firstIndex(of: $0) } ?? 0
    }

    /// Starts at the result's snippet paragraph (or the first hit). The short wait lets the lazy transcript lay out
    /// before scrolling to a paragraph far down.
    private func showFirstHit() async {
        hits = []
        findHits()
        guard hits.indices.contains(hitIndex) else { return }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        reveal(hits[hitIndex])
        #if DEBUG
        let steps = UserDefaults.standard.integer(forKey: "stepHits")   // QA hook: `-stepHits 5` taps Next 5 times
        if steps > 0 {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            for _ in 0..<steps { step(1) }
        }
        #endif
    }

    /// Next/previous paragraph with a hit, wrapping around.
    private func step(_ delta: Int) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + delta + hits.count) % hits.count
        hitGeometry.userScrolled = .now                     // Listen's following waits: the user went there
        withAnimation { reveal(hits[hitIndex]) }
    }

    /// The bookmarked sentences' ranges by paragraph. Also when the paragraph's text no longer matches (the vocabulary
    /// pass or Edit Text changed a word): the highlight stays where it was, clamped to the text
    /// (Bookmarks.merged), until the places are found again a moment later (`bookmarkPlaces`); dropping it
    /// made it blink at each change.
    static func bookmarkRanges(_ places: [Bookmarks.Place], in segments: [TranscriptSegment]) -> [UUID: [Range<Int>]] {
        guard !places.isEmpty else { return [:] }
        let ids = Set(segments.map(\.id))
        var result: [UUID: [Range<Int>]] = [:]
        for place in places {
            guard let range = place.range, ids.contains(place.segmentID) else { continue }
            result[place.segmentID, default: []].append(range)
        }
        return result
    }

    /// A bookmark in the Bookmarks row: its paragraph scrolled so the sentence is on screen (a long paragraph is
    /// scrolled as far into it as the sentence starts). Listen's following waits, as for any scroll by the user.
    private func reveal(_ place: Bookmarks.Place) {
        hitGeometry.userScrolled = .now
        withAnimation(.snappy) {
            scroller?.scrollTo(place.segmentID, anchor: UnitPoint(x: 0.5, y: min(max(place.position, 0.1), 0.9)))
        }
    }

    /// Like Safari's Find on Page: scrolls a hit to the centre only when it isn't wholly visible between the top
    /// margin and the bottom toolbar. A hit already on screen (at the start, often the first turns) leaves the card
    /// where it is: centring it pulled the title up under the back button.
    private func reveal(_ hit: UUID) {
        if let frame = hitGeometry.frames[hit], hitGeometry.visible.contains(frame) { return }
        scroller?.scrollTo(hit, anchor: .center)
    }

    /// What tapping a name says while speakers are not final: preliminary (live) speaker numbers are not the offline
    /// ones, so a name given now could land on a different person when the offline pass replaces the segments.
    private var preliminaryNotice: String {
        recording.speakerStatus == .failed ? String(localized: "Speakers couldn't be identified — try again above, then name them")
                                           : String(localized: "Speakers are still being identified — you can name them in a moment")
    }

    #if DEBUG
    /// QA hook: `-renameFirstSpeaker` opens the rename sheet for the first speaker once speakers are final.
    private func renameFirstSpeakerForQA() async {
        guard ProcessInfo.processInfo.arguments.contains("-renameFirstSpeaker") else { return }
        for _ in 0..<100 where recording.speakerStatus != .done {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard recording.speakerStatus == .done, let speaker = recording.segments.lazy.compactMap(\.speakerIndex).first
        else { return }
        renaming = SpeakerRenameTarget(speaker: speaker)
    }
    #endif

    /// The flashes for a paragraph: the recently replaced words (SpeakerIdentifier.recentChanges) that fall into it,
    /// as ranges of its text. The paragraph's text is its words joined by spaces (TranscriptAligner.fold); when that
    /// doesn't hold (older data), nothing flashes.
    private var flashes: ((TranscriptSegment) -> [ChangeFlash])? {
        guard let changes = services.identifier.recentChanges[recording.id], !changes.isEmpty else { return nil }
        let words = recording.words
        return { segment in
            // Words are in time order: from the first that starts at the paragraph (binary search), while inside it.
            // Called per paragraph on screen only (the transcript is a LazyVStack).
            var low = 0, high = words.count
            while low < high {
                let mid = (low + high) / 2
                if words[mid].start < segment.start - 0.001 { low = mid + 1 } else { high = mid }
            }
            let inside = words[low...].prefix { $0.end <= segment.end + 0.001 }
            guard inside.map(\.text).joined(separator: " ") == segment.text else { return [] }
            var result: [ChangeFlash] = []
            var index = segment.text.startIndex
            for word in inside {
                let end = segment.text.index(index, offsetBy: word.text.count)
                if let change = changes.first(where: { word.start < $0.end + 0.001 && word.end > $0.start - 0.001 }) {
                    if let last = result.last, last.range.upperBound == index || segment.text[last.range.upperBound..<index] == " ",
                       last.vocabulary == change.vocabulary {
                        result[result.count - 1].range = last.range.lowerBound..<end
                    } else {
                        result.append(ChangeFlash(range: index..<end, vocabulary: change.vocabulary, at: change.at))
                    }
                }
                guard end < segment.text.endIndex else { break }
                index = segment.text.index(after: end)              // the space
            }
            return result
        }
    }

    private var titleText: Binding<String> {
        Binding(get: { recording.name }, set: { name in
            guard name != recording.name else { return }
            recording.name = name
            recording.nameIsUserSet = true
        })
    }

    private func normalizeTitle() {
        let trimmed = recording.name.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.name = trimmed.isEmpty ? String(localized: "Untitled Transcript") : trimmed
    }
}

/// Where the hit paragraphs are (in the content's coordinates) and what the scroll view shows of it, read when a hit is
/// revealed. Not view state: it changes with every layout and scroll, and nothing is drawn from it.
private final class PlaybackMapBox {
    var map = PlaybackMap()
}

private final class HitGeometry {
    var frames: [UUID: CGRect] = [:]
    var visible = CGRect.null
    /// When the user last moved the transcript (or went somewhere: a match, Add Tag): following the spoken word waits.
    var userScrolled: ContinuousClock.Instant?
    /// The user's finger is on the transcript, or it is still gliding from it.
    var userScrolling = false

    var userScrolledRecently: Bool {
        userScrolling || userScrolled.map { ContinuousClock.now - $0 < .seconds(3) } ?? false
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        RecordingDetailView(recording: PreviewData.sample(), onClose: {})
    }
    .modelContainer(PreviewData.container)
    .environment(AppServices(container: PreviewData.container))
}
#endif

/// "Speakers Merged · Undo": a glass capsule with what was done and an Undo button (also for a removed action item in
/// the Action Items sheet: ActionItemUndoToast).
struct UndoToast: View {
    let title: String
    let undo: () -> Void
    /// Not while the transcript's vocabulary pass runs (SpeakerIdentifier.undoLastCorrection waits for it).
    var isEnabled = true
    var identifier = "UndoCorrection"

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .disabled(!isEnabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// Which paragraph and which of its tokens (as WordText splits a paragraph: at spaces) each word of the transcript is,
/// both ways: the playing word's place for the highlight, a tapped word's start time to play from.
nonisolated struct PlaybackMap: Sendable {
    struct Place: Equatable, Sendable {
        var segment: UUID
        /// The word's tokens in its paragraph: more than one when its text has a space in it (a term of Your Words).
        var tokens: Range<Int>
        /// How far into the paragraph the word is (its first token of all its tokens), as an estimate of its line.
        var fraction: Double
    }

    /// The words the map was built from (the player loads the same).
    private(set) var words: [TranscriptWord] = []
    private var placeOfWord: [Place?] = []
    private var wordsOfSegment: [UUID: [Int]] = [:]        // token index → word index

    init() {}

    @concurrent
    static func build(words: [TranscriptWord], segments: [TranscriptSegment]) async -> PlaybackMap {
        PlaybackMap(words: words, segments: segments)
    }

    init(words: [TranscriptWord], segments: [TranscriptSegment]) {
        self.words = words
        placeOfWord = Array(repeating: nil, count: words.count)
        let ranges = Recording.wordRanges(words: words, segments: segments)
        for segment in segments {
            guard let range = ranges[segment.id] else { continue }
            var tokens: [Int] = []
            for index in range {
                // A word whose text has a space in it is more than one token: each of them plays the word.
                let pieces = max(1, words[index].text.split(separator: " ").count)
                placeOfWord[index] = Place(segment: segment.id, tokens: tokens.count..<tokens.count + pieces, fraction: 0)
                tokens += Array(repeating: index, count: pieces)
            }
            for index in range {
                if let first = placeOfWord[index]?.tokens.lowerBound {
                    placeOfWord[index]?.fraction = Double(first) / Double(max(1, tokens.count))
                }
            }
            wordsOfSegment[segment.id] = tokens
        }
    }

    func place(of word: Int) -> Place? {
        placeOfWord.indices.contains(word) ? placeOfWord[word] : nil
    }

    /// The word a tapped token is: its index and start time (the words' own time).
    func word(at token: Int, in segment: UUID) -> (index: Int, start: TimeInterval)? {
        guard let tokens = wordsOfSegment[segment], tokens.indices.contains(token) else { return nil }
        return (tokens[token], words[tokens[token]].start)
    }
}

/// The card's playback upkeep, out of its `body` (one modifier chain was too long for the type checker): whether the
/// recording's audio is there, the word map while listening, the spoken word kept on screen, and a pause when editing
/// starts.
private struct PlaybackFollowing: ViewModifier {
    let card: RecordingDetailView
    let segments: [TranscriptSegment]

    func body(content: Content) -> some View {
        content
            .task(id: card.recording.id) { await card.checkAudio() }
            // Built when Listen starts, not when the card opens: off, nothing of it is needed.
            .task(id: card.listening && card.hasAudio ? segments : nil) {
                if card.listening, card.hasAudio { await card.refreshPlaybackMap(segments) }
            }
            .task(id: card.listening && !card.isEditingText) { await card.showWords() }
            .onChange(of: card.playingPlace) { _, place in card.follow(place) }
            .onScrollPhaseChange { _, phase in card.scrollPhaseChanged(phase) }
            .onChange(of: card.isEditingText) { _, editing in card.editingChanged(editing) }
    }
}

/// The last correction's Undo, above the bottom toolbar for a few seconds (like Mail's Undo after a delete): the toast,
/// its 6 s (counted once "Add to Your Words?" after an edit is answered, behind which it can't be tapped, and once the
/// vocabulary pass is over, meanwhile it is greyed: Undo waits for it), and the Undo going when the correction does
/// (the transcript changed in another way, or another correction replaced it). Here rather than in the card's modifier
/// chain, which the type checker gave up on.
private struct UndoOffer: ViewModifier {
    let toast: UUID?
    let shownKind: SpeakerIdentifier.UndoableCorrection.Kind?
    let correctionID: UUID?
    let correctionHere: Bool
    let passRunning: Bool
    let alert: Bool
    let undo: () -> Void
    let timedOut: () -> Void
    let withdraw: () -> Void
    let passChanged: (Bool) -> Void

    #if DEBUG
    @Environment(\.undoManager) private var undoManager
    #endif

    func body(content: Content) -> some View {
        content
            #if DEBUG
            .overlay(alignment: .center) {
                // UI tests (`-debugUndoButton`, a button over the middle of the card): undoes as a shake does, with the window's UndoManager. XCUITest can't
                // shake, and ⌘Z presses got lost on the iOS 27 simulator (logged: the UndoManager never saw them).
                if ProcessInfo.processInfo.arguments.contains("-debugUndoButton") {
                    Button("Debug Undo") { undoManager?.undo() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("DebugUndo")
                }
            }
            #endif
            .overlay(alignment: .bottom) {
                if let shownKind {
                    UndoToast(title: RecordingDetailView.undoTitle(shownKind), undo: undo, isEnabled: !passRunning)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: toast)
            .task(id: UndoTimer(toast: toast, alert: alert, waits: passRunning)) {
                guard toast != nil, !alert, !passRunning else { return }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                timedOut()
            }
            .onChange(of: correctionID) { _, id in
                if id == nil || !correctionHere { withdraw() }
            }
            .onChange(of: passRunning) { _, running in passChanged(running) }
    }
}

private struct UndoTimer: Equatable {
    var toast: UUID?
    var alert: Bool
    var waits: Bool
}

/// What the bookmarks' sentences are found from: the paragraphs, and whether the text is final.
private struct BookmarkSource: Equatable {
    let segments: [TranscriptSegment]
    let isFinal: Bool
}
