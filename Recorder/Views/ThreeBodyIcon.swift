import SwiftUI

/// The pipeline status line's activity mark: three bodies chasing each other along the figure-eight orbit of the
/// three-body problem (Chenciner & Montgomery, 2000), three equal masses on one curve, each a third of a period behind
/// the next. The orbit is the real one, integrated once from its published initial conditions (`FigureEight`), so the
/// bodies speed up through the crossing and slow down in the loops as they do there; a short fading trail follows each.
/// Drawn in the status text's secondary colour, 22 × 11 pt (scaled with Dynamic Type). With Reduce
/// Motion the bodies stand still. Decorative: hidden from VoiceOver (the text says what is happening).
struct ThreeBodyIcon: View {
    /// Seconds per orbit on screen.
    var period: TimeInterval = 2.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 22

    var body: some View {
        Group {
            if reduceMotion {
                orbit(phase: 0.1)                         // a pose with the three bodies apart
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    orbit(phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
                }
            }
        }
        .frame(width: width, height: width * 0.5)
        .accessibilityHidden(true)
    }

    private func orbit(phase: Double) -> some View {
        Canvas { context, size in
            let radius = size.width * 0.095
            // The orbit spans about ±1.08 × ±0.34: one scale for both axes keeps its shape, centred in the frame.
            let scale = (size.width - 2 * radius) / (2 * FigureEight.halfWidth)
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: size.width / 2 + p.x * scale, y: size.height / 2 - p.y * scale)
            }
            let colour = Color(uiColor: .secondaryLabel)
            for body in 0..<3 {
                let own = phase + Double(body) / 3
                for step in stride(from: Self.trail, through: 1, by: -1) {          // oldest first, under the body
                    let back = Double(step) * Self.trailSpacing
                    let fade = 1 - Double(step) / Double(Self.trail + 1)
                    let r = radius * (0.45 + 0.4 * fade)
                    let c = point(FigureEight.position(at: own - back))
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(colour.opacity(0.45 * fade)))
                }
                let c = point(FigureEight.position(at: own))
                context.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .color(colour))
            }
        }
    }

    /// Trail dots per body, and how far apart (fractions of the orbit).
    private static let trail = 8
    private static let trailSpacing = 0.012
}

/// The figure-eight solution of the planar three-body problem (G = 1, unit masses), from Chenciner & Montgomery's
/// initial conditions: bodies at ±(0.97000436, −0.24308753) and the origin, the middle one moving with
/// (−0.93240737, −0.86473146), the other two with half that, reversed; period 6.32591398. Integrated once (RK4) into
/// `samples`: body 1's position over one period. Since it is a choreography, the other two are the same curve a third
/// and two thirds of a period on. Pure, computed on first use (well under a millisecond).
nonisolated enum FigureEight {
    static let period = 6.32591398
    static let count = 720
    static let halfWidth = 1.1

    static let samples: [CGPoint] = {
        var r: [SIMD2<Double>] = [SIMD2(0.97000436, -0.24308753), SIMD2(-0.97000436, 0.24308753), SIMD2(0, 0)]
        let v3 = SIMD2(-0.93240737, -0.86473146)
        var v: [SIMD2<Double>] = [-v3 / 2, -v3 / 2, v3]
        func accelerations(_ r: [SIMD2<Double>]) -> [SIMD2<Double>] {
            (0..<3).map { i in
                (0..<3).filter { $0 != i }.reduce(SIMD2<Double>(0, 0)) { a, j in
                    let d = r[j] - r[i]
                    let dist = (d * d).sum().squareRoot()
                    return a + d / (dist * dist * dist)
                }
            }
        }
        let substeps = 8
        let h = period / Double(count * substeps)
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(CGPoint(x: r[0].x, y: r[0].y))
            for _ in 0..<substeps {                                // classic RK4 on positions and velocities
                let a1 = accelerations(r)
                let r2 = zip(r, v).map { $0 + $1 * (h / 2) }, v2 = zip(v, a1).map { $0 + $1 * (h / 2) }
                let a2 = accelerations(r2)
                let r3 = zip(r, v2).map { $0 + $1 * (h / 2) }, v3 = zip(v, a2).map { $0 + $1 * (h / 2) }
                let a3 = accelerations(r3)
                let r4 = zip(r, v3).map { $0 + $1 * h }, v4 = zip(v, a3).map { $0 + $1 * h }
                let a4 = accelerations(r4)
                for i in 0..<3 {
                    r[i] += (v[i] + 2 * v2[i] + 2 * v3[i] + v4[i]) * (h / 6)
                    v[i] += (a1[i] + 2 * a2[i] + 2 * a3[i] + a4[i]) * (h / 6)
                }
            }
        }
        return out
    }()

    /// Body 1's position at `phase` (fractions of the period, any real number), between the two nearest samples.
    static func position(at phase: Double) -> CGPoint {
        let x = (phase - phase.rounded(.down)) * Double(count)
        let i = Int(x) % count, j = (i + 1) % count
        let t = x - x.rounded(.down)
        let a = samples[i], b = samples[j]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
