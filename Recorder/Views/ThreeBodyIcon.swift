import SwiftUI

/// The pipeline status line's activity mark: three bodies under their mutual gravity in 3D, chaotic, as in the
/// three-body problem, seen through a slowly turning camera with perspective: a body nearer the viewer is larger,
/// brighter and drawn in front, each is shaded like a small planet (a highlight towards the top left, a faint glow),
/// and each leaves a comet tail. The bodies differ a little in size and are three warm clay tones in dark mode and
/// dark terracotta in light mode (`ThreeBodyLook`: the settings the user chose in the tuner on 2026-10-06, named as
/// there). 20 × 16 pt, scaled with Dynamic Type. On every new step of the pipeline (`step`) the three turn together
/// around the centre, flat on the screen, laid over their own motion and tapering out (`ThreeBodySimulation.burst`),
/// at most once every 1.5 s, so steps that follow each other closely don't make it flicker. With Reduce Motion one
/// irregular moment stands still. Decorative: hidden from VoiceOver (the text says what is happening).
/// A first version showed the figure-eight orbit (Chenciner & Montgomery), one of the rare periodic solutions: too
/// regular for the three-body problem's character. The tuner (a web page with the same simulation and drawing in
/// JavaScript, sliders for every setting here, previews in both appearances) is how the look was found; its values
/// transfer one to one.
struct ThreeBodyIcon: View {
    /// The pipeline's step running now: each change spins the bodies.
    var step: PipelineProgress.Step?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = ThreeBodyLook.iconWidth
    @State private var simulation = ThreeBodySimulation()

    /// The Canvas is this much larger than the icon's layout frame on each side: a Canvas clips to its own bounds,
    /// and a body at the edge of the scene, with its size and glow, was cut off at the frame's corner.
    private static let overflow = 1.8

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
        .frame(width: width * Self.overflow, height: width * 0.8 * Self.overflow)
        .frame(width: width, height: width * 0.8)         // the layout size; the drawing may overflow it
        .accessibilityHidden(true)
        .onChange(of: step) { _, new in if new != nil { simulation.burst() } }
    }

    private static func draw(_ frame: ThreeBodyFrame, dark: Bool) -> some View {
        Canvas { context, size in
            typealias L = ThreeBodyLook
            let half = min(size.width, size.height) / 2 / overflow   // the scene's scale is the layout frame's
            func point(_ p: ThreeBodyFrame.Point) -> CGPoint {
                CGPoint(x: size.width / 2 + p.x * half, y: size.height / 2 - p.y * half)
            }
            let radius = half * L.radiusFactor
            let drift = L.hueDrift * frame.time                       // the shimmer, when on: every hue cycles slowly
            func wrap(_ h: Double) -> Double { (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }
            func hue(_ i: Int) -> Double { wrap(L.hues[i] + drift) }
            // The core colour per body and appearance, its rim (the two-tone's second hue) and its trail.
            func core(_ i: Int, hue h: Double) -> Color {
                dark ? Color(hue: h, saturation: L.saturations[i], brightness: L.brightnesses[i])
                     : Color(hue: h, saturation: L.lightCoreSaturation, brightness: L.lightCoreBrightness)
            }
            func trailColour(_ i: Int) -> Color {
                dark ? core(i, hue: hue(i))
                     : Color(hue: wrap(hue(i) + 0.02), saturation: L.lightTrailSaturation, brightness: L.lightTrailBrightness)
            }
            // Trails first (behind every body): one round-capped stroke per step, thinner and fainter towards the old
            // end (the taper exponent makes it slim quickly), the width at the body the body's own.
            for (i, trail) in frame.trails.enumerated() where trail.count > 1 {
                let colour = trailColour(i)
                for k in 1..<trail.count {
                    let age = Double(k) / Double(trail.count)          // 0 old ... 1 new
                    var segment = Path()
                    segment.move(to: point(trail[k - 1]))
                    segment.addLine(to: point(trail[k]))
                    let width = radius * L.trailWidth * pow(age, L.trailTaper) * trail[k].size * L.sizes[i]
                    context.stroke(segment,
                                   with: .color(colour.opacity((dark ? L.trailOpacity : L.trailOpacityLight) * age * trail[k].light)),
                                   style: StrokeStyle(lineWidth: max(0.3, width), lineCap: .round))
                }
            }
            // Far bodies first: the near one covers them. Each: a faint glow, then the planet's shading.
            for (i, body) in frame.bodies.enumerated().sorted(by: { $0.element.depth < $1.element.depth }) {
                let r = radius * body.size * L.sizes[i]
                let c = point(body)
                context.opacity = body.light
                if L.glowOpacity > 0 {
                    let glowColour = dark ? core(i, hue: hue(i))
                                          : Color(hue: hue(i), saturation: L.lightCoreSaturation, brightness: 0.6)
                    let glow = Gradient(stops: [.init(color: glowColour.opacity(L.glowOpacity * (dark ? 1 : 0.6)), location: 0),
                                                .init(color: glowColour.opacity(0), location: 1)])
                    let reach = r * 1.9
                    context.fill(Path(ellipseIn: CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach)),
                                 with: .radialGradient(glow, center: c, startRadius: r * 0.6, endRadius: reach))
                }
                let shading = Gradient(stops: [.init(color: .white.opacity(dark ? L.highlight : L.highlightLight), location: 0),
                                               .init(color: core(i, hue: hue(i)), location: L.shadeStop),
                                               .init(color: core(i, hue: wrap(hue(i) + L.rimHueShift)).opacity(L.edgeOpacity), location: 1)])
                let offset = r * L.highlightOffset
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(shading, center: CGPoint(x: c.x - offset, y: c.y - offset),
                                                   startRadius: 0, endRadius: r * 1.35))
                context.opacity = 1
            }
        }
    }
}

