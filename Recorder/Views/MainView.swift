import CoreSpotlight
import SwiftUI
import SwiftData
import UIKit

/// The app's tabs, Apple Music's layout with Liquid Glass (iOS 26): Settings, Transcripts and Search (at the right end, where
/// it stays when the bar minimizes) in the tab bar, and
/// the record control as the tab bar's bottom accessory, where Music has its mini player. Scrolling down minimizes the
/// bar to three items like Music's: the current tab, the accessory and Search on its own. On iOS 27 a
/// `Tab(role: .search)` sits in the expanded bar like any tab and becomes the circle when it minimizes, so its role is
/// constant there. iOS 26 drew it apart as its own circle in both states, so there Search is an ordinary tab while the
/// bar is expanded and takes the search role only while it is minimized (`isBarMinimized`, from the accessory's
/// placement). On iOS 27 that switch replaced the Search tab (UITab ↔ UISearchTab, a new object each time) in the
/// middle of the bar's own morph, and the magnifier sometimes dropped into its place from above as the bar unfolded.
enum AppTab: Hashable {
    case transcripts, settings, search
}

/// The text and tokens of the search, shared by the tabs: a tag chip in the Transcripts list or a pull on it opens the
/// Search tab with them.
@MainActor @Observable
final class SearchState {
    var query = ""
    /// What is searched: `query` after a typing pause (the Search list's debounce), or at once when the app sets it
    /// (a person page's topic set only `query`, and the list showed the person's results with the old text first).
    var appliedQuery = ""
    var tokens: [SearchToken] = []
    /// Bumped on every tap on Search (also when it is the current tab already): the field takes the focus again.
    var focusRequest = 0

    func add(_ token: SearchToken) {
        if !tokens.contains(where: { $0.id == token.id }) { tokens.append(token) }
    }
}

/// Root: the tabs, the record accessory and the transcript card. Owns the recording: a session is started here, not by
/// the recording view. A transcript is always shown in one full-screen card (`TranscriptCard`), like Apple Music's
/// "Now Playing": the accessory opens it out of itself with a zoom transition (`matchedTransitionSource` /
/// `.navigationTransition(.zoom)`) and records into it (live transcript, large Stop); when Stop has saved the
/// transcript, the same card turns into it in place. A row in the Transcripts or Search list, or in Settings › People
/// › person, opens the same card out of that row (`openTranscript` in the environment). Swiped down, or its grabber
/// tapped, the card shrinks back to where it came from; a recording goes on in the accessory (time, level, Stop).
struct MainView: View {
    @Environment(AppServices.self) var services
    @Environment(\.modelContext) var modelContext
    @State var tab: AppTab = .transcripts
    @State var searchState = SearchState()
    /// The tabs' navigation stacks (person pages; Settings' pages), so "Go to Person" can push onto the tab under the card.
    @State var navigation = AppNavigation()
    @State private var tabBeforeSearch: AppTab = .transcripts
    /// A topic or tag tapped on a person's page in the Search tab itself: that page and the search under it, which the
    /// fresh search replaced (its results show only with the page popped) and Close brings back, the latest first.
    /// Cleared when Search is left or started anew; empty, Close goes back to `tabBeforeSearch`.
    @State private var searchReturns: [SearchReturn] = []
    /// The accessory is inline (the bar minimized): Search shows as its own circle (`Tab(role: .search)`). It starts
    /// `true` and the accessory sets it right on its first appearance (before the first frame): the Search circle
    /// then exists from launch. Created only at the first collapse, the circle came late to the minimized bar's
    /// layout, and the accessory was first laid out as wide as without it, running under the circle for ~0.3 s
    /// before it snapped to its width (iPhone 17 simulator, iOS 27, frame by frame); every later collapse was fine.
    @State private var isBarMinimized = true

