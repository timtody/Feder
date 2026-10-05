import SwiftUI

/// The live screen's transcript. The provisional words follow the finalized ones, lighter, and firm up in place; each is
/// placed under its newest live label, so a new speaker starts a new paragraph at once. New words are readable at once
/// and settle within 0.2 s. A speaker's coloured name appears above a turn once its label held (LiveTranscript). It
/// follows new text while scrolled to the bottom; scrolling up stops that and offers "Jump to Live".
struct LiveTranscriptView: View {
    let text: LiveText

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = LiveTranscriptModel()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true
    @State private var isUserScrolling = false

    @ScaledMetric(relativeTo: .body) private var topFade: CGFloat = 20   // about half a line

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.paragraphs) { paragraph in
                    LiveParagraphRow(paragraph: paragraph)
                        .animation(reduceMotion ? nil : .smooth) { row in   // a turn that just became known eases open
                            row.padding(.top, paragraph.id == 0 ? 0
                                        : paragraph.startsTurn ? TranscriptStyle.turnSpacing : TranscriptStyle.paragraphSpacing)
                        }
                }
            }
            .transcriptText()
            .padding(.horizontal, TranscriptStyle.margin)
            .padding(.bottom, 24)
            .frame(maxWidth: TranscriptStyle.maxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(isFollowing ? .bottom : nil, for: .sizeChanges)   // follow: keep the newest line in view
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .interacting || phase == .decelerating
        }
        .onScrollGeometryChange(for: BottomState.self) { BottomState($0) } action: { old, new in
            if new.isAtBottom {
                isFollowing = true
            } else if isFollowing, !isUserScrolling, new.height > old.height {
                position.scrollTo(edge: .bottom)   // text outgrew the view where the size-change anchor doesn't apply
            } else {
                isFollowing = false                // any other move off the bottom (drag, status bar, VoiceOver, keys)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .contentMargins(.top, topFade, for: .scrollContent)
        .mask {                                    // a soft top edge instead of lines cut through under the header
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: topFade)
                Color.black
            }
            .ignoresSafeArea(edges: .bottom)       // keep the text under the Stop bar for its scroll edge effect
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if !isFollowing {
                    Button("Jump to Live", systemImage: "arrow.down", action: jumpToLive)
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.glass)
                        .padding(.bottom, 12)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.smooth(duration: 0.25), value: isFollowing)
        }
        .onChange(of: text, initial: true) { update() }
        #if DEBUG
        .task {                                    // QA hook: `-scrollUpAfter <seconds>` scrolls up as a user would
            let seconds = UserDefaults.standard.double(forKey: "scrollUpAfter")
            guard seconds > 0 else { return }
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            isFollowing = false
            position.scrollTo(edge: .top)
        }
        #endif
    }

    private func update() {
        model.update(text, fades: !reduceMotion)
    }

    private func jumpToLive() {
        isFollowing = true
        withAnimation(reduceMotion ? nil : .smooth) { position.scrollTo(edge: .bottom) }
    }
}

/// What following needs from the scroll geometry: whether it is at the end, and whether the text grew.
private struct BottomState: Equatable {
    var isAtBottom: Bool
    var height: CGFloat

    /// At the end (within half a line): the visible rect reaches the content's end above the bottom inset.
    init(_ geometry: ScrollGeometry) {
        isAtBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 16
        height = geometry.contentSize.height
    }
}

/// One paragraph of the live transcript as drawn.
struct LiveParagraph: Identifiable, Equatable {
    let id: Int                    // position: the live transcript only grows at the end, so rows keep their place
    var speakerIndex: Int?         // confirmed live label (SteadyLabels), nil = none yet
    var startsTurn = false         // a different speaker than the last labelled paragraph above: extra space
    var showsName = false          // first paragraph of a labelled speaker turn: the coloured name goes above it
    var text: String               // finalized words, then the provisional ones, separated by single spaces
    var provisionalCount = 0       // how many of the last words are provisional (drawn lighter)
    var births: [Date] = []        // per word while any is fading in: when it appeared (.distantPast = settled); else []
    var nameKey: LiveNames.Key?    // its first word and shown speaker (LiveNames)

    var isFading: Bool { !births.isEmpty }
    var words: [Substring] { text.split(separator: " ", omittingEmptySubsequences: false) }

