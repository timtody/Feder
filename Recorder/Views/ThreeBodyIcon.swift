import SwiftUI

/// The pipeline status line's activity mark: three bodies under their mutual gravity in 3D, chaotic, as in the
/// three-body problem, seen through a slowly turning camera with perspective: a body nearer the viewer is larger,
/// more opaque and drawn in front, each is shaded like a small sphere (a highlight towards the top left), and each
/// leaves a tapering tail in 3D. The bodies differ in size and are drawn as glowing stars in one muted, dusty blue:
/// in dark mode pale blue-white cores in a blue glow, in light mode black cores in a faint blue glow; 20 × 16 pt,
/// scaled with Dynamic Type. It begins with the three bodies together in the centre, flung
/// out, and every new step of the pipeline (`step`) pulls them back together and flings them out again (`burst`), at
/// most once every 1.5 s, so steps that follow each other closely don't make it flicker. With Reduce Motion one
/// irregular moment stands still. Decorative: hidden from VoiceOver (the text says what is happening).
/// A first version showed the figure-eight orbit (Chenciner & Montgomery), one of the rare periodic solutions: too
/// regular for the three-body problem's character.
struct ThreeBodyIcon: View {
    /// The pipeline's step running now: each change pulls the bodies together and flings them out.
    var step: PipelineProgress.Step?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 20
    @State private var simulation = ThreeBodySimulation()

    var body: some View {
        Group {
            if reduceMotion {
                Self.draw(simulation.frame, dark: colorScheme == .dark)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    // Advancing here (main actor) and handing the Canvas a value: its renderer captures nothing else.
                    Self.draw(simulation.advance(to: context.date), dark: colorScheme == .dark)
                }
            }
        }
        .frame(width: width, height: width * 0.8)
        .accessibilityHidden(true)
        .onChange(of: step) { _, new in if new != nil { simulation.burst() } }
    }

    /// Each body's size, the largest first. All three are one dusty, muted blue (deep space, not a palette): in dark
    /// mode a pale blue-white core in a wide blue bloom (two layers, out to 4.5 radii), the larger bodies a shade
    /// brighter, in light mode a black core in a fainter bloom, since a pale star has nothing to shine against on
    /// white. The tails are as wide as the bloom at the body and taper to a point, a glow and a brighter core each:
    /// hairlines looked cheap against the bodies, and tails as wide as the core looked thin beside its bloom. (The speakers' blue, orange and green were tried first and read as a toy.)
    private static let sizes: [Double] = [1.2, 1.0, 0.8]
    /// The blue: hue 0.6 (a touch towards indigo), muted.
    private static let glowColour = Color(hue: 0.6, saturation: 0.55, brightness: 0.75)
    private static let coreColours: [Color] = [0.97, 0.9, 0.82].map { Color(hue: 0.6, saturation: 0.22, brightness: $0) }
    private static let darkTrail = Color(hue: 0.6, saturation: 0.5, brightness: 0.8)
    private static let lightTrail = Color(hue: 0.62, saturation: 0.45, brightness: 0.35)

    private static func draw(_ frame: ThreeBodyFrame, dark: Bool) -> some View {
        Canvas { context, size in
            let half = min(size.width, size.height) / 2
            func point(_ p: ThreeBodyFrame.Point) -> CGPoint {
                CGPoint(x: size.width / 2 + p.x * half, y: size.height / 2 - p.y * half)
            }
            let radius = half * 0.2
            let trailColour = dark ? darkTrail : lightTrail
            // Tails first (behind every body), two strokes a segment: a wide faint glow and a narrower bright core,
            // both the body's bloom's width at the newest end (wider than the core, which the bloom makes look bigger
            // than it is) and tapering to a point at the oldest, fading the same way.
            for (i, trail) in frame.trails.enumerated() where trail.count > 1 {
                for k in 1..<trail.count {
                    let age = Double(k) / Double(trail.count)          // 0 old ... 1 new
                    var segment = Path()
                    segment.move(to: point(trail[k - 1]))
                    segment.addLine(to: point(trail[k]))
                    let diameter = 2 * radius * trail[k].size * sizes[i]
                    context.stroke(segment, with: .color(glowColour.opacity((dark ? 0.16 : 0.1) * age * trail[k].light)),
                                   style: StrokeStyle(lineWidth: max(0.5, diameter * 2.2 * age), lineCap: .round))
                    context.stroke(segment, with: .color(trailColour.opacity((dark ? 0.6 : 0.4) * age * trail[k].light)),
                                   style: StrokeStyle(lineWidth: max(0.5, diameter * 1.15 * age * age), lineCap: .round))
                }
            }
            // Far bodies first: the near one covers them. Each: the bloom in two layers (a wide soft halo out to 4.5
            // radii and a brighter one out to 2.4), then the core with a small glint towards the top left.
            for (i, body) in frame.bodies.enumerated().sorted(by: { $0.element.depth < $1.element.depth }) {
                let r = radius * body.size * sizes[i]
                let c = point(body)
                context.opacity = body.light
                // The wide halo falls off fast (three blooms overlapping must not merge into one blob).
                let halo = Gradient(stops: [.init(color: glowColour.opacity(dark ? 0.4 : 0.22), location: 0),
                                            .init(color: glowColour.opacity(dark ? 0.08 : 0.05), location: 0.35),
                                            .init(color: glowColour.opacity(0), location: 1)])
                let far = r * 4.0
                context.fill(Path(ellipseIn: CGRect(x: c.x - far, y: c.y - far, width: 2 * far, height: 2 * far)),
                             with: .radialGradient(halo, center: c, startRadius: 0, endRadius: far))
                let glow = Gradient(stops: [.init(color: glowColour.opacity(dark ? 0.9 : 0.55), location: 0),
                                            .init(color: glowColour.opacity(dark ? 0.35 : 0.2), location: 0.45),
                                            .init(color: glowColour.opacity(0), location: 1)])
                let reach = r * 2.2
                context.fill(Path(ellipseIn: CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach)),
                             with: .radialGradient(glow, center: c, startRadius: 0, endRadius: reach))
                let core = dark ? coreColours[i] : Color.black
                let shading = Gradient(stops: [.init(color: dark ? .white : Color.white.opacity(0.3), location: 0),
                                               .init(color: core, location: 0.45),
                                               .init(color: core.opacity(0.85), location: 1)])
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(shading, center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.3),
                                                   startRadius: 0, endRadius: r * 1.2))
                context.opacity = 1
            }
        }
    }
}

