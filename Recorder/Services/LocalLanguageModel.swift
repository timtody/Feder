import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Google's Gemma 4 E2B (instruction-tuned, 4-bit) run on this iPhone's GPU with MLX: the "Better Summaries"
/// model of TranscriptTitler. A file-based model: `BetterSummaries` downloads the files into `directory`; this loads
/// them on first use and answers one request at a time (an actor). Greedy decoding for the titles, so a transcript
/// always gets the same one; the smart corrections sample at a low temperature. Platform-neutral (also builds for the
/// Mac, where the summary bench runs it).
actor LocalLanguageModel {
    /// The Hugging Face repository and the pinned revision of its files (3.58 GB, with Gemma 4's vision and audio
    /// towers, which are not used). The smaller text-only conversion `mlx-community/Gemma4-E2B-IT-Text-int4` (2.67 GB)
    /// wrote much worse summaries in the summary bench ("Zusammenfassung der nächsten Schritte").
    nonisolated static let repository = "mlx-community/gemma-4-e2b-it-4bit"
    nonisolated static let revision = "238767527555cb75a05732a84dff5d6ba0dd6809"     // 2026-07-06
    nonisolated static let files = ["config.json", "generation_config.json", "chat_template.jinja", "processor_config.json",
                                    "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json",
                                    "model.safetensors"]
    nonisolated static let downloadBytes: Int64 = 3_583_000_000
    nonisolated static let displayName = "Gemma 4 E2B"
    /// Tokens a request may use (instructions + transcript + answer). Gemma 4 E2B reads 128K; 20K keeps the KV cache
    /// and the prefill time of one request small (about an hour of conversation; longer ones are summarized in parts).
    nonisolated static let contextTokens = 20_000

    nonisolated let directory: URL
    private var container: ModelContainer?
    /// Bumped by `unload()`: a load that was suspended meanwhile drops its result instead of keeping the weights.
    private var generation = 0

    init(directory: URL) {
        self.directory = directory
    }

    /// Loads the weights (memory-mapped; a few seconds) unless they are loaded already.
    func load() async throws {
        guard container == nil else { return }
        Memory.cacheLimit = 64 * 1024 * 1024             // buffers kept for reuse between requests
        let started = generation
        let loaded = try await loadModelContainer(from: directory, using: TransformersTokenizerLoader())
        guard generation == started else { throw CancellationError() }   // unloaded meanwhile (actor reentrancy)
        container = loaded
    }

    /// Frees the weights and the GPU cache (3.7 GB at the peak of an 8,300-token transcript on a Mac): after a while without requests, and before a recording.
    func unload() {
        generation += 1
        container = nil
        Memory.clearCache()
    }

    /// The answer to `prompt` under `instructions` (a system turn), at most `maxTokens` long; greedy at `temperature` 0
    /// (the titles), sampled above it (the corrections, 0.25). Checks for cancellation between tokens and throws
    /// CancellationError then.
    func respond(instructions: String, prompt: String, maxTokens: Int = 400, temperature: Float = 0,
                 partial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await load()
        guard let container else { throw CancellationError() }
        let input = UserInput(chat: [.system(instructions), .user(prompt)],
                              additionalContext: ["enable_thinking": false])
        let prepared = try await container.prepare(input: input)
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
        var text = ""
        for await generation in try await container.generate(input: prepared, parameters: parameters) {
            try Task.checkCancellation()                         // leaving the loop ends the generation
            if let chunk = generation.chunk {
                text += chunk
                partial?(text)
            }
        }
        try Task.checkCancellation()
        return text
    }

    /// Tokens of `text` under the model's tokenizer. Not called by the app: the Mac summary bench (README) measured
    /// `TranscriptTitler.reservedTokens` and the characters per token with it, so it stays with this file.
    func tokenCount(_ text: String) async throws -> Int {
        try await load()
        guard let container else { throw CancellationError() }
        return await container.tokenizer.encode(text: text, addSpecialTokens: false).count
    }
}

/// swift-transformers' tokenizer for MLX (what `#huggingFaceTokenizerLoader()` of MLXHuggingFace expands to, without
/// its macro and Hugging Face downloader packages).
nonisolated struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }

    private struct TokenizerBridge: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer

        init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(messages: messages, tools: tools,
                                                      additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
}
