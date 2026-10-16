#if DEBUG
import SwiftUI

/// Settings › About › Mac Link Test (Debug builds, FED-141): starts and stops the probe, shows what it measures, and shares
/// its log. Developer-only, so its strings are verbatim (not in the catalog).
struct MacLinkProbeView: View {
    @Environment(AppServices.self) private var services
    private var probe: MacLinkProbe { .shared }

    var body: some View {
        let snapshot = probe.snapshot
        Form {
            Section {
                Button(probe.isRunning ? "Stop Test" : "Start Test") {
                    if probe.isRunning {
                        probe.stop()
                    } else {
                        let identifier = services.identifier
                        probe.start { identifier.isRecording }
                    }
                }
                .accessibilityIdentifier("MacLinkStartStop")
                if let url = probe.logURL {
                    ShareLink(item: url) { Text(verbatim: "Share Log") }
                }
            } footer: {
                Text(verbatim: "Run build/qa/linkspike/sender on the Mac (same Wi-Fi). Start the test, start a recording, lock the iPhone. Without a recording iOS suspends Feder: the stream stalls.")
            }
            Section {
                row("State", snapshot.state)
                row("Mac", snapshot.mac ?? "–")
                row("Path", snapshot.path)
                row("Messages", "\(snapshot.messages) (\(snapshot.kilobytes) KB)")
                row("Last message", snapshot.lastMessageAgo.map { String(format: "%.1f s ago", $0) } ?? "–")
                row("Lag p50 / p99 / max", [snapshot.lagP50, snapshot.lagP99, snapshot.lagMax].map(Self.ms).joined(separator: " / "))
                row("Longest gap", String(format: "%.2f s", snapshot.longestGap))
                row("Gaps over 1 s", "\(snapshot.gapsOver1s)")
                row("Reconnects", "\(snapshot.reconnects)")
                row("Clock offset (Mac − iPhone)", Self.ms(snapshot.clockOffset))
            }
            Section {
                ForEach(Array(snapshot.events.reversed().enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.caption.monospaced())
                }
            } header: {
                Text(verbatim: "Log")
            }
        }
        .navigationTitle(Text(verbatim: "Mac Link Test"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent { Text(verbatim: value).monospacedDigit() } label: { Text(verbatim: title) }
    }

    private static func ms(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "–"
    }
}
#endif
