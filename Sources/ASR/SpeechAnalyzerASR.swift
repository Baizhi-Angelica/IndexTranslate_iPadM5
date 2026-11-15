//
//  SpeechAnalyzerASR.swift
//  ASR 层：用 iPadOS 26 的 SpeechAnalyzer + SpeechTranscriber 做流式转写。
//
//  职责：
//  - 支持同时跑多个 locale（自动模式：zh-CN + en-US），每个 locale 一套
//    transcriber / analyzer / 输入流，互不干扰；
//  - 通过 Core.swift 定义的 ASREvent 向上层抛 partial / final / level / error；
//  - 音频链路：AVAudioEngine tap（麦克风原生格式）→ AVAudioConverter（目标格式）
//    → AsyncStream<AnalyzerInput> → SpeechAnalyzer。
//
//  约束：
//  - 工程部署目标是 iOS 17，所以整类用 @available(iOS 26.0, *) 门控；
//  - 麦克风权限由上层负责（这里不使用 AVAudioApplication）；
//  - 不用 actor：tap 回调里只读取启动后不再变化的数组，事件直接 onEvent 抛出，
//    由上层自己切回 MainActor。
//

import AVFoundation
import Foundation
import Speech

@available(iOS 26.0, *)
final class SpeechAnalyzerASR: ASREngine {

    // MARK: - 音频线程上下文

    /// installTap 回调（音频线程）要用的不可变上下文。
    /// 这些数组在启动阶段建好后就只读，音频线程不会看到半成品状态。
    /// `didReportConversionError` 只在音频线程（tap 回调）里读写。
    private final class TapContext: @unchecked Sendable {

        let converters: [AVAudioConverter]
        let continuations: [AsyncStream<AnalyzerInput>.Continuation]
        let targetFormats: [AVAudioFormat]
        let micSampleRate: Double
        let onEvent: @Sendable (ASREvent) -> Void

        /// 转换失败时只报一次错，避免音频线程每个 buffer 都往上层刷 error。
        var didReportConversionError: Bool

        init(converters: [AVAudioConverter],
             continuations: [AsyncStream<AnalyzerInput>.Continuation],
             targetFormats: [AVAudioFormat],
             micSampleRate: Double,
             onEvent: @escaping @Sendable (ASREvent) -> Void) {
            self.converters = converters
            self.continuations = continuations
            self.targetFormats = targetFormats
            self.micSampleRate = micSampleRate
            self.onEvent = onEvent
            self.didReportConversionError = false
        }
    }

    // MARK: - 状态

    private var running: Bool = false
    private var tapInstalled: Bool = false
    private var audioSessionActive: Bool = false

    private var engine: AVAudioEngine?
    private var analyzers: [SpeechAnalyzer] = []
    private var streams: [AsyncStream<AnalyzerInput>] = []
    private var continuations: [AsyncStream<AnalyzerInput>.Continuation] = []
    private var converters: [AVAudioConverter] = []
    private var tasks: [Task<Void, Never>] = []

    // MARK: - 错误

    private static let errorDomain: String = "SpeechAnalyzerASR"

