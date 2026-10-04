import SwiftUI

/// What the card shows, owned by MainView. An observable object the card reads itself, not values handed to the
/// cover's content closure: MainView's body doesn't read them, and the cover then came up with the stale (empty)
/// values of its last evaluation, a blank card.
@MainActor @Observable
final class TranscriptCardContent {
    /// The recording (the accessory shows it too); the card shows it while there is no `transcript`.
    var session: RecordingSession?
    var transcript: Recording?
    /// Opened from a search result: its highlights and "n of m".
    var search: TranscriptSearchContext?
    /// The transcript took the recording's place in the open card (its summary, tags and text fade in).
    var turnedFromRecording = false
    /// Where the card zooms out of and back into: the accessory or a row (`OpenTranscriptAction.rowSource`).
    var sourceID = TranscriptCardContent.recorderSource

    /// The accessory's zoom source id.
    static let recorderSource = "recorder"
}

/// The card's back button at the top left: a glass circle with a chevron, where a pushed page has its Back and where
/// Photos puts it over a zoomed photo, the same glass as the search bar's close button. It says the card is swiped
/// away to the right; a tap closes it too. `hint` says where it goes (back into the accessory while recording, back
/// to the list for a transcript). Content scrolls under it (the glass shows it), so there is no band and no fade.
struct CardCloseButton: View {
    let hint: LocalizedStringKey
    let action: () -> Void

    static let size: CGFloat = 44
    /// From the top safe area and from the leading edge (a navigation bar's leading item).
    static let inset: CGFloat = 8, leading: CGFloat = 16
    /// Where the card's content starts: below the button. The recording and the transcript both start their title here.
    static let contentTop: CGFloat = inset + size + 8

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Minimize")
        .accessibilityHint(hint)
    }
}

extension View {
    /// The card's back button floating over the top left of this view. An overlay, not a top `safeAreaBar` (which
    /// gave the system's scroll edge effect): on iOS 27 that switched off the transcript's text selection, a long
    /// press selected nothing and showed no Copy (testLongPressMenusKeepTextSelection).
    func cardCloseButton(hint: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        overlay(alignment: .topLeading) {
            CardCloseButton(hint: hint, action: action)
                .padding(.top, CardCloseButton.inset)
                .padding(.leading, CardCloseButton.leading)
        }
    }
}

/// Opens a transcript in MainView's card, zooming out of the view marked `.cardSource(sourceID)` (and back into it
/// when the card closes). Set by MainView for the lists and Settings › People › person.
struct OpenTranscriptAction {
    let open: (Recording, TranscriptSearchContext?, String) -> Void

    func callAsFunction(_ recording: Recording, search: TranscriptSearchContext? = nil, sourceID: String) {
        open(recording, search, sourceID)
    }

    /// The zoom source id of a transcript's row in one list. Scoped by list: every tab stays alive in the TabView, so
    /// the same transcript is a row in several lists at once, and an id shared between them zoomed out of a hidden one.
    static func rowSource(_ list: String, _ recording: Recording) -> String { "\(list):\(recording.id)" }
}

extension EnvironmentValues {
    @Entry var openTranscript: OpenTranscriptAction? = nil
    /// The namespace of the card's zoom transition (MainView's).
    @Entry var cardZoom: Namespace.ID? = nil
}

extension View {
    /// Marks this view as where the card zooms out of, and back into, for `sourceID`.
    func cardSource(_ sourceID: String) -> some View {
        modifier(CardSourceModifier(sourceID: sourceID))
    }
}

private struct CardSourceModifier: ViewModifier {
    let sourceID: String
    @Environment(\.cardZoom) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: sourceID, in: namespace)
        } else {
            content                                              // previews: no card
        }
    }
}
