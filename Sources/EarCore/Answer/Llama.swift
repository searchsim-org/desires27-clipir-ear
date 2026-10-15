import Foundation
import Synchronization
import llama

/// Thin, serialised wrapper over one llama.cpp model + context (P3.3, P3.5).
/// Blocking C calls; callers run it off the main actor.
public final class LlamaEngine: @unchecked Sendable {
    public let modelName: String
    let model: OpaquePointer
    let ctx: OpaquePointer
    let vocab: OpaquePointer
    let embeddings: Bool
    private let lock = NSLock()
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)  // silence llama.cpp's stderr logging
        llama_backend_init()
    }()

    public init(path: String, contextLength: Int = 4096, embeddings: Bool = false) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        #if targetEnvironment(simulator)
            mp.n_gpu_layers = 0  // Metal in the simulator is not reliable for ggml
        #else
            mp.n_gpu_layers = 99
        #endif
        guard let m = llama_model_load_from_file(path, mp) else { throw EarError.model("could not load \(path)") }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextLength)
        cp.n_batch = 512
        cp.n_ubatch = 512
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        cp.embeddings = embeddings
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw EarError.model("could not create a context for \(path)")
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        self.embeddings = embeddings
        modelName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    func tokenize(_ text: String, special: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        let n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &tokens, Int32(tokens.count), special, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            _ = llama_tokenize(vocab, text, Int32(utf8.count - 1), &tokens, Int32(tokens.count), special, true)
            return tokens
        }
        return Array(tokens.prefix(Int(n)))
    }

    func piece(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    /// Builds the chat prompt with the model's own template; falls back to ChatML / Gemma turns.
    func chatPrompt(system: String, user: String) -> String {
        let isQwen = modelName.lowercased().contains("qwen")
        let userText = isQwen ? user + " /no_think" : user  // Qwen3: answer directly, no reasoning trace
        if let tmpl = llama_model_chat_template(model, nil) {
            let rendered: String? = system.withCString { s in
                userText.withCString { u in
                    "system".withCString { rs in
                        "user".withCString { ru in
                            var msgs = [
                                llama_chat_message(role: rs, content: s), llama_chat_message(role: ru, content: u),
                            ]
                            var buf = [CChar](repeating: 0, count: (system.utf8.count + userText.utf8.count) * 2 + 1024)
                            let n = llama_chat_apply_template(tmpl, &msgs, 2, true, &buf, Int32(buf.count))
                            guard n > 0, Int(n) < buf.count else { return nil }
                            return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        }
                    }
                }
            }
            if let rendered { return rendered }
        }
        if modelName.lowercased().contains("gemma") {
            return "<start_of_turn>user\n\(system)\n\n\(userText)<end_of_turn>\n<start_of_turn>model\n"
        }
        return
            "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(userText)<|im_end|>\n<|im_start|>assistant\n"
    }

    /// Greedy generation. `onText` gets UTF-8-safe text pieces; return false to stop. Returns (prompt, completion) tokens.
    func generate(prompt: String, maxTokens: Int, onText: (String) -> Bool) throws -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        llama_memory_clear(llama_get_memory(ctx), true)
        var tokens = tokenize(prompt, special: true)
        let nCtx = Int(llama_n_ctx(ctx))
        if tokens.count > nCtx - maxTokens - 8 { tokens = Array(tokens.suffix(nCtx - maxTokens - 8)) }
        var i = 0
        while i < tokens.count {
            let chunk = Array(tokens[i..<min(i + 512, tokens.count)])
            var c = chunk
            let rc = c.withUnsafeMutableBufferPointer {
                llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count)))
            }
            guard rc == 0 else { throw EarError.model("decode failed (\(rc))") }
            i += chunk.count
        }
        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy())
        var pending: [UInt8] = []
        var produced = 0
        var filter = ThinkFilter()
        while produced < maxTokens {
            var t = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, t) { break }
            produced += 1
            pending += piece(t)
            if let s = String(validating: pending, as: UTF8.self) {  // wait for complete multi-byte characters
                pending = []
                let visible = filter.feed(s)
                if !visible.isEmpty, !onText(visible) { break }
            }
            let rc = llama_decode(ctx, llama_batch_get_one(&t, 1))
            guard rc == 0 else { throw EarError.model("decode failed (\(rc))") }
        }
        return (tokens.count, produced)
    }

    /// Mean-pooled, L2-normalised embedding (embedding engines only).
    func embed(_ text: String) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        llama_memory_clear(llama_get_memory(ctx), true)
        var tokens = tokenize(text, special: true)
        if tokens.count > 512 { tokens = Array(tokens.prefix(512)) }
        let rc = tokens.withUnsafeMutableBufferPointer {
            llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count)))
        }
        guard rc == 0, let p = llama_get_embeddings_seq(ctx, 0) ?? llama_get_embeddings(ctx) else {
            throw EarError.model("embedding failed (\(rc))")
        }
        let v = Array(UnsafeBufferPointer(start: p, count: Int(llama_model_n_embd(model))))
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n == 0 ? v : v.map { $0 / n }
    }
}

