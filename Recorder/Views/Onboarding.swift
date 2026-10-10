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
    /// Recognizing people by voice: what it does, that voice profiles are biometric data and need consent, that they
    /// never leave the iPhone; its switch is off until the user turns it on. Once for everyone.
    case voiceProfiles
    /// The optional downloads, on one page, each with its switch: Parakeet (610 MB, more accurate transcripts after
    /// Stop) and Gemma (3.6 GB, titles and summaries; 8 GB iPhones only). Download / Not Now.
    case improvements
}

/// The onboarding sheet MainView shows once at launch (`offerOnboarding`), with only the pages still due on this
/// iPhone, and Settings › About › Welcome shows again. Replaced (October 2026) a two-page sheet that explained the
/// speaker model by name with a live download row, which read as too technical: the pages now say what Feder does
/// and what the user should know, and the downloads show in the record accessory and Settings.
///
/// Laid out like Apple's welcome sheets (Journal, Freeform, Notes' What's New): a large centred title, feature rows
/// with tinted symbols, one prominent glass button at the bottom (and a plain one under it where there is a choice).
/// The pages are a NavigationStack inside the sheet, so iOS draws the push, the back button and the edge swipe.
/// Welcome and Before You Record can't be swiped away (each counts only once its Continue is tapped); Optional
/// Improvements can, and counts as shown when it appears. No permission is asked here: the microphone is asked at the
/// first Transcribe, as Voice Memos does, and location at the first Stop. Copy without dashes (they read as machine
/// written), and about privacy in the first person plural: "We never upload…", not "Feder doesn't…".
struct Onboarding: View {
    let pages: [OnboardingPage]
    /// Settings › About › Welcome: shown again to re-read, so it can be swiped away and has Done.
    var isReplay = false
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var path: [OnboardingPage] = []

    /// UserDefaults: Before You Record was confirmed (Continue).
    static let recordingNoticeKey = "recordingNoticeShown"
    /// UserDefaults: the voice profiles page was shown.
    static let voiceProfilesShownKey = "voiceProfilesOnboardingShown"
    /// UserDefaults: Optional Improvements was shown. (Until October 2026 a Gemma-only page, `gemmaOnboardingShown`.)
    static let improvementsShownKey = "improvementsOnboardingShown"
    /// UserDefaults: the Gemma-only page it replaced was shown, so Gemma was offered once already.
    static let legacyGemmaShownKey = "gemmaOnboardingShown"

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
            case .voiceProfiles: voiceProfiles
            case .improvements: improvements
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
            OnboardingRow(symbol: "lock.fill", title: "Completely Private",
                          text: "Everything happens on this iPhone: recording, transcription, speakers and summaries. We never upload your recordings or transcripts.")
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

    private var voiceProfiles: some View {
        VoiceProfilesPage(onDone: { next(after: .voiceProfiles) })
            .onAppear { UserDefaults.standard.set(true, forKey: Self.voiceProfilesShownKey) }
    }

