import SwiftUI

/// Ask (FED-17, a prototype): a chat with Gemma on this iPhone, to try how talking to it feels before it answers from
/// the transcripts. A card that zooms out of the record accessory's Ask button (MainView's sheet) at full height (typing
/// took it there anyway; a drag down closes it): New Chat at the top, the field at the bottom, over the keyboard while
/// typing. Laid out like Claude's app (the user's reference, FED-137): the questions in calm grey bubbles on the right,
/// Gemma's answers as plain text on the left, suggestions over the field while the chat is empty, and a field of two rows
/// (the text, then the microphone and Send) in glass, the conversation fading milkily under it. SwiftUI has no chat
/// component; the pieces are system ones. DEBUG builds only, on iPhones that run Gemma (`isAvailable`); no CHANGELOG line until it
/// ships. Until October 2026 it was a tab of its own, with its field as the tab bar's accessory on that tab.
struct ChatView: View {
    /// Ask's general chat, or one about a transcript (FED-137: from its More menu), whose title is the subtitle.
    let chat: GemmaChat
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    /// The field grows with the text up to five lines; the button stays a 32 pt circle (as in Messages).
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The conversation's scroll position: to the end by its edge, which counts the field and keyboard over it
    /// (a message's id as anchor left the last lines under the field now and then, FED-137).
    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether the conversation shows its end: scrolled up, a glass arrow takes it back (as Jump to Live does).
    @State private var isAtEnd = true
    /// The conversation's visible height (the room between the title and the field or the keyboard): the empty chat's
    /// glow only where it fits.
    @State private var visibleHeight: CGFloat = 600
    @State private var dictation = ChatDictation()
    /// What was typed when dictation started: the dictated words follow it.
    @State private var typedBefore = ""

    /// Whether Ask exists: DEBUG builds on an iPhone that runs Gemma (8 GB; the simulator with `-fakeGemma`).
    static var isAvailable: Bool {
        #if DEBUG
        BetterSummaries.isSupported
        #else
        false
        #endif
    }

