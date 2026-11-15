//
//  AppModel.swift
//  ITXTranslate
//
//  UI 状态机：麦克风权限 / 模型加载 / ASR 事件配对 / 串行翻译队列。
//
//  设计要点：
//  * 所有可变状态只在主线程（@MainActor）改，ASR 事件、推理结果一律回主线程再写；
//  * 推理放 Task.detached，主线程只负责状态迁移，避免卡界面；
//  * 自动模式同时跑 zh / en 两个识别器，final 先攒在 pendingFinals 里，
//    静默 700ms 后只挑一条去翻译（避免重复翻译同一句话）；
//  * 翻译队列丢最旧保最新，最多 3 条。
//

import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

/// 排队中的一条翻译任务（只在主线程使用）。
private struct TranslationJob {
    let text: String
    let source: SpeechLanguage
    let target: OutputLanguage
}

/// 推理结果跨线程传回来的载体（全部是 Sendable 值）。
private struct TranslationOutput: Sendable {
    let text: String
    let metrics: String
    let latencyMS: Int
    let generation: Int
}

/// 模型加载结果（全部是 Sendable 值）。
private struct LoadedModelInfo: Sendable {
    let description: String
    let isLoaded: Bool
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: - 对外界面状态

    @Published var inputMode: InputMode = .chinese
    @Published var target: OutputLanguage = .english
    @Published var statusText: String = "启动中…"
    @Published var isModelReady: Bool = false
    @Published var isListening: Bool = false
    @Published var transcript: String = ""
    @Published var translation: String = ""
    @Published var errorMessage: String = ""
    @Published var metrics: String = ""
    @Published var level: Double = 0
    @Published var modelName: String = ""
    @Published var supportedLocalesText: String = ""
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var lastLatencyMS: Int = 0

    // 过程状态（界面用于隐藏/显示加载卡片与“翻译中”指示）
    @Published var isLoadingModel: Bool = true
    @Published var isTranslating: Bool = false

    // MARK: - 私有状态

    private let translator: LlamaTranslator = LlamaTranslator()
    private var asr: (any ASREngine)?

    /// 已经定稿的转写文本；实时 partial 拼在它后面显示
    private var finalizedTranscript: String = ""

    /// 自动模式下等待配对的 final
    private var pendingFinals: [(localeID: String, text: String)] = []
    private var flushScheduled: Bool = false
    private var flushTask: Task<Void, Never>?
    private var flushToken: Int = 0

    /// 翻译任务。数组只放“排队中”的任务，正在跑的那条在 pump 里被取走。
    private static let maxQueuedJobs: Int = 3
    private var jobs: [TranslationJob] = []
    private var isPumping: Bool = false

    /// 清空时自增，让在途的模型加载/翻译结果作废
    private var generation: Int = 0
    private var isLoadingTask: Bool = false
    private var isStartingListening: Bool = false
    /// 每次开始聆听自增，用来丢弃上一次会话迟到的 ASR 事件
    private var sessionToken: Int = 0

    // MARK: - 启动

    /// 请求麦克风权限 → 找模型并加载 → 读取系统语音识别支持的语言。
    func bootstrap() async {
        // 启动时先弹一次系统麦克风授权；真正点“开始聆听”时还会再校验一次
        _ = await AppModel.requestMicPermission()

        loadModelIfNeeded()
        supportedLocalesText = await AppModel.loadSupportedLocalesText()
    }

    /// 找模型并异步加载。找不到就把状态留在“未找到模型，请下载或导入”。
    func loadModelIfNeeded() {
        guard !isModelReady, !isLoadingTask else { return }

        guard let modelURL = ModelStore.locateModel() else {
            isLoadingModel = false
            isModelReady = false
            statusText = "未找到模型，请下载或导入"
            return
        }

        isLoadingTask = true
        isLoadingModel = true
        statusText = "正在加载模型…"

        let path: String = modelURL.path
        let translator: LlamaTranslator = self.translator
        let currentGeneration: Int = generation

        let task: Task<LoadedModelInfo, Error> = Task.detached {
            try translator.load(modelPath: path)
            return LoadedModelInfo(description: translator.modelDescription,
                                   isLoaded: translator.isLoaded)
        }

        Task { @MainActor in
            do {
                let info: LoadedModelInfo = try await task.value
                guard currentGeneration == self.generation else {
                    self.isLoadingTask = false
                    self.isLoadingModel = false
                    return
                }
                self.modelName = info.description
                self.isModelReady = info.isLoaded
                self.isLoadingTask = false
                self.isLoadingModel = false
                if info.isLoaded {
                    self.errorMessage = ""
                    self.statusText = "就绪"
                } else {
                    self.statusText = "模型加载失败"
                    self.errorMessage = "模型加载失败：未能建立推理上下文。"
                }
            } catch {
                guard currentGeneration == self.generation else {
                    self.isLoadingTask = false
                    self.isLoadingModel = false
                    return
                }
                self.isModelReady = false
                self.isLoadingTask = false
                self.isLoadingModel = false
                self.statusText = "模型加载失败"
                self.errorMessage = "模型加载失败：" + error.localizedDescription
            }
        }
    }