    private static func makeError(_ message: String, code: Int) -> NSError {
        return NSError(domain: errorDomain,
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - ASREngine

    func start(localeIDs: [String], onEvent: @escaping @Sendable (ASREvent) -> Void) async throws {
        guard !running else {
            throw SpeechAnalyzerASR.makeError("语音识别已经在运行中，请先调用 stop()", code: 1)
        }
        guard !localeIDs.isEmpty else {
            throw SpeechAnalyzerASR.makeError("没有指定要识别的语言", code: 2)
        }
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerASR.makeError("当前设备不支持 SpeechTranscriber 语音识别（isAvailable == false）", code: 3)
        }
        running = true

        // 1. 逐个解析系统支持的语言。supportedLocale 返回的是“等价 locale”，
        //    例如请求 "zh-CN" 可能解析成 "zh_CN" 或 "zh-Hans-CN"。
        var resolvedIDs: [String] = []
        var resolvedLocales: [Locale] = []
        for localeID in localeIDs {
            let candidate: Locale = Locale(identifier: localeID)
            guard let supported: Locale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) else {
                let supportedLocales: [Locale] = await SpeechTranscriber.supportedLocales
                let preview: String = supportedLocales.prefix(6).map { $0.identifier }.joined(separator: ", ")
                throw SpeechAnalyzerASR.makeError("当前设备不支持语音识别语言 \(localeID)。可用语言示例：\(preview)", code: 4)
            }
            resolvedIDs.append(localeID)
            resolvedLocales.append(supported)
        }

        do {
            // 2. 每个 locale 一个 transcriber；模型没装就先下载安装。
            var transcribers: [SpeechTranscriber] = []
            for locale in resolvedLocales {
                let transcriber: SpeechTranscriber = SpeechTranscriber(locale: locale,
                                                                      preset: .progressiveTranscription)
                transcribers.append(transcriber)
            }

            let modules: [any SpeechModule] = transcribers.map { $0 as any SpeechModule }
            let assetStatus: AssetInventory.Status = await AssetInventory.status(forModules: modules)
            if assetStatus != .installed {
                if let request: AssetInstallationRequest = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await request.downloadAndInstall()
                }
            }

            // 3. 每个 locale 一个 analyzer（各自持有一个 transcriber）。
            var analyzers: [SpeechAnalyzer] = []
            for transcriber in transcribers {
                let analyzer: SpeechAnalyzer = SpeechAnalyzer(modules: [transcriber as any SpeechModule],
                                                              options: nil)
                analyzers.append(analyzer)
            }

            // 4. 每个 transcriber 取一个目标音频格式；拿不到就退回 16kHz 单声道 Float32。
            var targetFormats: [AVAudioFormat] = []
            for transcriber in transcribers {
                let bestFormat: AVAudioFormat? = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber as any SpeechModule])
                let targetFormat: AVAudioFormat = bestFormat ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                targetFormats.append(targetFormat)
            }

            // 5. 预热分析器，减少第一句结果的启动延迟。
            for index in 0..<analyzers.count {
                try await analyzers[index].prepareToAnalyze(in: targetFormats[index])
            }

            // 6 + 7. 每个 analyzer 一条独立输入流；同时起“分析任务”和“结果消费任务”。
            var streams: [AsyncStream<AnalyzerInput>] = []
            var continuations: [AsyncStream<AnalyzerInput>.Continuation] = []
            var tasks: [Task<Void, Never>] = []

            for index in 0..<analyzers.count {
                let analyzer: SpeechAnalyzer = analyzers[index]
                let transcriber: SpeechTranscriber = transcribers[index]
                let localeID: String = resolvedIDs[index]

                let pair: (stream: AsyncStream<AnalyzerInput>, continuation: AsyncStream<AnalyzerInput>.Continuation) =
                    AsyncStream<AnalyzerInput>.makeStream(of: AnalyzerInput.self)
                let inputStream: AsyncStream<AnalyzerInput> = pair.stream
                let continuation: AsyncStream<AnalyzerInput>.Continuation = pair.continuation

                // analyzer.start 本身会立刻返回，分析在 analyzer 内部继续跑；
                // 这里 catch 的是启动/运行期间的即时错误。
                let startTask: Task<Void, Never> = Task {
                    do {
                        try await analyzer.start(inputSequence: inputStream)
                    } catch {
                        if Task.isCancelled { return }
                        onEvent(.error("\(localeID) 语音分析器启动失败：\(error.localizedDescription)"))
                    }
                }

                let resultsTask: Task<Void, Never> = Task {
                    do {
                        for try await result in transcriber.results {
                            let text: String = String(result.text.characters)
                            if text.isEmpty { continue }
                            if result.isFinal {
                                onEvent(.final(localeID: localeID, text: text))
                            } else {
                                onEvent(.partial(localeID: localeID, text: text))
                            }
                        }
                    } catch {
                        if Task.isCancelled { return }
                        onEvent(.error("\(localeID) 语音识别失败：\(error.localizedDescription)"))
                    }
                }

                streams.append(inputStream)
                continuations.append(continuation)
                tasks.append(startTask)
                tasks.append(resultsTask)
            }

            // 先登记到属性里，后面任何一步 throw 都能被 catch 统一清理。
            self.analyzers = analyzers
            self.streams = streams
            self.continuations = continuations
            self.tasks = tasks

            // 8. 录音会话：只录不播。
            let session: AVAudioSession = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            self.audioSessionActive = true

            // 9. AVAudioEngine：麦克风原生格式 → 每个 locale 的目标格式 → 各自的输入流。
            let audioEngine: AVAudioEngine = AVAudioEngine()
            self.engine = audioEngine

            let inputNode: AVAudioInputNode = audioEngine.inputNode
            let micFormat: AVAudioFormat = inputNode.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
                throw SpeechAnalyzerASR.makeError("无法获取麦克风输入格式（采样率或声道数为 0），请检查麦克风权限", code: 5)
            }

            var converters: [AVAudioConverter] = []
            for targetFormat in targetFormats {
                guard let converter: AVAudioConverter = AVAudioConverter(from: micFormat, to: targetFormat) else {
                    throw SpeechAnalyzerASR.makeError("无法创建音频格式转换器（\(micFormat.sampleRate) Hz / \(micFormat.channelCount) ch → \(targetFormat.sampleRate) Hz / \(targetFormat.channelCount) ch）", code: 6)
                }
                converters.append(converter)
            }
            self.converters = converters

            let tapContext: TapContext = TapContext(converters: converters,
                                                    continuations: continuations,
                                                    targetFormats: targetFormats,
                                                    micSampleRate: micFormat.sampleRate,
                                                    onEvent: onEvent)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
                SpeechAnalyzerASR.handleTapBuffer(buffer, context: tapContext)
            }
            self.tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

        } catch {
            self.running = false
            self.shutdownAfterFailedStart()
            throw error
        }
    }

    func stop() async {
        running = false

        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil

        for continuation in continuations {
            continuation.finish()
        }

        // 输入流已结束：让 analyzer 把已进入的数据分析完，并吐出最后一批 final 结果。
        for analyzer in analyzers {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // finalize 返回后结果流虽然已经结束，但结果消费任务可能还有最后 1~2 条 final
        // 没来得及处理（Apple 文档也提到：立刻取消消费任务会丢掉末尾的结果）。
        // 这里给一个很短的宽限时间，避免“停止时最后一句话丢失”。
        if !tasks.isEmpty {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        for task in tasks {
            task.cancel()
        }

        if audioSessionActive {
            audioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }

        resetState()
    }

    // MARK: - 音频线程

    /// installTap 回调体（音频线程）。
    /// 这里只做 RMS + 格式转换 + yield；不要碰 UI、不要做耗时操作。
    private static func handleTapBuffer(_ buffer: AVAudioPCMBuffer, context: TapContext) {
        context.onEvent(.level(rmsLevel(of: buffer)))

        let frameLength: AVAudioFrameCount = buffer.frameLength
        guard frameLength > 0 else { return }

        for index in 0..<context.converters.count {
            let converter: AVAudioConverter = context.converters[index]
            let targetFormat: AVAudioFormat = context.targetFormats[index]

            let micRate: Double = context.micSampleRate
            let targetRate: Double = targetFormat.sampleRate
            guard micRate > 0, targetRate > 0 else { continue }

            // 输出容量按采样率比例放大，再留 64 帧余量（转换器内部有少量延迟/取整）。
            let capacityValue: Double = (Double(frameLength) * targetRate / micRate).rounded(.up) + 64.0
            let capacity: AVAudioFrameCount = AVAudioFrameCount(capacityValue)
            guard capacity > 0,
                  let outputBuffer: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                                        frameCapacity: capacity) else {
                continue
            }

            var conversionError: NSError?
            var inputDelivered: Bool = false

            let status: AVAudioConverterOutputStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                // 输入 block 只提供一次数据：首次给 buffer，之后一律 .noDataNow。
                if inputDelivered {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputDelivered = true
                inputStatus.pointee = .haveData
                return buffer
            }

            if status == .error || conversionError != nil {
                if !context.didReportConversionError {
                    context.didReportConversionError = true
                    let detail: String = conversionError?.localizedDescription ?? "未知错误"
                    context.onEvent(.error("音频格式转换失败：\(detail)"))
                }
                continue
            }

            if outputBuffer.frameLength > 0 {
                let input: AnalyzerInput = AnalyzerInput(buffer: outputBuffer)
                context.continuations[index].yield(input)
            }
        }
    }

    /// 计算 RMS 电平，限制在 0...1。麦克风格式一般是 Float32；这里顺带兼容 Int16。
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frameCount: Int = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        if let floatData: UnsafeMutablePointer<Float> = buffer.floatChannelData?[0] {
            for index in 0..<frameCount {
                let sample: Float = floatData[index]
                sum += sample * sample
            }
            return min(1, (sum / Float(frameCount)).squareRoot())
        }
        if let int16Data: UnsafeMutablePointer<Int16> = buffer.int16ChannelData?[0] {
            for index in 0..<frameCount {
                let sample: Float = Float(int16Data[index]) / 32768.0
                sum += sample * sample
            }
            return min(1, (sum / Float(frameCount)).squareRoot())
        }
        return 0
    }

    // MARK: - 清理

    /// 启动过程出错时的清理：停引擎、收流、取消任务（不调用 finalize，避免二次错误/卡住）。
    private func shutdownAfterFailedStart() {
        running = false

        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil

        for continuation in continuations {
            continuation.finish()
        }
        for task in tasks {
            task.cancel()
        }

        if audioSessionActive {
            audioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }

        resetState()
    }

    private func resetState() {
        tapInstalled = false
        audioSessionActive = false
        engine = nil
        analyzers.removeAll()
        streams.removeAll()
        continuations.removeAll()
        converters.removeAll()
        tasks.removeAll()
    }
}
