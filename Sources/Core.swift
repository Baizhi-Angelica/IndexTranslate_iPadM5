//
//  Core.swift
//  共享类型与接口契约。所有模块（数据层 / ASR 层 / UI 层）都只依赖这里的定义。
//

import Foundation

// MARK: - 输入与输出语言

/// 输入模式：自动（zh-CN + en-US 两路，按转写文字判定），或手动指定 8 种输入语言之一
enum InputMode: String, CaseIterable, Identifiable {
    case chinese
    case english
    case japanese
    case korean
    case french
    case german
    case spanish
    case italian
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinese:  return "中文"
        case .english:  return "English"
        case .japanese: return "日本語"
        case .korean:   return "한국어"
        case .french:   return "Français"
        case .german:   return "Deutsch"
        case .spanish:  return "Español"
        case .italian:  return "Italiano"
        case .auto:     return "自动（中/Eng）"
        }
    }

    /// 手动模式对应的源语言；自动模式为 nil
    var speechLanguage: SpeechLanguage? {
        switch self {
        case .chinese:  return .chinese
        case .english:  return .english
        case .japanese: return .japanese
        case .korean:   return .korean
        case .french:   return .french
        case .german:   return .german
        case .spanish:  return .spanish
        case .italian:  return .italian
        case .auto:     return nil
        }
    }

    /// 需要启动哪些识别器
    var localeIDs: [String] {
        if let language: SpeechLanguage = speechLanguage {
            return [language.localeID]
        }
        // 自动：两路（未开「双识别器」时只用第一路 zh-CN）
        return [SpeechLanguage.chinese.localeID, SpeechLanguage.english.localeID]
    }
}

/// 输入语言（转写文本的语种）。8 种都与输出语言一一对应。
/// 注意：俄语目前只有输出（`OutputLanguage.russian`），没有输入——
/// iPadOS 26 的 `SpeechTranscriber.supportedLocales` 里没有 ru-RU，Apple 还没提供俄语识别模型。
enum SpeechLanguage: String, CaseIterable, Identifiable {
    case chinese
    case english
    case japanese
    case korean
    case french
    case german
    case spanish
    case italian

    var id: String { rawValue }

    /// 识别器用的 locale（都在 iPadOS 26 的 supportedLocales 里）
    var localeID: String {
        switch self {
        case .chinese:  return "zh-CN"
        case .english:  return "en-US"
        case .japanese: return "ja-JP"
        case .korean:   return "ko-KR"
        case .french:   return "fr-FR"
        case .german:   return "de-DE"
        case .spanish:  return "es-ES"
        case .italian:  return "it-IT"
        }
    }

    /// 界面显示名
    var displayName: String {
        switch self {
        case .chinese:  return "中文"
        case .english:  return "English"
        case .japanese: return "日本語"
        case .korean:   return "한국어"
        case .french:   return "Français"
        case .german:   return "Deutsch"
        case .spanish:  return "Español"
        case .italian:  return "Italiano"
        }
    }

    /// prompt 里用的语言名（模型卡片用中文语言名）
    var promptName: String {
        switch self {
        case .chinese:  return "中文"
        case .english:  return "英文"
        case .japanese: return "日语"
        case .korean:   return "韩语"
        case .french:   return "法语"
        case .german:   return "德语"
        case .spanish:  return "西班牙语"
        case .italian:  return "意大利语"
        }
    }

    /// 对应的输出语言（用于「源 = 目标」时纠正目标）
    var outputLanguage: OutputLanguage {
        switch self {
        case .chinese:  return .chinese
        case .english:  return .english
        case .japanese: return .japanese
        case .korean:   return .korean
        case .french:   return .french
        case .german:   return .german
        case .spanish:  return .spanish
        case .italian:  return .italian
        }
    }

    /// 中文 ⇄ 英文；其它语言默认翻成中文（再不行回退英文）
    var counterpart: SpeechLanguage {
        self == .chinese ? .english : .chinese
    }

    static func from(localeID: String) -> SpeechLanguage {
        let lower: String = localeID.lowercased()
        if lower.hasPrefix("zh") { return .chinese }
        if lower.hasPrefix("ja") { return .japanese }
        if lower.hasPrefix("ko") { return .korean }
        if lower.hasPrefix("fr") { return .french }
        if lower.hasPrefix("de") { return .german }
        if lower.hasPrefix("es") { return .spanish }
        if lower.hasPrefix("it") { return .italian }
        return .english
    }

    /// 依据转写文本判定语种：含汉字 → 中文；否则英文。
    /// （只用于「自动」模式的两路配对；手动模式的语言由用户指定，不走这里）
    static func detect(from text: String) -> SpeechLanguage {
        for scalar in text.unicodeScalars where isHan(scalar) {
            return .chinese
        }
        return .english
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

/// 输出语言（比输入语言多俄语：俄语只作为译文目标，因为系统识别器还不支持 ru-RU）
enum OutputLanguage: String, CaseIterable, Identifiable {
    case chinese
    case english
    case japanese
    case korean
    case french
    case german
    case spanish
    case italian
    case russian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese:  return "中文"
        case .english:  return "English"
        case .japanese: return "日本語"
        case .korean:   return "한국어"
        case .french:   return "Français"
        case .german:   return "Deutsch"
        case .spanish:  return "Español"
        case .italian:  return "Italiano"
        case .russian:  return "Русский"
        }
    }

    /// prompt 里用的语言名（模型卡片用中文语言名）
    var promptName: String {
        switch self {
        case .chinese:  return "中文"
        case .english:  return "英语"
        case .japanese: return "日语"
        case .korean:   return "韩语"
        case .french:   return "法语"
        case .german:   return "德语"
        case .spanish:  return "西班牙语"
        case .italian:  return "意大利语"
        case .russian:  return "俄语"
        }
    }

    /// 该输出语言对应的输入语种（用于"源=目标"时自动纠正）；俄语没有对应输入，返回 nil。
    var speechLanguage: SpeechLanguage? {
        switch self {
        case .chinese:  return .chinese
        case .english:  return .english
        case .japanese: return .japanese
        case .korean:   return .korean
        case .french:   return .french
        case .german:   return .german
        case .spanish:  return .spanish
        case .italian:  return .italian
        case .russian:  return nil
        }
    }
}

// MARK: - ASR 事件与引擎接口

enum ASREvent: Sendable {
    /// 未定稿的实时文字（只用于 UI 显示）
    case partial(localeID: String, text: String)
    /// 一句话定稿
    case final(localeID: String, text: String)
    /// 输入电平 0...1（用于 UI 与静音判定）
    case level(Float)
    /// 出错
    case error(String)
}

/// ASR 引擎：具体实现见 SpeechAnalyzerASR（iPadOS 26+）
protocol ASREngine: AnyObject {
    func start(localeIDs: [String], onEvent: @escaping @Sendable (ASREvent) -> Void) async throws
    func stop() async
}

// MARK: - 翻译耗时

struct LlamaTiming {
    var promptTokens: Int32 = 0
    var genTokens: Int32 = 0
    var promptMS: Int32 = 0
    var genMS: Int32 = 0

    var tokensPerSecond: Double {
        guard genMS > 0 else { return 0 }
        return Double(genTokens) / (Double(genMS) / 1000.0)
    }

    var summary: String {
        String(format: "prefill %d tok/%d ms · decode %d tok/%d ms · %.1f tok/s",
               promptTokens, promptMS, genTokens, genMS, tokensPerSecond)
    }
}
