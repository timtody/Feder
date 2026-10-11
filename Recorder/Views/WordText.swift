import Synchronization
import SwiftUI

/// A transcript paragraph whose words can be tapped (to hear them: RecordingDetailView plays from the word) and whose
/// spoken word is highlighted while the audio plays. SwiftUI's `Text` says nothing about where a word was drawn, so
/// each word is its own run with its index (`WordToken`), and `WordRenderer` notes each run's frame while it draws
/// (`WordFrames`); a tap's location then names the word. The search's highlights are kept (each word styled with its
/// share of them). Words are the paragraph's text split at spaces: the paragraphs are their words joined by single
/// spaces (TranscriptAligner.fold), so a token is a word unless a word's own text has a space in it (the caller maps
/// tokens to words with that in mind).
struct WordParagraph: View, Equatable {
    let text: String
    var highlights: [Range<String.Index>] = []
    /// The token being spoken, nil: none.
    var playing: Int?
    let onTap: (Int) -> Void

    @State private var frames = WordFrames()

    /// Without the tap closure (a new one at every update of the transcript): while the audio plays, the transcript
    /// updates a few times a second, and only the paragraph whose spoken word changed is built again.
    static func == (a: WordParagraph, b: WordParagraph) -> Bool {
        a.text == b.text && a.highlights == b.highlights && a.playing == b.playing
    }

    var body: some View {
        WordText.make(text, highlights: highlights, playing: playing)
            .textRenderer(WordRenderer(frames: frames))
            // Simultaneous: the paragraph's text selection (a long press) keeps working.
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                if let token = frames.token(at: value.location) { onTap(token) }
            })
    }
}

nonisolated struct WordToken: TextAttribute {
    var index: Int
}

nonisolated struct PlayingWord: TextAttribute {}

/// The frames of a paragraph's words as last drawn, by token index (written while drawing, read on a tap).
nonisolated final class WordFrames: Sendable {
    private let frames = Mutex<[Int: CGRect]>([:])

    func set(_ new: [Int: CGRect]) {
        frames.withLock { $0 = new }
    }

    /// The word under `point`, or the nearest one on that line (a tap in the gap between two words, or just past the
    /// line's end, still names a word).
    func token(at point: CGPoint) -> Int? {
        frames.withLock { frames in
            if let hit = frames.first(where: { $0.value.insetBy(dx: -2, dy: -3).contains(point) }) { return hit.key }
            let line = frames.filter { $0.value.minY - 3 <= point.y && point.y <= $0.value.maxY + 3 }
            return line.min { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }?.key
        }
    }
}

/// Draws the paragraph as usual, a tint behind the spoken word, and notes where each word went.
nonisolated struct WordRenderer: TextRenderer {
    let frames: WordFrames

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var found: [Int: CGRect] = [:]
        for line in layout {
            for run in line {
                let rect = run.typographicBounds.rect
                if let token = run[WordToken.self] {
                    found[token.index] = found[token.index].map { $0.union(rect) } ?? rect
                }
                if run[PlayingWord.self] != nil {
                    context.fill(Path(roundedRect: rect.insetBy(dx: -3, dy: -1), cornerRadius: 5),
                                 with: .color(.accentColor.opacity(0.22)))
                }
                context.draw(run)
            }
        }
        frames.set(found)
    }
}

enum WordText {
    /// The paragraph as one `Text` of word runs (each with its `WordToken`), the search's highlights per word, the
    /// spoken word marked `PlayingWord`.
    static func make(_ text: String, highlights: [Range<String.Index>], playing: Int?) -> Text {
        var result = Text(verbatim: "")
        var index = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(of: " ") ?? text.endIndex
            if cursor < end {
                let range = cursor..<end
                let local = highlights.compactMap { hit -> Range<String.Index>? in
                    let lower = max(hit.lowerBound, range.lowerBound), upper = min(hit.upperBound, range.upperBound)
                    return lower < upper ? lower..<upper : nil
                }
                let word = String(text[range])
                // Offsets into the word: SearchHighlight works on the word's own string.
                let shifted = local.map { hit in
                    word.index(word.startIndex, offsetBy: text.distance(from: range.lowerBound, to: hit.lowerBound))
                        ..< word.index(word.startIndex, offsetBy: text.distance(from: range.lowerBound, to: hit.upperBound))
                }
                var run = SearchHighlight.text(word, shifted).customAttribute(WordToken(index: index))
                if index == playing { run = run.customAttribute(PlayingWord()) }
                result = Text("\(result)\(run)")
                index += 1
            }
            guard end < text.endIndex else { break }
            result = Text("\(result)\(Text(verbatim: " "))")
            cursor = text.index(after: end)
        }
        return result
    }
}
