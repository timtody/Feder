import SwiftUI

/// Ask (FED-17, a prototype): a chat with Gemma on this iPhone, to try how talking to it feels before it answers from
/// the transcripts. A card that zooms out of the record accessory's Ask button (MainView's sheet), opens at half height
/// and pulls up to full, as the system's sheets do (Maps, Find My): New Chat at the top, the field at the bottom, over the
/// keyboard while typing. Laid out like Messages: the questions in tinted bubbles on the right, Gemma's answers as plain
/// text on the left (as Apple Intelligence's and other assistants' answers read). SwiftUI has no chat component; the
/// pieces are system ones. DEBUG builds only, on iPhones that run Gemma (`isAvailable`); no CHANGELOG line until it
/// ships. Until October 2026 it was a tab of its own, with its field as the tab bar's accessory on that tab.
struct ChatView: View {
    /// Ask's general chat, or one about a transcript (FED-137: from its More menu), whose title is the subtitle.
    let chat: GemmaChat
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    /// The field grows with the text up to five lines; the button stays a 32 pt circle (as in Messages).
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 44
    @State private var detent: PresentationDetent = .medium

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
                .safeAreaBar(edge: .bottom) {
                    if services.betterSummaries.state == .ready { composer }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onAppear { InteractionTrace.shown("ask") }
        // Typing at half height: the card goes to full height, so the conversation keeps room over the keyboard.
        .onChange(of: isFocused) { _, focused in
            if focused, detent != .large { withAnimation(.snappy) { detent = .large } }
        }
        // A recording started from outside (the Action Button, Control Center): Gemma pauses, the keyboard goes, and
        // MainView closes the card for the recording's.
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
                if chat.messages.isEmpty {
                    ContentUnavailableView {
                        Label(chat.transcript == nil ? "Ask Gemma" : "Ask About This Transcript", systemImage: "bubble.left")
                    } description: {
                        Text(isRecording ? "Gemma pauses while you record."
                             : chat.transcript != nil ? "Gemma reads this transcript on this iPhone. Nothing leaves it."
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { message in
                        ChatMessageRow(message: message, retry: chat.retry)
                            .id(message.id)
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

    /// The field at the bottom of the card, over the keyboard while typing: up to five lines, Return is a new line,
    /// ⌘↩ sends.
    private var composer: some View {
        @Bindable var chat = chat
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
            ChatSendButton(chat: chat, isRecording: isRecording)
                .padding(6)
        }
        .frame(minHeight: minHeight)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: minHeight / 2))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// Send (an accent circle with an arrow), Stop while Gemma answers, at the end of the field.
struct ChatSendButton: View {
    @Environment(AppServices.self) private var services
    let chat: GemmaChat
    var isRecording = false

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
