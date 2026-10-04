import SwiftUI

/// The large Stop of the full-screen recording view: a solid red rounded square on an interactive Liquid Glass disc
/// (Voice Memos' record mark morphed into Stop); dimmed with a spinner while saving. The red stays opaque (the glass is
/// a sibling behind it, not around it: content inside a glass effect gets its vibrancy, which washed red out to pink).
struct StopButtonLabel: View {
    var isBusy = false

    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 72

    var body: some View {
        ZStack {
            Color.clear
                .glassEffect(.regular.interactive(!isBusy), in: Circle())
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(.red)
                .frame(width: size * 0.36, height: size * 0.36)
                .opacity(isBusy ? 0.35 : 1)
            if isBusy { ProgressView() }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}
