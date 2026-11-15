//
//  LegacyASR.swift
//  ASR 降级后端：iOS 17+ 可用的 SFSpeechRecognizer 设备端流式识别。
//
//  什么时候用：iOS 26 的 SpeechAnalyzer / SpeechTranscriber 在部分设备（或
//  VM/模拟器）上 `isAvailable == false`、`supportedLocales` 为空时，由
//  ASRFactory 降级到这里，保证第一次装机也能转写、不会卡死。
//
//  与 SpeechAnalyzerASR 的差别：
//  - 只支持一个 locale（localeIDs.first；自动模式下第二个 locale 直接忽略，
//    事件里的 localeID 仍是第一个）；
//  - 不做 AVAudioConverter：SFSpeechAudioBufferRecognitionRequest 接受麦克风
//    原生 PCM buffer，直接 append；
//  - 强制设备端识别（requiresOnDeviceRecognition = true），音频不出设备。
//

import AVFoundation
import Foundation
import Speech

final class LegacyASR: ASREngine {

    // MARK: - 状态

    private var running: Bool = false
    private var tapInstalled: Bool = false
    private var audioSessionActive: Bool = false

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var localeID: String = ""
    private var onEvent: (@Sendable (ASREvent) -> Void)?

    // MARK: - 错误

    private static let errorDomain: String = "LegacyASR"

    private static func makeError(_ message: String, code: Int) -> NSError {
        return NSError(domain: errorDomain,
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - ASREngine

    func start(localeIDs: [String], onEvent: @escaping @Sendable (ASREvent) -> Void) async throws {
        guard !running else {
            throw LegacyASR.makeError("语音识别已经在运行中，请先调用 stop()", code: 1)
        }
        guard let firstLocaleID: String = localeIDs.first else {
            throw LegacyASR.makeError("没有指定要识别的语言", code: 2)
        }

        running = true
        localeID = firstLocaleID
        self.onEvent = onEvent

        do {
            // 1. 语音识别权限（麦克风权限由上层处理）。
            //    SFSpeechRecognizer 授权会弹一次系统弹窗；已授权时回调立刻返回当前状态。
            let authStatus: SFSpeechRecognizerAuthorizationStatus = await LegacyASR.requestSpeechAuthorization()
            guard authStatus == .authorized else {
                throw LegacyASR.makeError("语音识别权限未开启（SFSpeechRecognizer 授权状态 \(authStatus.rawValue)）。请到 设置 → 隐私与安全性 → 语音识别 中允许本 App。", code: 3)
            }

            // 2. recognizer：初始化失败或没有设备端识别能力就走 throw（上层会报错）；
            //    这里只认设备端识别，避免把音频发到 Apple 服务器。
            let locale: Locale = Locale(identifier: firstLocaleID)
            guard let recognizer: SFSpeechRecognizer = SFSpeechRecognizer(locale: locale) else {
                throw LegacyASR.makeError("无法创建 SFSpeechRecognizer（语言：\(firstLocaleID)）", code: 4)
            }
            guard recognizer.supportsOnDeviceRecognition else {
                throw LegacyASR.makeError("当前设备/语言不支持设备端语音识别（supportsOnDeviceRecognition == false），SFSpeechRecognizer 降级不可用。", code: 5)
            }
            self.recognizer = recognizer

            // 3. 设备端流式请求。
            let request: SFSpeechAudioBufferRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            self.request = request

            // 4. 录音会话：只录不播。
            let session: AVAudioSession = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            self.audioSessionActive = true

            // 5. 识别任务：回调里用弱引用，避免 task → closure → self 的循环引用。
            let recognitionTask: SFSpeechRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.handleRecognitionCallback(result: result, error: error)
            }
            self.task = recognitionTask

            // 6. 麦克风 tap：算电平 + 原始 buffer 直接 append（不需要格式转换）。
            let audioEngine: AVAudioEngine = AVAudioEngine()
            self.engine = audioEngine

            let inputNode: AVAudioInputNode = audioEngine.inputNode
            let micFormat: AVAudioFormat = inputNode.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
                throw LegacyASR.makeError("无法获取麦克风输入格式（采样率或声道数为 0），请检查麦克风权限", code: 6)
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                self?.handleTapBuffer(buffer)
            }
            self.tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

        } catch {
            running = false
            teardown()
            throw error
        }
    }

    func stop() async {
        running = false
        teardown()
    }

    // MARK: - 回调

    /// 音频线程：算 RMS 电平，并把原始 PCM buffer 直接喂给识别请求。
    private func handleTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard running else { return }
        onEvent?(.level(LegacyASR.rmsLevel(of: buffer)))
        request?.append(buffer)
    }

    /// SFSpeechRecognizer 结果回调（在 recognizer 的 queue 上，不是音频线程）。
    private func handleRecognitionCallback(result: SFSpeechRecognitionResult?, error: Error?) {
        // stop() 之后迟到的回调一律丢弃（包括 cancel 产生的 Cancellation 类错误）。
        guard running else { return }

        if let result = result {
            let text: String = result.bestTranscription.formattedString
            if !text.isEmpty {
                if result.isFinal {
                    onEvent?(.final(localeID: localeID, text: text))
                } else {
                    onEvent?(.partial(localeID: localeID, text: text))
                }
            }
        }

        if let error = error {
            let nsError: NSError = error as NSError
            // 1110 = "No speech detected"：静音/没听到有效语音，属正常情况，不报错。
            if nsError.code == 1110 { return }
            onEvent?(.error("SFSpeechRecognizer 识别失败：\(nsError.localizedDescription)（code \(nsError.code)）"))
        }
    }

    // MARK: - 清理

    /// 停麦克风 → 结束音频 → 取消识别任务 → 释放会话。
    /// 注意顺序：先 removeTap 再 endAudio，避免结束后还有 buffer 被 append。
    private func teardown() {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil

        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recognizer = nil

        if audioSessionActive {
            audioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }

        onEvent = nil
        localeID = ""
    }

    // MARK: - 权限

    /// 用 withCheckedContinuation 包一层 SFSpeechRecognizer.requestAuthorization。
    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        return await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { (status: SFSpeechRecognizerAuthorizationStatus) in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - 电平

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
}