    /// 用户把 .gguf 放进 Documents 之后手动重新扫描。
    func rescanModel() {
        guard !isModelReady, !isLoadingTask else { return }
        isLoadingModel = true
        loadModelIfNeeded()
    }

    /// 请求麦克风权限（AVAudioSession 包一层 async）。
    static func requestMicPermission() async -> Bool {
        let session: AVAudioSession = AVAudioSession.sharedInstance()
        let granted: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            session.requestRecordPermission { (allowed: Bool) in
                continuation.resume(returning: allowed)
            }
        }
        return granted
    }

    /// 读取系统语音识别支持的语言列表，用“、”拼起来给界面用。
    private static func loadSupportedLocalesText() async -> String {
        if #available(iOS 26.0, *) {
            let locales: [Locale] = await SpeechTranscriber.supportedLocales
            if locales.isEmpty {
                return "本机不支持系统语音识别（或尚未安装语音资源）"
            }
            var identifiers: [String] = []
            identifiers.reserveCapacity(locales.count)
            for locale in locales {
                identifiers.append(locale.identifier.replacingOccurrences(of: "_", with: "-"))
            }
            identifiers.sort()
            return identifiers.joined(separator: "、")
        }
        return "需要 iPadOS 26 及以上才支持系统语音识别"
    }

    // MARK: - 麦克风开始 / 停止

    func toggleListening() {
        if isListening {
            Task { @MainActor in
                await self.stopListening()
            }
            return
        }
        if isDownloading {
            errorMessage = "模型正在下载，请稍候再试。"
            return
        }
        guard isModelReady else {
            errorMessage = "模型未就绪：请先下载或导入模型。"
            return
        }
        Task { @MainActor in
            await self.startListening()
        }
    }

    private func startListening() async {
        guard !isListening, !isStartingListening else { return }
        isStartingListening = true
        defer { isStartingListening = false }

        let granted: Bool = await AppModel.requestMicPermission()
        guard granted else {
            errorMessage = "麦克风权限未开启：请到 设置 → 隐私与安全性 → 麦克风 中允许本 App。"
            return
        }
        guard isModelReady else {
            errorMessage = "模型未就绪：请先下载或导入模型。"
            return
        }

        // 新的一轮聆听：清掉上一轮的实时转写，保留上一条译文方便对照
        finalizedTranscript = ""
        transcript = ""
        pendingFinals.removeAll()
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
        flushToken += 1
        errorMessage = ""

        if #available(iOS 26.0, *) {
            asr = SpeechAnalyzerASR()
        } else {
            errorMessage = "需要 iPadOS 26 及以上"
            return
        }

        guard let engine = asr else {
            errorMessage = "语音识别组件初始化失败。"
            return
        }

        let localeIDs: [String] = inputMode.localeIDs
        sessionToken += 1
        let token: Int = sessionToken
        statusText = "正在启动语音识别…"
        do {
            try await engine.start(localeIDs: localeIDs) { [weak self] (event: ASREvent) in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard token == self.sessionToken else { return }
                    self.handle(event)
                }
            }
            isListening = true
            level = 0
            statusText = "聆听中…"
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            asr = nil
            isListening = false
            UIApplication.shared.isIdleTimerDisabled = false
            errorMessage = "语音识别启动失败：" + error.localizedDescription
            statusText = isModelReady ? "就绪" : statusText
        }
    }

    func stopListening() async {
        guard isListening || asr != nil else { return }

        if let engine = asr {
            await engine.stop()
        }
        asr = nil
        isListening = false
        level = 0
        UIApplication.shared.isIdleTimerDisabled = false

        // 自动模式下把还没配对的 final 补翻译掉
        if inputMode == .auto {
            flushFinals()
        }

        if isTranslating {
            statusText = "翻译中…"
        } else {
            statusText = isModelReady ? "就绪" : statusText
        }
    }

    // MARK: - ASR 事件

    @MainActor
    private func handle(_ event: ASREvent) {
        switch event {
        case let .partial(_, text):
            var combined: String = finalizedTranscript
            let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !combined.isEmpty {
                    combined += " "
                }
                combined += trimmed
            }
            transcript = combined

        case let .final(localeID, text):
            handleFinal(localeID: localeID, text: text)

        case let .level(value):
            level = Double(min(Float(1.0), max(Float(0.0), value)))

        case let .error(message):
            errorMessage = message
        }
    }

    private func handleFinal(localeID: String, text: String) {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if finalizedTranscript.isEmpty {
            finalizedTranscript = trimmed
        } else {
            finalizedTranscript += " " + trimmed
        }
        transcript = finalizedTranscript

        if inputMode == .auto {
            pendingFinals.append((localeID: localeID, text: trimmed))
            scheduleFlushIfNeeded()
        } else {
            let source: SpeechLanguage = SpeechLanguage.from(localeID: localeID)
            enqueue(text: trimmed, source: source)
        }
    }

    /// 700ms 内没有新的 final，就把攒下的 final 配对成一句去翻译。
    /// 只在第一条 final 时排一次，后续 final 不会重置计时。
    private func scheduleFlushIfNeeded() {
        guard !flushScheduled else { return }
        flushScheduled = true
        flushToken += 1
        let token: Int = flushToken
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            guard token == self.flushToken else { return }
            self.flushFinals()
        }
    }

    private func flushFinals() {
        flushScheduled = false
        flushToken += 1
        flushTask?.cancel()
        flushTask = nil

        guard !pendingFinals.isEmpty else { return }

        var chosenLocaleID: String?
        var chosenText: String?

        // 1) 中文识别器且文本里确实有汉字 → 选它
        for entry in pendingFinals.reversed() {
            if SpeechLanguage.from(localeID: entry.localeID) == .chinese,
               AppModel.containsHan(entry.text) {
                chosenLocaleID = entry.localeID
                chosenText = entry.text
                break
            }
        }

        // 2) 英文识别器、含拉丁字母且没有汉字 → 选它
        if chosenText == nil {
            for entry in pendingFinals.reversed() {
                if SpeechLanguage.from(localeID: entry.localeID) == .english,
                   AppModel.containsLatinLetter(entry.text),
                   !AppModel.containsHan(entry.text) {
                    chosenLocaleID = entry.localeID
                    chosenText = entry.text
                    break
                }
            }
        }

        // 3) 都不满足 → 取最长的一条
        if chosenText == nil {
            var longest: (localeID: String, text: String)?
            for entry in pendingFinals {
                if longest == nil || entry.text.count > (longest?.text.count ?? 0) {
                    longest = entry
                }
            }
            if let best = longest {
                chosenLocaleID = best.localeID
                chosenText = best.text
            }
        }

        pendingFinals.removeAll()

        guard let text = chosenText, !text.isEmpty else { return }
        let source: SpeechLanguage
        if let localeID = chosenLocaleID {
            source = SpeechLanguage.from(localeID: localeID)
        } else {
            source = SpeechLanguage.detect(from: text)
        }
        enqueue(text: text, source: source)
    }

    private static func containsHan(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where SpeechLanguage.isHan(scalar) {
            return true
        }
        return false
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A:
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: - 翻译队列

    private func enqueue(text: String, source: SpeechLanguage) {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isModelReady else {
            errorMessage = "模型未就绪，无法翻译。"
            return
        }

        // 目标语言和源语言撞了 → 自动换成另一种（中英互译）
        var actualTarget: OutputLanguage = target
        if let targetSpeechLanguage = target.speechLanguage,
           targetSpeechLanguage == source {
            let corrected: OutputLanguage = (source.counterpart == .chinese) ? .chinese : .english
            actualTarget = corrected
            target = corrected
            statusText = "已自动切换为 " + corrected.displayName
        }

        // 丢最旧、保最新，队列最多 3 条
        if jobs.count >= AppModel.maxQueuedJobs {
            jobs.removeFirst()
        }
        jobs.append(TranslationJob(text: trimmed, source: source, target: actualTarget))
        pump()
    }

    /// 串行消费队列：一次只跑一条推理，跑完再 pump 下一条。
    private func pump() {
        guard !isPumping, !jobs.isEmpty, isModelReady else { return }

        let job: TranslationJob = jobs.removeFirst()
        isPumping = true
        isTranslating = true
        let currentGeneration: Int = generation

        let translator: LlamaTranslator = self.translator
        let prompt: String = PromptBuilder.full(text: job.text, source: job.source, target: job.target)
        let maxTokens: Int32 = 192

        let task: Task<TranslationOutput, Error> = Task.detached {
            let output: (text: String, timing: LlamaTiming) = try translator.translate(prompt: prompt,
                                                                                     maxTokens: maxTokens)
            let cleaned: String = PromptBuilder.clean(output.text)
            let summary: String = output.timing.summary
            let latency: Int = Int(output.timing.promptMS) + Int(output.timing.genMS)
            return TranslationOutput(text: cleaned,
                                     metrics: summary,
                                     latencyMS: latency,
                                     generation: currentGeneration)
        }

        Task { @MainActor in
            do {
                let result: TranslationOutput = try await task.value
                if result.generation == self.generation {
                    self.translation = result.text
                    self.metrics = result.metrics
                    self.lastLatencyMS = result.latencyMS
                }
            } catch {
                if currentGeneration == self.generation {
                    self.errorMessage = "翻译失败：" + error.localizedDescription
                }
            }
            self.isPumping = false
            self.isTranslating = false
            if !self.isListening, self.isModelReady {
                self.statusText = "就绪"
            }
            self.pump()
        }
    }

    // MARK: - 模型下载 / 导入

    func downloadModel() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = ""
        statusText = "正在下载模型…"

        let urlString: String = ModelStore.defaultDownloadURLString
        Task { @MainActor in
            do {
                let fileURL: URL = try await ModelStore.downloadModel(from: urlString) { [weak self] (fraction: Double) in
                    Task { @MainActor in
                        self?.downloadProgress = min(max(fraction, 0.0), 1.0)
                    }
                }
                _ = fileURL
                self.downloadProgress = 1.0
                self.isDownloading = false
                self.statusText = "模型下载完成，正在加载…"
                self.isLoadingModel = true
                self.loadModelIfNeeded()
            } catch {
                self.isDownloading = false
                self.statusText = "模型下载失败"
                self.errorMessage = "模型下载失败：" + error.localizedDescription
            }
        }
    }

    /// 文件选择器拿到的 URL 直接交给 ModelStore（安全作用域访问由它处理）。
    func importModel(url: URL) {
        guard !isDownloading, !isLoadingTask else { return }
        errorMessage = ""
        statusText = "正在导入模型…"
        isLoadingModel = true
        let sourceURL: URL = url

        Task { @MainActor in
            do {
                let task: Task<URL, Error> = Task.detached {
                    return try ModelStore.importModel(from: sourceURL)
                }
                _ = try await task.value
                self.loadModelIfNeeded()
            } catch {
                self.isLoadingModel = false
                self.statusText = "模型导入失败"
                self.errorMessage = "模型导入失败：" + error.localizedDescription
            }
        }
    }

    // MARK: - 语言选择

    func selectInputMode(_ mode: InputMode) {
        guard !isListening else { return }
        inputMode = mode
        if mode != .auto {
            pendingFinals.removeAll()
            flushTask?.cancel()
            flushTask = nil
            flushScheduled = false
            flushToken += 1
        }
    }

    func selectTarget(_ language: OutputLanguage) {
        target = language
    }

    // MARK: - 其它

    func clearAll() {
        generation += 1
        translation = ""
        transcript = ""
        finalizedTranscript = ""
        metrics = ""
        lastLatencyMS = 0
        level = 0
        errorMessage = ""
        isTranslating = false
        pendingFinals.removeAll()
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
        flushToken += 1
        jobs.removeAll()
    }

    func clearError() {
        errorMessage = ""
    }

    func reportError(_ message: String) {
        errorMessage = message
    }
}
