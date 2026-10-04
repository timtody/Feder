import SwiftUI

/// The line under a transcript's title: "Today at 14:02 · 0:42 · 📍 Mitte, Berlin", the place on a second line when it
/// doesn't fit. The transcript card shows it twice: on the recording (start time and place, and from Stop the slot the
/// timer lands in) and on the saved transcript, at exactly the same place, so it stays put when one turns into the
/// other. Date, duration and place are separate texts, so the duration has a slot of its own (one text with " · "
/// gave the timer nowhere to land).
struct TranscriptDateLine<Duration: View>: View {
    let date: Date
    /// nil: no duration yet (recording).
    let duration: Duration?
    let place: String?
    /// How far the duration's slot has opened, 0...1: the recording's timer flying into it pushes the place aside as
    /// it goes (RecordView drives it frame by frame).
    var reveal: CGFloat = 1

    var body: some View {
        DateLineLayout(hasDuration: duration != nil, hasPlace: place != nil, reveal: reveal) {
            Text(date.relativeDayText())
            if let duration {
                Text("·").accessibilityHidden(true)
                    .opacity(reveal)
                duration
            }
            if let place {
                Text("·").accessibilityHidden(true)
                Label(place, systemImage: "location.fill")
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }
        }
        .lineLimit(1)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        // The place is looked up while recording and comes in a moment later: a short fade, nothing else moves.
        .animation(.easeOut(duration: 0.25), value: place)
    }
}

/// Date, then "·" and the duration, then "·" and the place, on one line when they fit; otherwise the place alone on a
/// second line and its "·" parked off-screen. `reveal` narrows the duration's part (its "·", the duration and the space
/// before them) while its slot opens; whether the line fits is decided with it open, so it doesn't wrap halfway.
/// A place that fits beside the date alone but not beside the date and the duration (a long name, larger text) moves
/// from the first line to the second with `reveal`, and the line's height grows with it: decided with the slot open
/// from the first frame, the place jumped to the second line at Stop and the header grew a line at once.
/// Not `ViewThatFits`: iOS 26 measures its candidates on SwiftUI's async render thread (see MetaLineLayout).
/// `nonisolated`, no captured state.
nonisolated struct DateLineLayout: Layout {
    var hasDuration: Bool
    var hasPlace: Bool
    var reveal: CGFloat = 1

    static let spacing: CGFloat = 6
    static let lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // As wide as it is open: the width it is placed in then always holds the open line (sized while opening, it
        // got less than the open line needs, and the place wrapped to a second line during the timer's flight). As
        // tall as it is now: a place on its way to the second line takes the height with it.
        let width = proposal.width ?? .infinity
        let open = bounds(of: plan(subviews, width: width, reveal: 1))
        let now = bounds(of: plan(subviews, width: width, reveal: reveal))
        return CGSize(width: open.width, height: now.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // A little slack, as in MetaLineLayout: a text's width can differ by a point between measuring passes.
        for (subview, frame) in zip(subviews, plan(subviews, width: bounds.width + 1, reveal: reveal)) {
            if let frame {
                subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                              proposal: ProposedViewSize(frame.size))
            } else {
                subview.place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .unspecified)
            }
        }
    }

    private func bounds(of frames: [CGRect?]) -> CGSize {
        frames.compactMap { $0 }.reduce(CGSize.zero) {
            CGSize(width: max($0.width, $1.maxX.rounded(.up)), height: max($0.height, $1.maxY))
        }
    }

    /// Subviews: the date; with a duration its "·" and the duration; with a place its "·" and the place. Each one's
    /// frame, nil when hidden.
    private func plan(_ subviews: Subviews, width: CGFloat, reveal: CGFloat) -> [CGRect?] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let expected = 1 + (hasDuration ? 2 : 0) + (hasPlace ? 2 : 0)
        guard sizes.count == expected else { return sizes.map { CGRect(origin: .zero, size: $0) } }
        let s = Self.spacing
        let date = sizes[0]
        let durationPart = hasDuration ? s + sizes[1].width + s + sizes[2].width : 0
        let placeIndex = hasDuration ? 3 : 1
        let placePart = hasPlace ? s + sizes[placeIndex].width + s + sizes[placeIndex + 1].width : 0
        let fitsOpen = !hasPlace || date.width + durationPart + placePart <= width
        let fitsClosed = !hasPlace || date.width + placePart <= width
        // How far the place is on its way to the second line: 0 on the first, 1 on the second.
        let down: CGFloat = fitsOpen ? 0 : (fitsClosed && hasDuration ? reveal : 1)
        let oneLine = sizes.map(\.height).max() ?? 0
        let firstOfTwo = max(date.height, hasDuration ? sizes[2].height : 0)
        let height = oneLine + (firstOfTwo - oneLine) * down               // the first line's

        var frames = [CGRect?](repeating: nil, count: sizes.count)
        func put(_ i: Int, x: CGFloat, maxWidth: CGFloat = .infinity, lineHeight: CGFloat) {
            let size = sizes[i]
            frames[i] = CGRect(x: x, y: (lineHeight - size.height) / 2, width: min(size.width, maxWidth),
                               height: size.height)
        }
        put(0, x: 0, maxWidth: width, lineHeight: height)
        var x = date.width
        if hasDuration {
            put(1, x: x + s, lineHeight: height)
            put(2, x: x + s + sizes[1].width + s, lineHeight: height)
            x += durationPart * reveal
        }
        guard hasPlace else { return frames }
        let dot = sizes[placeIndex], place = sizes[placeIndex + 1]
        // On the first line after the date (and the duration, as far as it is open) and its "·"; on the second at the
        // start. On its way it goes straight from one to the other, its "·" riding along in front of it until that
        // would leave the line's start (then parked: a 3 pt dot near the end of the move).
        let first = CGPoint(x: x + s + dot.width + s, y: (height - place.height) / 2)
        let second = CGPoint(x: 0, y: firstOfTwo + Self.lineSpacing)
        let at = CGPoint(x: first.x + (second.x - first.x) * down, y: first.y + (second.y - first.y) * down)
        frames[placeIndex + 1] = CGRect(x: at.x, y: at.y, width: min(place.width, width), height: place.height)
        let dotX = at.x - s - dot.width
        if dotX >= 0, down < 1 {
            frames[placeIndex] = CGRect(x: dotX, y: at.y + (place.height - dot.height) / 2, width: dot.width,
                                        height: dot.height)
        }
        return frames
    }
}
