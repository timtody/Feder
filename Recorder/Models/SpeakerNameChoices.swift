import Foundation

/// The people the rename sheet offers for one speaker, best first: the person the speaker is linked to now, then people
/// whose voice fingerprint is like the speaker's voice (most alike first, `VoiceMatch.suggestion`), then everyone else
/// by name. While a name is typed only the people it matches are left (as search suggestions match: equal, name
/// prefix, word prefix inside the name, then substring from 3 characters), better matches first.
nonisolated enum SpeakerNameChoices {
    struct Candidate: Sendable, Equatable {
        var id: UUID
        var name: String
        var fingerprint: [Float]                 // empty: voice not known yet
    }

    struct Choice: Sendable, Identifiable, Equatable {
        enum Reason: Sendable, Equatable { case current, similarVoice, other }
        var id: UUID
        var name: String
        var reason: Reason
        var matched: Range<String.Index>?        // the typed part of the name (shown bold)
    }

    static func rank(_ candidates: [Candidate], voice: [Float]?, current: UUID?, typed: String) -> [Choice] {
        let fragment = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var ranked: [(choice: Choice, tier: Int, similarity: Float)] = []
        for candidate in candidates {
            var tier = 0
            var matched: Range<String.Index>?
            if !fragment.isEmpty {
                guard let (t, range) = SearchSuggestions.tier(of: fragment, in: candidate.name) else { continue }
                (tier, matched) = (t, range)
            }
            let similarity = voice.map { VoiceMatch.similarity($0, candidate.fingerprint) } ?? -1
            let reason: Choice.Reason = candidate.id == current ? .current
                : similarity >= VoiceMatch.suggestion ? .similarVoice : .other
            ranked.append((Choice(id: candidate.id, name: candidate.name, reason: reason, matched: matched), tier, similarity))
        }
        func group(_ reason: Choice.Reason) -> Int {
            switch reason { case .current: 0; case .similarVoice: 1; case .other: 2 }
        }
        return ranked.sorted { a, b in
            // While typing, how well the name matches comes first; otherwise who it most likely is.
            let ka = fragment.isEmpty ? (group(a.choice.reason), 0) : (a.tier, group(a.choice.reason))
            let kb = fragment.isEmpty ? (group(b.choice.reason), 0) : (b.tier, group(b.choice.reason))
            if ka != kb { return ka < kb }
            if a.choice.reason == .similarVoice, a.similarity != b.similarity { return a.similarity > b.similarity }
            return a.choice.name.localizedStandardCompare(b.choice.name) == .orderedAscending
        }
        .map(\.choice)
    }
}
