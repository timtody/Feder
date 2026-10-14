import Foundation
import Observation

/// One message in the Ask tab.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    enum Status: Equatable {
        /// Sent, no token yet ("Thinking…").
        case thinking
        case streaming
        case done
        /// Stop, leaving the app, or a recording started: the partial answer stays, captioned "Stopped".
        case stopped
        case failed(String)
    }

    let id = UUID()
    let role: Role
    var text: String
    /// `text` as Markdown (inline: bold, italics, code; Gemma's "* " list lines as bullets), parsed when a chunk
    /// arrives rather than in `body`.
    var rendered: AttributedString
    var status: Status

    init(role: Role, text: String, status: Status) {
        self.role = role
        self.text = text
        self.rendered = Self.render(text)
        self.status = status
    }

    nonisolated static func render(_ text: String) -> AttributedString {
        // Gemma writes "* item" / "- item" lists; the inline parser would leave the marker (or read "*" as emphasis).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            let indent = String(repeating: " ", count: line.count - trimmed.count)
            if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") { return indent + "• " + trimmed.dropFirst(2) }
            return String(line)
        }
        let markdown = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

/// The Ask tab's conversation with Gemma (FED-17, a prototype to try the ergonomics: no transcripts are read yet).
/// In memory only: New Chat and a relaunch clear it. One answer at a time, run by BetterSummaries.runInteractive ahead of
/// the background summaries. The partial answer is applied at most every 33 ms (about a frame at 30 Hz), so a long
/// answer doesn't re-render the list for every token.
@MainActor @Observable
final class GemmaChat {
    private(set) var messages: [ChatMessage] = []
    private(set) var isAnswering = false
    /// What is typed in the card's field (ChatView): kept here, so it survives closing the card and opening it again.
    var draft = ""
    @ObservationIgnored private let betterSummaries: BetterSummaries
    @ObservationIgnored private var answerTask: Task<Void, Never>?

    /// The system turn. English (Gemma follows the user's language); no transcript context yet.
    nonisolated static let instructions = "You are Gemma, a helpful assistant running entirely on this iPhone inside " +
        "Feder, a transcription app. Answer in the language of the user's message. Be concise."
    /// Characters of history a request may carry: about 16,000 tokens at TranscriptTitler's 3.5 characters per token,
    /// under `LocalLanguageModel.contextTokens` (20,000) with room for the answer (1,000 tokens) and the template.
    nonisolated static let historyCharacters = 56_000
    nonisolated static let maxAnswerTokens = 1_000
    /// A little sampling for a chat: greedy decoding (the summaries' 0) made the small model repeat itself in longer
    /// answers.
    nonisolated static let temperature: Float = 0.6

    init(betterSummaries: BetterSummaries) {
        self.betterSummaries = betterSummaries
    }

    /// Send: appends the question and a pending answer and returns; the answer is written off the main actor.
    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        messages.append(ChatMessage(role: .user, text: question, status: .done))
        let turns = Self.trimmed(messages.compactMap { message -> ChatTurn? in
            switch message.role {
            case .user: return ChatTurn(role: .user, text: message.text)
            case .assistant:
                // A failed or empty answer is left out: the model sees the question again without it.
                guard !message.text.isEmpty, message.status != .thinking else { return nil }
                if case .failed = message.status { return nil }
                return ChatTurn(role: .assistant, text: message.text)
            }
        }, limit: Self.historyCharacters)
        let answer = ChatMessage(role: .assistant, text: "", status: .thinking)
        messages.append(answer)
        isAnswering = true
        answerTask = Task { await self.answer(turns, id: answer.id) }
    }

    /// Stop: the partial answer stays, marked Stopped.
    func stop() {
        answerTask?.cancel()
    }

    /// Try Again under a failed answer: the question is asked once more.
    func retry() {
        guard !isAnswering, let last = messages.last, case .failed = last.status, messages.count >= 2,
              messages[messages.count - 2].role == .user else { return }
        let question = messages[messages.count - 2].text
        messages.removeLast(2)
        send(question)
    }

    /// New Chat: stops an answer and clears the conversation. Send stays off until the stopped answer has ended (a
    /// token later), so two answers never overlap.
    func newChat() {
        answerTask?.cancel()
        messages = []
        draft = ""
    }

    private func answer(_ turns: [ChatTurn], id: UUID) async {
        let (updates, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        let applier = Task { @MainActor in
            for await text in updates {
                self.update(id) {
                    $0.text = text
                    $0.rendered = ChatMessage.render(text)
                    $0.status = .streaming
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        let status: ChatMessage.Status
        var final: String?
        do {
            final = try await betterSummaries.runInteractive { model in
                try await model.chat(instructions: Self.instructions, turns: turns, maxTokens: Self.maxAnswerTokens,
                                     temperature: Self.temperature, partial: { continuation.yield($0) })
            }
            status = .done
        } catch is CancellationError {
            status = .stopped
        } catch let error as BetterSummaries.ChatUnavailable {
            status = switch error {
            case .recording: .failed(String(localized: "Gemma pauses while you record."))
            case .background: .failed(String(localized: "Gemma is available after the app is open again."))
            case .notDownloaded: .failed(String(localized: "Gemma isn't downloaded."))
            }
        } catch {
            status = .failed(String(localized: "Gemma couldn't answer. Try again."))
        }
        continuation.finish()
        await applier.value
        update(id) {                                          // gone after New Chat
            if let final {
                $0.text = final.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.rendered = ChatMessage.render($0.text)
            }
            $0.status = status
        }
        isAnswering = false
        answerTask = nil
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    /// The newest turns that fit in `limit` characters, the oldest dropped first; the newest (the question) always
    /// stays, and the history starts with a user turn (Gemma's template alternates from the user).
    nonisolated static func trimmed(_ turns: [ChatTurn], limit: Int) -> [ChatTurn] {
        var kept: [ChatTurn] = []
        var total = 0
        for turn in turns.reversed() {
            guard kept.isEmpty || total + turn.text.count <= limit else { break }
            kept.append(turn)
            total += turn.text.count
        }
        while kept.count > 1, kept.last?.role == .assistant { kept.removeLast() }
        return kept.reversed()
    }
}
