import SwiftUI

/// The Ask tab (FED-17, a prototype): a chat with Gemma on this iPhone, to try how talking to it feels before it answers
/// from the transcripts. Laid out like Messages: the questions in tinted bubbles on the right, Gemma's answers as plain
/// text on the left (as Apple Intelligence's and other assistants' answers read), and the field in a glass capsule in
/// the bottom safe-area bar, so it rides on the keyboard and the conversation scrolls under it with the scroll edge
/// effect. SwiftUI has no chat component; the pieces are system ones. DEBUG builds only, on iPhones that run Gemma
/// (`isAvailable`); no CHANGELOG line until it ships.
struct ChatView: View {
    @Environment(AppServices.self) private var services
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    /// The field grows with the text up to five lines; the button stays a 34 pt circle (as in Messages).
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
                            draft = ""
                        }
                        .disabled(chat.messages.isEmpty)
                    }
                }
                .safeAreaBar(edge: .bottom) {
                    if services.betterSummaries.state == .ready { inputBar }
                }
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
        } else if services.chat.messages.isEmpty {
            ContentUnavailableView {
                Label("Ask Gemma", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Gemma runs on this iPhone. Nothing you type leaves it.")
            }
        } else {
            conversation
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

    private var canSend: Bool {
        !isRecording && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        let chat = services.chat
        return HStack(alignment: .bottom, spacing: 0) {
            TextField(isRecording ? LocalizedStringKey("Gemma pauses while you record.") : "Ask Gemma",
                      text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .disabled(isRecording)
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 11)
                .accessibilityIdentifier("ChatField")
            Button {
                if chat.isAnswering {
                    chat.stop()
                } else {
                    InteractionTrace.begin("send"); InteractionTrace.shown("send")
                    chat.send(draft)
                    draft = ""
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
            .padding(6)
            .accessibilityLabel(chat.isAnswering ? "Stop Answer" : "Send")
            .accessibilityShowsLargeContentViewer()
        }
        .frame(minHeight: minHeight)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: minHeight / 2))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
