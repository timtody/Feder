import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The empty Ask card's glow (FED-137): a soft wash of colour behind the sparkle that turns once in 24 s and breathes in
/// 6 s, too slowly to read as motion, as Apple Intelligence's and Claude's empty states feel alive without moving. Still
/// with Reduce Motion. At 30 frames a second while the empty chat is on screen, nothing once the first question is
/// asked (the view goes).
struct ChatGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let turn = reduceMotion ? 0 : time.truncatingRemainder(dividingBy: 24) / 24 * 360
            let breath = reduceMotion ? 1 : 1 + 0.07 * sin(time * 2 * .pi / 6)
            Circle()
                .fill(AngularGradient(colors: [.blue, .indigo, .purple, .pink, .orange, .teal, .blue],
                                      center: .center, angle: .degrees(turn)))
                .frame(width: 150, height: 150)
                .scaleEffect(breath)
                .blur(radius: 42)
                .opacity(colorScheme == .dark ? 0.42 : 0.28)
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
