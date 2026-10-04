import SwiftUI
import SwiftData
import UIKit

/// The app's tabs, Apple Music's layout with Liquid Glass (iOS 26): Settings, Transcripts and Search (at the right end, where
/// it stays when the bar minimizes) in the tab bar, and
/// the record control as the tab bar's bottom accessory, where Music has its mini player. Scrolling down minimizes the
/// bar to three items like Music's: the current tab, the accessory and Search on its own. SwiftUI draws a
/// `Tab(role: .search)` apart as its own circle in both states, so Search is an ordinary tab while the bar is expanded
/// and takes the search role only while it is minimized (`isBarMinimized`, from the accessory's placement).
enum AppTab: Hashable {
    case transcripts, settings, search
}

/// The text and tokens of the search, shared by the tabs: a tag chip in the Transcripts list or a pull on it opens the
/// Search tab with them.
@MainActor @Observable
final class SearchState {
    var query = ""
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
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @State private var tab: AppTab = .transcripts
    @State private var searchState = SearchState()
    @State private var tabBeforeSearch: AppTab = .transcripts
    @State private var isBarMinimized = false            // the accessory is inline: Search shows as its own circle
    // The card. Its content stays until the cover's onDismiss: cleared in the same update that closed it, the card
    // went blank and lost its zoom back while it was still shrinking.
    @State private var showsCard = false
    /// From the moment the card is told to close until its onDismiss: it is still shrinking away. A request to open
    /// it meanwhile waits in `pendingCard` (writing the content then turned the shrinking card into the new one and
    /// zoomed it to the wrong place, and onDismiss wiped the content the new presentation needed: a blank card, or
    /// none at all while `showsCard` stayed true).
    @State private var isCardDismissing = false
    @State private var pendingCard: CardRequest?
    @State private var card = TranscriptCardContent()
    @Namespace private var cardZoom

    private static let recorderSource = TranscriptCardContent.recorderSource

    /// The recording, from Transcribe until it is saved or dropped (the accessory's and the card's).
    private var activeSession: RecordingSession? {
        get { card.session }
        nonmutating set { card.session = newValue }
    }
    /// The card's transcript; nil: the card shows the recording.
    private var cardTranscript: Recording? {
        get { card.transcript }
        nonmutating set { card.transcript = newValue }
    }
    private var cardSearch: TranscriptSearchContext? {
        get { card.search }
        nonmutating set { card.search = newValue }
    }
    private var cardSourceID: String {
        get { card.sourceID }
        nonmutating set { card.sourceID = newValue }
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
            Tab("Transcripts", systemImage: "waveform", value: AppTab.transcripts) {
                RecordingsListView(isSearch: false, searchState: searchState,
                                   openSearch: openSearch, closeSearch: closeSearch)
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: isBarMinimized ? .search : nil) {
                RecordingsListView(isSearch: true, searchState: searchState,
                                   openSearch: openSearch, closeSearch: closeSearch)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            RecordAccessory(session: activeSession, start: startRecording, open: openRecorder,
                            isInline: $isBarMinimized)
                .cardSource(Self.recorderSource)
        }
        // Full screen like Now Playing: the tab bar and the accessory are covered while the card is up.
        .fullScreenCover(isPresented: Binding(get: { showsCard }, set: { shows in   // false: also a swipe down
            if shows { showsCard = true } else { closeCard() }
        }), onDismiss: cardDismissed) {
            TranscriptCard(content: card, onClose: closeCard, onRetry: retryRecording, namespace: cardZoom)
        }
        .environment(\.cardZoom, cardZoom)
        .environment(\.openTranscript, OpenTranscriptAction { recording, search, sourceID in
            openCard(recording, search: search, sourceID: sourceID)
        })
        .onChange(of: tab) { old, new in
            if new == .search, old != .search { tabBeforeSearch = old }
            if old == .search, new != .search { endEditing() }   // the keyboard goes with the Search tab
        }
        .onChange(of: activeSession?.state) { _, state in
            guard let state else { return }
            switch state {
            case .finished(let recording): finished(recording)
            case .discarded: finished(nil)
            default: break
            }
        }
        #if DEBUG
        .task { await applyLaunchArguments() }
        #endif
    }

