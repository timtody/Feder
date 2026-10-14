import CoreText
import Foundation
import UIKit

/// A transcript as a file to share: PDF, Word, Markdown or subtitles (SRT, WebVTT), or as plain text. Built from a
/// `Snapshot` read on the main actor when Share is pressed, then written off the main actor (a long transcript's PDF
/// takes a moment) into a temporary folder, from where the share sheet sends it. Nothing is uploaded: the share sheet
/// is the user's own choice of where the file goes.
nonisolated enum TranscriptExport {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case text, pdf, word, markdown, srt, vtt
        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .text: "txt"
            case .pdf: "pdf"
            case .word: "docx"
            case .markdown: "md"
            case .srt: "srt"
            case .vtt: "vtt"
            }
        }

        /// Subtitles always carry times, and name speakers only as a prefix or voice tag.
        var isSubtitles: Bool { self == .srt || self == .vtt }
    }

    /// UserDefaults keys of the Share menu's two options.
    static let namesKey = "exportSpeakerNames"          // absent: on
    static let timestampsKey = "exportTimestamps"       // absent: off

    struct Paragraph: Sendable {
        var speaker: String?
        var start: TimeInterval
        var text: String
        /// Its bookmarked sentences (Bookmarks.places), as character offsets into `text`: each written as the card shows
        /// it, a bookmark at its start and the sentence highlighted (`runs`). Until October 2026 a line above the
        /// paragraph, "🔖 Bookmark · 3:21", said when but not what (FED-76). Not in subtitles.
        var marks: [Range<Int>] = []
    }

    /// A bookmark in the list under the summary, as the card's Bookmarks row has it.
    struct Bookmark: Sendable {
        var time: TimeInterval
        var sentence: String
    }

    struct Word: Sendable {
        var speaker: String?
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// What an export needs, copied out of the model.
    struct Snapshot: Sendable {
        var title: String
        var metaLine: String                 // date · duration · place, as the card shows it
        var summary: String?
        var tags: [String]
        var paragraphs: [Paragraph]
        var words: [Word]                    // for subtitles
        var aiNote: String
        var names: Bool
        var timestamps: Bool
        /// The action items the user didn't remove, one line each (ActionItemText.line), under their heading after the
        /// summary; plain text and subtitles stay the transcript alone.
        var actionItemsHeading = ""
        var actionItems: [String] = []
        /// The bookmarks under their heading right after the summary (before the action items), as the card lists them
        /// under its Summary row; plain text and subtitles stay the transcript alone.
        var bookmarksHeading = ""
        var bookmarks: [Bookmark] = []
    }

    /// The app's accent (AccentColor, light: paper is white): the bookmark and the list's times. The highlight behind
    /// a bookmarked sentence is it at 12 % over white, as the card's (BookmarkHighlight.tint). Read from the asset, so
    /// the exports follow when the accent changes (they were hard-coded and fell out of step).
    static let accent = UIColor.accentLight
    static let accentHex = hex(accent), tintHex = hex(accent, overWhite: 0.12)

    /// `RRGGBB` of `color` (sRGB), laid at `alpha` over white.
    private static func hex(_ color: UIColor, overWhite alpha: CGFloat = 1) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, own: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &own)
        return [red, green, blue]
            .map { String(format: "%02X", Int((alpha * min(max($0, 0), 1) + 1 - alpha) * 255 + 0.5)) }
            .joined()
    }

    // MARK: Writing

    /// The file for `format` (not `.text`), in a fresh temporary folder, named after the transcript.
    @concurrent
    static func file(_ format: Format, of snapshot: Snapshot) async throws -> URL {
        let data: Data = switch format {
        case .text: Data(plainText(snapshot).utf8)
        case .markdown: Data(markdown(snapshot).utf8)
        case .pdf: pdf(snapshot)
        case .word: try docx(snapshot)
        case .srt: Data(subtitles(snapshot, vtt: false).utf8)
        case .vtt: Data(subtitles(snapshot, vtt: true).utf8)
        }
        // The last export's file goes: the share sheet has handed it on by then (or the user cancelled).
        let exports = FileManager.default.temporaryDirectory.appending(path: "Export")
        try? FileManager.default.removeItem(at: exports)
        let folder = exports.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(fileName(snapshot.title)).\(format.fileExtension)")
        try data.write(to: url, options: .completeFileProtection)
        return url
    }

    /// The title without characters a file name can't have.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Transcript" : String(cleaned.prefix(100))
    }

    /// "0:42", "1:02:03": the card's time format, rounded as the card rounds (to the nearest second: down, a turn at
    /// 3.6 s read 0:03 in the export and 0:04 in the card).
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A paragraph's lead: "Anna Schmidt (0:42)", "Anna Schmidt", "0:42" or nothing, per the options.
    static func lead(_ paragraph: Paragraph, _ snapshot: Snapshot) -> String? {
        let name = snapshot.names ? paragraph.speaker : nil
        let time = snapshot.timestamps ? clock(paragraph.start) : nil
        switch (name, time) {
        case let (name?, time?): return "\(name) (\(time))"
        case let (name?, nil): return name
        case let (nil, time?): return time
        case (nil, nil): return nil
        }
    }

    /// Paragraphs of one speaker in a row are a turn: the lead (name, and the turn's start time with Timestamps) is
    /// written once, at the turn's start, as the card does. (With Timestamps every paragraph had one until October
    /// 2026, so a speaker's pause split their turn into "Speaker 1 (0:08)", "Speaker 1 (0:19)".)
    static func startsTurn(_ index: Int, _ paragraphs: [Paragraph]) -> Bool {
        index == 0 || paragraphs[index - 1].speaker != paragraphs[index].speaker
    }

    /// The list's Share swipe action: plain text with the options last chosen in the card's Share menu.
    @MainActor
    static func plainText(_ recording: Recording) -> String {
        let defaults = UserDefaults.standard
        return plainText(recording.exportSnapshot(names: defaults.object(forKey: namesKey) as? Bool ?? true,
                                                  timestamps: defaults.bool(forKey: timestampsKey)))
    }

    /// The paragraph's text in runs, in order, each bookmarked sentence one of its own (`marked`).
    static func runs(_ paragraph: Paragraph) -> [(text: String, marked: Bool)] {
        let text = paragraph.text
        func slice(_ range: Range<Int>) -> String {
            let start = text.index(text.startIndex, offsetBy: range.lowerBound)
            return String(text[start..<text.index(start, offsetBy: range.count)])
        }
        var runs: [(text: String, marked: Bool)] = []
        var cursor = 0
        for mark in Bookmarks.merged(paragraph.marks, length: text.count) {
            if cursor < mark.lowerBound { runs.append((slice(cursor..<mark.lowerBound), false)) }
            runs.append((slice(mark), true))
            cursor = mark.upperBound
        }
        if cursor < text.count { runs.append((slice(cursor..<text.count), false)) }
        return runs
    }

    /// The turns alone; a bookmarked sentence starts with "🔖", the card's bookmark (plain text has no highlight).
    static func plainText(_ snapshot: Snapshot) -> String {
        snapshot.paragraphs.enumerated().map { index, paragraph in
            let text = runs(paragraph).map { $0.marked ? "🔖 " + $0.text : $0.text }.joined()
            if let lead = lead(paragraph, snapshot), startsTurn(index, snapshot.paragraphs) {
                return "\(lead): \(text)"
            }
            return text
        }
        .joined(separator: "\n\n")
    }

    /// CommonMark, so every Markdown app reads it as meant: the transcript's own text escaped (a paragraph starting
    /// with "1." or "- " became a list, "*" italics), the summary quoted line by line (only its first line was, and a
    /// blank line in it ended the quote). A bookmarked sentence is `🔖 <mark>…</mark>`: inline HTML is CommonMark, and
    /// GitHub (whose filter keeps `mark`), Obsidian, Typora and VS Code show it highlighted; where an app draws no HTML,
    /// the sentence stays readable after its bookmark. (`==…==` is no CommonMark: GitHub shows the equals signs.) The
    /// bookmarks' list and the action items are lists under their headings; the action items a GitHub task list, a
    /// plain list where there are no checkboxes.
    static func markdown(_ snapshot: Snapshot) -> String {
        var lines = ["# \(markdownInline(snapshot.title))", "", "_\(markdownInline(snapshot.metaLine))_"]
        if !snapshot.tags.isEmpty {
            lines += ["", snapshot.tags.map { "#" + markdownInline($0.replacingOccurrences(of: " ", with: "-")) }
                .joined(separator: " ")]
        }
        if let summary = snapshot.summary {
            lines.append("")
            lines += summary.components(separatedBy: .newlines).map { line in
                let line = markdownLineStarts(markdownInline(line))
                return line.isEmpty ? ">" : "> " + line
            }
        }
        if !snapshot.bookmarks.isEmpty {
            lines += ["", "## \(markdownInline(snapshot.bookmarksHeading))", ""]
                + snapshot.bookmarks.map { "- **\(clock($0.time))** \(markdownInline($0.sentence))" }
        }
        // A task list: Notes, Obsidian and GitHub show checkboxes.
        if !snapshot.actionItems.isEmpty {
            lines += ["", "## \(markdownInline(snapshot.actionItemsHeading))", ""]
                + snapshot.actionItems.map { "- [ ] \(markdownInline($0))" }
        }
        lines.append("")
        for (index, paragraph) in snapshot.paragraphs.enumerated() {
            if let lead = lead(paragraph, snapshot), startsTurn(index, snapshot.paragraphs) {
                lines += ["**\(markdownInline(lead))**", ""]
            }
            let text = runs(paragraph).map { run in
                run.marked ? "🔖 <mark>\(markdownInline(run.text))</mark>" : markdownInline(run.text)
            }
            lines += [markdownLineStarts(text.joined()), ""]
        }
        lines += ["---", "", "_\(markdownInline(snapshot.aiNote))_", ""]
        return lines.joined(separator: "\n")
    }

    /// Text that stays text in Markdown: a character that would start emphasis, code, a link, HTML, a heading or
    /// GitHub's strikethrough backslash-escaped (CommonMark allows it before any ASCII punctuation), and an "&" that
    /// would read as an entity ("&amp;"). Rare in speech, so the file reads as typed.
    static func markdownInline(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if "\\`*_[]<#~".contains(character)
                || character == "&" && text[index...].prefixMatch(of: /&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/) != nil {
                out.append("\\")
            }
            out.append(character)
            index = text.index(after: index)
        }
        return out
    }

    /// Each line's start, so the line stays a paragraph's text: leading spaces dropped (four made a code block), a ">",
    /// "-", "+" or "=" (a quote, list, rule or heading underline) escaped, and a number's "." or ")" (a numbered
    /// list). "#", "*" and "_" are escaped everywhere (`markdownInline`).
    static func markdownLineStarts(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            var line = String(line.drop { $0 == " " || $0 == "\t" })
            if let first = line.first, ">-+=".contains(first) {
                line.insert("\\", at: line.startIndex)
            } else if let number = line.prefixMatch(of: /[0-9]{1,9}[.)]/) {
                line.insert("\\", at: line.index(before: number.range.upperBound))
            }
            return line
        }
        .joined(separator: "\n")
    }

    // MARK: Subtitles

    /// Cues of at most two lines (84 characters) and 6 s, never across a speaker change or a pause over 1 s.
    static func cues(_ words: [Word]) -> [(start: TimeInterval, end: TimeInterval, speaker: String?, text: String)] {
        var cues: [(start: TimeInterval, end: TimeInterval, speaker: String?, text: String)] = []
        for word in words {
            if var last = cues.last, last.speaker == word.speaker, word.start - last.end <= 1,
               word.end - last.start <= 6, last.text.count + 1 + word.text.count <= 84 {
                last.text += " " + word.text
                last.end = word.end
                cues[cues.count - 1] = last
            } else {
                cues.append((word.start, word.end, word.speaker, word.text))
            }
        }
        // Each cue stays up until the next one starts (at most 1 s longer than its last word), so short words are
        // readable.
        for i in cues.indices {
            let next = i + 1 < cues.count ? cues[i + 1].start : cues[i].end + 1
            cues[i].end = max(cues[i].end, min(next, cues[i].end + 1))
        }
        return cues
    }

    static func subtitles(_ snapshot: Snapshot, vtt: Bool) -> String {
        func time(_ seconds: TimeInterval) -> String {
            let ms = max(0, Int((seconds * 1000).rounded()))
            return String(format: vtt ? "%02d:%02d:%02d.%03d" : "%02d:%02d:%02d,%03d",
                          ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var blocks: [String] = vtt ? ["WEBVTT"] : []
        for (index, cue) in cues(snapshot.words).enumerated() {
            var text = twoLines(cue.text)
            if snapshot.names, let speaker = cue.speaker {
                text = vtt ? "<v \(speaker)>\(text)" : "\(speaker): \(text)"
            }
            let timing = "\(time(cue.start)) --> \(time(cue.end))"
            blocks.append(vtt ? "\(timing)\n\(text)" : "\(index + 1)\n\(timing)\n\(text)")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Over 42 characters (a subtitle line): broken at the space nearest the middle, so players show two even lines.
    static func twoLines(_ text: String) -> String {
        guard text.count > 42 else { return text }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let spaces = text.indices.filter { text[$0] == " " }
        guard let split = spaces.min(by: { abs(text.distance(from: middle, to: $0)) < abs(text.distance(from: middle, to: $1)) })
        else { return text }
        var lines = text
        lines.replaceSubrange(split...split, with: "\n")
        return lines
    }

    // MARK: PDF

    /// A4 pages with the card's order: title, date line, tags, summary, bookmarks, action items, the turns, and the AI
    /// note at the end; page numbers at the foot. Laid out with Core Text (`CTFramesetter`), page by page. A bookmarked
    /// sentence has the card's tint behind it (Core Text's background colour) and its bookmark, the SF Symbol the card
    /// shows, in a gap the text leaves for it (a run delegate), drawn after each page's text at the text's size.
    static func pdf(_ snapshot: Snapshot) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let body = page.insetBy(dx: 56, dy: 64)
        let symbol = snapshot.paragraphs.contains { !$0.marks.isEmpty } ? bookmarkImage() : nil
        let scale = textFont.pointSize / (symbol?.pointSize ?? 1)
        let symbolSize = CGSize(width: (symbol?.image.size.width ?? 0) * scale, height: (symbol?.image.size.height ?? 0) * scale)
        let symbolBaseline = (symbol?.baseline ?? 0) * scale
        let text = attributed(snapshot, symbol: symbolSize, symbolBaseline: symbolBaseline)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: {
            let format = UIGraphicsPDFRendererFormat()
            format.documentInfo = [kCGPDFContextTitle as String: snapshot.title, kCGPDFContextCreator as String: "Feder"]
            return format
        }())
        return renderer.pdfData { context in
            var location = 0
            var number = 1
            repeat {
                context.beginPage()
                let cg = context.cgContext
                cg.saveGState()
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: page.height)
                cg.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: CGRect(x: body.minX, y: page.height - body.maxY, width: body.width,
                                               height: body.height), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), path, nil)
                CTFrameDraw(frame, cg)
                let visible = CTFrameGetVisibleStringRange(frame)
                cg.restoreGState()
                if let symbol = symbol?.image {
                    // The bookmarks' gaps, from Core Text's coordinates (y up from the page's foot) to UIKit's.
                    let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
                    var origins = [CGPoint](repeating: .zero, count: lines.count)
                    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                    for (line, origin) in zip(lines, origins) {
                        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? []
                        where (CTRunGetAttributes(run) as NSDictionary)[bookmarkGap] != nil {
                            var position = CGPoint.zero
                            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                            let baseline = body.minY + body.height - origin.y      // UIKit: the frame's top is body.minY
                            symbol.draw(in: CGRect(x: body.minX + origin.x + position.x,
                                                   y: baseline + symbolBaseline - symbolSize.height,
                                                   width: symbolSize.width, height: symbolSize.height))
                        }
                    }
                }
                let footer = NSAttributedString(string: "\(number)", attributes: [
                    .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
                footer.draw(at: CGPoint(x: page.midX - footer.size().width / 2, y: page.height - 40))
                guard visible.length > 0 else { break }          // nothing fits: never loop forever
                location += visible.length
                number += 1
            } while location < text.length
        }
    }

    /// The transcript's text size in the PDF.
    private static var textFont: UIFont { .systemFont(ofSize: 11) }

    /// Marks the placeholder a bookmark is drawn over (`pdf`).
    private static let bookmarkGap = NSAttributedString.Key("FederBookmarkGap")

    /// A run delegate's size: the symbol's width, its height above and below the baseline.
    private struct GapSize { var width, ascent, descent: CGFloat }

    private static func attributed(_ snapshot: Snapshot, symbol: CGSize, symbolBaseline: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func style(before: CGFloat, after: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineHeightMultiple = 1.15
            if indent > 0 {                                  // a list's hanging indent: wrapped lines under the text
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                style.headIndent = indent
            }
            return style
        }
        func add(_ string: String, _ font: UIFont, _ color: UIColor = .black, before: CGFloat = 0, after: CGFloat = 0) {
            out.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style(before: before, after: after)]))
        }
        // The bookmark's gap in the text: an object replacement character, invisible, as wide as the symbol.
        let size = UnsafeMutablePointer<GapSize>.allocate(capacity: 1)
        size.initialize(to: GapSize(width: symbol.width, ascent: symbol.height - symbolBaseline, descent: symbolBaseline))
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { $0.assumingMemoryBound(to: GapSize.self).deallocate() },
            getAscent: { $0.assumingMemoryBound(to: GapSize.self).pointee.ascent },
            getDescent: { $0.assumingMemoryBound(to: GapSize.self).pointee.descent },
            getWidth: { $0.assumingMemoryBound(to: GapSize.self).pointee.width })
        let delegate = CTRunDelegateCreate(&callbacks, size)
        let tint = accent.withAlphaComponent(0.12).cgColor
        add(snapshot.title, .systemFont(ofSize: 22, weight: .bold), after: 4)
        add(snapshot.metaLine, .systemFont(ofSize: 10), .darkGray, after: 4)
        if !snapshot.tags.isEmpty { add(snapshot.tags.map { "#\($0)" }.joined(separator: "  "), .systemFont(ofSize: 10), .darkGray, after: 4) }
        if let summary = snapshot.summary { add(summary, .italicSystemFont(ofSize: 11), .darkGray, before: 6, after: 6) }
        if !snapshot.bookmarks.isEmpty {
            add(snapshot.bookmarksHeading, .systemFont(ofSize: 10.5, weight: .semibold), UIColor(white: 0.12, alpha: 1),
                before: 8, after: 2)
            let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let indent = ceil(snapshot.bookmarks.map {
                NSAttributedString(string: clock($0.time), attributes: [.font: timeFont]).size().width
            }.max() ?? 0) + 10
            for bookmark in snapshot.bookmarks {
                let entry = NSMutableAttributedString(string: clock(bookmark.time) + "\t",
                                                      attributes: [.font: timeFont, .foregroundColor: accent])
                entry.append(NSAttributedString(string: bookmark.sentence + "\n",
                                                attributes: [.font: textFont, .foregroundColor: UIColor.darkGray]))
                entry.addAttribute(.paragraphStyle, value: style(before: 0, after: 2, indent: indent),
                                   range: NSRange(location: 0, length: entry.length))
                out.append(entry)
            }
        }
        if !snapshot.actionItems.isEmpty {
            add(snapshot.actionItemsHeading, .systemFont(ofSize: 10.5, weight: .semibold), UIColor(white: 0.12, alpha: 1),
                before: 8, after: 2)
            for item in snapshot.actionItems { add("• " + item, .systemFont(ofSize: 11), after: 2) }
        }
        for (index, paragraph) in snapshot.paragraphs.enumerated() {
            let turn = startsTurn(index, snapshot.paragraphs)
            var before: CGFloat = turn ? 12 : 0
            if let lead = lead(paragraph, snapshot), turn {
                // Near black: a grey heading read as provisional next to the black text.
                add(lead, .systemFont(ofSize: 10.5, weight: .semibold), UIColor(white: 0.12, alpha: 1), before: 12, after: 2)
                before = 0
            }
            let text = NSMutableAttributedString()
            for run in runs(paragraph) {
                if run.marked, let delegate {
                    text.append(NSAttributedString(string: "\u{FFFC}", attributes: [
                        .font: textFont, .foregroundColor: UIColor.clear, bookmarkGap: true,
                        NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate]))
                    text.append(NSAttributedString(string: "\u{202F}", attributes: [.font: textFont]))   // as the card
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: UIColor.black]
                if run.marked { attributes[NSAttributedString.Key(kCTBackgroundColorAttributeName as String)] = tint }
                text.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            text.append(NSAttributedString(string: "\n", attributes: [.font: textFont]))
            text.addAttribute(.paragraphStyle, value: style(before: before, after: 4),
                              range: NSRange(location: 0, length: text.length))
            out.append(text)
        }
        add(snapshot.aiNote, .systemFont(ofSize: 8), .gray, before: 18)
        return out
    }

    // MARK: Word

    /// A minimal Office Open XML document (Word, Pages and Google Docs open it): the same order as the PDF, direct
    /// formatting, no styles part. Zipped without compression (`StoredZip`). A bookmarked sentence is shaded in the
    /// card's tint, after its bookmark: the SF Symbol as a small PNG, inline (an emoji's bookmark looked nothing like the
    /// card's, and Word has no symbol for it).
    static func docx(_ snapshot: Snapshot) throws -> Data {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        // Run properties in the schema's order (b, i, color, sz, shd): Word reads elements out of order as damage.
        func run(_ text: String, size: Int, bold: Bool = false, italic: Bool = false, color: String? = nil,
                 shade: String? = nil) -> String {
            var properties = bold ? "<w:b/>" : ""
            if italic { properties += "<w:i/>" }
            if let color { properties += "<w:color w:val=\"\(color)\"/>" }
            properties += "<w:sz w:val=\"\(size)\"/>"
            if let shade { properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(shade)\"/>" }
            return "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(escaped(text))</w:t></w:r>"
        }
        func paragraph(runs: String, before: Int = 0, after: Int = 120, hanging: Int = 0) -> String {
            let indent = hanging > 0 ? "<w:ind w:left=\"\(hanging)\" w:hanging=\"\(hanging)\"/>" : ""
            return "<w:p><w:pPr><w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/>\(indent)</w:pPr>\(runs)</w:p>"
        }
        func paragraph(_ text: String, size: Int, bold: Bool = false, italic: Bool = false, color: String? = nil,
                       before: Int = 0, after: Int = 120) -> String {
            paragraph(runs: run(text, size: size, bold: bold, italic: italic, color: color), before: before, after: after)
        }
        // The bookmark as large as the symbol at the text's 11 pt (drawn at 88 pt and scaled down).
        let symbol = snapshot.paragraphs.contains { !$0.marks.isEmpty } ? bookmarkImage() : nil
        let png = symbol?.image.pngData()
        var drawings = 0
        func bookmark() -> String {
            guard let symbol, png != nil else { return "" }
            drawings += 1
            let scale = 11 / symbol.pointSize * 12_700        // EMU per pixel: 12 700 per point
            let (cx, cy) = (Int(symbol.image.size.width * scale), Int(symbol.image.size.height * scale))
            return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
                + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(drawings)\" name=\"Bookmark \(drawings)\"/>"
                + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
                + "<pic:nvPicPr><pic:cNvPr id=\"\(drawings)\" name=\"bookmark.png\"/><pic:cNvPicPr/></pic:nvPicPr>"
                + "<pic:blipFill><a:blip r:embed=\"rIdBookmark\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
                + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>"
                + "</wp:inline></w:drawing></w:r>"
        }
        var body = paragraph(snapshot.title, size: 40, bold: true, after: 80)
        body += paragraph(snapshot.metaLine, size: 18, color: "666666", after: 80)
        if !snapshot.tags.isEmpty { body += paragraph(snapshot.tags.map { "#\($0)" }.joined(separator: "  "), size: 18, color: "666666") }
        if let summary = snapshot.summary { body += paragraph(summary, size: 21, italic: true, color: "555555", before: 120, after: 200) }
        if !snapshot.bookmarks.isEmpty {
            body += paragraph(snapshot.bookmarksHeading, size: 21, bold: true, color: "1F1F1F", before: 120, after: 40)
            let hanging = snapshot.bookmarks.contains { $0.time >= 3600 } ? 1000 : 720   // "1:02:03" is wider
            for item in snapshot.bookmarks {
                body += paragraph(runs: run(clock(item.time), size: 22, color: accentHex) + "<w:r><w:tab/></w:r>"
                                  + run(item.sentence, size: 22, color: "555555"), after: 40, hanging: hanging)
            }
        }
        if !snapshot.actionItems.isEmpty {
            body += paragraph(snapshot.actionItemsHeading, size: 21, bold: true, color: "1F1F1F", before: 120, after: 40)
            for item in snapshot.actionItems { body += paragraph("• " + item, size: 22, after: 40) }
        }
        for (index, item) in snapshot.paragraphs.enumerated() {
            let turn = startsTurn(index, snapshot.paragraphs)
            if let lead = lead(item, snapshot), turn {
                body += paragraph(lead, size: 20, bold: true, color: "1F1F1F", before: 240, after: 40)
            }
            body += paragraph(runs: runs(item).map { piece in
                piece.marked ? bookmark() + run("\u{202F}", size: 22) + run(piece.text, size: 22, shade: tintHex)
                             : run(piece.text, size: 22)
            }.joined())
        }
        body += paragraph(snapshot.aiNote, size: 16, color: "888888", before: 360)
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
            <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1418" w:right="1134" w:bottom="1418" \
            w:left="1134" w:header="709" w:footer="709" w:gutter="0"/></w:sectPr></w:body></w:document>
            """
        let types = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/word/document.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """
        let relations = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="word/document.xml"/></Relationships>
            """
        var files = [("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(relations.utf8)),
                     ("word/document.xml", Data(document.utf8))]
        if let png {
            let images = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rIdBookmark" \
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" \
                Target="media/bookmark.png"/></Relationships>
                """
            files += [("word/_rels/document.xml.rels", Data(images.utf8)), ("word/media/bookmark.png", png)]
        }
        return StoredZip.archive(files)
    }

    /// The card's bookmark (the SF Symbol, in the accent) as a bitmap drawn at `pointSize` (88: sharp when printed at
    /// 11 pt), with its baseline's height. A bitmap also in the PDF: the symbol drawn straight into the PDF became a
    /// plain block without its notch (Preview, Quick Look).
    static func bookmarkImage() -> (image: UIImage, baseline: CGFloat, pointSize: CGFloat)? {
        let pointSize: CGFloat = 88
        guard let symbol = UIImage(systemName: "bookmark.fill",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize))?
            .withTintColor(accent, renderingMode: .alwaysOriginal) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in symbol.draw(at: .zero) }
        return (image, symbol.baselineOffsetFromBottom ?? 0, pointSize)
    }
}

