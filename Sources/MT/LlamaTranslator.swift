//
//  LlamaTranslator.swift
//  IndexTranslate
//
//  llama.cpp 推理封装。Swift 侧只负责"加载模型 / 喂完整 prompt / 收完整文本"，
//  tokenize / decode / sampler / KV 清理全部留在 ITXLlama.c 里。
//

import Foundation

/// 翻译器：内部持有 C 侧的 itx_context。
/// C 层没有共享可变全局状态以外的 Swift 对象，这里用 @unchecked Sendable 把
/// "串行化由 NSLock 保证"这一点显式告诉编译器。
final class LlamaTranslator: @unchecked Sendable {

    // MARK: - 错误

    enum LlamaError: LocalizedError {
        /// 还没加载模型就调用 translate
        case notLoaded
        /// itx_load 返回 NULL
        case loadFailed
        /// itx_generate 返回负数
        case generateFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "模型尚未加载"
            case .loadFailed:
                return "模型加载失败"
            case .generateFailed(let code):
                return "推理失败（错误码 \(code)）"
            }
        }
    }

    // MARK: - 内部状态

    /// itx_context *：C 侧不透明结构体，Swift 里就是 OpaquePointer。
    private var handle: OpaquePointer?
    /// 保护 handle / modelDescription 的短临界区（不覆盖长时间推理）。
    private let lock: NSLock = NSLock()
    /// 串行化 load / translate / unload，保证推理期间 handle 不会被释放。
    private let workLock: NSLock = NSLock()
    /// modelDescription 的存储（读写在 lock 内）。
    private var descriptionStorage: String = "未加载模型"

    init() {
    }

    deinit {
        if let context: OpaquePointer = handle {
            itx_free(context)
        }
    }

    // MARK: - 对外状态

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    var modelDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return descriptionStorage
    }

    // MARK: - 加载 / 卸载

    /// 加载 GGUF。模拟器上不做 Metal offload（gpuLayers = 0），真机全部 offload（999）。
    func load(modelPath: String) throws {
        workLock.lock()
        defer { workLock.unlock() }

        let threads: Int32 = LlamaTranslator.recommendedThreadCount
        let gpuLayers: Int32 = LlamaTranslator.recommendedGPULayers

        let loadedHandle: OpaquePointer? = modelPath.withCString {
            (pathPointer: UnsafePointer<CChar>) -> OpaquePointer? in
            return itx_load(pathPointer, threads, 2048, gpuLayers)
        }
        guard let newHandle: OpaquePointer = loadedHandle else {
            throw LlamaError.loadFailed
        }

        var buffer = [CChar](repeating: 0, count: 256)
        let written: Int32 = itx_model_desc(newHandle, &buffer, Int32(buffer.count))
        let newDescription: String
        if written > 0 {
            newDescription = String(cString: buffer)
        } else {
            newDescription = "Index-Translate-2B（GGUF）"
        }

        lock.lock()
        let oldHandle: OpaquePointer? = handle
        handle = newHandle
        descriptionStorage = newDescription
        lock.unlock()

        if let previous: OpaquePointer = oldHandle {
            itx_free(previous)
        }
    }

    /// 翻译一段已经套好 ChatML 的完整 prompt。输出缓冲 8192 字节。
    func translate(prompt: String, maxTokens: Int32 = 192) throws -> (text: String, timing: LlamaTiming) {
        workLock.lock()
        defer { workLock.unlock() }

        lock.lock()
        let currentHandle: OpaquePointer? = handle
        lock.unlock()

        guard let context: OpaquePointer = currentHandle else {
            throw LlamaError.notLoaded
        }

        var outputBuffer = [CChar](repeating: 0, count: 8192)
        var stats: itx_stats = itx_stats()

        let written: Int32 = prompt.withCString {
            (promptPointer: UnsafePointer<CChar>) -> Int32 in
            return itx_generate(context,
                                promptPointer,
                                maxTokens,
                                &outputBuffer,
                                Int32(outputBuffer.count),
                                &stats)
        }
        guard written >= 0 else {
            throw LlamaError.generateFailed(code: written)
        }

        let text: String = String(cString: outputBuffer)
        let timing = LlamaTiming(promptTokens: stats.prompt_tokens,
                                 genTokens: stats.gen_tokens,
                                 promptMS: stats.prompt_ms,
                                 genMS: stats.gen_ms)
        return (text: text, timing: timing)
    }

    /// 释放 C 侧资源（会等待正在进行的推理结束）。
    func unload() {
        workLock.lock()
        defer { workLock.unlock() }

        lock.lock()
        let oldHandle: OpaquePointer? = handle
        handle = nil
        descriptionStorage = "未加载模型"
        lock.unlock()

        if let context: OpaquePointer = oldHandle {
            itx_free(context)
        }
    }

    // MARK: - 参数

    /// max(2, min(8, 活跃核数 - 2))
    private static var recommendedThreadCount: Int32 {
        let active: Int = ProcessInfo.processInfo.activeProcessorCount
        let candidate: Int = active - 2
        let clamped: Int = max(2, min(8, candidate))
        return Int32(clamped)
    }

    /// 真机全量 offload 到 Metal；模拟器不支持 Metal，必须为 0。
    private static var recommendedGPULayers: Int32 {
        #if targetEnvironment(simulator)
        return 0
        #else
        return 999
        #endif
    }
}

/// 兼容写法：`LlamaError` 和 `LlamaTranslator.LlamaError` 都可用。
typealias LlamaError = LlamaTranslator.LlamaError