    /// The tab selection; a tap on Search, also on the current one, asks the search field for the focus (keyboard up).
    private var tabSelection: Binding<AppTab> {
        Binding(get: { tab }, set: { new in
            if new == .search { searchState.focusRequest += 1 }
            tab = new
        })
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
        /// A transcript just saved: the Transcripts tab goes behind the card, where it tops the list when it closes.
        var showsList = false
        /// Presented on the next turn of the main actor (see openRecorder).
        var deferred = false
    }

    /// A transcript from a list: the card zooms out of its row.
    private func openCard(_ recording: Recording, search: TranscriptSearchContext?, sourceID: String) {
        endEditing()
        present(CardRequest(transcript: recording, search: search, sourceID: sourceID))
    }

    /// Opens the card on `request`, or, while the last card is still shrinking away, once it is gone (cardDismissed).
    private func present(_ request: CardRequest) {
        guard !isCardDismissing else { pendingCard = request; return }
        guard request.transcript != nil || activeSession != nil else { return }   // the recording ended meanwhile
        cardTranscript = request.transcript
        cardSearch = request.search
        cardSourceID = request.sourceID
        card.turnedFromRecording = false
        if request.showsList { tab = .transcripts }
        if request.deferred {
            Task { if isCardDismissing { pendingCard = request } else { showsCard = true } }
        } else {
            showsCard = true
        }
    }

    /// The grabber, a swipe down, Delete, a failure screen's Close: the card shrinks away (until cardDismissed).
    private func closeCard() {
        guard showsCard else { return }
        isCardDismissing = true
        showsCard = false
    }

    /// The cover's onDismiss, once the card has shrunk away: only now does its content go. A recording that is still
    /// going on stays in the accessory; one that ended (saved, discarded or failed) is dropped. Then a request that
    /// came while it was shrinking opens the card again.
    private func cardDismissed() {
        isCardDismissing = false
        cardTranscript = nil
        cardSearch = nil
        cardSourceID = Self.recorderSource
        card.turnedFromRecording = false
        if let session = activeSession, !session.isOngoing { activeSession = nil }
        if let request = pendingCard {
            pendingCard = nil
            present(request)
        }
    }

    // MARK: Recording

    /// Transcribe (the accessory): a fresh session, started here so it survives the card being swiped down.
    private func startRecording() {
        guard activeSession == nil else { openRecorder(); return }
        let session = services.makeRecordingSession()
        activeSession = session
        openRecorder()
        Task {
            // Once the card is on its way: starting activates the audio session and the engine on the main thread,
            // which held it long enough that the card only came up after "Preparing…", without a visible zoom.
            try? await Task.sleep(for: Self.startDelay)
            await session.start()
        }
    }

    /// From the tap on Transcribe to starting the session (see startRecording).
    private static let startDelay: Duration = .milliseconds(120)

    /// The accessory opens the card on the recording, out of itself. Presented on the next turn of the main actor, so
    /// the accessory has laid out its new state (Transcribe → Preparing…) before the zoom takes it as its source.
    private func openRecorder() {
        present(CardRequest(sourceID: Self.recorderSource, deferred: true))
    }

    private func retryRecording() {
        activeSession = nil
        startRecording()
    }

    /// Saved (with the new transcript) or discarded. Saved with the card up on the recording: the same card turns into
    /// the transcript in place. Saved while the card was minimized (Stop in the accessory) or still shrinking into
    /// the accessory: the card opens on it (once it is gone). Discarded: the card closes. Saved while the card shows
    /// another transcript: the new one waits in the list, and that card's tab (its zoom source) stays as it is.
    private func finished(_ recording: Recording?) {
        let showsRecording = showsCard && cardTranscript == nil
        guard let recording else {
            if showsRecording { closeCard() } else if !isCardDismissing { activeSession = nil }   // else onDismiss
            return
        }
        activeSession = nil                      // the accessory says Transcribe again
        if showsRecording {
            tab = .transcripts                   // behind the card: the new transcript tops the list when it closes
            cardTranscript = recording           // in place (TranscriptCard turns the recording into it)
            cardSearch = nil
            card.turnedFromRecording = true
        } else if !showsCard {
            present(CardRequest(transcript: recording, sourceID: Self.recorderSource, showsList: true, deferred: true))
        }
    }

    // MARK: Search

    /// Pull-to-search and tag chips: the Search tab, with `token` added. A tag chip starts a search for that tag, so
    /// text typed in an earlier search is cleared.
    private func openSearch(_ token: SearchToken?) {
        if let token {
            searchState.query = ""
            searchState.add(token)
        }
        tab = .search
        searchState.focusRequest += 1
    }

