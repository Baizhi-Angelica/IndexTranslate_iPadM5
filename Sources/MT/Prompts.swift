//
//  Prompts.swift
//  IndexTranslate
//
//  提示词构造（纯函数，无状态）。
//
//  对齐 Index-Translate-2B 模型卡片：
//  * Qwen ChatML 模板；
//  * 关闭 thinking：assistant 回合后紧跟空的 <think></think>；
//  * 中文 → 非英语：使用模型卡片的"约束翻译"格式，并把源文里的英文片段抽成
//    身份术语表（X→X）——这是实测最有效的"英文原样保留"手段。
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
    /// 中文 → 非英语时走模型卡片的"约束翻译"格式，并把源文里的英文片段抽成
    /// **身份术语表**（`X→X`）——实测这比"请保留英文"这类软约束强得多：
    /// 按词保留率 52.3% → 99.2%，整句全中率 25% → 97.9%（见 tools/out/ab_english.md）。
    /// 其余情况（含目标为英语、源文为英语）走通用翻译格式。
    static func userPrompt(text: String, source: SpeechLanguage, target: OutputLanguage) -> String {
        if source == .chinese && target != .english {
            let terms: [String] = englishTerms(in: text)
            let header: String = "请将以下中文文本翻译成" + target.promptName + "，并且严格遵循所有约束要求。"
            let sourcePart: String = "【源文】\n" + text

            let rulesPart: String
            if terms.isEmpty {
                rulesPart = "1. 【硬性要求】保留源文中的英文单词、专有名词、品牌名和缩写原样输出，不要翻译、不要改写、不要音译。\n"
                    + "2. 【注意】自然口语风格。"
            } else {
                let pairs: [String] = terms.map { (term: String) -> String in
                    return term + "→" + term
                }
                rulesPart = "1. 【硬性要求】专名/术语对照: " + pairs.joined(separator: "、") + "\n"
                    + "2. 【注意】自然口语风格。"
            }

            let footer: String = "只输出译文，不要有任何额外说明。"
            return header + "\n\n" + sourcePart + "\n\n【约束要求】\n" + rulesPart + "\n\n" + footer
        }

        return "请将以下" + source.promptName + "文本翻译为" + target.promptName + "，直接输出翻译结果，不要进行任何解释。\n\n" + text
    }

    /// 抽取源文里的英文片段（连续拉丁词，允许中间空格 / 连字符 / 撇号 / 点 / &），
    /// 去重保序，最多 12 个。用于构造身份术语表。
    static func englishTerms(in text: String, limit: Int = 12) -> [String] {
        let pattern: String = "[A-Za-z][A-Za-z0-9'’\\-.&]*(?:[ \\t]+[A-Za-z][A-Za-z0-9'’\\-.&]*)*"
        guard let regex: NSRegularExpression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let nsText: NSString = text as NSString
        let matches: [NSTextCheckingResult] = regex.matches(in: text,
                                                            options: [],
                                                            range: NSRange(location: 0, length: nsText.length))
        var ordered: [String] = []
        var seen: Set<String> = Set<String>()
        for match: NSTextCheckingResult in matches {
            var term: String = nsText.substring(with: match.range)
            // 去掉尾部标点
            while let lastCharacter: Character = term.last, ".-'".contains(lastCharacter) {
                term.removeLast()
            }
            term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if term.count < 2 {
                continue
            }
            let key: String = term.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            ordered.append(term)
            if ordered.count >= limit {
                break
            }
        }
        return ordered
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

        // 3) 去掉成对包裹的引号（最多 5 层，如 "「译文」"）
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
        if opening == "\u{201C}" && closing == "\u{201D}" { return true }
        if opening == "\u{2018}" && closing == "\u{2019}" { return true }
        if opening == "\u{300C}" && closing == "\u{300D}" { return true }
        if opening == "\u{300E}" && closing == "\u{300F}" { return true }
        if opening == "\u{300A}" && closing == "\u{300B}" { return true }
        return false
    }
}