    /// See the type's comment: constant on iOS 27, following the bar on iOS 26.
    private var searchRole: TabRole? {
        if #available(iOS 27, *) { return .search }
        return isBarMinimized ? .search : nil
    }
    /// The card: `open` while it is up; `closing` from the moment it is told to close until the cover's onDismiss,
    /// while it is still shrinking away. Its content stays until then (cleared in the same update that closed it, the
    /// card went blank and lost its zoom back), and a request to open it meanwhile waits in `pendingCard` (writing the
    /// content then turned the shrinking card into the new one and zoomed it to the wrong place, and onDismiss wiped
    /// the content the new presentation needed: a blank card, or none at all while the cover stayed presented).
    private enum CardPhase { case closed, open, closing }
    @State private var cardPhase = CardPhase.closed
    @State private var pendingCard: CardRequest?
    /// "Go to Person" while the card was up: the person's page, pushed once the card has shrunk back into its row
    /// (cardDismissed; pushed earlier, the push took the card's zoom target away).
    @State private var pendingPerson: UUID?
    @State var card = TranscriptCardContent()
    @Namespace private var cardZoom
    /// The onboarding sheet's pages while it is up (see offerOnboarding); empty otherwise.
    @State private var onboardingPages: [OnboardingPage] = []
    /// Import: the file picker is up; a file is being converted; what went wrong.
    @State private var showsImporter = false
    @State private var isImporting = false
    /// Files to import after the one being converted (shared one after another, or several at once).
    @State private var importQueue: [URL] = []
    @State private var importError: String?

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
            Tab("Transcripts", systemImage: "waveform", value: AppTab.transcripts) {
                RecordingsListView(isSearch: false, searchState: searchState)
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: searchRole) {
                RecordingsListView(isSearch: true, searchState: searchState)
            }
        }
        // Through the environment, not as closure properties: with closures the lists compared unequal on every
        // MainView update (a tab, the card, the bar minimizing) and both re-ran their bodies (~50 ms each on the
        // simulator: the @Query and every row); with plain properties SwiftUI skips them.
        .environment(\.searchActions, SearchActions(open: openSearch, close: closeSearch, search: freshSearch))
        .environment(navigation)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            RecordAccessory(session: card.session, start: startRecording, open: openRecorder,
                            importAudio: { showsImporter = true }, isImporting: isImporting,
                            isInline: $isBarMinimized)
                .cardSource(TranscriptCardContent.recorderSource)
        }
        // Full screen like Now Playing: the tab bar and the accessory are covered while the card is up.
        .fullScreenCover(isPresented: Binding(get: { cardPhase == .open }, set: { shows in
            if shows { cardPhase = .open } else { closeCard() }
        }), onDismiss: cardDismissed) {
            TranscriptCard(content: card, onClose: closeCard, onRetry: retryRecording, namespace: cardZoom)
        }
        .sheet(isPresented: Binding(get: { !onboardingPages.isEmpty }, set: { if !$0 { onboardingPages = [] } })) {
            Onboarding(pages: onboardingPages)
        }
        .task { await offerOnboarding() }
        // Start and stop from outside the app: the Control Center control, the Action Button, Siri, Shortcuts
        // (RecordingIntents) and the lock screen widget's link. A start asked for while the app was launching waits
        // in RecordingControl until here.
        .task {
            RecordingControl.shared.start = { startRecording() }
            RecordingControl.shared.stop = { await card.session?.stop() }
            if RecordingControl.shared.takePendingStart() { startRecording() }
        }
        .onOpenURL { url in
            if url.scheme == FederURL.scheme, url.host() == "record" { startRecording() }
            if url.isFileURL { importAudio(from: url) }          // "Feder" in another app's share sheet
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { importAudio(from: url) }
        }
        .alert("Can't Import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        // A transcript tapped in Spotlight (SpotlightIndex): its card, out of its row in the Transcripts list.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = SpotlightIndex.recordingID(from: activity) else { return }
            openFromOutside(id)
        }
        .environment(\.cardZoom, cardZoom)
        .environment(\.openTranscript, OpenTranscriptAction { recording, search, sourceID in
            openCard(recording, search: search, sourceID: sourceID)
        })
        .environment(\.openPerson, OpenPersonAction { openPerson($0) })
        .onChange(of: tab) { old, new in
            if new == .search, old != .search { tabBeforeSearch = old }
            if old == .search, new != .search {
                endEditing()                                     // the keyboard goes with the Search tab
                searchReturns = []
            }
        }
        .onChange(of: card.session?.state) { _, state in
            guard let state else { return }
            services.appLock.recordingChanged(state)        // a start while locked: Face ID once it records
            switch state {
            case .finished(let recording): finished(recording)
            case .discarded: finished(nil)
            default: break
            }
        }
        // App Lock's window shows the recording's time, level and Stop while Feder is locked (AppLockView).
        .onChange(of: card.session?.id, initial: true) { services.appLock.session = card.session }
        #if DEBUG
        .task { await applyLaunchArguments() }
        #endif
    }

    /// The tab selection; a tap on Search, also on the current one, asks the search field for the focus (keyboard up).
    private var tabSelection: Binding<AppTab> {
        Binding(get: { tab }, set: { new in
            InteractionTrace.begin("tab"); InteractionTrace.shown("tab")   // the tabs are alive: the next commit shows it
            if new == .search {
                // Tapped again: back to its results from a person page. The field only takes the focus where it is
                // on screen, not under a person page kept from before.
                if tab == .search {
                    navigation.search = []
                    searchReturns = []
                }
                if navigation.search.isEmpty { searchState.focusRequest += 1 }
            }
            tab = new
        })
    }

    /// The onboarding sheet with the pages still due: Welcome on a new install (it also allows the speaker models'
    /// downloads; existing users are migrated past it, AppServices), Before You Record once for everyone, and Optional
    /// Improvements once while Parakeet or Gemma (8 GB iPhones) can still be added. Nothing when none is due. A
    /// second after launch, so the sheet rises over the list instead of with the first frame, and not over a recording
    /// or transcript opened meanwhile (`-autoRecord`, a tap).
    private func offerOnboarding() async {
        let defaults = UserDefaults.standard
        var pages: [OnboardingPage] = []
        if !AppServices.modelDownloadsAllowed { pages.append(.welcome) }
        if !defaults.bool(forKey: Onboarding.recordingNoticeKey) { pages.append(.beforeYouRecord) }
        if !defaults.bool(forKey: Onboarding.voiceProfilesShownKey) { pages.append(.voiceProfiles) }
        if !defaults.bool(forKey: Onboarding.spotlightShownKey) { pages.append(.spotlight) }
        if services.offersParakeet || services.offersGemma, !defaults.bool(forKey: Onboarding.improvementsShownKey) {
            pages.append(.improvements)
        }
        guard !pages.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1))
        guard cardPhase == .closed, card.session == nil else { return }
        onboardingPages = pages
    }

    /// Puts the keyboard away. The Search tab's field stayed first responder over the next tab: its view is kept alive
    /// by the TabView, so dropping its focus state on disappear did not reach UIKit.
    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Card

    /// What the card is asked to show: a transcript out of `sourceID`, or (no transcript) the recording out of the
    /// accessory.
    private struct CardRequest {
        var transcript: Recording?
        var search: TranscriptSearchContext?
        var sourceID: String
        /// A transcript just saved, or opened from outside: the Transcripts list goes behind the card (when it opens),
        /// where it tops the list when it closes.
        var showsList = false
        /// Presented on the next turn of the main actor (see openRecorder).
        var deferred = false
    }

    /// A transcript from a list: the card zooms out of its row.
    func openCard(_ recording: Recording, search: TranscriptSearchContext?, sourceID: String) {
        InteractionTrace.begin("open")
        endEditing()
        present(CardRequest(transcript: recording, search: search, sourceID: sourceID))
    }

    /// A transcript asked for from outside the app (Spotlight): the Transcripts list goes behind the card, and the card
    /// opens out of its row. A recording going on stays in the accessory. A card that is up shrinks back into its own
    /// row first: the list is shown (a person page there popped) only when the new card opens (`showsList`), as Go to
    /// Person waits, since switching under the shrinking card took its zoom target away.
    func openFromOutside(_ id: UUID) {
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let recording = try? modelContext.fetch(descriptor).first else { return }
        if cardPhase == .open { closeCard() }
        InteractionTrace.begin("open")
        endEditing()
        present(CardRequest(transcript: recording,
                            sourceID: OpenTranscriptAction.rowSource(RecordingsListView.transcriptsList, recording),
                            showsList: true))
    }

    /// Opens the card on `request`, or, while the last card is still shrinking away, once it is gone (cardDismissed).
    private func present(_ request: CardRequest) {
        guard cardPhase != .closing else { pendingCard = request; return }
        guard request.transcript != nil || card.session != nil else { return }   // the recording ended meanwhile
        card.transcript = request.transcript
        card.search = request.search
        card.sourceID = request.sourceID
        card.turnedFromRecording = false
        if request.showsList { showList() }
        if request.deferred {
            Task { if cardPhase == .closing { pendingCard = request } else { cardPhase = .open } }
        } else {
            cardPhase = .open
        }
    }

    /// The back button, a swipe to the right, Delete, a failure screen's Close: the card shrinks away (until
    /// cardDismissed).
    func closeCard() {
        guard cardPhase == .open else { return }
        cardPhase = .closing
    }

    /// The cover's onDismiss, once the card has shrunk away: only now does its content go. A recording that is still
    /// going on stays in the accessory; one that ended (saved, discarded or failed) is dropped. Then a request that
    /// came while it was shrinking opens the card again.
    private func cardDismissed() {
        cardPhase = .closed
        card.transcript = nil
        card.search = nil
        card.sourceID = TranscriptCardContent.recorderSource
        card.turnedFromRecording = false
        if let session = card.session, !session.isOngoing { card.session = nil }
        if let person = pendingPerson {
            pendingPerson = nil
            pushPerson(person)
        }
        if let request = pendingCard {
            pendingCard = nil
            present(request)
        } else if card.session == nil, onboardingPages.isEmpty {
            // The onboarding skipped at launch because a recording or transcript was up comes now (a new user who
            // recorded in the first second would otherwise never see Welcome or Before You Record).
            Task { await offerOnboarding() }
        }
    }

    // MARK: People

    /// "Go to Person" in a card's name row, like Apple Music's Go to Artist: the card shrinks back into its row, then
    /// the person's page is pushed onto the tab under it. Opened from that person's own page (its rows' source ids
    /// name the person), closing the card is the way back to it.
    func openPerson(_ id: UUID) {
        switch cardPhase {
        case .closed: pushPerson(id)
        case .closing: pendingPerson = id
        case .open:
            if !(card.sourceID.hasPrefix("person.") && card.sourceID.contains(id.uuidString)) { pendingPerson = id }
            closeCard()
        }
    }

    private func pushPerson(_ id: UUID) {
        InteractionTrace.begin("person")
        navigation.push(PersonRoute(id: id), on: tab)
    }

    /// The Transcripts list itself, a person page pushed there popped: a transcript opened from outside zooms out of
    /// its row, and one just saved tops the list when the card closes.
    private func showList() {
        tab = .transcripts
        navigation.transcripts = []
    }

    // MARK: Recording

    /// Transcribe (the accessory): a fresh session, started here so it survives the card being swiped down. Started
    /// at once: the audio session and the engine come up on the audio hardware's actor (MicrophoneCapture), so the
    /// card's zoom runs on a free main thread (started on it, the card only came up after "Preparing…").
    func startRecording() {
        InteractionTrace.begin(card.session == nil ? "transcribe" : "reopen")
        guard card.session == nil else { openRecorder(); return }
        let session = services.makeRecordingSession()
        card.session = session
        openRecorder()
        Task { await session.start() }
    }

    /// The accessory opens the card on the recording, out of itself. Presented on the next turn of the main actor, so
    /// the accessory has laid out its new state (Transcribe → Preparing…) before the zoom takes it as its source.
    func openRecorder() {
        present(CardRequest(sourceID: TranscriptCardContent.recorderSource, deferred: true))
    }

    private func retryRecording() {
        card.session = nil
        startRecording()
    }

    /// Saved (with the new transcript) or discarded. Saved with the card up on the recording: the same card turns into
    /// the transcript in place. Saved while the card was minimized (Stop in the accessory) or still shrinking into
    /// the accessory: the card opens on it (once it is gone). Discarded: the card closes. Saved while the card shows
    /// another transcript: the new one waits in the list, and that card's tab (its zoom source) stays as it is.
    private func finished(_ recording: Recording?) {
        let showsRecording = cardPhase == .open && card.transcript == nil
        guard let recording else {
            if showsRecording { closeCard() } else if cardPhase != .closing { card.session = nil }   // else onDismiss
            return
        }
        card.session = nil                      // the accessory says Transcribe again
        if showsRecording {
            showList()                           // behind the card: the new transcript tops the list when it closes
            card.transcript = recording           // in place (TranscriptCard turns the recording into it)
            card.search = nil
            card.turnedFromRecording = true
        } else if cardPhase != .open {
            present(CardRequest(transcript: recording, sourceID: TranscriptCardContent.recorderSource, showsList: true, deferred: true))
        }
    }

    // MARK: Import

    /// A file from the picker or another app's share sheet: converted off the main actor (AudioImporter), saved as a
    /// transcript in the language it is spoken in (LanguageProbe; the one chosen for the next recording when that
    /// can't be told), queued for the steps after Stop, and opened in the
    /// card out of the accessory, where its status line says what is being done. Files that come while one is being
    /// converted wait their turn (dropped, a second file shared from Voice Memos was lost without a word, its Inbox copy
    /// left behind); the card opens on the last one. A card in Edit Text stays open: the imports wait in the list, as
    /// closing it would throw its drafts away.
    func importAudio(from url: URL) {
        importQueue.append(url)
        guard !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            var last: Recording?
            var failure: String?
            while !importQueue.isEmpty {
                let url = importQueue.removeFirst()
                do {
                    let converted = try await AudioImporter.convert(url)
                    AudioImporter.removeInboxCopy(url)
                    // The file's own language, not just the accessory's (LanguageProbe: a second or two, off the main
                    // actor, while the accessory says "Importing…").
                    let locale = await LanguageProbe.language(of: AudioFileStore.url(for: converted.fileName),
                                                              duration: converted.duration,
                                                              chosen: TranscriptionLanguage.current)
                    let recording = Recording(name: converted.name, audioFileName: converted.fileName,
                                              localeIdentifier: locale.identifier(.bcp47))
                    recording.createdAt = converted.created ?? .now
                    recording.duration = converted.duration
                    modelContext.insert(recording)
                    try? modelContext.save()
                    services.identifier.enqueue(recording)
                    last = recording
                } catch {
                    AudioImporter.removeInboxCopy(url)
                    failure = error.localizedDescription
                }
            }
            if let failure {
                importError = failure                         // the ones that worked are in the list
                return
            }
            guard let last else { return }
            // The card in Edit Text and the tab under it (a person page) stay as they are; otherwise the list is shown
            // when the new card opens (`showsList`), after the open one has shrunk back into its row.
            guard services.identifier.editingText.isEmpty else { return }
            if cardPhase == .open { closeCard() }
            present(CardRequest(transcript: last, sourceID: TranscriptCardContent.recorderSource, showsList: true,
                                deferred: true))
        }
    }

    // MARK: Search

    /// Pull-to-search and tag chips: the Search tab, with `token` added. A tag chip starts a search for that tag, so
    /// text typed in an earlier search is cleared.
    private func openSearch(_ token: SearchToken?) {
        if let token {
            searchState.query = ""
            searchState.appliedQuery = ""
            searchState.add(token)
        }
        searchReturns = []
        navigation.search = []                       // the results, not a person page left in the Search tab
        tab = .search
        searchState.focusRequest += 1
    }

    /// What Close brings back after a topic tapped on a person's page in the Search tab (`searchReturns`).
    private struct SearchReturn {
        var path: [PersonRoute]
        var query: String
        var appliedQuery: String
        var tokens: [SearchToken]
    }

    /// A person page's topic or tag: the Search tab with exactly these tokens and text (replacing what was searched
    /// before), applied at once (not after the typing pause: the person's results with the old text showed first).
    /// From a page in the Search tab itself, that page and its search are kept for Close.
    private func freshSearch(_ tokens: [SearchToken], _ text: String) {
        if tab == .search, !navigation.search.isEmpty {
            searchReturns.append(SearchReturn(path: navigation.search, query: searchState.query,
                                              appliedQuery: searchState.appliedQuery, tokens: searchState.tokens))
        } else {
            searchReturns = []
        }
        searchState.tokens = tokens
        searchState.query = text
        searchState.appliedQuery = text
        navigation.search = []
        tab = .search
        searchState.focusRequest += 1
    }

    /// The search bar's close button: back to the tab Search was opened from (text and tokens are kept), or to the
    /// person's page in the Search tab whose topic started this search, with the search it was over.
    private func closeSearch() {
        guard let back = searchReturns.popLast() else {
            tab = tabBeforeSearch == .search ? .transcripts : tabBeforeSearch
            return
        }
        endEditing()
        searchState.tokens = back.tokens
        searchState.query = back.query
        searchState.appliedQuery = back.appliedQuery
        // Pushed again, with the push's slide over the search it was on (that is where its Back leads). The slide
        // stayed under `withTransaction(\.disablesAnimations, true)` too (iOS 27 simulator, frame by frame).
        navigation.search = back.path
    }
}
