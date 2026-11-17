// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import llama
import StickflowCore

public enum LocalModelError: Error, Equatable, Sendable {
    /// The file is not a model this build of llama.cpp can read, or there is no memory for it.
    case loadFailed(String)
    case contextFailed
    case grammarFailed
    case decodeFailed(Int32)
    /// The text with the prompt does not fit the context.
    case tooLong(tokens: Int)
}

/// How the model is run. The numbers are kept in `Tuning.swift` on the app's side.
public struct LlamaSettings: Sendable, Equatable {
    /// Tokens of context: the prompt with its five examples, three minutes of speech, the answer.
    public var contextLength: UInt32 = 6144
    public var batchSize: UInt32 = 512
    /// Tokens of answer at most; a plan of fifteen items fits in far fewer.
    public var maxAnswerTokens = 900
    /// Layers on the GPU; negative — all of them, 0 — none.
    public var gpuLayers: Int32 = -1
    public var threads: Int32 = LlamaSettings.performanceCores
    /// The model leaves memory this long after the last use (spec 18.10: five minutes).
    public var idleUnload: TimeInterval = 300

    public init() {}

    /// Threads for the CPU part: the performance cores, as llama.cpp advises on Apple Silicon.
    public static var performanceCores: Int32 {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return min(count, 8) }
        return Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8)))
    }
}

/// What one answer cost.
public struct LlamaTimings: Sendable, Equatable {
    public var loading: TimeInterval = 0
    public var prompt: TimeInterval = 0
    public var answer: TimeInterval = 0
    /// Prompt tokens that were already in the context and were not read again.
    public var reused = 0
    public var promptTokens = 0
    public var answerTokens = 0
}

/// One model in memory and the text it has read (spec 18.10). All work happens
/// on one serial queue, off the cooperative pool: a token takes milliseconds,
/// an answer seconds. The prompt's rules and examples are the same every time,
/// so the context keeps them and only what follows is read again.
public final class LlamaRunner: @unchecked Sendable {
    public let file: URL
    public let settings: LlamaSettings

    private let queue = DispatchQueue(label: "io.github.stickflow.llama", qos: .userInitiated)
    // Touched only on `queue`.
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var batch: OpaquePointer?
    private var cached: [llama_token] = []
    private var template: String?
    private var unloadWork: DispatchWorkItem?
    private var lastLoad: TimeInterval = 0

    private let lock = NSLock()
    private var isStopped = false

    public init(file: URL, settings: LlamaSettings = LlamaSettings()) {
        self.file = file
        self.settings = settings
    }

    deinit {
        free()
    }

    /// The model is in memory now.
    public var isLoaded: Bool {
        queue.sync { context != nil }
    }

    /// How the model wants its conversation written, read from the model file.
    public func promptFormat() async throws -> PromptFormat? {
        try await perform { runner in
            try runner.loadIfNeeded()
            return PromptFormat.detect(template: runner.template)
        }
    }

    /// Writes the answer to `prompt` that `grammar` allows, greedily.
    public func generate(prompt: String, grammar: String) async throws -> (text: String, timings: LlamaTimings) {
        setStopped(false)
        return try await withTaskCancellationHandler {
            try await perform { runner in try runner.answer(prompt: prompt, grammar: grammar) }
        } onCancel: {
            setStopped(true)
        }
    }

    /// Loads the model and reads `prompt` without answering, so that a request
    /// that begins with it only reads what follows.
    public func prefill(prompt: String) async throws {
        _ = try await perform { runner in try runner.read(prompt).count }
    }

    /// Frees the memory now; the next request loads the model again.
    public func unload() {
        queue.async { [self] in free() }
    }

    // MARK: On the queue