/// The look, as tuned (the tuner's names; its "Clay" scheme).
nonisolated enum ThreeBodyLook {
    static let iconWidth: CGFloat = 20
    static let radiusFactor = 0.22                    // body radius, of the frame's half height
    static let sizes = [1.077, 1.0, 0.932]            // per body
    static let highlight = 0.95                       // the glint's opacity, dark mode
    static let highlightLight = 0.45
    static let highlightOffset = 0.35                 // towards the top left, in radii
    static let shadeStop = 0.5                        // where the shading reaches the core colour
    static let edgeOpacity = 0.8                      // at the rim
    static let lightMin = 0.55                        // brightness of the farthest body
    static let trailLength = 34                       // sixtieths of a second
    static let trailWidth = 2.0                       // at the body, in radii: the body's width
    static let trailTaper = 1.4                       // exponent: slims quickly
    static let trailOpacity = 0.75
    static let trailOpacityLight = 0.5
    static let hues = [0.04, 0.07, 0.10]              // terracotta, clay, sand
    static let saturations = [0.3, 0.3, 0.3]
    static let brightnesses = [0.85, 0.8, 0.75]       // dark mode cores
    static let rimHueShift = 0.0                      // a two-tone rim, off
    static let hueDrift = 0.0                         // cycles per second (a shimmer), off
    static let glowOpacity = 0.08
    static let lightCoreSaturation = 0.35
    static let lightCoreBrightness = 0.35
    static let lightTrailSaturation = 0.3
    static let lightTrailBrightness = 0.45
}

/// What the icon draws at one moment: the bodies and their trails projected into [-1, 1] (y up), with their depth
/// (-1 far ... 1 near), size factor and brightness, and the simulation's clock (for the shimmer).
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
    var time: TimeInterval = 0
}

/// Three equal masses under softened gravity (G = 1, softening 0.5: close passes swing past instead of whipping), in a
/// gentle pull towards the centre (k = 1.6, so no body leaves the picture) and a weak thermostat (friction 0.1 and
/// random nudges at temperature 0.8, Langevin), integrated with velocity Verlet in 0.004 steps, 1.26 time units per
/// second on screen. Without the thermostat two bodies often locked into a pair for good (in 6 of 20 starts over 900
/// time units); with it, no pair lasted longer than 6 time units in 16 starts, the bodies stay within about 2 units
/// (p99), and two copies 1e-8 apart part visibly within about a minute: chaotic, never repeating. Tuned in a scratch
/// replay (numpy), 2026-10-05. The camera follows the system's size smoothly and turns around the vertical axis.
/// Time advances in slices of a sixtieth of a second, one trail point each, so the trails look the same on a 60 and
/// a 120 Hz display. A burst (the start, and each new pipeline step) is a spin: the three turn together around the
/// centre in the plane of the screen, the way they are already turning (the sign of their angular momentum about the
/// view axis, so no body is dragged against its own motion), `spinTurns` over `spinTime`, the speed ramping up over
/// the first `spinAttack` of the time and then falling off as (time left)^`spinTaper`, laid over the running motion
/// (gravity never stops), so it tapers out into their own movement with nothing freezing or jumping. (Earlier bursts
/// gathered the bodies and flung them out, then spun them on a ring: both read as a jolt.)
final class ThreeBodySimulation {
    private static let softening = 0.5
    private static let pull = 1.6
    private static let friction = 0.1
    private static let temperature = 0.8
    private static let step = 0.004
    private static let speed = 1.259                  // time units per second on screen
    private static let turn = 0.244                   // camera radians per second
    private static let tilt = 0.5                     // radians the camera looks down
    private static let distance = 3.0                 // camera distance, in units of `extent`
    private static let zoom = 0.95                    // the scene's size in the frame
    private static let slice = 1.0 / 60               // the trail's clock
    private static let spinTime = 1.1
    private static let spinTurns = 1.5
    private static let spinAttack = 0.12
    private static let spinTaper = 2.5
    private static let burstCooldown = 1.5

