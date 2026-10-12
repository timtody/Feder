import Foundation
import FluidAudio
// ParakeetTranscriber.words(from:), verbatim.
enum ParakeetWords {
    static let alignmentOffset: TimeInterval = -0.12
    nonisolated static func words(from tokens: [TokenTiming]) -> (words: [TranscriptWord], confidences: [Double]) {
        var words: [TranscriptWord] = []
        var confidences: [Double] = []
        var pendingBoundary = false                 // a bare "▁" token: the next piece starts a new word
        for token in tokens where !token.token.isEmpty && token.token != "<blank>" && token.token != "<pad>" {
            let marked = token.token.hasPrefix("▁") || token.token.hasPrefix(" ")
            let piece = marked ? String(token.token.drop { $0 == "▁" || $0 == " " }) : token.token
            guard !piece.isEmpty else { pendingBoundary = true; continue }
            let startsWord = marked || pendingBoundary
            pendingBoundary = false
            let punctuationOnly = piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if words.isEmpty || (startsWord && !punctuationOnly) {
                words.append(TranscriptWord(text: piece, start: token.startTime, end: token.endTime))
                confidences.append(Double(token.confidence))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = max(words[words.count - 1].end, token.endTime)
                confidences[confidences.count - 1] = min(confidences[confidences.count - 1], Double(token.confidence))
            }
        }
        return (words, confidences)
    }
}
