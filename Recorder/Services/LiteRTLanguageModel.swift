#if LITERT
import Foundation
import LiteRTLM

/// Gemma 4 (E2B or E4B, a `.litertlm` file) on Google's LiteRT-LM, as a `TextWriter`: the candidate next to
/// `LocalLanguageModel` (Gemma 4 E2B on MLX) that Feder Lab tries on the iPhone (FED-150, FED-152) and the Mac bench
/// runs (build/qa/litertbench). Only in the Feder Lab target (`LITERT`): Release builds never link LiteRT-LM.
/// Same contract as LocalLanguageModel: greedy at temperature 0, thinking off, the instructions as the system turn, the
/// whole conversation sent again with each request (no KV cache kept between requests), cancellation between tokens
/// (`Conversation.cancel`).
actor LiteRTLanguageModel: TextWriter {
    nonisolated let file: URL
    nonisolated let backend: Backend
    /// Multi-token prediction (Google: "universally recommended" on Metal; the model files since May 2026 carry the
    /// drafter). Read when the engine is created.
    nonisolated let speculativeDecoding: Bool
    private var engine: Engine?

    init(file: URL, backend: Backend = .gpu, speculativeDecoding: Bool = false) {
        self.file = file
        self.backend = backend
        self.speculativeDecoding = speculativeDecoding
    }

    /// Creates the engine: maps the file and compiles the GPU programs (cached in Caches/LiteRT after the first run).
    func load() async throws {
        guard engine == nil else { return }
        let cache = URL.cachesDirectory.appending(path: "LiteRT")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = speculativeDecoding
        let config = try EngineConfig(modelPath: file.path(percentEncoded: false), backend: backend,
                                      maxNumTokens: LocalLanguageModel.contextTokens,
                                      cacheDir: cache.path(percentEncoded: false))
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
}
#endif