/// A ZIP archive without compression ("stored"), enough for a .docx: local headers, the central directory and its end
/// record, CRC-32 per file. (No dependency for one format; Foundation has no ZIP writer on iOS.)
nonisolated enum StoredZip {
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in files {
            let nameData = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            var local = Data()
            local.append(le32: 0x0403_4b50); local.append(le16: 20); local.append(le16: 0x0800)   // version, UTF-8 names
            local.append(le16: 0); local.append(le16: 0); local.append(le16: 0x21)                // stored, time, date
            local.append(le32: crc); local.append(le32: UInt32(data.count)); local.append(le32: UInt32(data.count))
            local.append(le16: UInt16(nameData.count)); local.append(le16: 0)
            out.append(local); out.append(nameData); out.append(data)
            central.append(le32: 0x0201_4b50); central.append(le16: 20); central.append(le16: 20)
            central.append(le16: 0x0800); central.append(le16: 0); central.append(le16: 0); central.append(le16: 0x21)
            central.append(le32: crc); central.append(le32: UInt32(data.count)); central.append(le32: UInt32(data.count))
            central.append(le16: UInt16(nameData.count)); central.append(le16: 0); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0); central.append(le32: 0); central.append(le32: offset)
            central.append(nameData)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4b50); out.append(le16: 0); out.append(le16: 0)
        out.append(le16: UInt16(files.count)); out.append(le16: UInt16(files.count))
        out.append(le32: UInt32(central.count)); out.append(le32: centralOffset); out.append(le16: 0)
        return out
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

