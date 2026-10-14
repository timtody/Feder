import SwiftUI

/// The Ask tab (FED-17, a prototype): a chat with Gemma on this iPhone, to try how talking to it feels before it answers
/// from the transcripts. Laid out like Messages: the questions in tinted bubbles on the right, Gemma's answers as plain
/// text on the left (as Apple Intelligence's and other assistants' answers read). The field is the tab bar's bottom
/// accessory on this tab (`ChatAccessory`, where the other tabs show Transcribe, as Music's mini player sits there);
/// a tap on it brings up the keyboard with the editing field (`composer`) riding on it in the bottom safe-area bar.
/// SwiftUI has no chat component; the pieces are system ones. DEBUG builds only, on iPhones that run Gemma
/// (`isAvailable`); no CHANGELOG line until it ships.
///
/// Why two fields: a TextField inside `tabViewBottomAccessory` takes the focus, but the accessory stays where the tab
/// bar is, so the keyboard covers it (and what is typed), and the system keeps it one capsule high, so the text can't
/// grow to five lines (iOS 27 simulator, iPhone 17: the field stayed at y 735–783 under a keyboard from y 590). So the
/// accessory shows the draft and opens the composer, which lives over the keyboard while editing, as the search
/// field of a search tab rises from the tab bar's place with the keyboard; the keyboard covers the accessory meanwhile.
struct ChatView: View {
    @Environment(AppServices.self) private var services
    @FocusState private var isFocused: Bool
    /// The composer grows with the text up to five lines; the button stays a 32 pt circle (as in Messages).
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 44

    /// Whether the tab exists: DEBUG builds on an iPhone that runs Gemma (8 GB; the simulator with `-fakeGemma`).
    static var isAvailable: Bool {
        #if DEBUG
        BetterSummaries.isSupported
        #else
        false
        #endif
    }

