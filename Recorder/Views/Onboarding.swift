import SwiftUI
import Speech

/// A page of the onboarding sheet.
enum OnboardingPage: Hashable {
    /// What Feder does, that recordings stay on the iPhone, and how much the speaker models download (App Review
    /// 4.2.3(ii): disclose the size and ask before downloading what the app needs; its Continue allows the downloads,
    /// AppServices.allowModelDownloads). New installs only.
    case welcome
    /// The notice every user gets once, existing users too: ask people before recording them (§ 201 StGB), voices
    /// you name are remembered on this iPhone, automatic results can contain mistakes; and the privacy policy.
    case beforeYouRecord
    /// Gemma for titles and summaries: 3.6 GB, so it asks (Download / Not Now). 8 GB iPhones only.
    case summaries
}

/// The onboarding sheet MainView shows once at launch (`offerOnboarding`), with only the pages still due on this
/// iPhone, and Settings › About › Welcome shows again. Replaced (October 2026) a two-page sheet that explained the
/// speaker model by name with a live download row, which read as too technical: the pages now say what Feder does
/// and what the user should know, and the downloads show in the record accessory and Settings.
///
/// Laid out like Apple's welcome sheets (Journal, Freeform, Notes' What's New): a large centred title, feature rows
/// with tinted symbols, one prominent glass button at the bottom (and a plain one under it where there is a choice).
/// The pages are a NavigationStack inside the sheet, so iOS draws the push, the back button and the edge swipe.
/// Welcome and Before You Record can't be swiped away (each counts only once its Continue is tapped); the Gemma page
/// can, and counts as shown when it appears. No permission is asked here: the microphone is asked at the first
/// Transcribe, as Voice Memos does, and location at the first Stop.
struct Onboarding: View {
    let pages: [OnboardingPage]
    /// Settings › About › Welcome: shown again to re-read, so it can be swiped away and has Done.
    var isReplay = false
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var path: [OnboardingPage] = []

    /// UserDefaults: Before You Record was confirmed (Continue).
    static let recordingNoticeKey = "recordingNoticeShown"
    /// UserDefaults: the Gemma page was shown.
    static let summariesShownKey = "gemmaOnboardingShown"

    private var current: OnboardingPage? { path.last ?? pages.first }

    var body: some View {
        NavigationStack(path: $path) {
            if let first = pages.first {
                content(first)
                    .navigationDestination(for: OnboardingPage.self) { content($0) }
            }
        }
        .interactiveDismissDisabled(!isReplay && (current == .welcome || current == .beforeYouRecord))
    }

