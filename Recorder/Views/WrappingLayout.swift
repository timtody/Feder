import SwiftUI

/// Lays its subviews out left to right and starts a new line when the next one doesn't fit the width (a flow layout:
/// the search tokens and the suggestion chips). A subview wider than the whole width gets the whole width (its text
/// truncates). `nonisolated`, no captured state, like MetaLineLayout: iOS 26 measures layouts on SwiftUI's render thread.
nonisolated struct WrappingLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = arrange(subviews, width: width)
        let used = frames.reduce(CGSize.zero) { CGSize(width: max($0.width, $1.maxX), height: max($0.height, $1.maxY)) }
        return CGSize(width: proposal.width ?? used.width, height: used.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each subview's frame: at its ideal size (at most the width), on the current line while it fits; lines are
    /// filled first to last and stacked top to bottom.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0, x + size.width > width {                // doesn't fit: next line
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0                                    // from the top
        for line in lines where !line.isEmpty {
            let height = line.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for item in line {
                frames[item.index] = CGRect(x: x, y: y + (height - item.size.height) / 2,
                                            width: item.size.width, height: item.size.height)
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
        return frames
    }
}
