import SwiftUI

/// The pipeline status line's activity mark: a pixel-art feather in front of the text that only jitters, a cell at a
/// time, the way a hand-drawn sprite "boils": it steps one cell up, back, one cell right, back, about twice a second.
/// On every new step of the pipeline (`step`) it shakes quickly for a moment, at most once every 1.5 s. The sprite is
/// one hand-drawn 16 × 16 grid (`sprite`) in the app's clay tones with a dark outline, so it reads on light and dark
/// backgrounds alike; its cells are whole device pixels (4 px at @3x) and filled without antialiasing, so the pixels
/// stay crisp at every Dynamic Type size. The layout frame is the status line's 20 × 16 pt; the drawing may overflow
/// it a little (as the three bodies did), so the line's height doesn't change. With Reduce Motion it stands still.
/// Decorative: hidden from VoiceOver (the text says what is happening). The same design, redrawn at 24 × 24, is the
/// app icon's glyph. Earlier versions let a code-drawn feather fall through the frame or rock through three tilts:
/// out of sight half the time, and too much movement for a mark next to text.
struct PixelFeatherIcon: View {
    var step: PipelineProgress.Step?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 20
    @State private var shakeUntil: Date?
    @State private var lastShake: Date?

    nonisolated private static let shake: TimeInterval = 0.5
    nonisolated private static let cooldown: TimeInterval = 1.5
    /// Cells of room around the sprite for the jitter.
    nonisolated private static let margin = 1

    var body: some View {
        // A cell is a whole number of device pixels: 20 pt at @3x is 60 px, a 16-cell sprite gets 4 px (1.33 pt) cells.
        let cell = max(1, (width * displayScale / CGFloat(Self.size)).rounded()) / displayScale
        let side = cell * CGFloat(Self.size + 2 * Self.margin)
        Group {
            if reduceMotion {
                Self.draw(offset: (0, 0), cell: cell)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    Self.draw(offset: Self.jitter(at: context.date, shaking: shakeUntil.map { context.date < $0 } ?? false),
                              cell: cell)
                }
            }
        }
        .frame(width: side, height: side)
        .frame(width: width, height: width * 0.8)       // the layout size; the drawing may overflow it
        .accessibilityHidden(true)
        .onChange(of: step) { _, new in
            guard new != nil else { return }
            let now = Date.now
            if let last = lastShake, now.timeIntervalSince(last) < Self.cooldown { return }
            lastShake = now
            shakeUntil = now.addingTimeInterval(Self.shake)
        }
    }

    /// The sprite's offset in cells at `date`: a slow four-step boil (still, up, still, right), or while shaking a
    /// quick walk through the four neighbours.
    nonisolated static func jitter(at date: Date, shaking: Bool) -> (x: Int, y: Int) {
        let t = date.timeIntervalSinceReferenceDate
        let steps = shaking ? [(1, 0), (0, -1), (-1, 0), (0, 1)] : [(0, 0), (0, -1), (0, 0), (1, 0)]
        return steps[Int(t / (shaking ? 0.06 : 0.45)) % steps.count]
    }

    private static func draw(offset: (x: Int, y: Int), cell: CGFloat) -> some View {
        Canvas { context, _ in
            for (y, line) in rows.enumerated() {
                for (x, letter) in line.enumerated() {
                    guard let colour = palette[letter] else { continue }
                    let rect = CGRect(x: CGFloat(x + margin + offset.x) * cell, y: CGFloat(y + margin + offset.y) * cell,
                                      width: cell, height: cell)
                    context.fill(Path(rect), with: .color(colour), style: FillStyle(antialiased: false))
                }
            }
        }
    }

    nonisolated private static let rows: [[Character]] = sprite.split(separator: "\n").map(Array.init)
    nonisolated private static let size = max(rows.count, rows.map(\.count).max() ?? 0)

    /// The palette's letters (the design tool's): o outline, q quill, r rachis, w sparkle, h highlight, v vane,
    /// d vane shade, H/m/D the mid section, t/T the tip.
    nonisolated private static let palette: [Character: Color] = [
        "o": rgb(46, 32, 28), "q": rgb(140, 102, 74), "r": rgb(118, 84, 62), "w": rgb(255, 252, 244),
        "h": rgb(252, 244, 230), "v": rgb(236, 220, 196), "d": rgb(206, 176, 146), "H": rgb(248, 220, 184),
        "m": rgb(230, 180, 132), "D": rgb(196, 138, 98), "t": rgb(206, 110, 72), "T": rgb(160, 76, 52),
    ]

    nonisolated private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255)
    }

    /// 16 × 16, quill at the bottom left, tip at the top right: a slender writing quill with a light rachis, three
    /// barb splits on the upper edge, cream to sand to a terracotta tip. Drawn by hand in a design pass over four
    /// styles (broad two-tone, quill, phoenix, soft) judged at the real status-line size; the quill read best.
    nonisolated private static let sprite = """
        .............oo.
        ...........ootto
        ..........otttTo
        .........oHtmTTo
        .......ooHHwmDo.
        ......oHoHwmDo..
        ......oHHwmDDo..
        ....oovHwmDoo...
        ...ovovhmDDo....
        ...ovvhvddo.....
        ...ovhvddo......
        ..ovhddoo.......
        ..ohdoo.........
        .oqoo...........
        oqo.............
        .o..............
        """
}