    var body: some View {
        let chat = services.chat
        NavigationStack {
            content
                .navigationTitle("Ask")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Chat", systemImage: "square.and.pencil") {
                            chat.newChat()
                        }
                        .disabled(chat.messages.isEmpty)
                    }
                }
                .safeAreaBar(edge: .bottom) {
                    if chat.isComposing { composer }
                }
        }
        // The keyboard went away (a scroll, another tab, the card): the draft goes back into the accessory.
        // Both a moment late: in one run of four (iOS 27 simulator, the first keyboard after launch) the composer came
        // and went at once, the focus dropped while the accessory stepped aside under it.
        .onChange(of: isFocused) { _, focused in
            guard !focused else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !isFocused { chat.isComposing = false }
            }
        }
        .onChange(of: chat.isComposing) { _, composing in
            guard composing else { return }
            Task {
                for _ in 0..<4 where !isFocused {
                    isFocused = true
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }
        // A recording started from outside (the Action Button, Control Center) takes the accessory: the keyboard goes.
        .onChange(of: isRecording) { _, recording in
            if recording { isFocused = false }
        }
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
            ZStack {
                conversation
                if services.chat.messages.isEmpty {
                    ContentUnavailableView {
                        Label("Ask Gemma", systemImage: "bubble.left")
                    } description: {
                        Text(isRecording ? "Gemma pauses while you record."
                                         : "Gemma runs on this iPhone. Nothing you type leaves it.")
                    }
                    .allowsHitTesting(false)          // a drag over it reaches the scroll view and puts the keyboard away
                }
            }
        }
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
        let chat = services.chat
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { message in
                        ChatMessageRow(message: message, retry: chat.retry)
                            .id(message.id)
                    }
                    // The recording took the accessory's place (MainView): said under the conversation.
                    if isRecording, !chat.messages.isEmpty {
                        Label("Gemma pauses while you record.", systemImage: "pause.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .id("paused")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Opens at the end, and stays there while the answer grows (as Messages follows a conversation).
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.count) {
                withAnimation(.snappy) { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var isRecording: Bool { services.identifier.isRecording }

    /// The field while typing, over the keyboard: up to five lines, Return is a new line, ⌘↩ sends.
    private var composer: some View {
        @Bindable var chat = services.chat
        return HStack(alignment: .bottom, spacing: 0) {
            TextField(isRecording ? LocalizedStringKey("Gemma pauses while you record.") : "Ask Gemma",
                      text: $chat.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .disabled(isRecording)
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 11)
                .accessibilityIdentifier("ChatField")
            ChatSendButton(isRecording: isRecording)
                .padding(6)
        }
        .frame(minHeight: minHeight)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: minHeight / 2))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// Send (an accent circle with an arrow), Stop while Gemma answers: in the accessory and in the composer.
struct ChatSendButton: View {
    @Environment(AppServices.self) private var services
    var isRecording = false

    private var canSend: Bool {
        !isRecording && services.betterSummaries.state == .ready
            && !services.chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let chat = services.chat
        Button {
            if chat.isAnswering {
                chat.stop()
            } else {
                InteractionTrace.begin("send"); InteractionTrace.shown("send")
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

/// The Ask tab's field at rest, as the tab bar's bottom accessory (MainView puts it there instead of Transcribe on
/// this tab, while nothing records): the system's capsule, size and glass, and it minimizes with the tab bar, as
/// Music's mini player does. It shows the draft (or "Ask Gemma") and Send / Stop; a tap on the rest opens the
/// composer over the keyboard (see ChatView).
struct ChatAccessory: View {
    @Environment(AppServices.self) private var services
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    /// Reports whether the bar is minimized, as RecordAccessory does (MainView's Search role on iOS 26).
    @Binding var isInline: Bool

    private var inline: Bool { placement == .inline }

    var body: some View {
        let chat = services.chat
        let ready = services.betterSummaries.state == .ready
        // While the composer is up MainView takes the accessory away (iOS 26.1+); on 26.0 it stays under the keyboard,
        // empty: its text and Send showed through the keyboard's glass, and hidden by opacity only, VoiceOver and the
        // UI tests still found two Send buttons.
        if chat.isComposing {
            Color.clear
                .onChange(of: inline, initial: true) { _, value in
                    if isInline != value { isInline = value }
                }
        } else {
            rest(chat, ready: ready)
        }
    }

    private func rest(_ chat: GemmaChat, ready: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                InteractionTrace.begin("compose"); InteractionTrace.shown("compose")
                chat.isComposing = true
            } label: {
                HStack(spacing: 0) {
                    Text(chat.draft.isEmpty ? String(localized: "Ask Gemma") : chat.draft)
                        .font(inline ? .subheadline : .body)
                        .foregroundStyle(chat.draft.isEmpty ? Color(.placeholderText) : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, inline ? 14 : 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityLabel(chat.draft.isEmpty ? Text("Ask Gemma") : Text(chat.draft))
            .accessibilityHint("Opens the keyboard to ask Gemma")
            .accessibilityIdentifier("ChatAccessory")
            ChatSendButton()
                .scaleEffect(inline ? 0.85 : 1)
                .frame(width: 44, height: 44)
        }
        .padding(.trailing, inline ? 0 : 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)    // as the composer: the capsule's height is the system's
        .onChange(of: inline, initial: true) { _, value in
            if isInline != value { isInline = value }
        }
    }
}

/// A question (a tinted bubble on the right) or an answer (plain text on the left, selectable; "Thinking…" until the
/// first token, "Stopped" or the failure under it).
private struct ChatMessageRow: View {
    let message: ChatMessage
    let retry: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentFill, in: .rect(cornerRadius: 20))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.status == .thinking {
                    Label("Thinking…", systemImage: "sparkles")
                        .symbolEffect(.pulse)
                        .foregroundStyle(.secondary)
                } else if !message.text.isEmpty {
                    Text(message.rendered)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ChatAnswer")
                }
                switch message.status {
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
