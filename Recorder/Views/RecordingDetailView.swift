import SwiftUI
import SwiftData

/// One saved recording, the transcript card's content (`TranscriptCard`; Music's "Now Playing" for a transcript): the
/// back button at the top left, inline-editable title, date and duration, the automatic summary, tags, speaker-identification
/// status and the transcript grouped by speaker; its actions in the system's bottom toolbar (Liquid Glass): Share,
/// Add Tag, Speakers and Delete. No top bar. Tapping a speaker's name row (or "Rename Speaker…" in its long-press menu) opens
/// the rename sheet for that speaker, once speakers are final.
/// Opened from a search result (`search`), the transcript highlights the hits, starts at the result's paragraph and
/// steps through the paragraphs with hits from the bottom toolbar ("2 of 5"), between a More menu (Share, Add Tag and
/// Speakers) and Delete.
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

    @State private var confirmDelete = false
    @State private var pendingSpeakerCount: Int??    // a count waiting for "names will be reset" confirmation
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
                TranscriptView(segments: segments, speakerName: recording.speakerName(_:),
                               preliminary: recording.speakerStatus != .done, preliminaryNotice: preliminaryNotice,
                               renameSpeaker: { renaming = SpeakerRenameTarget(speaker: $0) },
                               search: search, currentHit: hits.indices.contains(hitIndex) ? hits[hitIndex] : nil,
                               hitFrame: search == nil ? nil : { id, frame in hitGeometry.frames[id] = frame },
                               flashes: flashes,
                               showsNameTip: search == nil && recording.speakerNames.isEmpty)
                    .opacity(bodyShown ? 1 : 0)
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
        .onChange(of: segments) { findHits() }             // the vocabulary pass or a new speaker count rewrote them
        .onChange(of: statusText != nil, initial: true) { _, shown in if shown { keepsStatusRow = true } }
        .onChange(of: recording.speakerStatusRaw) {        // "Speakers: n" re-runs identification: numbers change
            if recording.speakerStatus != .done { renaming = nil }
        }
        .sheet(item: $renaming) { target in
            SpeakerNameSheet(recording: recording, speaker: target.speaker)
        }
        #if DEBUG
        .task { await renameFirstSpeakerForQA() }
        #endif
        // Like Photos, Mail and Notes: the transcript's actions in the system's bottom toolbar (Liquid Glass), within
        // thumb reach, where the recording had its large Stop.
        .toolbar { bottomBar }
        .toolbar(turning ? .hidden : .visible, for: .bottomBar)
        .task(id: holdsBody) {
            // Started when it is let go rather than with a `.delay`: with a delay the value is already set, and a part
            // re-made in the meantime (the speaker status row, as identification starts) appeared at once. A task, so
            // a transcript inserted after the live text was gone still fades in rather than appearing with its view.
            guard !holdsBody, !bodyShown else { return }
            withAnimation(.easeOut(duration: 0.25)) { bodyShown = true }
        }
        .confirmationDialog("Identify speakers again?", isPresented: Binding(
            get: { pendingSpeakerCount != nil }, set: { if !$0 { pendingSpeakerCount = nil } }
        ), titleVisibility: .visible) {
            Button("Identify Again") {
                if let count = pendingSpeakerCount { services.identifier.setSpeakerCount(count, for: recording) }
            }
        } message: {
            Text("The speaker names you entered will be reset.")
        }
        .onDisappear {
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

    /// Share, Add Tag and Speakers on the left (one glass group), Delete on the right; opened from a search, the hits'
    /// "n of m" with previous/next between them (like Safari's Find on Page).
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if combinesActions {
            // With the hit navigator the bar would have seven items, which fit no iPhone: iOS moved Next Match (and
            // Previous Match) into an overflow menu on the iPhone 17, the iPhone Air and the iPhone 18 Pro Max alike
            // (iOS 27 simulators). Share, Add Tag and Speakers share one menu instead, so the navigator and Delete stay
            // visible. (Before Add Tag, six items fit from 402 pt on.)
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    shareButton
                    addTagButton
                    speakersPicker.pickerStyle(.menu)       // a submenu here
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        } else {
            ToolbarItem(placement: .bottomBar) { shareButton }
            ToolbarItem(placement: .bottomBar) { addTagButton }
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    speakersPicker
                } label: {
                    Label("Speakers", systemImage: "person.2")
                }
            }
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
            Section {
                Toggle("Speaker Names", isOn: $exportNames)
                Toggle("Timestamps", isOn: $exportTimestamps)
            }
        } label: {
            Label("Share Transcript", systemImage: "square.and.arrow.up")
        }
    }

    private func share(_ format: TranscriptExport.Format) {
        let snapshot = recording.exportSnapshot(names: exportNames, timestamps: exportTimestamps,
                                                withWords: format.isSubtitles)
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
            titleFocused = false
            editingTags = true
            tagFocusRequest += 1
            Task {
                await Task.yield()                          // the line exists from the next layout on
                withAnimation(.snappy) { scroller?.scrollTo(TagEditor.scrollID, anchor: .center) }
            }
        }
    }

    private var speakersPicker: some View {
        Picker(selection: speakerCountChoice) {
            Text("Automatic").tag(Int?.none)
            ForEach(2...6, id: \.self) { Text("\($0) Speakers").tag(Int?.some($0)) }
        } label: {
            Label("Speakers", systemImage: "person.2")
        }
        .disabled(services.identifier.inFlight.contains(recording.id))
    }

    /// With the hit navigator (opened from a search result), on every iPhone.
    private var combinesActions: Bool { !hits.isEmpty }

    private var hasSummary: Bool { recording.summary?.isEmpty == false }

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
        withAnimation { reveal(hits[hitIndex]) }
    }

    /// Like Safari's Find on Page: scrolls a hit to the centre only when it isn't wholly visible between the top
    /// margin and the bottom toolbar. A hit already on screen (at the start, often the first turns) leaves the card
    /// where it is: centring it pulled the title up under the back button.
    private func reveal(_ hit: UUID) {
        if let frame = hitGeometry.frames[hit], hitGeometry.visible.contains(frame) { return }
        scroller?.scrollTo(hit, anchor: .center)
    }

    /// The "Speakers" picker: automatic or an exact count. Choosing re-runs speaker identification; with names given,
    /// it asks first, because the speaker numbers change.
    private var speakerCountChoice: Binding<Int?> {
        Binding(
            get: { recording.speakerCountOverride },
            set: { count in
                guard count != recording.speakerCountOverride else { return }
                if recording.speakerNames.isEmpty {
                    services.identifier.setSpeakerCount(count, for: recording)
                } else {
                    pendingSpeakerCount = .some(count)
                }
            }
        )
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
private final class HitGeometry {
    var frames: [UUID: CGRect] = [:]
    var visible = CGRect.null
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