    /// The zoom source of the card: the accessory's Ask button (MainView's namespace).
    static let askSource = "ask"

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Ask Gemma")
                .navigationSubtitle(chat.transcript?.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier("CloseAsk")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Chat", systemImage: "square.and.pencil") {
                            chat.newChat()
                        }
                        .disabled(chat.messages.isEmpty && chat.draft.isEmpty)
                    }
                }
                // A bar (not an inset): the conversation scrolling under it fades out in the soft scroll edge effect,
                // the milky look of the recording view's controls; the suggestions and the two-row field make it tall
                // enough to read as such (the hard style drew a line instead).
                .safeAreaBar(edge: .bottom) {
                    if services.betterSummaries.state == .ready {
                        VStack(spacing: 10) {
                            if chat.messages.isEmpty, !isRecording { suggestions }
                            composer
                        }
                        .padding(.top, 12)
                    }
                }
        }
        // Full height only (FED-137): at half height the first tap into the field took it to full anyway, and the card
        // changed colour on the way (glass at half height, opaque at full). A drag down closes it, as any sheet.
        .presentationDetents([.large])
        .onAppear { InteractionTrace.shown("ask") }
        // A recording started from outside (the Action Button, Control Center): Gemma pauses, the keyboard goes, and
        // MainView closes the card for the recording's.
        .onChange(of: isRecording) { _, recording in
            if recording {
                isFocused = false
                Task { await dictation.stop() }        // the microphone is the recording's
            }
        }
        // The keyboard and the field's growth move the end of the conversation: to the end again once they have
        // settled (the keyboard's animation takes about 0.4 s).
        .onChange(of: isFocused) { scrollToEndSoon() }
        .onDisappear { Task { await dictation.stop() } }
    }

    @ViewBuilder private var content: some View {
        let better = services.betterSummaries
        if better.state != .ready {
            ContentUnavailableView {
                Label("Download Gemma to Chat", systemImage: "arrow.down.circle")
            } description: {
                Text("Gemma runs on this iPhone. Nothing you type leaves it.")
            } actions: {
                downloadState
            }
        } else {
            // The empty chat's text over the (empty) conversation, not instead of it: swapping the views on the first
            // Send put the keyboard away (iOS 27 simulator), and Messages keeps it up.
            conversation
        }
    }

    /// The empty chat (FED-137): a sparkle in a slowly breathing glow (ChatGlow), the greeting in New York (the serif
    /// of Gemma's answers), the transcript's title when the chat is about one, and a quiet line that it all stays here.
    private func hero(glow: Bool) -> some View {
        VStack(spacing: 10) {
            if glow {
                ZStack {
                    ChatGlow()
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(LinearGradient(colors: [.accentColor, .purple], startPoint: .topLeading,
                                                        endPoint: .bottomTrailing))
                        .symbolEffect(.breathe, isActive: !reduceMotion)
                }
                .frame(height: 130)
            }
            if let transcript = chat.transcript {
                Text("Ask About This Transcript")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(transcript.title)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.serif)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            } else {
                Text("What would you like to know?")
                    .font(.title2.weight(.semibold))
                    .fontDesign(.serif)
                    .multilineTextAlignment(.center)
            }
            Label(isRecording ? "Gemma pauses while you record." : "On this iPhone. Nothing leaves it.",
                  systemImage: isRecording ? "pause.circle" : "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, glow ? 40 : 0)              // optically centred over the suggestions and the field
    }

    /// The download as Settings › Summaries shows it (ModelDownloadRow), without the Form around it.
    @ViewBuilder private var downloadState: some View {
        let better = services.betterSummaries
        switch better.state {
        case .waitingForWiFi:
            Text("Waiting for Wi-Fi…").foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading \(better.variant.displayName)…")
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
            }
            .frame(maxWidth: 280)
        default:
            if case .failed(let reason) = better.state {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Download \(better.variant.displayName) (\(better.variant.sizeText))") { better.download() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var conversation: some View {
        ScrollView {
            // The empty chat's hero inside the scroll view, filling what it shows: beside it in a ZStack its fixed
            // height (the glow, the greeting) won against the safe-area bar when the keyboard left little room, and
            // the bar was squeezed: the field stopped growing at two lines, and its accessibility frames lagged 35 pt
            // behind the drawing (taps landed on the keyboard's predictions). Scrolled content never pushes on the bar.
            // As a background the greeting wasn't drawn at all (iOS 27 simulator).
            if chat.messages.isEmpty {
                hero(glow: visibleHeight >= 380)      // the keyboard up: no glow, the greeting stays
                    .containerRelativeFrame([.horizontal, .vertical])
                    .allowsHitTesting(false)          // a drag over it reaches the scroll view and puts the keyboard away
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(chat.messages) { message in
                    ChatMessageRow(message: message, retry: chat.retry)
                        .id(message.id)
                        // A new message rises into place (a question from the field, an answer under it).
                        .transition(reduceMotion ? AnyTransition.opacity
                                    : AnyTransition.opacity.combined(with: .offset(y: 16))
                                        .combined(with: .scale(scale: 0.98, anchor: .bottom)))
                }
                // A recording started while the card was up (it closes for the recording's): said here meanwhile.
                if isRecording, !chat.messages.isEmpty {
                    Label("Gemma pauses while you record.", systemImage: "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .id("paused")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, chat.messages.isEmpty ? 0 : 12)   // empty: the hero alone fills the view, no scrolling
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: chat.messages.count)
        }
        // Opens at the end, and stays there while the answer grows (as Messages follows a conversation).
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // The visible rect, not the offset: a short conversation sits at the bottom by a top inset as tall as the
            // gap above it, and `containerSize` leaves the insets out (measured: offset -554, container 611, insets
            // 554/131 for 151 pt of content at its end).
            geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40
        } action: { _, atEnd in
            withAnimation(.smooth(duration: 0.25)) { isAtEnd = atEnd }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, height in
            withAnimation(.smooth(duration: 0.25)) { visibleHeight = height }
        }
        .overlay(alignment: .bottom) {                // over the field: the safe-area bar is under this edge
            if !isAtEnd, !chat.messages.isEmpty {
                Button("Scroll to End", systemImage: "arrow.down") {
                    withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(.bottom, 10)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
                .accessibilityIdentifier("ScrollToEnd")
            }
        }
        .onChange(of: chat.messages.count) {
            withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
        }
        // A light tap with every question sent (the field's Send or a suggestion), as Messages gives one.
        .sensoryFeedback(.impact(weight: .light), trigger: chat.messages.count) { old, new in new > old }
        .onChange(of: chat.draft.filter(\.isNewline).count) { scrollToEndSoon() }
    }

    private func scrollToEndSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
        }
    }

    private var isRecording: Bool { services.identifier.isRecording }

    /// Speak the question (ChatDictation): the words come into the field as they are heard, after what was typed.
    /// Pressed again, it stops; Send stops it too.
    private var microphoneButton: some View {
        Button {
            if dictation.isActive {
                Task { await dictation.stop() }
            } else {
                typedBefore = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                dictation.start(makeTranscriber: services.makeDictationTranscriber) { [chat, typedBefore] text in
                    chat.draft = typedBefore.isEmpty ? text : typedBefore + " " + text
                }
            }
        } label: {
            Group {
                if dictation.state == .preparing {
                    ProgressView()
                } else {
                    Image(systemName: dictation.isActive ? "waveform" : "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(dictation.isActive ? Color.white : Color.primary)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.isActive && !reduceMotion)
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(dictation.isActive ? Color.red : Color.primary.opacity(0.1)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isRecording || services.identifier.isRecording)
        .accessibilityLabel(dictation.isActive ? "Stop Dictating" : "Dictate")
        .accessibilityIdentifier("ChatDictate")
        .alert("Can't Dictate", isPresented: Binding(
            get: { if case .failed = dictation.state { true } else { false } },
            set: { _ in })) {
            Button("OK", role: .cancel) { Task { await dictation.stop() } }
        } message: {
            if case .failed(let reason) = dictation.state { Text(reason) }
        }
    }

    /// The field at the bottom of the card, over the keyboard while typing, in two rows as in Claude's app: the text
    /// (up to five lines, Return is a new line, ⌘↩ sends), then the microphone and Send on the right. One row put the
    /// microphone lower than Send (the row was bottom-aligned and only Send had padding), and was too thin to read as a
    /// place to talk.
    private var composer: some View {
        @Bindable var chat = chat
        return VStack(alignment: .leading, spacing: 2) {
            TextField(isRecording ? LocalizedStringKey("Gemma pauses while you record.") : "Ask Gemma",
                      text: $chat.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .disabled(isRecording)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .accessibilityIdentifier("ChatField")
            HStack(spacing: 10) {
                Spacer()
                microphoneButton
                ChatSendButton(chat: chat, isRecording: isRecording) {
                    dictation.detach()                       // its words would fill the field again after the send
                    Task { await dictation.stop() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(minHeight: minHeight)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// While the chat is empty: questions to start with, in glass capsules over the field (as Claude's and ChatGPT's
    /// apps offer them), each with a small glyph, wrapping onto a second line rather than running off the edge; a tap
    /// asks it. In the language of the app, so Gemma answers in it.
    private var suggestions: some View {
        WrappingLayout(spacing: 8, lineSpacing: 8) {
            ForEach(suggestionList, id: \.text) { suggestion in
                Button {
                    ask(suggestion.text)
                } label: {
                    Label(suggestion.text, systemImage: suggestion.symbol)
                        .labelStyle(SuggestionLabelStyle())
                }
                .font(.subheadline)
                .buttonStyle(.glass)
                .accessibilityIdentifier("AskSuggestion")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private var suggestionList: [(text: String, symbol: String)] {
        guard let transcript = chat.transcript else {
            return [(String(localized: "What can you do?"), "sparkles"),
                    (String(localized: "Help me plan my day"), "calendar"),
                    (String(localized: "Explain something simply"), "lightbulb")]
        }
        return [(String(localized: "Summarize this transcript"), "text.alignleft")]
            + (transcript.highlights.isEmpty ? [] : [(String(localized: "What did I bookmark?"), "bookmark")])
            + [(String(localized: "List the action items"), "checklist"),
               (String(localized: "What did each person say?"), "person.2")]
    }

    private func ask(_ text: String) {
        guard services.betterSummaries.state == .ready, !chat.isAnswering, !isRecording else { return }
        dictation.detach()
        Task { await dictation.stop() }
        chat.send(text)
    }
}

/// Send (an accent circle with an arrow), Stop while Gemma answers, at the end of the field.
struct ChatSendButton: View {
    @Environment(AppServices.self) private var services
    let chat: GemmaChat
    var isRecording = false
    /// Before the question is sent: the card stops dictation here.
    var beforeSend: () -> Void = {}

    private var canSend: Bool {
        !isRecording && services.betterSummaries.state == .ready
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button {
            if chat.isAnswering {
                chat.stop()
            } else {
                InteractionTrace.begin("send"); InteractionTrace.shown("send")
                beforeSend()
                chat.send(chat.draft)
                chat.draft = ""
            }
        } label: {
            Image(systemName: chat.isAnswering ? "stop.fill" : "arrow.up")
                .font(.system(size: chat.isAnswering ? 13 : 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(chat.isAnswering || canSend ? Color.accentFill : Color(.systemGray3)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!chat.isAnswering && !canSend)
        .keyboardShortcut(.return, modifiers: .command)        // ⌘↩ with a hardware keyboard; ↩ is a new line
        .accessibilityLabel(chat.isAnswering ? "Stop Answer" : "Send")
        .accessibilityShowsLargeContentViewer()
    }
}

/// A question (a grey bubble on the right) or an answer (New York on the left, selectable; a shimmering "Thinking…"
/// until the first token; Copy, "Stopped" or the failure under it).
private struct ChatMessageRow: View {
    let message: ChatMessage
    let retry: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 20, style: .continuous))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.status == .thinking {
                    ThinkingShimmer()
                } else if !message.text.isEmpty {
                    // New York for what Gemma writes (as Claude's app sets its answers in a serif): reads as an answer,
                    // set apart from the questions without a bubble of its own.
                    Text(message.rendered)
                        .fontDesign(.serif)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ChatAnswer")
                }
                switch message.status {
                case .done:
                    ChatCopyButton(text: message.text)
                        .padding(.leading, -8)                // the glyph, not its tap area, lines up with the text
                case .stopped:
                    Text("Stopped").font(.footnote).foregroundStyle(.secondary)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again", action: retry)
                        .font(.footnote.weight(.semibold))
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A suggestion's glyph a little smaller and quieter than its text.
private struct SuggestionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}
