//
//  AppModel.swift
//  ITXTranslate
//
//  UI 状态机：麦克风权限 / 模型加载 / ASR 事件配对 / 串行翻译队列。
//
//  设计要点：
//  * 所有可变状态只在主线程（@MainActor）改，ASR 事件、推理结果一律回主线程再写；
//  * 推理放 Task.detached，主线程只负责状态迁移，避免卡界面；
//  * 自动模式默认只跑中文识别器（中英混说时英文词也能被中文识别器捕捉，实测更稳）；
//    只有打开实验开关 dualRecognizer 才同时跑 zh / en 两路。两路时 final 先攒着，
//    尽量等两路到齐（或距第一条 final 1200ms）再配对：只挑一条翻译，另一条整条丢弃，
//    避免英文识别器对中文音频的幻觉被翻译；
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
    /// 这条译文对应的原文（用于「上一句」搬移与诊断）
    let sourceText: String
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

    /// 实验开关：自动模式同时跑中英双识别器（默认关；单中文识别器实测更好）
    @Published var dualRecognizer: Bool = false
    /// 当前识别引擎名（SpeechAnalyzer / SFSpeechRecognizer（降级）），来自 ASRFactory
    @Published var asrEngineName: String = ""

    /// 当前这句译文的原文（上一句搬移时用到）
    @Published var sourceText: String = ""
    /// 当前这句（正在说 / 刚翻译）的原文：原文行只显示这一段，不累积整场
    @Published var currentSource: String = ""
    /// 正在说话（未定稿）的实时文本：显示在 metrics 行下面，不占「当前句原文」的位置
    @Published var livePartial: String = ""
    /// 上一句译文（连续字幕：上方同字号灰色）
    @Published var previousTranslation: String = ""
    /// 上一句原文（连续字幕：上方更小一号灰色）
    @Published var previousSource: String = ""

    // 过程状态（界面用于隐藏/显示加载卡片与“翻译中”指示）
    @Published var isLoadingModel: Bool = true
    @Published var isTranslating: Bool = false

    // MARK: - 私有状态

    private let translator: LlamaTranslator = LlamaTranslator()
    private var asr: (any ASREngine)?

    /// 已经定稿的转写文本；实时 partial 拼在它后面显示
    private var finalizedTranscript: String = ""

    /// 电平自适应归一化用的慢衰减峰值（安静后慢慢回落，约 2 秒半衰）
    private var levelPeak: Double = 0.45

    /// 自动模式配对：localeID -> 该识别器给出的 final（每路保留一条）
    private var pendingFinals: [String: String] = [:]
    /// 本批第一条 final 的到达时间；flushDeadline 由此 +1.2s 得出，不随新 final 重置
    private var pendingFirstArrival: Date?
    /// 本批配对的截止时间（两路没到齐时到点强制 flush）
    private var flushDeadline: Date?
    private var flushScheduled: Bool = false
    private var flushTask: Task<Void, Never>?
    private var flushToken: Int = 0
    /// 本次聆听实际启动的识别器 locale（只有 1 路时不需要等另一路）
    private var activeLocaleIDs: Set<String> = []
    /// 状态栏临时提示（丢弃幻觉等）的 token，防止旧提示的清空任务串台
    private var statusNoticeToken: Int = 0
    /// 临时提示预计消失的时间；翻译完成时不要用「就绪」提前盖掉提示
    private var statusNoticeUntil: Date?

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
        pendingFirstArrival = nil
        flushDeadline = nil
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
        flushToken += 1
        statusNoticeToken += 1
        statusNoticeUntil = nil
        errorMessage = ""

        // 优先 iOS 26 的 SpeechAnalyzer；硬件/资源不支持时自动降级到 SFSpeechRecognizer（设备端）
        let factoryResult: (engine: any ASREngine, name: String) = ASRFactory.make()
        asr = factoryResult.engine
        asrEngineName = factoryResult.name

        guard let engine = asr else {
            errorMessage = "语音识别组件初始化失败。"
            return
        }

        // 自动模式：默认只跑中文识别器（中英混说时英文词也能被它捕捉，实测比双路更稳）；
        // 只有打开 dualRecognizer 实验开关后才同时跑 zh + en 两路。
        var localeIDs: [String] = inputMode.localeIDs
        if inputMode == .auto && !dualRecognizer {
            localeIDs = [SpeechLanguage.chinese.localeID]
        }
        if factoryResult.name.contains("降级") && localeIDs.count > 1 {
            // 降级后端只有一路识别，自动模式退化为默认中文（英文词仍能被中文识别器捕捉）
            localeIDs = [localeIDs[0]]
        }
        activeLocaleIDs = Set(localeIDs)
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
            statusText = "聆听中…（" + asrEngineName + "）"
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
        levelPeak = 0.45
        livePartial = ""
        UIApplication.shared.isIdleTimerDisabled = false
        statusNoticeToken += 1
        statusNoticeUntil = nil

        if isTranslating {
            statusText = "翻译中…"
        } else {
            statusText = isModelReady ? "就绪" : statusText
        }

        // 自动模式下把还没配对的 final 补翻译掉（可能在这里再显示“已丢弃…”提示）
        if inputMode == .auto {
            flushFinals()
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
                // 实时 partial 只进「正在听」区，不占「当前句原文」的位置
                livePartial = trimmed
                if !combined.isEmpty {
                    combined += " "
                }
                combined += trimmed
            }
            transcript = combined

        case let .final(localeID, text):
            handleFinal(localeID: localeID, text: text)

        case let .level(value):
            // 自适应归一化：宽范围 dB 原始值 + 慢衰减峰值，正常说话大半格、喊叫接近满格
            let rms: Double = Double(max(value, 0.000001))
            let db: Double = 20.0 * log10(rms)
            let raw: Double = min(1.0, max(0.0, (db + 55.0) / 50.0))
            levelPeak = max(raw, levelPeak * 0.995)
            let normalized: Double = min(1.0, raw / max(levelPeak, 0.45))
            level = max(normalized, level * 0.80)

        case let .error(message):
            errorMessage = message
        }
    }

    private func handleFinal(localeID: String, text: String) {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if inputMode == .auto {
            // 同一路识别器在上一批还没配对完又来了一条：先把上一批 flush 掉，
            // 避免待配对那句被新的一句覆盖丢失。
            if pendingFinals[localeID] != nil {
                flushFinals()
            }

            // 自动模式：先攒起来配对，不要立刻进原文区 / 翻译队列
            if pendingFinals.isEmpty || flushDeadline == nil {
                let now: Date = Date()
                if pendingFirstArrival == nil {
                    pendingFirstArrival = now
                }
                if flushDeadline == nil {
                    let firstArrival: Date = pendingFirstArrival ?? now
                    flushDeadline = firstArrival.addingTimeInterval(AppModel.pairingWindowSeconds)
                }
            }
            pendingFinals[localeID] = trimmed

            let pendingLocales: Set<String> = Set(pendingFinals.keys)
            if activeLocaleIDs.count <= 1 || activeLocaleIDs.isSubset(of: pendingLocales) {
                // 只有一路识别器（默认）或两路都到齐 → 不需要再等
                flushFinals()
            } else {
                scheduleFlushAtDeadline()
            }
        } else {
            // 手动模式：不配对，直接追加原文并翻译
            let source: SpeechLanguage = SpeechLanguage.detect(from: trimmed)
            currentSource = trimmed
            livePartial = ""
            appendFinalToTranscript(trimmed, source: source)
            enqueue(text: trimmed, source: source)
        }
    }

    /// 两路识别器时等待另一路 final 的窗口；到点还没到齐就强制 flush。
    private static let pairingWindowSeconds: TimeInterval = 1.2

    /// 两路还没到齐时，按本批 flushDeadline 排一次定时 flush。
    /// flushDeadline 由本批第一条 final 决定，后续 final 不会重置它。
    private func scheduleFlushAtDeadline() {
        guard !flushScheduled else { return }
        flushScheduled = true
        flushToken += 1
        let token: Int = flushToken
        let deadline: Date = flushDeadline ?? Date().addingTimeInterval(AppModel.pairingWindowSeconds)
        let interval: TimeInterval = max(0.0, deadline.timeIntervalSinceNow)
        let nanos: UInt64 = UInt64(interval * 1_000_000_000.0)
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            guard token == self.flushToken else { return }
            self.flushFinals()
        }
    }

    /// 自动模式配对：从 pendingFinals 里挑一条，其余整条丢弃（不进原文区、也不翻译）。
    private func flushFinals() {
        flushScheduled = false
        flushToken += 1
        flushTask?.cancel()
        flushTask = nil
        pendingFirstArrival = nil
        flushDeadline = nil

        let entries: [String: String] = pendingFinals
        pendingFinals.removeAll()
        guard !entries.isEmpty else { return }

        var chosenLocaleID: String?
        var chosenText: String?

        // 1) 中文识别器且文本里确实有汉字 → 选它
        for (localeID, text) in entries {
            if SpeechLanguage.from(localeID: localeID) == .chinese,
               AppModel.containsHan(text) {
                chosenLocaleID = localeID
                chosenText = text
                break
            }
        }

        // 2) 英文识别器、含拉丁字母且没有汉字 → 选它
        if chosenText == nil {
            for (localeID, text) in entries {
                if SpeechLanguage.from(localeID: localeID) == .english,
                   AppModel.containsLatinLetter(text),
                   !AppModel.containsHan(text) {
                    chosenLocaleID = localeID
                    chosenText = text
                    break
                }
            }
        }

        // 3) 都不满足 → 取最长的一条
        if chosenText == nil {
            var longest: (localeID: String, text: String)?
            for (localeID, text) in entries {
                if longest == nil || text.count > (longest?.text.count ?? 0) {
                    longest = (localeID: localeID, text: text)
                }
            }
            if let best = longest {
                chosenLocaleID = best.localeID
                chosenText = best.text
            }
        }

        // 未选中的识别器结果整条丢弃，并在状态栏留一句可诊断的痕迹
        var discardNotice: String?
        for (localeID, text) in entries {
            if let chosen = chosenLocaleID, localeID == chosen { continue }
            let isChinesePath: Bool = SpeechLanguage.from(localeID: localeID) == .chinese
            let kind: String = isChinesePath ? "中文识别结果" : "英文幻觉"
            let preview: String = String(text.prefix(20)).replacingOccurrences(of: "\n", with: " ")
            if discardNotice == nil {
                discardNotice = "已丢弃" + kind + "：" + preview
            }
        }

        guard let text = chosenText, !text.isEmpty else { return }

        // 源语言以选中文本本身判定（中文识别器路径里也可能是一整句英文）
        let source: SpeechLanguage = SpeechLanguage.detect(from: text)
        // 选中这一条：它既是原文行当前显示，也是这条翻译 job 的原文
        currentSource = text
        livePartial = ""
        appendFinalToTranscript(text, source: source)
        enqueue(text: text, source: source)

        if let notice = discardNotice {
            showStatusNotice(notice)
        }
    }

    /// 把定稿文本追加到原文区。英文片段之间 / 中英边界补空格，避免粘连。
    private func appendFinalToTranscript(_ text: String, source: SpeechLanguage) {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if finalizedTranscript.isEmpty {
            finalizedTranscript = trimmed
        } else {
            var needsSpace: Bool = false
            if source == .english {
                needsSpace = true
            } else if let lastScalar = finalizedTranscript.unicodeScalars.last,
                      AppModel.isLatinLetter(lastScalar) {
                needsSpace = true
            }
            finalizedTranscript += (needsSpace ? " " : "") + trimmed
        }
        transcript = finalizedTranscript
    }

    /// 状态栏临时提示（如“已丢弃英文幻觉：…”），duration 秒后恢复常规状态文字。
    private func showStatusNotice(_ text: String, duration: TimeInterval = 3.0) {
        statusNoticeToken += 1
        let token: Int = statusNoticeToken
        statusNoticeUntil = Date().addingTimeInterval(duration)
        statusText = text
        let nanos: UInt64 = UInt64(duration * 1_000_000_000.0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            guard token == self.statusNoticeToken else { return }
            self.statusNoticeUntil = nil
            self.statusText = self.restingStatusText()
        }
    }

    /// 提示消失、或从「已自动切换为…」这类临时文案回落后，应恢复的状态文字。
    private func restingStatusText() -> String {
        if isListening {
            if asrEngineName.isEmpty {
                return "聆听中…"
            }
            return "聆听中…（" + asrEngineName + "）"
        }
        if isTranslating {
            return "翻译中…"
        }
        if isModelReady {
            return "就绪"
        }
        return statusText
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A:
            return true
        default:
            return false
        }
    }

    private static func containsHan(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where SpeechLanguage.isHan(scalar) {
            return true
        }
        return false
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where AppModel.isLatinLetter(scalar) {
            return true
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
        let jobSourceText: String = job.text
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
                                     generation: currentGeneration,
                                     sourceText: jobSourceText)
        }

        Task { @MainActor in
            do {
                let result: TranslationOutput = try await task.value
                if result.generation == self.generation {
                    // 连续字幕：先把当前这句搬到「上一句」，再落新的
                    if !self.translation.isEmpty {
                        self.previousTranslation = self.translation
                        // sourceText 只在上一次译文落地时写过，正好是上一句译文对应的原文
                        self.previousSource = self.sourceText
                    }
                    self.translation = result.text
                    self.sourceText = result.sourceText
                    // 原句显示与这条译文配对；用户若已在说下一句，后续 partial 会再刷新它
                    self.currentSource = result.sourceText
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
                if self.statusNoticeUntil == nil {
                    self.statusText = "就绪"
                }
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
            pendingFirstArrival = nil
            flushDeadline = nil
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

    /// 「复制诊断」用的多行文本。
    var diagnosticReport: String {
        var lines: [String] = []
        lines.append("模型：" + (modelName.isEmpty ? "未加载" : modelName))
        lines.append("引擎：" + (asrEngineName.isEmpty ? "未启动" : asrEngineName))

        let inputText: String
        if inputMode == .auto {
            inputText = dualRecognizer ? "自动（双识别器）" : "自动（单中文识别器）"
        } else {
            inputText = inputMode.title
        }
        lines.append("输入：" + inputText)
        lines.append("输出：" + target.displayName)
        lines.append("metrics：" + (metrics.isEmpty ? "暂无" : metrics))
        lines.append("延迟：" + (lastLatencyMS > 0 ? String(lastLatencyMS) + " ms" : "暂无"))
        lines.append("错误：" + (errorMessage.isEmpty ? "无" : errorMessage))
        lines.append("支持语言：" + (supportedLocalesText.isEmpty ? "暂无" : supportedLocalesText))
        lines.append("状态：" + statusText)
        return lines.joined(separator: "\n")
    }

    func clearAll() {
        generation += 1
        translation = ""
        transcript = ""
        finalizedTranscript = ""
        sourceText = ""
        currentSource = ""
        livePartial = ""
        previousTranslation = ""
        previousSource = ""
        metrics = ""
        lastLatencyMS = 0
        level = 0
        levelPeak = 0.45
        errorMessage = ""
        isTranslating = false
        pendingFinals.removeAll()
        pendingFirstArrival = nil
        flushDeadline = nil
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
        flushToken += 1
        statusNoticeToken += 1
        statusNoticeUntil = nil
        jobs.removeAll()
    }

    func clearError() {
        errorMessage = ""
    }

    func reportError(_ message: String) {
        errorMessage = message
    }
}
