import Foundation
import Network

/// Where an optional on-device model is, as Settings shows it (ParakeetModel, NemotronModel).
enum ModelDownloadState: Equatable {
    case notDownloaded
    case waitingForWiFi
    case downloading(Double)                     // fraction completed
    case ready
    case failed(String)

    /// `.downloading(fraction)` when that is worth publishing: only while downloading, and only every half per cent.
    /// FluidAudio and URLSession report every chunk, which was a main-actor hop and a re-render of Settings per chunk.
    func advanced(to fraction: Double) -> ModelDownloadState? {
        guard case .downloading(let shown) = self, fraction - shown >= 0.005 else { return nil }
        return .downloading(fraction)
    }
}

nonisolated enum ModelDownload {
    /// Cellular, personal hotspot or Low Data Mode: automatic model downloads wait for Wi-Fi there.
    static func isExpensiveNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "Scribe.network"))
        }
    }
}