/// What the icon draws at one moment: the bodies and their trails projected into [-1, 1] (y up), with their depth
/// (-1 far ... 1 near), size factor and brightness.
nonisolated struct ThreeBodyFrame: Sendable {
    struct Point: Sendable {
        var x: Double
        var y: Double
        var depth: Double
        var size: Double
        var light: Double
    }

    var bodies: [Point] = []
    var trails: [[Point]] = []
}

/// Three equal masses under softened gravity (G = 1, softening 0.5: close passes swing past instead of whipping), in a
/// gentle pull towards the centre (k = 1.6, so no body leaves the picture) and a weak thermostat (friction 0.1 and
/// random nudges at temperature 0.8, Langevin), integrated with velocity Verlet in 0.004 steps, 1.9 time units per
/// second on screen (1.3 read as slow, 2.2 as hectic). Without the thermostat two bodies often locked into a pair for good (in 6 of 20 starts over 900
/// time units); with it, no pair lasted longer than 6 time units in 16 starts, the bodies stay within about 2 units
/// (p99), and two copies 1e-8 apart part visibly within about a minute: chaotic, never repeating. Tuned in a scratch
/// replay (numpy), 2026-10-05. The camera follows the system's size smoothly and turns around the vertical axis.
/// A burst (the start, and each new pipeline step): for `gatherTime` the bodies are drawn in towards the centre
/// (velocities steered at the centre and damped, so they arrive together instead of shooting through), then let go
/// with fresh speeds pointing outward (`flingSpeed`), from where gravity takes over again.
final class ThreeBodySimulation {
    private static let softening = 0.5
    private static let pull = 1.6
    private static let friction = 0.1
    private static let temperature = 0.8
    private static let step = 0.004
    private static let speed = 1.9                   // time units per second on screen (2.2 was a touch hectic)
    private static let turn = 0.35                    // camera radians per second
    private static let tilt = 0.45                    // radians the camera looks down
    private static let trailLength = 34               // positions per trail, one per frame: about half a second
    private static let gatherTime = 0.35              // seconds the bodies are drawn to the centre
    private static let flingSpeed = 2.4               // their speed when let go (mean speed in free motion is ~1.2)
    private static let burstCooldown = 1.5            // seconds before the next burst can start

    private var p: [SIMD3<Double>]
    private var v: [SIMD3<Double>]
    private var trails: [[SIMD3<Double>]] = [[], [], []]
    private var rng = SplitMix(seed: UInt64.random(in: 1...UInt64.max))
    private var last: Date?
    private var angle = 0.0
    private var extent = 1.0
    private var gathering: TimeInterval?              // seconds left of the gather; nil: free
    private var lastBurst: Date?
    private(set) var frame = ThreeBodyFrame()

