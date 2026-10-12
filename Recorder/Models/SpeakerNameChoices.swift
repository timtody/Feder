import Foundation

/// The people the rename sheet offers for one speaker, best first: the person the speaker is linked to now, then people
/// whose voice fingerprint is like the speaker's voice (most alike first, `VoiceMatch.suggestion`), then everyone else
/// by name. While a name is typed only the people it matches are left (as search suggestions match: equal, name
/// prefix, word prefix inside the name, then substring from 3 characters), better matches first.
/// With the invitees of the calendar event the transcript was started in (`Recording.calendarAttendees`), each invitee
/// is a choice too, marked `isInvitee` (the sheet's "Invitees" section): one who already is a person is that person's
/// choice (offered once, there), the others are names without a person yet, made a person only when chosen.
nonisolated enum SpeakerNameChoices {
    struct Candidate: Sendable, Equatable {
        var id: UUID
        var name: String
        var fingerprint: [Float]                 // empty: voice not known yet
    }

    struct Choice: Sendable, Identifiable, Equatable {
        enum Reason: Sendable, Equatable { case current, similarVoice, other }
        /// "p:<person id>", or "i:<folded name>" for an invitee who isn't a person yet: stable while typing.
        var id: String
        var personID: UUID?                      // nil: an invitee who isn't a person yet
        var name: String
        var reason: Reason
        var isInvitee = false
        var matched: Range<String.Index>?        // the typed part of the name (shown bold)
    }

    static func rank(_ candidates: [Candidate], invitees: [String] = [], voice: [Float]?, current: UUID?,
                     typed: String) -> [Choice] {
        let fragment = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let invited = Set(invitees.map(SearchFolding.fold))
        var people: Set<String> = []
        var ranked: [(choice: Choice, tier: Int, similarity: Float)] = []
        /// How well the typed fragment matches `name` (0 without typing); nil: filtered out.
        func match(_ name: String) -> (tier: Int, range: Range<String.Index>?)? {
            guard !fragment.isEmpty else { return (0, nil) }
            guard let (tier, range) = SearchSuggestions.tier(of: fragment, in: name) else { return nil }
            return (tier, range)
        }
        for candidate in candidates {
            let folded = SearchFolding.fold(candidate.name)
            people.insert(folded)
            guard let (tier, matched) = match(candidate.name) else { continue }
            let similarity = voice.map { VoiceMatch.similarity($0, candidate.fingerprint) } ?? -1
            let reason: Choice.Reason = candidate.id == current ? .current
                : similarity >= VoiceMatch.suggestion ? .similarVoice : .other
            ranked.append((Choice(id: "p:\(candidate.id.uuidString)", personID: candidate.id, name: candidate.name,
                                  reason: reason, isInvitee: invited.contains(folded), matched: matched),
                           tier, similarity))
        }
        for invitee in invitees {
            let folded = SearchFolding.fold(invitee)
            guard !people.contains(folded), let (tier, matched) = match(invitee) else { continue }
            ranked.append((Choice(id: "i:\(folded)", personID: nil, name: invitee, reason: .other, isInvitee: true,
                                  matched: matched), tier, -1))
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
