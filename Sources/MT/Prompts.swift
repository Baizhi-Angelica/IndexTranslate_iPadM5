//
//  Prompts.swift
//  IndexTranslate
//
//  提示词构造（纯函数，无状态）。
//
//  对齐 Index-Translate-2B 模型卡片：
//  * Qwen ChatML 模板；
//  * 关闭 thinking：assistant 回合后紧跟空的 <think></think>；
//  * 中文 → 非英语：使用模型卡片的"约束翻译"格式，用硬约束保住英文词。
//

import Foundation

enum PromptBuilder {

    // MARK: - ChatML

    /// 把一段 user 内容套成 Qwen ChatML，并关闭 thinking。
    /// 结尾 `<think>\n\n</think>\n\n` 的形状必须逐字节保持，
    /// 否则模型会打开思考模式，把推理内容混进译文。
    static func chat(_ content: String) -> String {
        let prefix: String = "<|im_start|>user\n"
        let suffix: String = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        return prefix + content + suffix
    }

    // MARK: - user 内容

    /// 构造 user 回合内容。
    /// 中文 → 非英语时走模型卡片的"约束翻译"格式（保住源文里的英文词）；
    /// 其余情况（含目标为英语、源文为英语）走通用翻译格式。
    static func userPrompt(text: String, source: SpeechLanguage, target: OutputLanguage) -> String {
        if source == .chinese && target != .english {
            let header: String = "请将以下中文文本翻译成" + target.promptName + "，并且严格遵循所有约束要求。"
            let sourcePart: String = "【源文】\n" + text
            let rulesPart: String = "1. 【硬性要求】保留源文中的英文单词、专有名词、品牌名和缩写原样输出，不要翻译、不要改写、不要音译。\n"
                + "2. 【注意】自然口语风格。"
            let footer: String = "只输出译文，不要有任何额外说明。"
            return header + "\n\n" + sourcePart + "\n\n【约束要求】\n" + rulesPart + "\n\n" + footer
        }

        return "请将以下" + source.promptName + "文本翻译为" + target.promptName + "，直接输出翻译结果，不要进行任何解释。\n\n" + text
    }

    /// 完整 prompt：user 内容 + ChatML 包装。
    static func full(text: String, source: SpeechLanguage, target: OutputLanguage) -> String {
        let content: String = userPrompt(text: text, source: source, target: target)
        return chat(content)
    }

    // MARK: - 输出清理

    /// 清理模型原始输出：
    /// 1. 有 `</think>` 时删掉最后一个 `</think>` 及其之前的推理段；
    /// 2. 删除开头残留的 `</think>` / `<think>`；
    /// 3. 去掉首尾空白与成对包裹的引号；
    /// 4. 连续空行压成一个。
    static func clean(_ raw: String) -> String {
        var text: String = raw.replacingOccurrences(of: "\r\n", with: "\n")

        // 1) 删掉最后一个 </think> 之前的内容（含推理段）
        if let lastClose: Range<String.Index> = text.range(of: "</think>", options: .backwards) {
            text = String(text[lastClose.upperBound..<text.endIndex])
        }

        // 2) 删除开头残留的 </think> 或 <think>（循环以防连续出现）
        var didStripMarker: Bool = true
        while didStripMarker {
            didStripMarker = false
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let closingMarker: String = "</think>"
            let openingMarker: String = "<think>"
            if text.hasPrefix(closingMarker) {
                text.removeFirst(closingMarker.count)
                didStripMarker = true
            } else if text.hasPrefix(openingMarker) {
                text.removeFirst(openingMarker.count)
                didStripMarker = true
            }
        }

        // 3) 去掉成对包裹的引号（最多 5 层，如 “「译文」”）
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<5 {
            guard text.count >= 2 else { break }
            guard let firstCharacter: Character = text.first,
                  let lastCharacter: Character = text.last else { break }
            if !isPairedQuote(opening: firstCharacter, closing: lastCharacter) {
                break
            }
            text = String(text.dropFirst().dropLast())
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 4) 连续空行压成一个
        let lines: [String] = text.components(separatedBy: "\n")
        var keptLines: [String] = []
        keptLines.reserveCapacity(lines.count)
        for line: String in lines {
            let isBlank: Bool = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                if keptLines.isEmpty || keptLines[keptLines.count - 1].isEmpty {
                    continue
                }
                keptLines.append("")
            } else {
                keptLines.append(line)
            }
        }

        let result: String = keptLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            return ""
        }
        return result
    }

    /// 常见的成对包裹引号。
    private static func isPairedQuote(opening: Character, closing: Character) -> Bool {
        if opening == "\"" && closing == "\"" { return true }
        if opening == "'" && closing == "'" { return true }
        if opening == "“" && closing == "”" { return true }
        if opening == "‘" && closing == "’" { return true }
        if opening == "「" && closing == "」" { return true }
        if opening == "『" && closing == "』" { return true }
        if opening == "《" && closing == "》" { return true }
        return false
    }
}
