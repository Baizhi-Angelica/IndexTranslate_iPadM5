//
//  ASRFactory.swift
//  ASR 后端选择：优先 iOS 26 SpeechAnalyzer，不可用时降级到 SFSpeechRecognizer。
//
//  这个文件故意不标 @available：内部用 if #available 分支，
//  这样 AppModel 等 iOS 17 部署目标下的代码可以无条件调用。
//

import Speech

enum ASRFactory {

    /// 优先 iOS 26 SpeechAnalyzer；不可用（硬件/资源/系统版本不支持）时降级到 SFSpeechRecognizer。
    static func make() -> (engine: any ASREngine, name: String) {
        if #available(iOS 26.0, *) {
            if SpeechTranscriber.isAvailable {
                return (engine: SpeechAnalyzerASR(), name: "SpeechAnalyzer")
            }
        }
        return (engine: LegacyASR(), name: "SFSpeechRecognizer（降级）")
    }
}
