import Foundation

/// How Gemma writes a transcript's summary (FED-15). Brief is the summary as it always was (two or three sentences, the
/// benched request byte for byte); the others are lines: Meeting (decisions, to-dos and open questions under fixed
/// headings), Lecture (key ideas), Interview (questions and answers) and Bullet Points. Chosen while recording (the disc
/// right of Stop), in the open summary (written again), or per tag (Settings › Summaries › Styles for Tags); a choice by
/// hand comes first, then the first of the transcript's tags with a style, then Brief. No default style in Settings:
/// the issue asks for none, and the fallback is Brief in one place (`SpeakerIdentifier.describe`).
/// Only where Gemma can run: without it nothing about styles shows.
nonisolated enum SummaryStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case brief, meeting, lecture, interview, bulletPoints

    var id: String { rawValue }

    var name: LocalizedStringResource {
        switch self {
        case .brief: "Brief"
        case .meeting: "Meeting"
        case .lecture: "Lecture"
        case .interview: "Interview"
        case .bulletPoints: "Bullet Points"
        }
    }

    var symbol: String {
        switch self {
        case .brief: "text.alignleft"
        case .meeting: "person.2"
        case .lecture: "graduationcap"
        case .interview: "questionmark.bubble"
        case .bulletPoints: "list.bullet"
        }
    }
}

/// The summary style per tag (Settings › Summaries › Styles for Tags), in UserDefaults: tags are plain strings on the
/// transcripts (no Tag model to hold it), matched without case as `Recording.addTag` does. A transcript gets the style
/// of its first tag (in its order) that has one, when its first summary is written and when such a tag is added to it
/// later; changing a tag's style here rewrites nothing that exists (never the archive, as Gemma's background work).
nonisolated enum SummaryStyles {
    static let key = "summaryStylesByTag"

    /// Tag (lowercased) → SummaryStyle.rawValue.
    static var byTag: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func style(forTag tag: String) -> SummaryStyle? {
        byTag[tag.lowercased()].flatMap(SummaryStyle.init(rawValue:))
    }

    /// The style of the first of `tags` that has one.
    static func style(forTags tags: [String]) -> SummaryStyle? {
        let map = byTag
        guard !map.isEmpty else { return nil }
        return tags.lazy.compactMap { map[$0.lowercased()].flatMap(SummaryStyle.init(rawValue:)) }.first
    }

    static func set(_ style: SummaryStyle?, forTag tag: String) {
        var map = byTag
        map[tag.lowercased()] = style?.rawValue
        UserDefaults.standard.set(map, forKey: key)
    }

    /// How many tags have a style (the Summaries page's row value).
    static var count: Int { byTag.count }
}