    private func perform<T: Sendable>(_ work: @escaping @Sendable (LlamaRunner) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                unloadWork?.cancel()
                continuation.resume(with: Result { try work(self) })
                scheduleUnload()
            }
        }
    }

    private func scheduleUnload() {
        let work = DispatchWorkItem { [weak self] in self?.free() }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + settings.idleUnload, execute: work)
    }

    private func free() {
        if let batch { llama_batch_ext_free(batch) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        batch = nil
        context = nil
        model = nil
        cached = []
    }

    private func loadIfNeeded() throws {
        guard context == nil else { return }
        LlamaBackend.start()
        let started = Date()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = settings.gpuLayers
        var loaded = llama_model_load_from_file(file.path, modelParams)
        if loaded == nil, settings.gpuLayers != 0 {
            // A Mac whose GPU cannot take the model still runs it on the CPU.
            modelParams.n_gpu_layers = 0
            loaded = llama_model_load_from_file(file.path, modelParams)
        }
        guard let loaded else { throw LocalModelError.loadFailed(file.lastPathComponent) }
        var params = llama_context_default_params()
        params.n_ctx = settings.contextLength
        params.n_batch = settings.batchSize
        params.n_ubatch = settings.batchSize
        params.n_seq_max = 1
        params.n_threads = settings.threads
        params.n_threads_batch = settings.threads
        guard let made = llama_init_from_model(loaded, params) else {
            llama_model_free(loaded)
            throw LocalModelError.contextFailed
        }
        guard let newBatch = llama_batch_ext_init(made) else {
            llama_free(made)
            llama_model_free(loaded)
            throw LocalModelError.contextFailed
        }
        model = loaded
        context = made
        batch = newBatch
        cached = []
        template = llama_model_chat_template(loaded, nil).map { String(cString: $0) }
        lastLoad = Date().timeIntervalSince(started)
    }

    /// Reads the prompt into the context: only what differs from what it already holds.
    /// - Returns: the prompt's tokens, and how many of them were there already.
    private func read(_ prompt: String) throws -> (tokens: [llama_token], count: Int, reused: Int) {
        try loadIfNeeded()
        guard let model, let context, let batch, let vocab = llama_model_get_vocab(model) else {
            throw LocalModelError.contextFailed
        }
        let tokens = tokenize(prompt, vocab: vocab)
        guard tokens.count + settings.maxAnswerTokens <= Int(settings.contextLength), !tokens.isEmpty else {
            throw LocalModelError.tooLong(tokens: tokens.count)
        }
        let memory = llama_get_memory(context)
        var common = zip(cached, tokens).prefix { pair in pair.0 == pair.1 }.count
        // The last token is read again: its logits start the answer.
        common = min(common, tokens.count - 1)
        if common < cached.count, !llama_memory_seq_rm(memory, 0, llama_pos(common), -1) {
            llama_memory_clear(memory, true)
            common = 0
        }
        cached = Array(tokens.prefix(common))
        var position = common
        while position < tokens.count {
            try checkStopped()
            llama_batch_ext_clear(batch)
            let end = min(position + Int(settings.batchSize), tokens.count)
            for index in position..<end {
                try add(tokens[index], at: index, output: index == tokens.count - 1, to: batch)
            }
            try process(batch, in: context, memory: memory)
            cached.append(contentsOf: tokens[position..<end])
            position = end
        }
        return (tokens, tokens.count, common)
    }

    private func answer(prompt: String, grammar: String) throws -> (text: String, timings: LlamaTimings) {
        var timings = LlamaTimings()
        lastLoad = 0
        var started = Date()
        let prompted = try read(prompt)
        timings.loading = lastLoad
        timings.prompt = Date().timeIntervalSince(started) - lastLoad
        timings.promptTokens = prompted.count
        timings.reused = prompted.reused
        guard let model, let context, let batch, let vocab = llama_model_get_vocab(model) else {
            throw LocalModelError.contextFailed
        }
        let memory = llama_get_memory(context)
        var position = prompted.count

        // The answer, one token at a time, each one allowed by the grammar.
        started = Date()
        guard let rules = llama_sampler_init_grammar(vocab, grammar, "root") else { throw LocalModelError.grammarFailed }
        defer { llama_sampler_free(rules) }
        var bytes: [UInt8] = []
        var shape = JSONDepth()
        while timings.answerTokens < settings.maxAnswerTokens {
            try checkStopped()
            let token = pick(from: context, vocab: vocab, rules: rules)
            if llama_vocab_is_eog(vocab, token) { break }
            llama_sampler_accept(rules, token)
            let piece = self.piece(token, vocab: vocab)
            bytes.append(contentsOf: piece)
            timings.answerTokens += 1
            // The object is closed: nothing else may follow, so there is nothing to wait for.
            if shape.read(piece) { break }
            llama_batch_ext_clear(batch)
            try add(token, at: position, output: true, to: batch)
            try process(batch, in: context, memory: memory)
            cached.append(token)
            position += 1
        }
        timings.answer = Date().timeIntervalSince(started)
        // The grammar writes whole characters; a cut at the token limit leaves no plan anyway.
        return (String(bytes: bytes, encoding: .utf8) ?? "", timings)
    }

    /// The likeliest token the grammar allows. Most of the time the likeliest
    /// token of all is allowed, and only it is checked.
    private func pick(from context: OpaquePointer, vocab: OpaquePointer, rules: UnsafeMutablePointer<llama_sampler>) -> llama_token {
        let count = Int(llama_vocab_n_tokens(vocab))
        guard let logits = llama_get_logits_ith(context, -1) else { return llama_vocab_eos(vocab) }
        var best = 0
        for index in 1..<count where logits[index] > logits[best] {
            best = index
        }
        var single = llama_token_data(id: llama_token(best), logit: logits[best], p: 0)
        let allowed = withUnsafeMutablePointer(to: &single) { pointer in
            var array = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(rules, &array)
            return array.data[0].logit.isFinite
        }
        if allowed { return llama_token(best) }
        var candidates = (0..<count).map { llama_token_data(id: llama_token($0), logit: logits[$0], p: 0) }
        return candidates.withUnsafeMutableBufferPointer { buffer in
            var array = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
            llama_sampler_apply(rules, &array)
            var chosen = llama_vocab_eos(vocab)
            var top = -Float.infinity
            for index in 0..<array.size where array.data[index].logit > top {
                top = array.data[index].logit
                chosen = array.data[index].id
            }
            return chosen
        }
    }

    private func add(_ token: llama_token, at index: Int, output: Bool, to batch: OpaquePointer) throws {
        let slot = llama_batch_ext_add_token(batch, 0, token)
        guard slot >= 0 else { throw LocalModelError.decodeFailed(slot) }
        var position = llama_pos(index)
        llama_batch_ext_set_pos(batch, slot, &position)
        llama_batch_ext_set_output_logits(batch, slot, output)
    }

    private func process(_ batch: OpaquePointer, in context: OpaquePointer, memory: llama_memory_t?) throws {
        let result = llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch)
        guard result == 0 else {
            // What the context holds is unknown now: start the next prompt from scratch.
            llama_memory_clear(memory, true)
            cached = []
            throw LocalModelError.decodeFailed(result)
        }
    }

    private func tokenize(_ text: String, vocab: OpaquePointer?) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), false, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), false, true)
        }
        return Array(tokens.prefix(Int(max(count, 0))))
    }

    private func piece(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(count, 0))).map { UInt8(bitPattern: $0) }
    }

    private func setStopped(_ value: Bool) {
        lock.lock()
        isStopped = value
        lock.unlock()
    }

    private func checkStopped() throws {
        lock.lock()
        let stop = isStopped
        lock.unlock()
        if stop { throw CancellationError() }
    }
}

/// Follows the answer's braces, outside strings: the plan is written when the
/// outermost object closes.
struct JSONDepth {
    private var depth = 0
    private var started = false
    private var inString = false
    private var escaped = false

    /// - Returns: true once the outermost object has closed.
    mutating func read(_ bytes: [UInt8]) -> Bool {
        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
                started = true
            case UInt8(ascii: "}"): depth -= 1
                if started, depth == 0 { return true }
            default: break
            }
        }
        return false
    }
}

/// llama.cpp is set up once per process, and keeps quiet unless something breaks.
enum LlamaBackend {
    private static let once: Void = {
        llama_log_set({ level, text, _ in
            guard let text, level == GGML_LOG_LEVEL_ERROR || getenv("STICKFLOW_LLAMA_LOG") != nil else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        }, nil)
        llama_backend_init()
    }()

    static func start() {
        _ = once
    }
}