    private var p: [SIMD3<Double>]
    private var v: [SIMD3<Double>]
    private var trails: [[SIMD3<Double>]] = [[], [], []]
    private var rng = SplitMix(seed: UInt64.random(in: 1...UInt64.max))
    private var last: Date?
    private var pending: TimeInterval = 0             // time not yet sliced
    private var time: TimeInterval = 0
    private var angle = 0.0
    private var extent = 1.0
    private var spin: (left: TimeInterval, direction: Double)?
    private var lastBurst: Date?
    private var queued = false                        // a burst asked for inside the cooldown
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
        startSpin()                                             // the opening
        frame = project()
    }

    /// Spins the bodies (at most once per `burstCooldown`: a burst inside it waits for its end); the start is one.
    func burst(at date: Date = .now) {
        if let last = lastBurst, date.timeIntervalSince(last) < Self.burstCooldown {
            queued = true                                   // fires when the cooldown ends (a quick first step, e.g.)
            return
        }
        lastBurst = date
        queued = false
        startSpin()
    }

    /// Advances to `date` (at most 0.1 s at once: after a pause the bodies don't jump) and returns the frame.
    func advance(to date: Date) -> ThreeBodyFrame {
        let dt = min(max(0, last.map { date.timeIntervalSince($0) } ?? 0), 0.1)
        last = date
        guard dt > 0 else { return frame }
        if queued, let last = lastBurst, date.timeIntervalSince(last) >= Self.burstCooldown { burst(at: date) }
        pending += dt
        while pending >= Self.slice {
            pending -= Self.slice
            advanceSlice(Self.slice)
        }
        frame = project()
        return frame
    }

    /// One slice: the bodies' own motion, the spin laid over it, the camera, one trail point.
    private func advanceSlice(_ dt: TimeInterval) {
        time += dt
        for _ in 0..<max(1, Int((dt * Self.speed / Self.step).rounded())) { integrate() }
        if let (left, direction) = spin {
            let total = Self.spinTurns * 2 * .pi * direction
            let u = min(1, 1 - left / Self.spinTime)
            let ramp = Self.spinAttack > 0 ? min(1, u / Self.spinAttack) : 1
            let dTheta = total * (Self.spinTaper + 1) * pow(1 - u, Self.spinTaper) * ramp / Self.spinTime * dt
            let (ex, ey) = screenAxes()
            for i in 0..<3 {
                p[i] = Self.turned(p[i], by: dTheta, ex: ex, ey: ey)
                v[i] = Self.turned(v[i], by: dTheta, ex: ex, ey: ey)
            }
            spin = left - dt > 0 ? (left - dt, direction) : nil
        }
        angle += dt * Self.turn
        let reach = p.map { ($0 * $0).sum().squareRoot() }.max() ?? 1
        extent += (max(0.8, reach) - extent) * min(1, dt * 1.5)
        for i in 0..<3 {
            trails[i].append(p[i])
            if trails[i].count > ThreeBodyLook.trailLength { trails[i].removeFirst() }
        }
    }

    /// The spin goes the way the three already turn on screen (the sign of their angular momentum about the view
    /// axis); when they hardly turn, counter-clockwise.
    private func startSpin() {
        let (ex, ey) = screenAxes()
        var moment = 0.0
        for i in 0..<3 {
            let a = (p[i] * ex).sum(), b = (p[i] * ey).sum(), va = (v[i] * ex).sum(), vb = (v[i] * ey).sum()
            moment += a * vb - b * va
        }
        spin = (Self.spinTime, moment < -0.05 ? -1 : 1)
    }

    /// The world vectors that project onto the screen's x and y (the inverse of `project`'s rotation and tilt): the
    /// plane the spin turns in.
    private func screenAxes() -> (SIMD3<Double>, SIMD3<Double>) {
        let (ca, sa, ct, st) = (cos(angle), sin(angle), cos(Self.tilt), sin(Self.tilt))
        return (SIMD3(ca, 0, sa), SIMD3(st * sa, ct, -st * ca))
    }

    /// `q` turned by `theta` in the plane of `ex` and `ey` (its component along the view axis unchanged).
    private static func turned(_ q: SIMD3<Double>, by theta: Double, ex: SIMD3<Double>, ey: SIMD3<Double>) -> SIMD3<Double> {
        let a = (q * ex).sum(), b = (q * ey).sum()
        let (c, s) = (cos(theta), sin(theta))
        let a2 = a * c - b * s, b2 = a * s + b * c
        return q + (a2 - a) * ex + (b2 - b) * ey
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
        func view(_ q: SIMD3<Double>) -> ThreeBodyFrame.Point {
            let q = q / (extent * 1.25)
            let x1 = q.x * ca + q.z * sa, z1 = -q.x * sa + q.z * ca      // turn around the vertical axis
            let y2 = q.y * ct - z1 * st, z2 = q.y * st + z1 * ct           // look down a little
            let s = Self.distance / (Self.distance - z2)
            let depth = max(-1, min(1, z2))
            return .init(x: x1 * s * Self.zoom, y: y2 * s * Self.zoom, depth: depth, size: s,
                         light: ThreeBodyLook.lightMin + (1 - ThreeBodyLook.lightMin) * (depth + 1) / 2)
        }
        return ThreeBodyFrame(bodies: p.map(view), trails: trails.map { $0.map(view) }, time: time)
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
