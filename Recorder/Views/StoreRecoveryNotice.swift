import SwiftUI

/// Shown once after Feder couldn't open its transcripts and set the store aside (StoreRecovery, FED-171), so a list that
/// starts empty never looks like lost transcripts: what happened, the files to share on a tap, the old list to try
/// again at the next launch, or carry on with the new one. Nothing is deleted whichever is chosen.
struct StoreRecoveryNotice: View {
    let notice: StoreRecovery.Notice
    let close: () -> Void
    @State private var willRetry = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Your Transcripts Couldn't Be Opened")
                    .font(.title2.bold())
                Text("Feder started with a new, empty list and set the old one aside on this iPhone. Nothing was deleted. Your recordings are coming back as new transcripts called Recovered Recording: the words are transcribed again, but names, speakers, tags and edits aren't in them.")
                    .foregroundStyle(.secondary)
                if willRetry {
                    Label("Close Feder and open it again to try the old list.", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("storeRecoveryRetryNote")
                }
                Spacer()
                VStack(spacing: 12) {
                    Button {
                        StoreRecovery.restoreAtNextLaunch()
                        willRetry = true
                    } label: {
                        Text("Try the Old List Again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(willRetry)
                    .accessibilityIdentifier("storeRecoveryTryAgain")
                    ShareLink(items: notice.files) {
                        Text("Share Recovery Files").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("storeRecoveryShare")
                    Button(willRetry ? "Not Now" : "Continue", action: close)
                        .accessibilityIdentifier("storeRecoveryContinue")
                }
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .interactiveDismissDisabled()
    }
}
