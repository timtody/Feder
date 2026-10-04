import LinkPresentation
import UIKit

/// Presents the system share sheet for a transcript's text right away, from the frontmost view controller (the list's
/// Share swipe action): the activity view controller itself, with its own (fast) presentation, so nothing waits for
/// ShareLink's item preparation. (A still image over the row's snap-back and a container sheet were tried and dropped:
/// they made the sheet appear later.)
@MainActor
enum ShareSheet {
    static func present(text: String, title: String) {
        guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: [TranscriptItem(text: text, title: title)],
                                                  applicationActivities: nil)
        top.present(controller, animated: true)
    }

    /// The transcript as plain text, with its title for the sheet's header (what ShareLink's `SharePreview` showed).
    private final class TranscriptItem: NSObject, UIActivityItemSource {
        let text: String
        let title: String

        init(text: String, title: String) {
            self.text = text
            self.title = title
        }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { text }

        func activityViewController(_ controller: UIActivityViewController,
                                    itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text }

        func activityViewController(_ controller: UIActivityViewController,
                                    subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

        func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
            let metadata = LPLinkMetadata()
            metadata.title = title
            // An icon instead of the share sheet's grey placeholder: the transcript symbol in the accent colour.
            let configuration = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
            if let symbol = UIImage(systemName: "waveform", withConfiguration: configuration)?
                .withTintColor(.tintColor, renderingMode: .alwaysOriginal) {
                metadata.iconProvider = NSItemProvider(object: symbol)
            }
            return metadata
        }
    }
}
