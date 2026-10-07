import Foundation

/// Where an optional on-device model is, as Settings shows it (ParakeetModel, NemotronModel, BetterSummaries).
/// `.waitingForWiFi` means an automatic download waits for a connection it may use; NetworkPath.kind says which reason
/// to show (no connection, cellular, Low Data Mode).
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