nonisolated private extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

extension Recording {
    /// What an export of this transcript needs (TranscriptExport), read on the main actor. Speaker names only once the
    /// speakers are final, as in the plain text: live labels' numbers are unrelated to the final ones.
    /// `withWords`: the words with their speakers, for subtitles only (a second large SwiftData read).
    /// `places`: the card's bookmarked sentences (Bookmarks.places), found already; nil: found here, from the words.
    func exportSnapshot(names: Bool, timestamps: Bool, withWords: Bool = false,
                        places: [Bookmarks.Place]? = nil) -> TranscriptExport.Snapshot {
        let labelled = speakerStatus == .done
        let segments = self.segments
        func speaker(_ index: Int?) -> String? { labelled ? index.map(speakerName) : nil }
        // The words: for subtitles, and for the bookmarked sentences when the card hasn't found them (the list's Share,
        // a card still finishing its text): a second large read, so only then.
        let marks = bookmarks
        let allWords = withWords || !marks.isEmpty && places == nil ? self.words : []
        let found = marks.isEmpty ? [] : places ?? Bookmarks.places(marks, words: allWords, segments: segments)
        let ranges = Dictionary(grouping: found, by: \.segmentID).mapValues { $0.compactMap(\.range) }
        // Each word takes its paragraph's speaker: the paragraphs are folds of consecutive words, so one walk does it.
        var words: [TranscriptExport.Word] = []
        var segment = 0
        for word in withWords ? allWords : [] {
            while segment + 1 < segments.count, word.start >= segments[segment + 1].start - 0.001 { segment += 1 }
            let name = segments.indices.contains(segment) ? speaker(segments[segment].speakerIndex) : nil
            words.append(.init(speaker: name, start: word.start, end: word.end, text: word.text))
        }
        var meta = [createdAt.formatted(date: .long, time: .shortened), duration.clockFormatted]
        if let placeName { meta.append(placeName) }
        var snapshot = TranscriptExport.Snapshot(
            title: name, metaLine: meta.joined(separator: " · "),
            summary: summary?.isEmpty == false ? summary : nil, tags: tags,
            paragraphs: segments.map { segment in
                .init(speaker: speaker(segment.speakerIndex), start: segment.start, text: segment.text,
                      marks: ranges[segment.id] ?? [])
            },
            words: words, aiNote: String(localized: "AI-generated content can contain mistakes."),
            names: names && labelled, timestamps: timestamps)
        snapshot.actionItemsHeading = String(localized: "Action Items")
        snapshot.actionItems = actionItems.filter { !$0.isRemoved }.map(ActionItemText.line)
        snapshot.bookmarksHeading = String(localized: "Bookmarks")
        snapshot.bookmarks = found.map { .init(time: $0.time, sentence: $0.sentence) }
        return snapshot
    }
}
