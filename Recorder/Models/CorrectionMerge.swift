import Foundation

/// What is left of Smart Corrections (removed in October 2026): the type of `Recording.proposedCorrections`, kept so the
/// store's schema does not change (SwiftData changes are additive only). Nothing creates or reads it any more.
nonisolated enum CorrectionMerge {
    struct Paragraph: Codable, Equatable, Sendable {
        var speakerIndex: Int?
        var words: [TranscriptWord]
    }
}
