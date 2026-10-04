import SwiftUI

/// A transcript row's second line, one line tall: date · duration, then the place, the chips, and a "+n" counter for
/// the chips that don't fit. Subviews, in order: the date/duration, the place (when `hasPlace`), `chips` chips, then
/// one counter per possible hidden count ("+1" … "+chips"; at least one). Preference: everything; without the place;
/// fewer chips (with the counter); at last no chips with the place truncated into what is left. Subviews not shown are
/// placed far off-screen, where they stay in the accessibility tree: the row gives VoiceOver the line as one element
/// (see `RecordingsListView.metaLine`). `nonisolated`, no captured state: safe wherever SwiftUI measures it.
nonisolated struct MetaLineLayout: Layout {
    var chips: Int
    var hasPlace: Bool
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = plan(subviews, width: width)
        let used = frames.compactMap { $0 }.reduce(CGSize.zero) {
            CGSize(width: max($0.width, $1.maxX), height: max($0.height, $1.maxY))
        }
        return CGSize(width: proposal.width.map { min($0, used.width.rounded(.up)) } ?? used.width.rounded(.up),
                      height: used.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // A little slack: SwiftUI measures the line several times, and a text's width can differ by a point or two
        // between those passes; without it, the last chip of an exactly fitting line dropped out.
        for (subview, frame) in zip(subviews, plan(subviews, width: bounds.width + 2)) {
            if let frame {
                subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                              proposal: ProposedViewSize(frame.size))
            } else {
                subview.place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .unspecified)
            }
        }
    }

    /// Each subview's frame, nil when hidden.
    private func plan(_ subviews: Subviews, width: CGFloat) -> [CGRect?] {
        guard !subviews.isEmpty else { return [] }
        let placeIndex: Int? = hasPlace ? 1 : nil
        let firstChip = hasPlace ? 2 : 1
        let firstCounter = firstChip + chips
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let meta = sizes[0]
        func chipsWidth(_ k: Int) -> CGFloat {
            (0..<k).reduce(0) { $0 + sizes[firstChip + $1].width + spacing }
        }
        func counterWidth(_ hidden: Int) -> CGFloat {
            hidden > 0 && firstCounter + hidden - 1 < sizes.count ? sizes[firstCounter + hidden - 1].width + spacing : 0
        }
        let placeWidth = placeIndex.map { sizes[$0].width + spacing / 2 } ?? 0

        var shownChips = 0
        var placeShown: CGFloat = 0                         // the place's width, 0 when hidden
        if meta.width + placeWidth + chipsWidth(chips) <= width {
            shownChips = chips
            placeShown = placeWidth
        } else if let k = stride(from: chips, through: 1, by: -1).first(where: {
            meta.width + chipsWidth($0) + counterWidth(chips - $0) <= width
        }) {
            shownChips = k
        } else {
            let left = width - meta.width - counterWidth(chips)
            placeShown = hasPlace ? max(0, min(placeWidth, left)) : 0
        }

        let lineHeight = sizes.map(\.height).max() ?? 0
        var frames = Array<CGRect?>(repeating: nil, count: subviews.count)
        var x: CGFloat = 0
        func put(_ index: Int, width: CGFloat) {
            frames[index] = CGRect(x: x, y: (lineHeight - sizes[index].height) / 2, width: width, height: sizes[index].height)
            x += width
        }
        put(0, width: min(meta.width, width))
        if let placeIndex, placeShown > 20 {
            x += spacing / 2
            put(placeIndex, width: placeShown - spacing / 2)
        }
        for i in 0..<shownChips {
            x += spacing
            put(firstChip + i, width: sizes[firstChip + i].width)
        }
        let hidden = chips - shownChips
        if hidden > 0, firstCounter + hidden - 1 < subviews.count {
            x += spacing
            put(firstCounter + hidden - 1, width: sizes[firstCounter + hidden - 1].width)
        }
        return frames
    }
}
