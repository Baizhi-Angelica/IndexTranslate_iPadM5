//
//  Core.swift
//  共享类型与接口契约。所有模块（数据层 / ASR 层 / UI 层）都只依赖这里的定义。
//

import Foundation

// MARK: - 输入与输出语言

/// 输入模式：手动指定中文/英文，或自动（同时跑两个识别器，按转写文字判定）
enum InputMode: String, CaseIterable, Identifiable {
    case chinese
    case english
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        case .auto:    return "自动"
        }
    }

    /// 需要启动哪些识别器
    var localeIDs: [String] {
        switch self {
        case .chinese: return ["zh-CN"]
        case .english: return ["en-US"]
        case .auto:    return ["zh-CN", "en-US"]
        }
    }
}

/// 输入语言（转写文本的语种）
enum SpeechLanguage: String, CaseIterable, Identifiable {
    case chinese
    case english

    var id: String { rawValue }

    var localeID: String {
        switch self {
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        }
    }

    /// prompt 里用的语言名（模型卡片的写法）
    var promptName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        }
    }

    /// 中英互译时的默认目标
    var counterpart: SpeechLanguage {
        self == .chinese ? .english : .chinese
    }

    static func from(localeID: String) -> SpeechLanguage {
        localeID.lowercased().hasPrefix("zh") ? .chinese : .english
    }

    /// 依据转写文本判定语种：含汉字 → 中文；否则英文。
    /// （沿用小米项目的经验：方向锚定转写文本，不靠模型/音频猜语种）
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

/// 输出语言
enum OutputLanguage: String, CaseIterable, Identifiable {
    case chinese
    case english
    case japanese
    case korean
    case french
    case german
    case spanish

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
        }
    }

    /// 该输出语言对应的输入语种（用于"源=目标"时自动纠正）
    var speechLanguage: SpeechLanguage? {
        switch self {
        case .chinese:  return .chinese
        case .english:  return .english
        default:        return nil
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