/// Drops `<think>…</think>` blocks that Qwen3 may emit even in no-think mode.
struct ThinkFilter {
    private var inThink = false
    private var carry = ""
    mutating func feed(_ s: String) -> String {
        var text = carry + s
        carry = ""
        var out = ""
        while !text.isEmpty {
            if inThink {
                guard let r = text.range(of: "</think>") else { return out }
                inThink = false
                text = String(text[r.upperBound...]).trimmingPrefix(while: \.isWhitespace)
            } else if let r = text.range(of: "<think>") {
                out += text[..<r.lowerBound]
                inThink = true
                text = String(text[r.upperBound...])
            } else if let lt = text.lastIndex(of: "<"), "<think>".hasPrefix(String(text[lt...])) {
                out += text[..<lt]  // possible partial tag: hold it back
                carry = String(text[lt...])
                return out
            } else {
                return out + text
            }
        }
        return out
    }
}

extension String {
    fileprivate func trimmingPrefix(while predicate: (Character) -> Bool) -> String {
        String(drop(while: predicate))
    }
}

/// On-phone answerer (P3.5) / TinyAnswerer with Qwen3-0.6B (P3.6). Lazy-loaded, kept warm.
public final class LlamaAnswerer: Answerer, @unchecked Sendable {
    public var name: String { "llama:\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)" }
    private let path: String
    private let contextLength: Int
    private let engine = Mutex<LlamaEngine?>(nil)
    private let cancelled = Mutex(false)

    public init(modelPath: String, contextLength: Int = 4096) {
        self.path = modelPath
        self.contextLength = contextLength
    }

    public static func tiny() throws -> LlamaAnswerer { LlamaAnswerer(modelPath: try Models.path(Models.qwen3CI)) }

    func loaded() throws -> LlamaEngine {
        if let e = engine.withLock({ $0 }) { return e }
        let e = try LlamaEngine(path: path, contextLength: contextLength)
        engine.withLock { $0 = e }
        return e
    }

    /// Loads the model now so the first question does not pay the load time (kept warm while listening).
    @discardableResult
    public func warm() throws -> String { try loaded().modelName }

    /// Frees the model (memory warning).
    public func unload() { engine.withLock { $0 = nil } }

    public func answer(_ req: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        cancelled.withLock { $0 = false }
        return AsyncThrowingStream { c in
            let task = Task.detached { [self] in
                do {
                    let e = try loaded()
                    c.yield(.tier(req.tier.rawValue))
                    let prompt = e.chatPrompt(system: PromptBuilder.system(req), user: PromptBuilder.user(req))
                    var splitter = SentenceSplitter(firstClause: true)  // ADR-020: speak the first clause early
                    var full = ""
                    let (p, n) = try e.generate(prompt: prompt, maxTokens: req.maxTokens) { text in
                        full += text
                        c.yield(.token(text))
                        for s in splitter.push(text) { c.yield(.sentence(s)) }
                        if cancelled.withLock({ $0 }) { return false }
                        // stop once the SOURCE: line is complete; nothing after it is used
                        if let r = full.range(of: "SOURCE:"), full[r.upperBound...].contains("\n") { return false }
                        return true
                    }
                    if let s = splitter.flush() { c.yield(.sentence(s)) }
                    c.yield(.knowledgeTier(PromptBuilder.parseSource(full).tier))
                    c.yield(.done(promptTokens: p, completionTokens: n))
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() { cancelled.withLock { $0 = true } }
}

/// nomic-embed-text-v1.5 through llama.cpp (P3.3), 768-d normalised.
public final class LlamaEmbedder: Embedder, @unchecked Sendable {
    public let dimension = 768
    private let engine: LlamaEngine
    public init(modelPath: String? = nil) throws {
        engine = try LlamaEngine(
            path: try modelPath ?? Models.path(Models.nomicEmbed), contextLength: 2048, embeddings: true)
    }
    public func embed(_ text: String) async throws -> [Float] { try engine.embed(text) }
}
