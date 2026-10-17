import Foundation
import LiteRTLM

/// Gemma 4 E4B (or any `.litertlm` file) on Google's LiteRT-LM, as a `TextWriter`: the FED-142 candidate next to the
/// app's `LocalLanguageModel` (Gemma 4 E2B on MLX). Same contract: greedy at temperature 0, thinking off, the
/// instructions as the system turn, the whole conversation sent again with each request (no KV cache kept between
/// requests), cancellation between tokens (`Conversation.cancel`).
actor LiteRTLanguageModel: TextWriter {
    nonisolated let file: URL
    nonisolated let backend: Backend
    private var engine: Engine?

    init(file: URL, backend: Backend = .gpu) {
        self.file = file
        self.backend = backend
    }

    /// Creates the engine: maps the file and compiles the GPU programs (cached next to the file after the first run).
    func load() async throws {
        guard engine == nil else { return }
        let config = try EngineConfig(modelPath: file.path, backend: backend,
                                      maxNumTokens: LocalLanguageModel.contextTokens)
        let engine = Engine(engineConfig: config)
        try await engine.initialize()
        self.engine = engine
    }

    func unload() { engine = nil }

    func respond(instructions: String, prompt: String, maxTokens: Int = 400, temperature: Float = 0,
                 partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await generate(instructions: instructions, turns: [ChatTurn(role: .user, text: prompt)],
                           maxTokens: maxTokens, temperature: temperature, partial: partial)
    }

    func chat(instructions: String, turns: [ChatTurn], maxTokens: Int = 1000, temperature: Float = 0,
              partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await generate(instructions: instructions, turns: turns, maxTokens: maxTokens, temperature: temperature,
                           partial: partial)
    }

    private func generate(instructions: String, turns: [ChatTurn], maxTokens: Int, temperature: Float,
                          partial: (@Sendable (String) -> Void)?) async throws -> String {
        try await load()
        guard let engine, let last = turns.last else { throw CancellationError() }
        // topK 1 is greedy whatever the temperature; the chat's 0.6 samples from the top 64 as Google suggests.
        let sampler = temperature == 0 ? try SamplerConfig(topK: 1, topP: 1, temperature: 0)
                                       : try SamplerConfig(topK: 64, topP: 0.95, temperature: temperature)
        let history = turns.dropLast().map { Message($0.text, role: $0.role == .user ? .user : .model) }
        let conversation = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message(instructions, role: .system), initialMessages: Array(history),
            samplerConfig: sampler, thinkingConfig: ThinkingConfig(enableThinking: false)))
        var text = ""
        try await withTaskCancellationHandler {
            for try await chunk in conversation.sendMessageStream(Message(last.text), maxOutputTokens: maxTokens,
                                                                  thinkingConfig: ThinkingConfig(enableThinking: false)) {
                text += chunk.toString
                partial?(text)
            }
        } onCancel: {
            try? conversation.cancel()
        }
        try Task.checkCancellation()
        return text
    }

    /// Tokens the conversation's KV cache holds after prefilling `text` as one user turn and answering one token.
    func tokenCount(_ text: String) async throws -> Int {
        try await load()
        guard let engine else { throw CancellationError() }
        let conversation = try await engine.createConversation(with: ConversationConfig(
            samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0)))
        _ = try await conversation.sendMessage(Message(text), maxOutputTokens: 1)
        return try conversation.getTokenCount()
    }
}
