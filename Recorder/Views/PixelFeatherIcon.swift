import SwiftUI

/// The pipeline status line's activity mark: a small pixel-art feather hovering in front of the text as a feather
/// hangs in the air, rocking slowly from tilted left through upright to tilted right and bobbing up and down, drawn
/// from three hand-made sprites on a grid of whole cells, so it moves in pixel steps and stays crisp at every Dynamic
/// Type size. On every new step of the pipeline (`step`) it flutters for a moment (the tilts alternate quickly), at
/// most once every 1.5 s. Clay tones like the app's other marks. With Reduce Motion it rests upright. Decorative:
/// hidden from VoiceOver (the text says what is happening). Replaced the three bodies of `ThreeBodyIcon` (kept for
/// other apps of the family). A first version let the feather fall through the frame and come back in at the top: out
/// of sight half the time, which a working mark must not be.
struct PixelFeatherIcon: View {
    var step: PipelineProgress.Step?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 20
    @State private var flutterUntil: Date?
    @State private var lastFlutter: Date?

    nonisolated private static let columns = 16
    nonisolated private static let rows = 13
    nonisolated private static let period: TimeInterval = 4.8        // one rock: left, upright, right, upright
        nonisolated private static let flutter: TimeInterval = 0.6
    nonisolated private static let cooldown: TimeInterval = 1.5

    var body: some View {
        let cell = width / CGFloat(Self.columns)
        Group {
            if reduceMotion {
                Self.draw(frame: .upright, column: (Self.columns - Sprite.upright.width) / 2,
                          row: (Self.rows - Sprite.upright.height) / 2, cell: cell, dark: colorScheme == .dark)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let placed = Self.place(at: context.date, fluttering: flutterUntil.map { context.date < $0 } ?? false)
                    Self.draw(frame: placed.frame, column: placed.column, row: placed.row, cell: cell, dark: colorScheme == .dark)
                }
            }
        }
        .frame(width: cell * CGFloat(Self.columns), height: cell * CGFloat(Self.rows))
        .accessibilityHidden(true)
        .onChange(of: step) { _, new in
            guard new != nil else { return }
            let now = Date.now
            if let last = lastFlutter, now.timeIntervalSince(last) < Self.cooldown { return }
            lastFlutter = now
            flutterUntil = now.addingTimeInterval(Self.flutter)
        }
    }

    /// Where the feather is at `date`: it bobs a cell up and down and rocks through the tilts, each a quarter of the
    /// period, upright between them. Fluttering, the tilts alternate quickly.
    nonisolated static func place(at date: Date, fluttering: Bool) -> (frame: Sprite, column: Int, row: Int) {
        let t = date.timeIntervalSinceReferenceDate
        let u = (t / period).truncatingRemainder(dividingBy: 1)
        let frame: Sprite
        if fluttering {
            frame = sin(2 * .pi * 7 * t) > 0 ? .left : .right
        } else {
            frame = u < 0.25 ? .upright : u < 0.5 ? .right : u < 0.75 ? .upright : .left
        }
        let bob = Int((1.2 * sin(2 * .pi * t / 2.4)).rounded())
        let sway = Int((1.0 * sin(2 * .pi * u)).rounded())
        return (frame, (columns - frame.width) / 2 + sway, (rows - frame.height) / 2 + bob)
    }

    private static func draw(frame: Sprite, column: Int, row: Int, cell: CGFloat, dark: Bool) -> some View {
        Canvas { context, _ in
            let palette: [Character: Color] = dark
                ? ["s": Color(hue: 0.04, saturation: 0.35, brightness: 0.6),
                   "v": Color(hue: 0.07, saturation: 0.3, brightness: 0.82),
                   "h": Color(hue: 0.10, saturation: 0.2, brightness: 0.96)]
                : ["s": Color(hue: 0.05, saturation: 0.5, brightness: 0.38),
                   "v": Color(hue: 0.07, saturation: 0.45, brightness: 0.55),
                   "h": Color(hue: 0.08, saturation: 0.35, brightness: 0.72)]
            for (y, line) in frame.lines.enumerated() {
                for (x, char) in line.enumerated() {
                    guard let colour = palette[char] else { continue }
                    let cx = column + x, cy = row + y
                    guard (0..<columns).contains(cx), (0..<rows).contains(cy) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(cx) * cell, y: CGFloat(cy) * cell, width: cell, height: cell)),
                                 with: .color(colour))
                }
            }
        }
    }

    /// The three sprites: `s` shaft, `v` vane, `h` the vane's light edge, `.` nothing. The quill's tip is at the
    /// bottom left, the feather's tip at the top right.
    nonisolated enum Sprite {
        case left, upright, right

        var lines: [[Character]] { Array(text.split(separator: "\n").map { Array($0) }) }
        var width: Int { lines.map(\.count).max() ?? 0 }
        var height: Int { lines.count }

        private var text: String {
            switch self {
            case .upright: """
                ........hv
                .......hvv
                ......hvvv
                .....hvvvv
                ....hvvvvs
                ....vv.vs.
                ...hvvvs..
                ...vvvs...
                ..hvvs....
                ..vvs.....
                ...s......
                ..s.......
                .s........
                """
            case .right: """
                .........hvvv
                ......hvvvvvv
                ...hvvvvvvvs.
                ..vvvv.vvss..
                .vvvvvss.....
                ..vvss.......
                ...s.........
                ..s..........
                .s...........
                """
            case .left: """
                .....hv
                .....vv
                ....hvv
                ....vvv
                ...hvvs
                ...vvvs
                ...v.s.
                ..hvvs.
                ..vvs..
                ..vvs..
                ...s...
                ...s...
                ..s....
                ..s....
                """
            }
        }
    }
}
