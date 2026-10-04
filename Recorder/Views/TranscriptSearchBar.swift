import SwiftUI

/// The Search tab's bar at the top of the screen, like Apple Music's: a glass capsule with the text field (focused
/// whenever the tab appears) and a clear button, the glass close button right beside it (back to the previous tab), and
/// the person/tag tokens floating under it as tinted glass chips (`SearchTokensBar`). Ours, not `.searchable`: Search is
/// an ordinary tab while the tab bar is expanded (see MainView), and the system field's place differs by iOS version. A
/// top safe-area bar: the results scroll under it and fade out.
struct TranscriptSearchBar: View {
    @Binding var query: String
    @Binding var tokens: [SearchToken]
    /// Changes on every tap on the Search tab: the field takes the focus again (not only when it first appears).
    var focusRequest = 0
    var close: () -> Void

    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                field
                closeButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, tokens.isEmpty ? 8 : 0)
            if !tokens.isEmpty {
                SearchTokensBar(tokens: $tokens)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: tokens.isEmpty)
        .onAppear { isFocused = true }                   // choosing the Search tab: keyboard up
        .onChange(of: focusRequest) { isFocused = true }  // each further tap on the tab, too
        .onDisappear { isFocused = false }               // another tab: the keyboard goes with the Search tab
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(tokens.isEmpty ? "People, tags or words" : "Narrow down", text: $query)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("SearchField")
            if !query.isEmpty || !tokens.isEmpty {
                Button {
                    query = ""
                    tokens = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: height)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var closeButton: some View {
        Button {
            isFocused = false
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: height, height: height)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Close")
    }

}