    /// Settled words as plain runs, provisional words lighter, words still fading in tagged with their birth.
    var styledText: Text {
        guard isFading || provisionalCount > 0 else { return Text(verbatim: text) }
        let words = self.words
        let firstProvisional = words.count - provisionalCount
        func birth(_ i: Int) -> Date? { i < births.count && births[i] != .distantPast ? births[i] : nil }
        var styled = Text(verbatim: "")
        var start = 0
        for end in 1...words.count {               // one run per stretch of words that look the same
            if end < words.count, (end >= firstProvisional) == (start >= firstProvisional), birth(end) == birth(start) {
                continue
            }
            var run = Text(verbatim: (start == 0 ? "" : " ") + words[start..<end].joined(separator: " "))
            if start >= firstProvisional { run = run.foregroundStyle(.secondary) }
            if let born = birth(start) { run = run.customAttribute(WordBirth(date: born)) }
            styled = Text("\(styled)\(run)")
            start = end
        }
        return styled
    }
}

private struct LiveParagraphRow: View, Equatable {
    let paragraph: LiveParagraph

    var body: some View {
        let _ = LiveTrace.body(paragraph: paragraph.id)
        let text = paragraph.styledText            // built once per change, not once per frame
        VStack(alignment: .leading, spacing: 6) {
            if paragraph.showsName, let speaker = paragraph.speakerIndex {
                Text("Speaker \(speaker + 1)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpeakerPalette.color(speaker))
                    .transition(.opacity)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !paragraph.isFading)) { context in
                text.textRenderer(WordFadeRenderer(now: context.date))
            }
        }
        .accessibilityElement(children: .ignore)          // one element: VoiceOver reads the name and text once
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(paragraph.speakerIndex.map { Text("Speaker \($0 + 1): \(paragraph.text)") }
                            ?? Text(verbatim: paragraph.text))
    }
}

/// Builds the live paragraphs and remembers when each word appeared. Births carry over by word order through the whole
/// transcript, so a word keeps its birth when it firms up (also with changed case or punctuation) or moves into another
/// paragraph (a speaker change); only new or changed words fade in.
@MainActor @Observable
final class LiveTranscriptModel {
    private(set) var paragraphs: [LiveParagraph] = []
    @ObservationIgnored private var segments: [TranscriptSegment] = []      // of the last update
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var names = LiveNames()

    /// Called with every change of the session's live text (a few times per second). The paragraphs of segments that
    /// did not change are kept as they are (a long recording has hundreds; usually only the last one or two change), then
    /// a word diff from the first paragraph whose text changed assigns the births.
    func update(_ live: LiveText, fades: Bool) {
        let start = ContinuousClock.now
        var kept = 0                               // not the last segment's paragraph: provisional words may continue it
        let keepable = min(live.segments.count, segments.count - 1, paragraphs.count)
        while kept < keepable, live.segments[kept] == segments[kept] { kept += 1 }
        segments = live.segments
        var drafts = Array(paragraphs[..<kept])
        for i in kept..<live.segments.count {
            drafts.append(LiveParagraph(id: i, speakerIndex: live.segments[i].speakerIndex, text: live.segments[i].text,
                                        nameKey: i < live.segmentKeys.count ? live.segmentKeys[i] : nil))
        }
        // Each provisional word goes under its newest live label (none yet: with the word before) and continues the
        // last paragraph unless that speaker differs, a pause over the paragraph gap came first, or the paragraph is
        // full (TranscriptAligner.isFull): SteadyLabels' own rules (`continues`, `newLabel`), which it applies once the
        // words are final, so firming up rarely moves them. A paragraph shows its speaker once a word's label held there.
        var end = live.segments.last?.end
        var previous = live.speaker                // the speaker the word before is shown under
        for provisional in live.provisional {
            let word = provisional.word
            let count = word.text.split(separator: " ", omittingEmptySubsequences: false).count
            let full = drafts.last.map { TranscriptAligner.isFull($0.text) } ?? false
            let speaker = provisional.speaker ?? previous
            let confirmed = provisional.steady != nil && provisional.steady == speaker
            if SteadyLabels.continues(lastEnd: end, full: full, speaker: speaker, previous: previous, start: word.start) {
                drafts[drafts.count - 1].text += " " + word.text
                drafts[drafts.count - 1].provisionalCount += count
                if confirmed { drafts[drafts.count - 1].speakerIndex = speaker }
            } else {
                let label = SteadyLabels.newLabel(speaker: speaker, previous: previous, confirmed: confirmed, full: full)
                drafts.append(LiveParagraph(id: drafts.count, speakerIndex: label, text: word.text, provisionalCount: count,
                                            nameKey: speaker.map { LiveNames.Key(word: provisional.id, speaker: $0) }))
            }
            previous = speaker
            end = word.end
        }
        // A name once shown stays while its paragraph keeps its first word and speaker (LiveNames).
        let shown = names.labels(drafts.map(\.speakerIndex), keys: drafts.map(\.nameKey))
        for i in drafts.indices { drafts[i].speakerIndex = shown[i] }
        var speaker = drafts[..<kept].last { $0.speakerIndex != nil }?.speakerIndex   // last labelled paragraph's speaker
        for i in kept..<drafts.count {
            guard let index = drafts[i].speakerIndex else { continue }
            drafts[i].startsTurn = speaker.map { $0 != index } ?? false
            drafts[i].showsName = speaker != index
            speaker = index
        }
        let now = Date.now
        if fades { assignBirths(to: &drafts, from: kept, now: now) }
        // Births older than the fade become .distantPast, all-settled ones (all, without fades) [].
        let settled = now - WordFadeRenderer.duration
        var same = kept                            // drafts before this index equal `paragraphs`
        var newest: Date?
        for i in drafts.indices where drafts[i].isFading {
            let births = fades && drafts[i].births.contains { $0 > settled }
                ? drafts[i].births.map { $0 > settled ? $0 : .distantPast } : []
            if i < same, births != drafts[i].births { same = i }
            drafts[i].births = births
            if let latest = births.max() { newest = max(newest ?? latest, latest) }
        }
        LiveTrace.modelUpdated(start: start, firstChanged: drafts.indices.dropFirst(same).first {   // nil: nothing new
            $0 >= paragraphs.count || drafts[$0] != paragraphs[$0]
        })
        guard drafts.count != paragraphs.count || drafts[same...] != paragraphs[same...] else { return }
        paragraphs = drafts
        settle?.cancel()
        guard let newest else { return }
        settle = Task { [weak self] in             // once everything has faded in: plain text, timelines paused
            try? await Task.sleep(for: .seconds(newest.timeIntervalSinceNow + WordFadeRenderer.duration))
            guard !Task.isCancelled, let self else { return }
            self.paragraphs = self.paragraphs.map { paragraph in
                var paragraph = paragraph
                paragraph.births = []
                return paragraph
            }
        }
    }

