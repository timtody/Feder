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
        /// "🔖 Bookmark · 3:21": the moments marked in it while recording (Bookmarks), written above it as the card
        /// shows them; nil: none. Not in subtitles.
        var bookmark: String? = nil
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

    static func plainText(_ snapshot: Snapshot) -> String {
        snapshot.paragraphs.enumerated().map { index, paragraph in
            let bookmark = paragraph.bookmark.map { $0 + "\n" } ?? ""
            if let lead = lead(paragraph, snapshot), startsTurn(index, snapshot.paragraphs) {
                return bookmark + "\(lead): \(paragraph.text)"
            }
            return bookmark + paragraph.text
        }
        .joined(separator: "\n\n")
    }

    static func markdown(_ snapshot: Snapshot) -> String {
        var lines = ["# \(snapshot.title)", "", "_\(snapshot.metaLine)_"]
        if !snapshot.tags.isEmpty { lines += ["", snapshot.tags.map { "#\($0.replacingOccurrences(of: " ", with: "-"))" }.joined(separator: " ")] }
        if let summary = snapshot.summary { lines += ["", "> \(summary)"] }
        // A task list: Notes, Obsidian and GitHub show checkboxes.
        if !snapshot.actionItems.isEmpty {
            lines += ["", "## \(snapshot.actionItemsHeading)", ""] + snapshot.actionItems.map { "- [ ] \($0)" }
        }
        lines.append("")
        for (index, paragraph) in snapshot.paragraphs.enumerated() {
            if let lead = lead(paragraph, snapshot), startsTurn(index, snapshot.paragraphs) {
                lines += ["**\(lead)**", ""]
            }
            if let bookmark = paragraph.bookmark { lines += ["_\(bookmark)_", ""] }
            lines += [paragraph.text, ""]
        }
        lines += ["---", "", "_\(snapshot.aiNote)_", ""]
        return lines.joined(separator: "\n")
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

    /// A4 pages with the card's order: title, date line, tags, summary, action items, the turns, and the AI note at the end; page
    /// numbers at the foot. Laid out with Core Text (`CTFramesetter`), page by page.
    static func pdf(_ snapshot: Snapshot) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let body = page.insetBy(dx: 56, dy: 64)
        let text = attributed(snapshot)
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
                let footer = NSAttributedString(string: "\(number)", attributes: [
                    .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
                footer.draw(at: CGPoint(x: page.midX - footer.size().width / 2, y: page.height - 40))
                guard visible.length > 0 else { break }          // nothing fits: never loop forever
                location += visible.length
                number += 1
            } while location < text.length
        }
    }

    private static func attributed(_ snapshot: Snapshot) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, _ font: UIFont, _ color: UIColor = .black, before: CGFloat = 0, after: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineHeightMultiple = 1.15
            out.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        add(snapshot.title, .systemFont(ofSize: 22, weight: .bold), after: 4)
        add(snapshot.metaLine, .systemFont(ofSize: 10), .darkGray, after: 4)
        if !snapshot.tags.isEmpty { add(snapshot.tags.map { "#\($0)" }.joined(separator: "  "), .systemFont(ofSize: 10), .darkGray, after: 4) }
        if let summary = snapshot.summary { add(summary, .italicSystemFont(ofSize: 11), .darkGray, before: 6, after: 6) }
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
            if let bookmark = paragraph.bookmark {
                add(bookmark, .systemFont(ofSize: 9.5, weight: .medium), .systemBlue, before: before, after: 2)
                before = 0
            }
            add(paragraph.text, .systemFont(ofSize: 11), before: before, after: 4)
        }
        add(snapshot.aiNote, .systemFont(ofSize: 8), .gray, before: 18)
        return out
    }

    // MARK: Word

    /// A minimal Office Open XML document (Word, Pages and Google Docs open it): the same order as the PDF, direct
    /// formatting, no styles part. Zipped without compression (`StoredZip`).
    static func docx(_ snapshot: Snapshot) throws -> Data {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func paragraph(_ text: String, size: Int, bold: Bool = false, italic: Bool = false, color: String? = nil,
                       before: Int = 0, after: Int = 120) -> String {
            var run = "<w:sz w:val=\"\(size)\"/>"
            if bold { run = "<w:b/>" + run }
            if italic { run = "<w:i/>" + run }
            if let color { run += "<w:color w:val=\"\(color)\"/>" }
            return "<w:p><w:pPr><w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/></w:pPr>"
                + "<w:r><w:rPr>\(run)</w:rPr><w:t xml:space=\"preserve\">\(escaped(text))</w:t></w:r></w:p>"
        }
        var body = paragraph(snapshot.title, size: 40, bold: true, after: 80)
        body += paragraph(snapshot.metaLine, size: 18, color: "666666", after: 80)
        if !snapshot.tags.isEmpty { body += paragraph(snapshot.tags.map { "#\($0)" }.joined(separator: "  "), size: 18, color: "666666") }
        if let summary = snapshot.summary { body += paragraph(summary, size: 21, italic: true, color: "555555", before: 120, after: 200) }
        if !snapshot.actionItems.isEmpty {
            body += paragraph(snapshot.actionItemsHeading, size: 21, bold: true, color: "1F1F1F", before: 120, after: 40)
            for item in snapshot.actionItems { body += paragraph("• " + item, size: 22, after: 40) }
        }
        for (index, item) in snapshot.paragraphs.enumerated() {
            let turn = startsTurn(index, snapshot.paragraphs)
            if let lead = lead(item, snapshot), turn {
                body += paragraph(lead, size: 20, bold: true, color: "1F1F1F", before: 240, after: 40)
            }
            if let bookmark = item.bookmark { body += paragraph(bookmark, size: 19, color: "1F5FBF", after: 40) }
            body += paragraph(item.text, size: 22)
        }
        body += paragraph(snapshot.aiNote, size: 16, color: "888888", before: 360)
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)\
            <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1418" w:right="1134" w:bottom="1418" \
            w:left="1134" w:header="709" w:footer="709" w:gutter="0"/></w:sectPr></w:body></w:document>
            """
        let types = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
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
        return StoredZip.archive([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(relations.utf8)),
                                  ("word/document.xml", Data(document.utf8))])
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
    func exportSnapshot(names: Bool, timestamps: Bool, withWords: Bool = false) -> TranscriptExport.Snapshot {
        let labelled = speakerStatus == .done
        let segments = self.segments
        func speaker(_ index: Int?) -> String? { labelled ? index.map(speakerName) : nil }
        // Each word takes its paragraph's speaker: the paragraphs are folds of consecutive words, so one walk does it.
        var words: [TranscriptExport.Word] = []
        var segment = 0
        for word in withWords ? self.words : [] {
            while segment + 1 < segments.count, word.start >= segments[segment + 1].start - 0.001 { segment += 1 }
            let name = segments.indices.contains(segment) ? speaker(segments[segment].speakerIndex) : nil
            words.append(.init(speaker: name, start: word.start, end: word.end, text: word.text))
        }
        var bookmarks = Bookmarks.byParagraph(self.bookmarks, in: segments)
        // Two in one paragraph may be on one sentence: written once, as the card lists it (Bookmarks.places). The words
        // are read only then, a large read.
        if bookmarks.values.contains(where: { $0.count > 1 }) {
            let marks = Bookmarks.places(self.bookmarks, words: self.words, segments: segments).map(\.time)
            bookmarks = Bookmarks.byParagraph(marks, in: segments)
        }
        var meta = [createdAt.formatted(date: .long, time: .shortened), duration.clockFormatted]
        if let placeName { meta.append(placeName) }
        var snapshot = TranscriptExport.Snapshot(
            title: name, metaLine: meta.joined(separator: " · "),
            summary: summary?.isEmpty == false ? summary : nil, tags: tags,
            paragraphs: segments.map { segment in
                .init(speaker: speaker(segment.speakerIndex), start: segment.start, text: segment.text,
                      bookmark: bookmarks[segment.id].map { "🔖 " + Bookmarks.line($0) })
            },
            words: words, aiNote: String(localized: "AI-generated content can contain mistakes."),
            names: names && labelled, timestamps: timestamps)
        snapshot.actionItemsHeading = String(localized: "Action Items")
        snapshot.actionItems = actionItems.filter { !$0.isRemoved }.map(ActionItemText.line)
        return snapshot
    }
}
