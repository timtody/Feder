import SwiftUI

/// The recording's timer: big (44 pt light, rounded) above the Stop, and, landed (`progress` 1), the date line's
/// duration (subheadline, secondary). One text throughout whose font size changes with `progress` (crisp in every
/// frame, unlike a scale effect), the two styles crossfading: a matched-geometry frame between two texts truncated the
/// big one to "0:…" while it shrank.
struct FlyingTimer: View {
    let text: String
    let dimmed: Bool                               // not recording yet: "0:00", lighter
    let progress: CGFloat
    let smallSize: CGFloat

    static let bigSize: CGFloat = 44

    var body: some View {
        let size = Self.bigSize + (smallSize - Self.bigSize) * progress
        ZStack {
            Text(verbatim: text)
                .font(.system(size: size, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(dimmed ? .tertiary : .primary)
                .opacity(1 - progress)
            Text(verbatim: text)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .opacity(progress)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

/// Where the timer is while recording and where it lands, in RecordView's coordinates.
struct TimerFrames {
    var hero: CGRect?
    var slot: CGRect?
}

/// Microphone level as five small rounded bars, red while recording: the centre bar follows the level fastest and the
/// outer ones more slowly, so speech ripples outwards; short pills in silence. Scales with Dynamic Type. Reduce Motion: no easing.
struct LevelMeter: View {
    let session: RecordingSession                  // read here, so only the meter redraws with the level
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 16

    private static let weights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
    private static let response: [Double] = [0.32, 0.22, 0.12, 0.22, 0.32]   // seconds to follow a change

    var body: some View {
        let level = isActive ? CGFloat(session.level) : 0
        let barWidth = max(3, (height * 0.19).rounded())   // 3 pt at the default size
        let rest = barWidth * 1.5                          // a short pill at rest, not a dot
        HStack(spacing: barWidth * 0.67) {
            ForEach(Self.weights.indices, id: \.self) { i in
                Capsule()
                    .frame(width: barWidth, height: rest + (height - rest) * level * Self.weights[i])
                    .animation(reduceMotion ? nil : .easeOut(duration: Self.response[i]), value: level)
            }
        }
        .frame(height: height)
        .foregroundStyle(isActive ? Color.red : Color.secondary)
        .accessibilityHidden(true)
    }
}
