import Foundation
import llama

/// Tencent HY-MT2 1.8B (Q8 GGUF) through llama.cpp on the GPU: an optional English → Chinese
/// translator. In a blind comparison of 10 recognized English sentences it gave the best Chinese
/// translation 7 times (Apple 3, TranslateGemma 0), in about 0.4 s per sentence.
actor HYMT2 {
    static let shared = HYMT2()
    static let fileName = "Hy-MT2-1.8B-Q8_0.gguf"
    nonisolated static var folder: URL { ModelStore.folder.appending(path: "hymt2", directoryHint: .isDirectory) }
    nonisolated static var modelURL: URL { folder.appending(path: fileName) }
    nonisolated static var isInstalled: Bool {
        ((try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_000_000_000
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    /// Loads the model (once). The file is memory-mapped, so this takes about a second.
    func load() throws {
        if context != nil { return }
        llama_log_set({ _, _, _ in }, nil)        // llama.cpp is very chatty; keep the console clean
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(Self.modelURL.path, mp) else {
            throw NSError(domain: "Interpreto", code: 10, userInfo: [NSLocalizedDescriptionKey: "The HY-MT2 model couldn’t be loaded."])
        }
        var cp = llama_context_default_params()
        cp.n_ctx = 2048
        cp.n_batch = 2048
        cp.n_threads = 4
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw NSError(domain: "Interpreto", code: 11, userInfo: [NSLocalizedDescriptionKey: "HY-MT2 couldn’t start."])
        }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())       // deterministic, like temperature 0
        model = m; context = c; vocab = llama_model_get_vocab(m); sampler = chain
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil; context = nil; model = nil; vocab = nil
    }

    /// Translates one sentence. `context`: the previous sentences, for consistency; `terms`:
    /// glossary entries (source, translation) that occur in the text.
    func translate(_ text: String, _ d: Direction, context previous: [String], terms: [(String, String)]) throws -> String {
        try load()
        guard let ctx = context, let vocab, let sampler else { return "" }
        let prompt = "<｜hy_User｜>" + Self.message(text, d, context: previous, terms: terms) + "<｜hy_Assistant｜>"

        llama_memory_clear(llama_get_memory(ctx), true)
        llama_sampler_reset(sampler)
        var tokens = tokenize(prompt)
        let ok = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
        }
        guard ok else { return "" }

        var bytes: [UInt8] = []
        let limit = tokens.count * 3 + 48
        for _ in 0..<limit {
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            if let s = String(bytes: bytes, encoding: .utf8), Self.stops.contains(where: s.contains) { break }
            let stepOK = withUnsafeMutablePointer(to: &token) { llama_decode(ctx, llama_batch_get_one($0, 1)) == 0 }
            if !stepOK { break }
        }
        var out = String(decoding: bytes, as: UTF8.self)
        for s in Self.stops { if let r = out.range(of: s) { out = String(out[..<r.lowerBound]) } }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let stops = ["<｜hy_place▁holder▁no▁2｜>", "<｜hy_end▁of▁sentence｜>", "<｜hy_User｜>"]

    /// The official HY-MT2 prompt (Chinese wording when Chinese is involved), as used before.
    static func message(_ text: String, _ d: Direction, context: [String], terms: [(String, String)]) -> String {
        let target = d == .enToZh ? "中文" : "英语"
        let head = terms.isEmpty ? "" : "参考下面的翻译：\n" + terms.map { "\($0.0) 翻译成 \($0.1)" }.joined(separator: "\n") + "\n\n"
        let previous = context.filter { !$0.isEmpty }.suffix(2)
        if !previous.isEmpty {
            return head + previous.joined(separator: " ") + "\n参考上面的信息，把下面的文本翻译成\(target)，注意不需要翻译上文，也不要额外解释：\n" + text
        }
        return head + "将以下文本翻译为\(target)，注意只需要输出翻译后的结果，不要额外解释：\n\n" + text
    }

    private func tokenize(_ s: String) -> [llama_token] {
        let n = Int32(s.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(n) + 16)
        var got = llama_tokenize(vocab, s, n, &tokens, Int32(tokens.count), true, true)
        if got < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-got))
            got = llama_tokenize(vocab, s, n, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, got))))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }
}