    private var improvements: some View {
        ImprovementsPage(onDone: { next(after: .improvements) })
            .onAppear { UserDefaults.standard.set(true, forKey: Self.improvementsShownKey) }
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

/// Recognize People by Voice: off by default (October 2026: voice profiles are biometric data, GDPR Art. 9, so they are
/// opt-in). The page says what it does, that a profile identifies a person and needs the agreement of the people
/// recorded, and that profiles never leave the iPhone; its switch is the setting itself (PeopleDirectory
/// .recognitionKey), so turning it on here is the user's consent. Every speaker's profile would be kept with its
/// transcript (SpeakerIdentifier), not only named ones: the copy says "each speaker".
private struct VoiceProfilesPage: View {
    let onDone: () -> Void
    @AppStorage(PeopleDirectory.recognitionKey) private var recognizesVoices = false

    var body: some View {
        OnboardingLayout(title: "Recognize People by Voice") {
            OnboardingRow(symbol: "person.crop.circle.badge.checkmark", title: "Know Who Is Speaking",
                          text: "Feder can keep a voice profile of each speaker and recognize people you've named in later recordings.")
            OnboardingRow(symbol: "hand.raised", title: "Biometric Data",
                          text: "A voice profile identifies a person. Turn this on only if the people you record agree.")
            OnboardingRow(symbol: "lock.fill", title: "Never Leaves This iPhone",
                          text: "Profiles stay on this iPhone and we never upload them. Turning it off in Settings deletes them.")
            Toggle(isOn: $recognizesVoices) {
                Text("Recognize People by Voice")
                    .font(.headline)
            }
            .padding(.top, 4)
        } footnote: {
            Text("Off unless you turn it on. You can change it any time in Settings.")
        } buttons: {
            ProminentButton("Continue", action: onDone)
        }
    }
}

/// Optional Improvements: two AI models, named by what they do ("AI Model for More Accurate Transcripts", "AI Model for
/// Summaries and Automatic Titles") with a one-line description and the model's name and size underneath (Parakeet,
/// Gemma by Google): clearly optional (Feder works without them), each with its switch, both on
/// by default since the page recommends them. Only what this iPhone can still get is listed: Parakeet unless it is
/// there or already asked for, Gemma on 8 GB iPhones while it isn't downloaded. Gemma's free storage is checked when
/// the page appears (it needs 4 GB): too little turns its switch off and says so, instead of failing after Download.
/// Both downloads wait for Wi-Fi (and Low Data Mode off), which the footnote says when the phone isn't there.
private struct ImprovementsPage: View {
    let onDone: () -> Void
    @Environment(AppServices.self) private var services
    @State private var wantsParakeet = true
    @State private var wantsGemma = true
    @State private var freeBytes: Int64?
    /// Parakeet's files and a margin, counted against free storage when it downloads too.
    private static let parakeetBytes: Int64 = 650_000_000

    private var offersParakeet: Bool { services.offersParakeet }
    private var offersGemma: Bool { services.offersGemma }
    private var gemmaHasRoom: Bool {
        (freeBytes ?? .max) >= BetterSummaries.neededBytes + (getsParakeet ? Self.parakeetBytes : 0)
    }
    private var getsParakeet: Bool { offersParakeet && wantsParakeet }
    private var getsGemma: Bool { offersGemma && wantsGemma && gemmaHasRoom }

    var body: some View {
        OnboardingLayout(title: "Optional Improvements") {
            // Parakeet can't be removed again in Settings (only Gemma can), so the copy says "add", not "remove".
            Text(offersParakeet && offersGemma
                 ? "Feder works without these. They run on this iPhone and download once over Wi-Fi. You can add them later in Settings."
                 : "Feder works without it. It runs on this iPhone and downloads once over Wi-Fi. You can add it later in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            if offersParakeet {
                OptionRow(symbol: "text.badge.checkmark", title: "AI Model for More Accurate Transcripts",
                          text: "Transcribes each recording again after you stop, with fewer mistakes, especially in German and other European languages.",
                          size: "Parakeet · 610 MB", isOn: $wantsParakeet)
            }
            if offersGemma {
                OptionRow(symbol: "text.alignleft", title: "AI Model for Summaries and Automatic Titles",
                          text: "Writes a title and a short summary for each transcript.",
                          size: gemmaHasRoom ? "Gemma by Google · 3.6 GB" : "Gemma by Google · 3.6 GB · not enough free storage",
                          isOn: $wantsGemma)
                    .disabled(!gemmaHasRoom)
            }
        } footnote: {
            if getsParakeet || getsGemma {
                let both = getsParakeet && getsGemma
                switch services.network.kind {
                case .lowData:
                    Text(both ? "The downloads start on Wi-Fi with Low Data Mode off." : "The download starts on Wi-Fi with Low Data Mode off.")
                case .cellular, .offline:
                    Text(both ? "The downloads start when this iPhone is on Wi-Fi." : "The download starts when this iPhone is on Wi-Fi.")
                case .wifi, nil:
                    EmptyView()
                }
            }
        } buttons: {
            ProminentButton(downloadTitle) {
                if getsParakeet { services.parakeet.request() }
                if getsGemma { services.betterSummaries.download() }
                onDone()
            }
            .disabled(!getsParakeet && !getsGemma)
            Button("Not Now", action: onDone)
                .controlSize(.large)
        }
        .task { freeBytes = await BetterSummaries.freeBytes() }
    }

    /// The button names what it downloads, as the App Store does.
    private var downloadTitle: LocalizedStringKey {
        switch (getsParakeet, getsGemma) {
        case (true, true): "Download (4.2 GB)"
        case (true, false): "Download (610 MB)"
        case (false, true): "Download (3.6 GB)"
        case (false, false): "Download"
        }
    }
}

/// An optional download as a switch: the row is the switch's label (a tinted symbol, the headline, what it does and its
/// size), so VoiceOver reads it once as one switch. From xxxLarge text the switch goes under the text and the symbol
/// away, as Settings rows do, so long German words keep their line (AnyLayout: a value, no main-actor closure).
private struct OptionRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let size: LocalizedStringKey
    @Binding var isOn: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isLarge: Bool { typeSize >= .xxxLarge }

    var body: some View {
        let layout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
        layout {
            if !isLarge {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                    .accessibilityHidden(true)
            }
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(size)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
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
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 20)
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
        // Always shown, also on the first page without a back button: hidden there, the pushed page laid out under a
        // bar that came in with its back button and slid down about 15 pt once the push had ended (seen frame by frame).
        .toolbarVisibility(.visible, for: .navigationBar)
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