    init() {
        var r = rng
        p = (0..<3).map { _ in SIMD3(r.uniform() * 2 - 1, r.uniform() * 2 - 1, r.uniform() * 2 - 1) }
        v = (0..<3).map { _ in SIMD3(r.gaussian(), r.gaussian(), r.gaussian()) * 0.6 }
        rng = r
        // Centre of mass at rest in the middle (the pull and the camera aim there).
        let centre = p.reduce(.zero, +) / 3, mean = v.reduce(.zero, +) / 3
        p = p.map { $0 - centre }
        v = v.map { $0 - mean }
        for _ in 0..<Int(4 / Self.step) { integrate() }        // past the made-up start: an irregular moment
        extent = max(0.8, p.map { ($0 * $0).sum().squareRoot() }.max() ?? 1)
        // Then the opening: the three together in the centre, flung out.
        fling()
        frame = project()
    }

    /// Pulls the bodies together and flings them out (at most once per `burstCooldown`); the start is one.
    func burst(at date: Date = .now) {
        if let last = lastBurst, date.timeIntervalSince(last) < Self.burstCooldown { return }
        lastBurst = date
        gathering = Self.gatherTime
    }

    /// The bodies close together at the centre, each sent outward along its own direction, a little above the
    /// speed free motion has, so they fly apart and gravity and the pull bring them back into their dance.
    private func fling() {
        for i in 0..<3 {
            var d = SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())
            d /= max((d * d).sum().squareRoot(), 1e-6)
            p[i] = d * 0.08
            v[i] = d * Self.flingSpeed
        }
        let centre = p.reduce(.zero, +) / 3, mean = v.reduce(.zero, +) / 3
        for i in 0..<3 { p[i] -= centre; v[i] -= mean }
        trails = [[], [], []]
    }

    /// Advances to `date` (at most 0.1 s at once: after a pause the bodies don't jump) and returns the frame.
    func advance(to date: Date) -> ThreeBodyFrame {
        let dt = min(max(0, last.map { date.timeIntervalSince($0) } ?? 0), 0.1)
        last = date
        guard dt > 0 else { return frame }
        if let left = gathering {
            gather(dt: dt, left: left)
            if left - dt <= 0 { gathering = nil; fling() } else { gathering = left - dt }
        } else {
            for _ in 0..<max(1, Int((dt * Self.speed / Self.step).rounded())) { integrate() }
        }
        angle += dt * Self.turn
        let reach = p.map { ($0 * $0).sum().squareRoot() }.max() ?? 1
        extent += (max(0.8, reach) - extent) * min(1, dt * 1.5)
        for i in 0..<3 {
            trails[i].append(p[i])
            if trails[i].count > Self.trailLength { trails[i].removeFirst() }
        }
        frame = project()
        return frame
    }

    /// The gather: every body's position eases towards the centre over the time left (it arrives as the time runs
    /// out), the trails following, so the three meet in the middle together.
    private func gather(dt: TimeInterval, left: TimeInterval) {
        let share = min(1, dt / max(left, 1e-6))
        for i in 0..<3 { p[i] -= p[i] * share }
    }

    private func integrate() {
        let h = Self.step
        var a = accelerations()
        for i in 0..<3 { v[i] += a[i] * (h / 2); p[i] += v[i] * h }
        a = accelerations()
        let sigma = (2 * Self.friction * Self.temperature * h).squareRoot()
        for i in 0..<3 {
            v[i] += a[i] * (h / 2)
            v[i] += -Self.friction * v[i] * h + SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()) * sigma
        }
        let mean = v.reduce(.zero, +) / 3
        for i in 0..<3 { v[i] -= mean }
    }

    private func accelerations() -> [SIMD3<Double>] {
        let e2 = Self.softening * Self.softening
        return (0..<3).map { i in
            var a = -Self.pull * p[i]
            for j in 0..<3 where j != i {
                let d = p[j] - p[i]
                let r2 = (d * d).sum() + e2
                a += d / (r2 * r2.squareRoot())
            }
            return a
        }
    }

    private func project() -> ThreeBodyFrame {
        let (ca, sa, ct, st) = (cos(angle), sin(angle), cos(Self.tilt), sin(Self.tilt))
        let distance = 3.5                                     // camera distance, in units of `extent`
        func view(_ q: SIMD3<Double>) -> ThreeBodyFrame.Point {
            let q = q / (extent * 1.25)
            let x1 = q.x * ca + q.z * sa, z1 = -q.x * sa + q.z * ca      // turn around the vertical axis
            let y2 = q.y * ct - z1 * st, z2 = q.y * st + z1 * ct           // look down a little
            let s = distance / (distance - z2)
            let depth = max(-1, min(1, z2))
            return .init(x: x1 * s * 0.92, y: y2 * s * 0.92, depth: depth, size: s,
                         light: 0.55 + 0.45 * (depth + 1) / 2)
        }
        return ThreeBodyFrame(bodies: p.map(view), trails: trails.map { $0.map(view) })
    }
}

/// A small seeded generator (SplitMix64) with uniform and Gaussian draws, for the thermostat's nudges.
nonisolated struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian() -> Double {                       // Box-Muller
        let u = max(uniform(), 1e-12), w = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * w)
    }
}
