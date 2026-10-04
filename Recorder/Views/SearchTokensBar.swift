import SwiftUI

/// The Search tab's person/tag tokens, floating under the search field as tinted glass chips (a tap removes one). They
/// wrap into more rows when they don't fit one, growing downward from the field. Not inside the field, which was
/// cluttered.
struct SearchTokensBar: View {
    @Binding var tokens: [SearchToken]

    @Namespace private var chips

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            WrappingLayout(spacing: 8, lineSpacing: 8) {
                ForEach(tokens) { token in
                    tokenChip(token)
                        .glassEffectID(token.id, in: chips)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.3), value: tokens)
    }

    /// A person or tag in tinted glass; the whole chip removes it (a larger target than a small ✕).
    private func tokenChip(_ token: SearchToken) -> some View {
        Button {
            tokens.removeAll { $0.id == token.id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: token.kind == .person ? "person.fill" : "number")
                    .imageScale(.small)
                Text(token.value)
                    .lineLimit(1)
                    .truncationMode(.middle)                // only a name wider than the whole row
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .opacity(0.8)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
        .accessibilityLabel("Remove \(token.value)")
        .accessibilityHint(token.kind == .person ? "Person filter" : "Tag filter")
        .accessibilityIdentifier("SearchToken")
    }
}