    /// Each word of the paragraphs from the first changed one on takes the birth of the same word at its place in the old
    /// text (or up to three words further, after a revision dropped some); unmatched words are born now, staggered a
    /// little when several arrive together. Paragraphs before `kept` are the old ones already.
    private func assignBirths(to drafts: inout [LiveParagraph], from kept: Int, now: Date) {
        let first = drafts.indices.dropFirst(kept).first { $0 >= paragraphs.count || paragraphs[$0].text != drafts[$0].text }
            ?? drafts.count
        var oldWords: [Substring] = []
        var oldBirths: [Date] = []
        for paragraph in paragraphs.dropFirst(first) {
            let words = paragraph.words
            oldWords += words
            oldBirths += paragraph.isFading ? paragraph.births : Array(repeating: .distantPast, count: words.count)
        }
        var next = 0                               // first old word not matched yet
        var born = 0                               // words born in this update, for the stagger
        for i in drafts.indices.dropFirst(kept) {
            guard i >= first else { drafts[i].births = paragraphs[i].births; continue }
            drafts[i].births = drafts[i].words.map { word in
                if let match = (next..<min(next + 4, oldWords.count))
                    .first(where: { VolatileTimer.isSame(oldWords[$0], word) }) {
                    next = match + 1
                    return oldBirths[match]
                }
                born += 1
                return now + min(Double(born - 1) * WordFadeRenderer.stagger, WordFadeRenderer.maxStagger)
            }
        }
    }
}

/// When a word appeared, read by WordFadeRenderer.
nonisolated struct WordBirth: TextAttribute {
    var date: Date
}

/// Fades words in without hiding them: a run tagged with a WordBirth is drawn at `startOpacity` the moment it appears
/// (readable at once, in place, unblurred) and reaches full opacity over `duration`. The text used to start transparent,
/// blurred and low and needed 0.45 s plus up to 0.4 s of stagger, so the console showed words well before the screen
/// did. Everything else draws as usual. With Reduce Motion nothing fades (LiveTranscriptModel gets no births).
nonisolated struct WordFadeRenderer: TextRenderer {
    static let duration: TimeInterval = 0.15
    static let startOpacity = 0.6
    static let stagger: TimeInterval = 0.025       // between words that arrive together
    static let maxStagger: TimeInterval = 0.05

    var now: Date

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        LiveTrace.drawn()
        for line in layout {
            for run in line {
                guard let born = run[WordBirth.self]?.date else { context.draw(run); continue }
                let t = min(max(now.timeIntervalSince(born) / Self.duration, 0), 1)
                guard t < 1 else { context.draw(run); continue }
                var faded = context
                faded.opacity = Self.startOpacity + (1 - Self.startOpacity) * t * (2 - t)   // ease out
                faded.draw(run)
            }
        }
    }
}