    /// A page, with Done in the replay (on every page: a toolbar on the NavigationStack itself wouldn't show).
    private func content(_ page: OnboardingPage) -> some View {
        Group {
            switch page {
            case .welcome: welcome
            case .beforeYouRecord: beforeYouRecord
            case .summaries: summaries
            }
        }
        .toolbar {
            if isReplay {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The page after `page`, or the end.
    private func next(after page: OnboardingPage) {
        if let index = pages.firstIndex(of: page), index + 1 < pages.count {
            path.append(pages[index + 1])
        } else {
            dismiss()
        }
    }

    // MARK: Pages

    private var welcome: some View {
        OnboardingLayout(title: "Welcome to Feder") {
            OnboardingRow(symbol: "waveform", title: "Transcribe As You Talk",
                          text: "Tap Transcribe and watch the words appear as people speak.")
            OnboardingRow(symbol: "person.2.wave.2", title: "Know Who Said What",
                          text: "Feder tells voices apart and recognizes people you've named before.")
            OnboardingRow(symbol: "magnifyingglass", title: "Find Anything",
                          text: "Search every word, person and tag across your transcripts.")
            OnboardingRow(symbol: "lock.fill", title: "Your Recordings Stay Here",
                          text: "Recording, transcription and speaker detection happen on this iPhone. Feder never uploads your recordings.")
        } footnote: {
            if !Self.canTranscribe {
                Text("Live transcription needs an iPhone 12 or later.")
            }
            Text("To tell speakers apart, Feder downloads its speaker models once: 21 MB now and 145 MB more on Wi-Fi.")
        } buttons: {
            ProminentButton("Continue") {
                services.allowModelDownloads()
                next(after: .welcome)
            }
        }
    }

    private var beforeYouRecord: some View {
        OnboardingLayout(title: "Before You Record") {
            OnboardingRow(symbol: "hand.raised", title: "Ask First",
                          text: "Tell people you're recording and get their OK. Recording a private conversation without consent is against the law in Germany and many other countries.")
            // Every speaker's voice profile is kept with its transcript (SpeakerIdentifier), not only named ones, and
            // deleting a person leaves the profiles in their transcripts: said as it is.
            OnboardingRow(symbol: "person.crop.circle.badge.checkmark", title: "Voices Are Remembered",
                          text: "Feder keeps a voice profile of everyone it hears, only on this iPhone, and recognizes people you've named. Delete a person and their transcripts to forget their voice.")
            OnboardingRow(symbol: "checkmark.bubble", title: "Check What Matters",
                          text: "Transcripts, speaker names and summaries are made automatically and can contain mistakes.")
        } footnote: {
            NavigationLink("Privacy Policy") { LegalTextView(document: .privacy) }
                .font(.footnote)
        } buttons: {
            ProminentButton("Continue") {
                UserDefaults.standard.set(true, forKey: Self.recordingNoticeKey)
                next(after: .beforeYouRecord)
            }
        }
    }

    private var summaries: some View {
        SummariesPage(onDone: { next(after: .summaries) })
            .onAppear { UserDefaults.standard.set(true, forKey: Self.summariesShownKey) }
    }

    /// SpeechTranscriber runs on an iPhone 12 (A14) or later; iOS 26 also runs on the iPhone 11 and SE 2, where Feder
    /// can't transcribe. The simulator's fake engines can.
    static var canTranscribe: Bool {
        #if DEBUG && targetEnvironment(simulator)
        true
        #else
        SpeechTranscriber.isAvailable
        #endif
    }
}

/// Gemma's page: what it does, that it runs here and can be wrong (HIG › Generative AI: say where AI is used and that
/// it can make mistakes), the download. Free storage is checked when the page appears, so too little space is said
/// here instead of failing after Download; off Wi-Fi (or in Low Data Mode) it says when the download starts.
private struct SummariesPage: View {
    let onDone: () -> Void
    @Environment(AppServices.self) private var services
    @State private var freeBytes: Int64?

    private var hasRoom: Bool { (freeBytes ?? .max) >= BetterSummaries.neededBytes }

    var body: some View {
        OnboardingLayout(title: "Titles and Summaries") {
            OnboardingRow(symbol: "text.alignleft", title: "A Title for Every Transcript",
                          text: "Feder names each transcript and sums up what was said and decided.")
            OnboardingRow(symbol: "iphone", title: "Written on This iPhone",
                          text: "Gemma, an AI model from Google, runs right here. Your words stay on your iPhone.")
            OnboardingRow(symbol: "exclamationmark.bubble", title: "Double-Check Important Details",
                          text: "Summaries can get things wrong. The full transcript is always there to check.")
            OnboardingRow(symbol: "arrow.down.circle", title: "A One-Time Download",
                          text: "3.6 GB over Wi-Fi. It keeps going while you use other apps.")
        } footnote: {
            if !hasRoom {
                Text("Gemma needs 4 GB of free storage. Free up space, then download it in Settings.")
            } else {
                switch services.network.kind {
                case .lowData: Text("The download starts on Wi-Fi with Low Data Mode off.")
                case .cellular, .offline: Text("The download starts when this iPhone is on Wi-Fi.")
                case .wifi, nil: EmptyView()
                }
            }
            Text("You can download it later in Settings.")
        } buttons: {
            ProminentButton("Download (3.6 GB)") {
                services.betterSummaries.download()
                onDone()
            }
            .disabled(!hasRoom)
            Button("Not Now", action: onDone)
                .controlSize(.large)
        }
        .task { freeBytes = await BetterSummaries.freeBytes() }
    }
}

// MARK: - Layout

/// A page: the large centred title, the rows, a footnote, and the buttons in the bottom scroll-edge bar
/// (`safeAreaBar`, iOS 26: the content scrolls under the glass edge, as in Apple's sheets).
private struct OnboardingLayout<Rows: View, Footnote: View, Buttons: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let rows: Rows
    @ViewBuilder let footnote: Footnote
    @ViewBuilder let buttons: Buttons

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 26) {
                    rows
                }
                VStack(spacing: 8) {
                    footnote
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 6) {
                buttons
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .toolbarTitleDisplayMode(.inline)
    }
}

/// A feature row: a tinted symbol, then a headline and its text.
private struct OnboardingRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The page's main action: full width, prominent glass, large.
private struct ProminentButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}
