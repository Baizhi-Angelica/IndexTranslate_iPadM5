//
//  InstructionPresets.swift
//  ITXTranslate
//
//  「翻译需求」：用户在 ⓘ → 翻译需求 里选一个场景，或自己写一句话；
//  它会变成 prompt 里的一条【注意】约束，交给 Index-Translate-2B 遵守。
//
//  格式对齐官方 Index-Translate 的 instTrans 提示词（inference/llm/call_api.py::build_prompt）：
//  自由文本按行渲染，不以【硬性要求】/【注意】/【软性要求】开头的行自动补 `【注意】`，
//  序号由 PromptBuilder 统一加。
//

import Foundation

/// 内置场景：中文标题（界面用）+ 中文约束文本（发给模型用）。
/// 标题和文本分开：用户自定义的文本不会命中任何场景，界面显示「自定义」。
enum TranslationInstructionPreset: String, CaseIterable, Identifiable {
    case formalMeeting
    case friends
    case newFriends
    case travelHelp
    case smallTalk

    var id: String { rawValue }

    /// ⓘ 二级页面里的选项标题
    var title: String {
        switch self {
        case .formalMeeting: return "严肃会议"
        case .friends:       return "朋友小聚"
        case .newFriends:    return "初见新朋友"
        case .travelHelp:    return "旅行中求助"
        case .smallTalk:     return "陌生人随便聊聊"
        }
    }

    /// 真正发给模型的那句话（不带序号 / 【注意】 前缀，PromptBuilder 负责补）
    var instruction: String {
        switch self {
        case .formalMeeting:
            return "请使用正式、准确、克制的语气，适合商务会议或正式场合，避免口语化表达。"
        case .friends:
            return "请使用轻松自然、口语化的语气，像朋友之间聊天，句子简短亲切。"
        case .newFriends:
            return "请使用礼貌、友善、适度正式的语气，适合初次见面交谈，保持得体和尊重。"
        case .travelHelp:
            return "请使用礼貌、直接、简短的语气，清楚说明需要什么帮助，方便对方立刻理解。"
        case .smallTalk:
            return "请使用中性、自然、友好但不过分熟络的语气，适合和陌生人闲聊。"
        }
    }

    /// 文本正好等于某个场景的约束时，返回该场景（界面用来打勾 / 显示标题）。
    static func matching(_ text: String) -> TranslationInstructionPreset? {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return TranslationInstructionPreset.allCases.first { $0.instruction == trimmed }
    }
}

/// 翻译需求在 UserDefaults 里的键。
/// 约定：只有用户勾了「保存这次的需求，下次默认使用」才落盘；
/// 否则退出 App 后不保留（下次启动回到「默认」）——对应 issue #4 的要求。
enum TranslationInstructionStore {
    static let textKey: String = "itx.instruction.text"
    static let saveKey: String = "itx.instruction.save"
}
