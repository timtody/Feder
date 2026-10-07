import SwiftUI

/// Asks once whether to download Gemma 4 E2B, which writes every transcript's title and summary (without it there are
/// none: Apple's on-device model invented whole meetings, see TranscriptTitler). Shown by MainView at launch to new and
/// existing users alike, on iPhones that can run it, while it is not downloaded; never again after Download or Not
/// Now (or a swipe down), whichever: Settings › Summaries keeps the download. Laid out like Apple's welcome sheets
/// (Journal, Notes' What's New): a large centred title, feature rows with tinted symbols, one prominent button at the
/// bottom and a plain one under it.
struct GemmaOnboarding: View {
    /// UserDefaults key: the sheet was shown (set when it appears).
    static let shownKey = "gemmaOnboardingShown"

    let download: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                Text("Titles and Summaries")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 52)
                VStack(alignment: .leading, spacing: 26) {
                    feature("text.alignleft", "A Title and the Key Points",
                            "Every transcript gets a short title and a summary of what was said and decided, and by whom.")
                    feature("lock.fill", "On This iPhone",
                            "Google's Gemma 4 E2B runs on device. Your recordings never leave your iPhone.")
                    feature("arrow.down.circle", "Downloads in the Background",
                            "A one-time 3.6 GB download over Wi-Fi. Keep using Feder or close it; it finishes on its own.")
                    feature("clock.arrow.circlepath", "Your Earlier Transcripts Too",
                            "Older transcripts get titles and summaries as well. Titles you typed stay.")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button {
                    download()
                    dismiss()
                } label: {
                    Text("Download Gemma (3.6 GB)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("Not Now") { dismiss() }
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .onAppear { UserDefaults.standard.set(true, forKey: Self.shownKey) }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
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