    /// The search bar's close button: back to the tab Search was opened from (text and tokens are kept).
    private func closeSearch() {
        tab = tabBeforeSearch == .search ? .transcripts : tabBeforeSearch
    }

    #if DEBUG
    /// Screenshot hooks for simulator QA and the UI tests: `-seedSamples` puts two sample transcripts with named
    /// speakers into the store (`-seedPendingSample`: also a newest one whose speakers are still being identified;
    /// `-seedFiller <n>`: n older ones, a list long enough to scroll; all simulator only, never into an iPhone's real
    /// store); `-showSettings` / `-showPeople` select the Settings tab;
    /// `-openFirstTranscript` opens the newest transcript's card; `-autoRecord` starts recording (the simulator's fakes
    /// then stream text and live speaker labels), and with `-autoStopAfter <seconds>` stops it again, which saves it
    /// and turns the card into it; `-minimizeAfter <seconds>` minimizes the card into the accessory after that long
    /// and reopens it 2 s later (counted into `-autoStopAfter`; with `-openFirstTranscript` it closes that card). Search: `-search <text>`, `-searchToken person:<name>` or `tag:<tag>` (several
    /// separated by commas), `-openFirstResult` (the search list opens its first result's card); `-addTag <tag>` tags
    /// the newest transcript.
    private func applyLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments
        #if targetEnvironment(simulator)                   // seeds the app's own store: never on an iPhone with real data
        if arguments.contains("-seedSamples") {
            PreviewData.seed(into: modelContext, people: services.people, identifier: services.identifier,
                             pending: arguments.contains("-seedPendingSample"),
                             filler: UserDefaults.standard.integer(forKey: "seedFiller"))
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }   // @Query catches up first
        }
        #endif
        let newest = (try? modelContext.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt,
                                                                                                  order: .reverse)])))?.first
        if arguments.contains("-showSettings") || arguments.contains("-showPeople") { tab = .settings }
        if let name = UserDefaults.standard.string(forKey: "nameFirstSpeaker"), let newest {
            services.people.name(name, speaker: 0, in: newest)        // `-nameFirstSpeaker Julius`: as if typed
        }
        if let tag = UserDefaults.standard.string(forKey: "addTag"), let newest {
            newest.addTag(tag)                                         // `-addTag work`: as if typed in the detail
        }
        if let text = UserDefaults.standard.string(forKey: "search") {
            searchState.query = text
            tab = .search
        }
        if let list = UserDefaults.standard.string(forKey: "searchToken") {
            for token in list.split(separator: ",") {
                let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { searchState.add(SearchToken(kind: parts[0] == "tag" ? .tag : .person, value: parts[1])) }
            }
            tab = .search
        }
        if arguments.contains("-openFirstTranscript"), let newest {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }   // the list (the zoom source) first
            openCard(newest, search: nil, sourceID: OpenTranscriptAction.rowSource(RecordingsListView.transcriptsList, newest))
            let count = UserDefaults.standard.integer(forKey: "speakerCount")   // `-speakerCount 3`: as if picked
            if count > 0 { services.identifier.setSpeakerCount(count, for: newest) }
            let close = UserDefaults.standard.double(forKey: "minimizeAfter")   // closes it again, as the grabber does
            if close > 0, !arguments.contains("-autoRecord") {
                do { try await Task.sleep(for: .seconds(close)) } catch { return }
                closeCard()
            }
        }
        guard arguments.contains("-autoRecord") else { return }
        await services.prepareLiveDiarizer()           // live labels need the model loaded before the session is made
        startRecording()
        let cycle = UserDefaults.standard.double(forKey: "minimizeAfter")   // `-minimizeAfter 3`: grabber, then accessory
        if cycle > 0 {
            do { try await Task.sleep(for: .seconds(cycle)) } catch { return }
            closeCard()                                // as the grabber does: back into the accessory
            do { try await Task.sleep(for: .seconds(2)) } catch { return }   // shrunk away by then
            openRecorder()                             // as a tap on the recording accessory does
        }
        let seconds = UserDefaults.standard.double(forKey: "autoStopAfter")
        guard seconds > 0, let session = activeSession else { return }
        do { try await Task.sleep(for: .seconds(max(0, seconds - (cycle > 0 ? cycle + 2 : 0)))) } catch { return }
        await session.stop()
    }
    #endif
}
