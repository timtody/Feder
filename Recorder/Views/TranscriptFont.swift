import SwiftUI

/// The typeface of what is read in a transcript: its text (live and saved) and its summary, chosen in Settings ›
/// Reading. Everything else (title, date line, speaker names and times, tags, the chrome the system draws) stays
/// SF Pro. New York is the default: the system serif, as in Books, a document rather than an interface.
/// Libron (Nico Verbruggen, a calmer revision of Readerly made for e-readers; SIL Open Font License 1.1) is bundled,
/// v0.25 from github.com/nicoverbruggen/libron (Libron.zip, SHA-256 a732102b…2b91a57), its four styles registered
/// through `UIAppFonts`; the license ships beside it (Fonts/Libron-OFL.txt). Nothing is downloaded.
nonisolated enum TranscriptFont: String, CaseIterable, Identifiable, Sendable {
    case newYork
    case system
    case libron

    static let key = "transcriptFont"
    static let standard = TranscriptFont.newYork

    var id: String { rawValue }

    var name: String {
        switch self {
        case .newYork: "New York"
        case .system: "SF Pro"
        case .libron: "Libron"
        }
    }

    /// At `size` points, already scaled for Dynamic Type (the transcript's `@ScaledMetric`).
    func font(fixedSize size: CGFloat) -> Font {
        switch self {
        case .newYork: .system(size: size, design: .serif)
        case .system: .system(size: size)
        case .libron: .custom("Libron", fixedSize: size)
        }
    }

    /// In a text style's size, scaling with Dynamic Type (the summary: subheadline).
    func font(_ style: Font.TextStyle) -> Font {
        switch self {
        case .newYork: .system(style, design: .serif)
        case .system: .system(style)
        case .libron: .custom("Libron", size: Self.pointSize(style), relativeTo: style)
        }
    }

    /// The text styles' sizes at the default Dynamic Type setting (Large), for `Font.custom(_:size:relativeTo:)`.
    private static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}
