import SwiftUI

/// Find in a transcript (the card's magnifier), in Safari's Find on Page layout: a glass close button, the field in a
/// glass capsule with "3 of 12" (or "No Matches") and a clear button inside it, and Previous/Next in one glass capsule.
/// Ours, not `.searchable`: the system's bottom-bar search field (DefaultToolbarItem(kind: .search) with
/// `.searchToolbarBehavior(.minimize)`) expands over the whole bar with only its own close button, and neither the
/// bar's other items nor a `.keyboard` toolbar group were shown beside it (iOS 27, iPhone 17 simulator, 2026-10-14):
/// no place for the count and the arrows. In the card's bottom safe-area bar, so it rides on the keyboard and stays at
/// the bottom when the keyboard goes; styled like the Search tab's bar (TranscriptSearchBar). Not past the largest
/// standard text size (`capped`).
struct TranscriptFindBar: View {
    @Binding var text: String
    /// The paragraphs with hits, and which one is current; nil while nothing is searched (an empty field).
    let matches: (index: Int, count: Int)?
    /// The hits for the field's text aren't known yet (its typing pause, then the search): no count and the arrows
    /// off, since the last words' "No Matches" or "2 of 5" would be wrong for the new ones.
    var searching = false
    /// Changes on each press of the toolbar's Find (⌘F while the bar is up): the field takes the focus again.
    var focusRequest = 0
    let step: (Int) -> Void
    /// Return: the next hit, or, within the typing pause, the hits for the text at once.
    let submit: () -> Void
    let close: () -> Void

    @FocusState private var isFocused: Bool
    /// The bar's height grows with the text; the buttons' width doesn't (as the toolbar's): at the largest standard
    /// size three growing circles left the field too little room for its text.
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 44

    /// At the accessibility sizes the three glass shapes grew wider than the screen (AX XL, iPhone 17 simulator) and
    /// pushed the whole card sideways. The bottom toolbar it stands in for doesn't grow its buttons either (the Large
    /// Content Viewer shows them). Outside the bar: its own scaled metric reads the size it is given.
    var capped: some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                closeButton
                field
                arrows
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onAppear {
            InteractionTrace.shown("find")
            // Focused on the next turn, after the bar is on screen, as the tag field is (TagEditor): focused in the
            // press's turn, the text field became first responder as UIKit inserted it and set up the keyboard there,
            // 19–24 ms of the press's 69–76 ms of main thread (Time Profiler, iPhone 17 simulator, Debug, software
            // keyboard). The keyboard still starts to rise one turn later.
            DispatchQueue.main.async { isFocused = true }
        }
        // ⌘F while the bar is up: the field takes the keys again, as in Safari. The toolbar's Find gets the press
        // even while the toolbar is hidden (logged during testFindKeyboardShortcuts, 2026-10-15); a ⌘F of the bar's
        // own (on the magnifier) was never called, the toolbar's took every press.
        .onChange(of: focusRequest) { isFocused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in Transcript", text: $text)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // Return goes to the next hit, as in Safari; the field keeps the keyboard (a submit ends its editing).
                .onSubmit {
                    submit()
                    isFocused = true
                }
                .accessibilityIdentifier("FindField")
            if let matches, !searching {
                Group {
                    if matches.count == 0 {
                        Text("No Matches")
                    } else {
                        Text("\(matches.index + 1) of \(matches.count)")
                            .accessibilityLabel("Match \(matches.index + 1) of \(matches.count)")
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityIdentifier("FindCount")
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Text")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: height)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var closeButton: some View {
        Button {
            isFocused = false
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: height)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Close Find")
        .accessibilityIdentifier("CloseFind")
        .accessibilityShowsLargeContentViewer()
    }

    /// Previous and Next in one capsule; ⇧⌘G and ⌘G with a hardware keyboard, as in Safari.
    private var arrows: some View {
        let enabled = !searching && (matches?.count ?? 0) > 0
        return HStack(spacing: 0) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 44, height: height)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .accessibilityLabel("Previous Match")
            .accessibilityShowsLargeContentViewer()
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: height)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut("g", modifiers: .command)
            .accessibilityLabel("Next Match")
            .accessibilityShowsLargeContentViewer()
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color(uiColor: .tertiaryLabel))
        .disabled(!enabled)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
