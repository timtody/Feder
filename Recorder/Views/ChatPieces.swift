import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The empty Ask card's mark (FED-137): Feder's own feather (the icon's, as on the App Lock screen: AppLockFeather) in
/// the icon's gradient, over a soft glow of the icon's two blues that breathes once in 6 s, too slowly to read as
/// motion. Feder's identity rather than a generic AI sparkle and a rainbow glow, which the user had removed. Still with
/// Reduce Motion; at 30 frames a second only while the empty chat is on screen.
struct FeatherMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The icon's gradient (AppIcon.icon's fill), top and bottom stop, light and dark.
    private var iconBlues: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.169, green: 0.356, blue: 0.756), Color(red: 0.043, green: 0.110, blue: 0.271)]
            : [Color(red: 0.361, green: 0.609, blue: 0.933), Color(red: 0.092, green: 0.280, blue: 0.579)]
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let breath = reduceMotion ? 1 : 1 + 0.06 * sin(time * 2 * .pi / 6)
                Circle()
                    .fill(RadialGradient(colors: iconBlues, center: .center, startRadius: 0, endRadius: 75))
                    .frame(width: 150, height: 150)
                    .scaleEffect(breath)
                    .blur(radius: 44)
                    .opacity(colorScheme == .dark ? 0.55 : 0.22)
            }
            Image(.appLockFeather)
                .resizable()
                .scaledToFit()
                .frame(height: 52)
                .foregroundStyle(LinearGradient(colors: colorScheme == .dark
                                                    ? [Color.accentColor, iconBlues[0]]
                                                    : iconBlues,
                                                startPoint: .top, endPoint: .bottom))
        }
        .accessibilityHidden(true)
    }
}

/// "Thinking…" until Gemma's first token: a light passing over the word every 1.6 s (the shimmer of Apple
/// Intelligence's and Claude's waiting states) instead of a pulsing label. Plain secondary text with Reduce Motion.
struct ThinkingShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = Text("Thinking…").font(.body.weight(.medium))
        label
            .foregroundStyle(.tertiary)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            LinearGradient(colors: [.clear, .primary, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: width * 0.6)
                                .offset(x: -width * 0.6 + phase * width * 1.6)
                        }
                        .mask(label)
                    }
                }
            }
            .accessibilityLabel("Thinking…")
    }
}

/// Copy under a finished answer: a quiet glyph that turns into a checkmark for a moment, with the system's success
/// haptic (as Claude's and ChatGPT's answers offer it). The pasteboard write is one call, no file I/O. Local only:
/// Universal Clipboard would otherwise hand the answer (about a client's meeting, say) to the user's Mac or iPad,
/// and the card promises that nothing leaves this iPhone.
struct ChatCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: [.localOnly: true])
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "square.on.square")
                .contentTransition(.symbolEffect(.replace))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .accessibilityIdentifier("CopyAnswer")
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }
}
