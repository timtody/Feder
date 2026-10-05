import Foundation

/// Merges the corrected "Name: text" lines a language model returns (TranscriptCorrector) into the transcript's words,
/// which keep their times: the answer's words are aligned with the paragraphs' words (longest common subsequence of
/// the words without case and punctuation), a word the model kept or respelled takes the time of the word it stands
/// for, words it added share the time between their neighbours, and a fragment it moved to the neighbouring speaker
/// keeps its times under its new paragraph. Answers that drop, merge or rename lines, or change more than a share of
/// the words (a paraphrase, a summary, a lost turn), are rejected as a whole, so the model can never rewrite the
/// transcript. Pure functions, no dependencies.
nonisolated enum CorrectionMerge {
    /// A paragraph as the corrector works on it: a segment's speaker and its words. Stored on the Recording as the
    /// proposal while the user reviews it (`proposedCorrections`).
    struct Paragraph: Codable, Equatable, Sendable {
        var speakerIndex: Int?
        var words: [TranscriptWord]

        var start: TimeInterval { words.first?.start ?? 0 }
        var end: TimeInterval { words.last?.end ?? 0 }
        var text: String { words.map(\.text).joined(separator: " ") }

        var segment: TranscriptSegment {
            TranscriptSegment(speakerIndex: speakerIndex, text: text, start: start, end: end)
        }
    }

    /// Share of a chunk's words the answer may change (beyond case and punctuation) before it is rejected as a
    /// paraphrase: Parakeet's word error rate is about 10 %, so a correction pass changes far fewer words.
    static let maxChangedShare = 0.3
    /// The same for one paragraph of at least `guardedWords` words (one turn rewritten inside a mostly copied chunk).
    static let maxParagraphChangedShare = 0.5
    static let guardedWords = 5
    /// The answer's word count relative to the input's must stay within this.
    static let countRange = 0.7...1.3

    /// One difference between the transcript's words and the proposal, as the review shows it: the old words (a range
    /// of the transcript's words, empty for an insertion) and the new words that stand in their place.
    struct Change: Equatable, Identifiable, Sendable {
        var oldRange: Range<Int>
        var oldWords: [TranscriptWord]
        var newWords: [TranscriptWord]
        var id: String { "\(oldRange.lowerBound)-\(oldRange.upperBound)-\(newWords.map(\.text).joined(separator: " "))" }
        /// Where the change is, for the paragraph that names its speaker.
        var time: TimeInterval { oldWords.first?.start ?? newWords.first?.start ?? 0 }
    }

    /// The differences between `old` and `new` (exact texts, so case and punctuation count), each a contiguous run of
    /// words that differ; two runs separated by a single unchanged word are one change ("an den Kragen." for
    /// "an Kragen,"), so a row reads as one edit.
    static func changes(from old: [TranscriptWord], to new: [TranscriptWord]) -> [Change] {
        let n = old.count, m = new.count, stride = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * stride)
        for i in (0..<n).reversed() {
            for j in (0..<m).reversed() {
                table[i * stride + j] = old[i].text == new[j].text
                    ? table[(i + 1) * stride + j + 1] + 1
                    : max(table[(i + 1) * stride + j], table[i * stride + j + 1])
            }
        }
        var changes: [Change] = []
        var i = 0, j = 0
        var run: (oldStart: Int, newStart: Int)?
        func close(_ i: Int, _ j: Int) {
            guard let r = run else { return }
            let change = Change(oldRange: r.oldStart..<i, oldWords: Array(old[r.oldStart..<i]), newWords: Array(new[r.newStart..<j]))
            // Joined with the previous change when only one unchanged word lies between them.
            if let last = changes.last, last.oldRange.upperBound + 1 == change.oldRange.lowerBound,
               let between = old[safe: last.oldRange.upperBound] {
                changes[changes.count - 1] = Change(oldRange: last.oldRange.lowerBound..<change.oldRange.upperBound,
                                                    oldWords: last.oldWords + [between] + change.oldWords,
                                                    newWords: last.newWords + [between] + change.newWords)
            } else {
                changes.append(change)
            }
            run = nil
        }
        while i < n || j < m {
            if i < n, j < m, old[i].text == new[j].text {
                close(i, j); i += 1; j += 1
            } else {
                if run == nil { run = (i, j) }
                if j >= m || (i < n && table[(i + 1) * stride + j] >= table[i * stride + j + 1]) { i += 1 } else { j += 1 }
            }
        }
        close(i, j)
        return changes
    }

    /// Words the proposal puts under another speaker than the transcript has them (rule 3: a fragment appended to
    /// the previous speaker), as runs: the words and the speaker they move to. Only "Apply All" realizes a move (an
    /// accepted single change keeps the paragraphs), so the review lists them without a checkmark.
    struct Move: Equatable, Identifiable, Sendable {
        var words: [TranscriptWord]
        var toSpeaker: Int?
        var id: String { "\(words.first?.start ?? 0)-\(toSpeaker ?? -1)" }
        var time: TimeInterval { words.first?.start ?? 0 }
    }

    static func moves(from current: [Paragraph], to proposal: [Paragraph]) -> [Move] {
        var speakerAt: [(start: TimeInterval, speaker: Int?)] = []
        for paragraph in current { for word in paragraph.words { speakerAt.append((word.start, paragraph.speakerIndex)) } }
        var moves: [Move] = []
        for paragraph in proposal {
            for word in paragraph.words {
                // The transcript's speaker of this word: the last word starting at or before it (times are kept).
                guard let before = speakerAt.last(where: { $0.start <= word.start + 0.001 }), before.speaker != paragraph.speakerIndex else { continue }
                if let last = moves.indices.last, moves[last].toSpeaker == paragraph.speakerIndex,
                   moves[last].words.last.map({ word.start - $0.end < 1.0 }) == true {
                    moves[last].words.append(word)
                } else {
                    moves.append(Move(words: [word], toSpeaker: paragraph.speakerIndex))
                }
            }
        }
        return moves
    }

    /// Whether `proposal` differs from the transcript at all: in its words, or in which paragraph a word belongs to.
    static func differs(_ proposal: [Paragraph], from words: [TranscriptWord], segments: [TranscriptSegment]) -> Bool {
        proposal.flatMap(\.words) != words
            || proposal.map(\.speakerIndex) != segments.map(\.speakerIndex)
            || proposal.map(\.text) != segments.map(\.text)
    }

    /// `words` with one `change` accepted: its old words replaced by the new ones.
    static func accepting(_ change: Change, in words: [TranscriptWord]) -> [TranscriptWord] {
        guard change.oldRange.upperBound <= words.count, Array(words[change.oldRange]) == change.oldWords else { return words }
        var words = words
        words.replaceSubrange(change.oldRange, with: change.newWords)
        return words
    }

    /// `words` partitioned by `segments`, in their order: a word belongs to the segment whose time range holds its
    /// middle, one in the gap between two paragraphs to the nearer one. Exact for segments folded from these words
    /// (TranscriptAligner), and still sensible when an earlier, interrupted pass moved a fragment to another speaker.
    /// Segments without words are left out.
    static func paragraphs(words: [TranscriptWord], segments: [TranscriptSegment]) -> [Paragraph] {
        guard !segments.isEmpty else { return words.isEmpty ? [] : [Paragraph(speakerIndex: nil, words: words)] }
        var result = segments.map { Paragraph(speakerIndex: $0.speakerIndex, words: []) }
        var s = 0
        for word in words {
            let middle = (word.start + word.end) / 2
            while s < segments.count - 1, segments[s].end < middle {
                if middle < segments[s + 1].start, middle - segments[s].end <= segments[s + 1].start - middle { break }
                s += 1
            }
            result[s].words.append(word)
        }
        return result.filter { !$0.words.isEmpty }
    }

    /// The texts of the answer's lines, one per name in `names` and in that order, or nil when they don't match: a
    /// line dropped, two merged, one split. Code fences, bullets and bold marks are ignored, so is a preamble
    /// ("Ausgabe:", "Hier ist das korrigierte Transkript:"); a line without a name continues the line before it (a
    /// wrapped paragraph). The names may all be changed consistently ("Speaker 1" written as "Sprecher 1" throughout):
    /// the mapping has to be one to one, which also catches a wrapped line mistaken for a turn.
    static func lines(in answer: String, names: [String]) -> [String]? {
        let expected = Set(names.map { $0.lowercased() })
        var lines: [(name: String, text: String)] = []
        for raw in answer.split(whereSeparator: \.isNewline) {
            var line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }
            if let first = line.first, "-*•".contains(first) {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            if let colon = line.firstIndex(of: ":"), line[..<colon].count <= 40,
               !line[..<colon].contains(where: { ".?!".contains($0) }) {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if expected.contains(name.lowercased()) {           // also with nothing after it: an emptied turn
                    lines.append((name, text))
                    continue
                }
                // An unknown short name with text, while lines are still to come: a renamed speaker.
                if name.split(separator: " ").count <= 3, !text.isEmpty, lines.count < names.count {
                    lines.append((name, text))
                    continue
                }
                if text.isEmpty { continue }                        // a preamble
            }
            guard !lines.isEmpty else { continue }                  // a preamble without a colon
            lines[lines.count - 1].text += " " + line
        }
        guard lines.count == names.count else { return nil }
        var forward: [String: String] = [:], backward: [String: String] = [:]
        for (line, name) in zip(lines, names) {
            let answered = line.name.lowercased(), wanted = name.lowercased()
            if let f = forward[wanted], f != answered { return nil }
            if let b = backward[answered], b != wanted { return nil }
            forward[wanted] = answered
            backward[answered] = wanted
        }
        return lines.map(\.text)
    }

    /// `texts` (one corrected line per paragraph) applied to `paragraphs`: the same paragraphs with corrected words
    /// that keep their times (a paragraph the model emptied is left out), or nil when the answer changed too much.
    /// Off the main actor: the alignment is a table of the chunk's words squared.
    @concurrent
    static func apply(_ texts: [String], to paragraphs: [Paragraph]) async -> [Paragraph]? {
        guard texts.count == paragraphs.count else { return nil }
        var old: [(word: TranscriptWord, key: String, line: Int)] = []
        for (line, paragraph) in paragraphs.enumerated() {
            for word in paragraph.words { old.append((word, VocabularyMerge.normalized(word.text), line)) }
        }
        var new: [(text: String, key: String, line: Int)] = []
        for (line, text) in texts.enumerated() {
            for token in text.split(whereSeparator: \.isWhitespace) {
                let key = VocabularyMerge.normalized(String(token))
                if key.isEmpty {                                    // a dash or "…" on its own joins the word before it
                    if let last = new.indices.last, new[last].line == line { new[last].text += " " + token }
                    continue
                }
                new.append((String(token), key, line))
            }
        }
        guard !old.isEmpty, countRange.contains(Double(new.count) / Double(old.count)) else { return nil }

        // Longest common subsequence of the normalized words; table[i][j] = LCS of old[i...] and new[j...].
        let n = old.count, m = new.count, stride = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * stride)
        for i in (0..<n).reversed() {
            for j in (0..<m).reversed() {
                table[i * stride + j] = old[i].key == new[j].key
                    ? table[(i + 1) * stride + j + 1] + 1
                    : max(table[(i + 1) * stride + j], table[i * stride + j + 1])
            }
        }
        var matchOfNew = [Int?](repeating: nil, count: m)
        var matchedOld = [Bool](repeating: false, count: n)
        var i = 0, j = 0
        while i < n, j < m {
            if old[i].key == new[j].key {
                matchOfNew[j] = i; matchedOld[i] = true; i += 1; j += 1
            } else if table[(i + 1) * stride + j] >= table[i * stride + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        // The guards. A substitution counts once (one word out, one in).
        let unmatchedOld = matchedOld.filter { !$0 }.count, unmatchedNew = matchOfNew.filter { $0 == nil }.count
        guard Double(max(unmatchedOld, unmatchedNew)) <= Double(n) * maxChangedShare else { return nil }
        for line in paragraphs.indices {
            let oldCount = old.filter { $0.line == line }.count
            let oldLost = old.indices.filter { old[$0].line == line && !matchedOld[$0] }.count
            let newCount = new.filter { $0.line == line }.count
            let newAdded = new.indices.filter { new[$0].line == line && matchOfNew[$0] == nil }.count
            if oldCount > 0, oldLost == oldCount, newCount == 0 { return nil }            // a turn dropped
            if oldCount >= guardedWords, Double(max(oldLost, newAdded)) > Double(oldCount) * maxParagraphChangedShare {
                return nil                                                                 // a turn rewritten
            }
        }

        // The words with their times, in the answer's order (the LCS keeps the time order).
        var words: [(word: TranscriptWord, line: Int)] = []
        var lastOld = -1                                            // the last matched old word
        j = 0
        while j < m {
            if let i = matchOfNew[j] {
                words.append((TranscriptWord(text: new[j].text, start: old[i].word.start, end: old[i].word.end), new[j].line))
                lastOld = i
                j += 1
                continue
            }
            var next = j                                            // the run of added words j..<next
            while next < m, matchOfNew[next] == nil { next += 1 }
            let nextOld = next < m ? matchOfNew[next]! : n
            // Their time: that of the old words they stand for (the unmatched ones between the matches around them),
            // else the gap between those matches.
            var spanStart: TimeInterval, spanEnd: TimeInterval
            if lastOld + 1 < nextOld {
                spanStart = old[lastOld + 1].word.start
                spanEnd = old[nextOld - 1].word.end
            } else {
                spanStart = lastOld >= 0 ? old[lastOld].word.end : (nextOld < n ? old[nextOld].word.start : 0)
                spanEnd = nextOld < n ? old[nextOld].word.start : spanStart
            }
            spanEnd = max(spanStart, spanEnd)
            let count = next - j
            for k in 0..<count {
                let start = spanStart + (spanEnd - spanStart) * Double(k) / Double(count)
                let end = spanStart + (spanEnd - spanStart) * Double(k + 1) / Double(count)
                words.append((TranscriptWord(text: new[j + k].text, start: start, end: end), new[j + k].line))
            }
            j = next
        }

        var result: [Paragraph] = []
        var lineOfLast = -1
        for (word, line) in words {
            if line == lineOfLast, let last = result.indices.last {
                result[last].words.append(word)
            } else {
                result.append(Paragraph(speakerIndex: paragraphs[line].speakerIndex, words: [word]))
            }
            lineOfLast = line
        }
        return result
    }
}

nonisolated private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
