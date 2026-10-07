import SwiftUI

/// A page of the onboarding sheet: the models that make Feder good, each explained once.
enum OnboardingPage: Hashable {
    /// Nemotron, which identifies the speakers after Stop: downloads by itself on Wi-Fi (NemotronModel), so the page
    /// explains it and shows how far it is; Continue.
    case speakers
    /// Gemma 4 E2B, which writes titles and summaries: 3.6 GB, so it asks (Download / Not Now). 8 GB iPhones only.
    case summaries
}

/// The onboarding sheet MainView shows once at launch (`offerOnboarding`): only the pages still useful on this iPhone
/// (Nemotron while it isn't downloaded, Gemma while it can run and isn't downloaded), so an existing user with
/// Nemotron sees just Gemma's page, and a new user on a 6 GB iPhone just Nemotron's. Each page is remembered when it
/// appears (`shownKey`), whatever is tapped, also a swipe down; Settings keeps both downloads. Laid out like Apple's
/// welcome sheets (Journal, Notes' What's New): a large centred title, feature rows with tinted symbols, one prominent
/// glass button at the bottom (and a plain one under it where there is a choice); the next page slides in from the
/// trailing edge, as in Apple's setup screens.
struct Onboarding: View {
    let pages: [OnboardingPage]
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    /// UserDefaults: the page was shown.
    static func shownKey(_ page: OnboardingPage) -> String {
        switch page {
        case .speakers: "nemotronOnboardingShown"
        case .summaries: "gemmaOnboardingShown"
        }
    }

    var body: some View {
        ZStack {
            if pages.indices.contains(index) {
                content(pages[index])
                    .id(index)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                    .onAppear { UserDefaults.standard.set(true, forKey: Self.shownKey(pages[index])) }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func content(_ page: OnboardingPage) -> some View {
        switch page {
        case .speakers: speakers
        case .summaries: summaries
        }
    }

    /// The next page, or the end.
    private func next() {
        if index + 1 < pages.count {
            withAnimation(.smooth) { index += 1 }
        } else {
            dismiss()
        }
    }

    // MARK: Pages

    private var speakers: some View {
        layout(title: "Know Who Said What") {
            feature("person.2.wave.2", "Every Speaker Apart",
                    "After you stop, NVIDIA's Nemotron tells the voices apart, also when people talk in quick succession.")
            feature("person.crop.circle.badge.checkmark", "Recognizes Your People",
                    "Name a speaker once, and Feder knows their voice in later recordings.")
            feature("lock.fill", "On This iPhone",
                    "Speakers are identified on device. Your recordings never leave your iPhone.")
            NemotronStatusRow(state: services.nemotron.state)
        } buttons: {
            Button(action: next) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private var summaries: some View {
        layout(title: "Titles and Summaries") {
            feature("text.alignleft", "A Title and the Key Points",
                    "Every transcript gets a short title and a summary of what was said and decided, and by whom.")
            feature("lock.fill", "On This iPhone",
                    "Google's Gemma 4 E2B runs on device. Your recordings never leave your iPhone.")
            feature("arrow.down.circle", "Downloads in the Background",
                    "A one-time 3.6 GB download over Wi-Fi. Keep using Feder or close it; it finishes on its own.")
        } buttons: {
            Button {
                services.betterSummaries.download()
                next()
            } label: {
                Text("Download Gemma (3.6 GB)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button("Not Now", action: next)
                .controlSize(.large)
        }
    }

    // MARK: Layout

    private func layout<Rows: View, Buttons: View>(title: LocalizedStringKey, @ViewBuilder rows: () -> Rows,
                                                   @ViewBuilder buttons: () -> Buttons) -> some View {
        ScrollView {
            VStack(spacing: 36) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 52)
                VStack(alignment: .leading, spacing: 26) {
                    rows()
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                buttons()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        OnboardingRow(symbol: symbol) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A feature row: a tinted symbol, then a headline and its text.
private struct OnboardingRow<Content: View>: View {
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Nemotron's download as the speakers page's last row, live: it starts by itself on Wi-Fi, so the page shows where
/// it is instead of asking. A finished download is still loaded and compiled for the Neural Engine (most of a minute
/// on an iPhone 17), shown as "Preparing".
private struct NemotronStatusRow: View {
    let state: ModelDownloadState

    var body: some View {
        switch state {
        case .downloading(let fraction) where fraction < NemotronModel.preparingFraction:
            OnboardingRow(symbol: "arrow.down.circle") {
                Text("Downloading \(fraction, format: .percent.precision(.fractionLength(0)))")
                    .font(.headline)
                    .monospacedDigit()
                ProgressView(value: fraction)
                    .padding(.vertical, 4)
                Text("A one-time 100 MB download. Keep using Feder meanwhile.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .downloading:
            OnboardingRow(symbol: "gearshape.2") {
                Text("Preparing…")
                    .font(.headline)
                Text("Downloaded. Feder is getting the model ready on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .waitingForWiFi:
            OnboardingRow(symbol: "wifi") {
                Text("Waiting for Wi-Fi")
                    .font(.headline)
                Text("The 100 MB download starts when this iPhone is on Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready:
            OnboardingRow(symbol: "checkmark.circle.fill") {
                Text("Ready")
                    .font(.headline)
                Text("Nemotron is on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .notDownloaded:
            OnboardingRow(symbol: "arrow.down.circle") {
                Text("100 MB Download")
                    .font(.headline)
                Text("Starts by itself on Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            OnboardingRow(symbol: "exclamationmark.triangle") {
                Text("Download Failed")
                    .font(.headline)
                Text("Feder tries again the next time it opens on Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
