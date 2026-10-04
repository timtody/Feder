import Foundation

/// Which audio speaks for each speaker's voice: the words the FINAL transcript gives that speaker (whichever diarizer
/// or speaker count produced the labels), cut into pieces (runs of that speaker's words without a pause over 1 s, at
/// least 1 s long), each piece one embedding-model input of at most 10 s (VoiceEmbedder). Pure.
///
/// Measured on DiarBench (voicerec study, synthetic German meetings): dropping the words at speaker changes, longer
/// minimum pieces, packing several pieces into one input and shorter inputs all recognized fewer people at the same
/// false-name rate than this.
nonisolated enum VoiceWindows {
    nonisolated struct Span: Codable, Hashable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
    }

    /// One embedding-model input: recording spans played back to back (`split` makes one span per window), and where
    /// the words lie inside it.
    nonisolated struct Window: Codable, Hashable, Sendable {
        var spans: [Span]          // seconds in the recording, concatenated in this order
        var mask: [Span]           // seconds in the concatenated audio that hold words (the model's frame weights)
        var speech: TimeInterval { mask.reduce(0) { $0 + $1.end - $1.start } }
    }

    static let minPiece: TimeInterval = 1.0    // shorter runs are not used
    static let maxPause: TimeInterval = 1.0    // a longer pause between two words of one speaker splits the run
    static let windowLength: TimeInterval = 10 // the embedding model's input (160 000 samples at 16 kHz)
    static let maxSpeech: TimeInterval = 180   // per speaker, longest pieces first: bounds the work on long recordings
    static let maxPieces = 60                  // per speaker, likewise (about 0.5 s of embedding on an M-series Mac)

    /// speakerIndex -> windows. `speakers[i]` is word i's final label (TranscriptAligner.speakers), nil = unlabelled.
    static func windows(words: [TranscriptWord], speakers: [Int?]) -> [Int: [Window]] {
        precondition(words.count == speakers.count)
        var result: [Int: [Window]] = [:]
        for speaker in Set(speakers.compactMap { $0 }) {
            var taken: TimeInterval = 0
            var count = 0
            var windows: [Window] = []
            // longest first (stable for equal lengths), then back in time order
            let chosen = pieces(words: words, speakers: speakers, of: speaker).enumerated()
                .sorted { ($0.element.end - $0.element.start, -$0.offset) > ($1.element.end - $1.element.start, -$1.offset) }
                .filter { piece in
                    guard taken < maxSpeech, count < maxPieces else { return false }
                    taken += piece.element.end - piece.element.start
                    count += 1
                    return true
                }
                .sorted { $0.offset < $1.offset }
            for (_, piece) in chosen { windows += split(piece) }
            if !windows.isEmpty { result[speaker] = windows }
        }
        return result
    }

    /// Runs of consecutive words of `speaker` (split at pauses > maxPause), at least `minPiece` long; the words at a
    /// speaker change are kept (dropping them measured worse). Each piece: (start, end, word spans).
    static func pieces(words: [TranscriptWord], speakers: [Int?], of speaker: Int) -> [(start: TimeInterval, end: TimeInterval, words: [Span])] {
        var out: [(TimeInterval, TimeInterval, [Span])] = []
        let n = words.count
        var i = 0
        while i < n {
            guard speakers[i] == speaker else { i += 1; continue }
            var j = i
            while j + 1 < n, speakers[j + 1] == speaker, words[j + 1].start - words[j].end <= maxPause { j += 1 }
            let spans = (i...j).map { Span(start: words[$0].start, end: words[$0].end) }
            let start = spans[0].start, end = spans[spans.count - 1].end
            if end - start >= minPiece { out.append((start, end, spans)) }
            i = j + 1
        }
        return out
    }

    /// One piece as windows of <= windowLength s (a longer piece is split).
    static func split(_ piece: (start: TimeInterval, end: TimeInterval, words: [Span])) -> [Window] {
        var out: [Window] = []
        var s = piece.start
        while s < piece.end - 1e-6 {
            let e = min(piece.end, s + windowLength)
            var mask: [Span] = []
            for w in piece.words {
                let a = max(w.start, s), b = min(w.end, e)
                if b > a { mask.append(Span(start: a - s, end: b - s)) }
            }
            out.append(Window(spans: [Span(start: s, end: e)], mask: mask))
            s = e
        }
        return out
    }
}
