import SwiftUI

/// A stretch of a paragraph whose words a pass just replaced, as the paragraph shows it: a tint behind the words that
/// holds for a moment and fades, plus an underline for a vocabulary term. The reader sees what the full-accuracy pass
/// and the vocabulary pass changed instead of the text silently becoming different.
nonisolated struct ChangeFlash: Equatable, Sendable {
    var range: Range<String.Index>
    var vocabulary: Bool
    var at: Date
}

/// The paragraph's text with its flashes drawn by `ChangeFlashRenderer` on a timeline that stops once they have faded.
/// With Reduce Motion the tint stands still at full strength (the flashes still go when the change record does).
struct ChangeFlashText: View {
    let text: String
    let flashes: [ChangeFlash]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let end = (flashes.map(\.at).max() ?? .distantPast) + ChangeFlashRenderer.hold + ChangeFlashRenderer.fade
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || Date.now > end)) { context in
            styled.textRenderer(ChangeFlashRenderer(now: reduceMotion ? (flashes.first?.at ?? context.date) : context.date))
        }
    }

    /// Runs tagged with their flash, plain text between them.
    private var styled: Text {
        var result = Text(verbatim: "")
        var cursor = text.startIndex
        for flash in flashes.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where flash.range.lowerBound >= cursor {
            if cursor < flash.range.lowerBound { result = Text("\(result)\(Text(verbatim: String(text[cursor..<flash.range.lowerBound])))") }
            let run = Text(verbatim: String(text[flash.range])).customAttribute(ChangedRun(at: flash.at, vocabulary: flash.vocabulary))
            result = Text("\(result)\(run)")
            cursor = flash.range.upperBound
        }
        if cursor < text.endIndex { result = Text("\(result)\(Text(verbatim: String(text[cursor...])))") }
        return result
    }
}

nonisolated struct ChangedRun: TextAttribute {
    var at: Date
    var vocabulary: Bool
}

/// Draws a rounded tint behind a changed run (and a line under a vocabulary term): full for `hold`, then fading over
/// `fade`. Nothing else is touched.
nonisolated struct ChangeFlashRenderer: TextRenderer {
    static let hold: TimeInterval = 1.5
    static let fade: TimeInterval = 2.5

    var now: Date

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if let change = run[ChangedRun.self] {
                    let t = now.timeIntervalSince(change.at)
                    let strength = t < Self.hold ? 1 : max(0, 1 - (t - Self.hold) / Self.fade)
                    if strength > 0 {
                        let rect = run.typographicBounds.rect.insetBy(dx: -3, dy: -2)
                        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.accentColor.opacity(0.22 * strength)))
                        if change.vocabulary {
                            let y = run.typographicBounds.rect.maxY + 1
                            context.stroke(Path { $0.move(to: CGPoint(x: rect.minX + 3, y: y)); $0.addLine(to: CGPoint(x: rect.maxX - 3, y: y)) },
                                           with: .color(.accentColor.opacity(0.9 * strength)), lineWidth: 1.5)
                        }
                    }
                }
                context.draw(run)
            }
        }
    }
}
