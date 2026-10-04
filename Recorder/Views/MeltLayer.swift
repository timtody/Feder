import SwiftUI

/// The Stop melting into the transcript's bottom toolbar: the Stop's Liquid Glass disc stretches, necks and splits into
/// the bar's two glass shapes (Share and Speakers in one capsule, Delete a circle) while its red square shrinks away
/// and the bar's symbols fade in. The system bar can't do this itself: a toolbar item is at most a 48 pt glass, and
/// only a regular-glass capsule at least ~92 pt wide morphed into the bar's group (a round 48 pt Stop or a red
/// `.glassProminent` one just faded, and Delete never split off the same blob). So these are replicas: two glass shapes
/// in a GlassEffectContainer that start on top of each other on the Stop (one blob) and move to the bar's measured
/// frames; then the real bar is shown under them in the same frame and they go (TranscriptCard.handOver). Only drawn:
/// no touches, hidden from VoiceOver; users and tests always reach the real toolbar.
struct MeltLayer: View {
    /// nil: on standby, as the Stop (TranscriptCard).
    let clock: TurnClock?
    let stop: CGRect
    let bar: (group: CGRect, delete: CGRect)

    /// From the Stop to the bar, on the turn's clock. A spring of 0.45 s with a little bounce (0.25), like `.bouncy`,
    /// eased onto its end over its last 0.2 s, so it is there at exactly 0.55 s. A SwiftUI `.bouncy(duration: 0.5)`
    /// with completion `.removed` (at `.logicallyComplete` it was still ~2 pt off, a visible jump when the real bar
    /// took over) only completed 1.0–1.4 s after Stop: the bar looked finished for over half a second before its
    /// buttons worked.
    nonisolated static let duration: TimeInterval = 0.55
    nonisolated private static let response: TimeInterval = 0.45
    nonisolated private static let damping = 0.75                       // 1 - bounce

    /// 0 on the Stop, 1 on the bar; past 1 while it overshoots.
    nonisolated static func progress(_ t: TimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        guard t < duration else { return 1 }
        let w = 2 * Double.pi / response, z = damping, wd = w * (1 - z * z).squareRoot()
        let rest = exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))   // what is left of the way
        let ease = min(max((t - (duration - 0.2)) / 0.2, 0), 1)                 // onto exactly 1 at the end
        return 1 - rest * (1 - ease * ease * (3 - 2 * ease))
    }

    var body: some View {
        TimelineView(.animation(paused: clock?.isOver ?? true)) { context in
            frame(at: clock?.time(at: context.date) ?? 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func frame(at t: TimeInterval) -> some View {
        let p = Self.progress(t)
        let group = Self.mix(stop, bar.group, p)
        let delete = Self.mix(stop, bar.delete, p)
        // The red square is gone within 0.1 s, before the glass necks apart: slower, it hung for a few frames as a pink
        // dot in the gap between the two shapes. The symbols fade in from 0.15 s on, over 0.25 s.
        let mark = 1 - min(max(t / 0.1, 0), 1)
        let symbols = min(max((t - 0.15) / 0.25, 0), 1)
        return ZStack(alignment: .topLeading) {
            // The glass alone in the container. Content inside it takes on the glass's vibrancy (the red turned pink,
            // the symbols grey), so the symbols and the red square are drawn above it.
            GlassEffectContainer(spacing: 30) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    glass(group)
                    glass(delete)
                }
            }
            ZStack(alignment: .topLeading) {
                Color.clear
                symbol("square.and.arrow.up", at: Self.shareCentre, in: group, of: bar.group)
                symbol("person.2", at: Self.speakersCentre, in: group, of: bar.group)
                symbol("trash", at: Self.deleteCentre, in: delete, of: bar.delete)
            }
            .opacity(1 - (1 - symbols) * (1 - symbols))     // ease out
            // The Stop's red square shrinks away where the Stop was, instead of riding into the Share capsule.
            RoundedRectangle(cornerRadius: stop.width * 0.08, style: .continuous)
                .fill(.red)
                .frame(width: stop.width * 0.36, height: stop.width * 0.36)
                .scaleEffect(0.2 + 0.8 * mark)
                .opacity(mark * mark)
                .position(x: stop.midX, y: stop.midY)
        }
    }

    /// The frame `p` of the way from `a` to `b`.
    nonisolated private static func mix(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
               width: max(0, a.width + (b.width - a.width) * p), height: max(0, a.height + (b.height - a.height) * p))
    }

    private func glass(_ frame: CGRect) -> some View {
        Color.clear
            .glassEffect(.regular.interactive(), in: Capsule())
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    /// A bar symbol at its measured place in its glass, scaled along while the glass is still the Stop.
    private func symbol(_ name: String, at centre: CGPoint, in frame: CGRect, of final: CGRect) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))      // the bar's symbols (regular was visibly thinner)
            .imageScale(.large)
            .foregroundStyle(Color.primary)
            .position(x: frame.minX + centre.x * frame.width / final.width,
                      y: frame.minY + centre.y * frame.height / final.height)
    }

    // The transcript's bar (Share, Speakers, flexible space, Delete), measured on iOS 27, iPhone 17 (402 × 874 pt),
    // from the system's glass views: Share and Speakers in one capsule (28, 798, 116 × 48), Delete a circle
    // (326, 798, 48 × 48), 28 pt from the screen's edges and 42 pt above the safe area's bottom. The symbols' centres
    // in their glass, from their image views (replicas there match the real bar to 0.02 pt).
    private static let shareCentre = CGPoint(x: 25.33, y: 22.67)
    private static let speakersCentre = CGPoint(x: 85.33, y: 25.0)
    private static let deleteCentre = CGPoint(x: 23.83, y: 23.33)

    static func barItems(in safeArea: CGRect) -> (group: CGRect, delete: CGRect) {
        let y = safeArea.maxY - 42
        return (CGRect(x: 28, y: y, width: 116, height: 48),
                CGRect(x: safeArea.maxX - 28 - 48, y: y, width: 48, height: 48))   // portrait only: safe x = screen x
    }

    /// Only where the bar was measured: iOS 27 on a Face ID iPhone (a home indicator below the bar), text sizes below
    /// the accessibility ones. Elsewhere the bar's glass may sit or be sized differently, and the replicas would jump
    /// when the real bar takes over; there the Stop fades out and the bar fades in instead.
    static func canMelt(_ geometry: RecordGeometry, dynamicTypeSize: DynamicTypeSize) -> Bool {
        guard #available(iOS 27, *) else { return false }
        return geometry.bottomInset > 0 && geometry.stop.width > 0 && !dynamicTypeSize.isAccessibilitySize
    }
}
