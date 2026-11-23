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
//    身份术语表（X→X）——这是实测最有效的"英文原样保留"手段；
//  * 翻译需求（instruction）：用户在 ⓘ 里选的场景/自定义文本，按官方 instTrans
//    格式渲染成 `【注意】…` 约束行；为空时完全不改变原 prompt（回归基线不变）。
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
    ///
    /// 三种情况：
    /// 1. 无翻译需求 + 中文 → 非英语：走模型卡片的"约束翻译"格式，并把源文里的英文片段抽成
    ///    **身份术语表**（`X→X`）——实测这比"请保留英文"这类软约束强得多：
    ///    按词保留率 52.3% → 99.2%，整句全中率 25% → 97.9%（见 tools/out/ab_english.md）。
    /// 2. 无翻译需求 + 其它方向：走通用翻译格式（与改动前逐字节一致，prompt 回归基线以此为准）。
    /// 3. 有翻译需求（instruction 非空）：一律走约束格式，把需求按官方 build_prompt 的规则
    ///    渲染成 `【注意】…` 行（中文源→非英语时身份术语表排在第一条【硬性要求】）——
    ///    格式见 https://github.com/bilibili/Index-Translate/blob/main/inference/llm/call_api.py。
    static func userPrompt(text: String, source: SpeechLanguage, target: OutputLanguage,
                           instruction: String = "") -> String {
        let instructionLines: [String] = constraintLines(from: instruction)
        let usesGlossary: Bool = source == .chinese && target != .english

        // 没有任何约束需求 → 保持原来的通用模板（不给 prompt 增重）
        if !usesGlossary && instructionLines.isEmpty {
            return "请将以下" + source.promptName + "文本翻译为" + target.promptName
                + "，直接输出翻译结果，不要进行任何解释。\n\n" + text
        }

        var constraints: [String] = []
        if usesGlossary {
            let terms: [String] = englishTerms(in: text)
            if terms.isEmpty {
                constraints.append("【硬性要求】保留源文中的英文单词、专有名词、品牌名和缩写原样输出，不要翻译、不要改写、不要音译。")
            } else {
                let pairs: [String] = terms.map { (term: String) -> String in
                    return term + "→" + term
                }
                constraints.append("【硬性要求】专名/术语对照: " + pairs.joined(separator: "、"))
            }
        }

        if instructionLines.isEmpty {
            // 原行为：中文源→非英语时补一条默认风格要求
            constraints.append("【注意】自然口语风格。")
        } else {
            constraints.append(contentsOf: instructionLines)
        }

        let header: String = "请将以下" + source.promptName + "文本翻译成" + target.promptName
            + "，并且严格遵循所有约束要求。"
        let sourcePart: String = "【源文】\n" + text
        var numbered: [String] = []
        numbered.reserveCapacity(constraints.count)
        for (index, constraint) in constraints.enumerated() {
            numbered.append(String(index + 1) + ". " + constraint)
        }
        let rulesPart: String = numbered.joined(separator: "\n")
        let footer: String = "只输出译文，不要有任何额外说明。"
        return header + "\n\n" + sourcePart + "\n\n【约束要求】\n" + rulesPart + "\n\n" + footer
    }

    /// 把用户/场景写的「翻译需求」渲染成约束行（与官方 build_prompt 一致）：
    /// * 按行拆分，空行丢弃；
    /// * 去掉行首的序号（`1.` / `2.` / 空格）；
    /// * 已经开始于【硬性要求】/【注意】/【软性要求】的行原样保留，其余补 `【注意】`。
    static func constraintLines(from instruction: String) -> [String] {
        let trimmed: String = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var lines: [String] = []
        let rawLines: [String] = trimmed.components(separatedBy: .newlines)
        for rawLine in rawLines {
            var line: String = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            line = strippingLeadingNumbering(line)
            if line.isEmpty { continue }
            if line.hasPrefix("【硬性要求】") || line.hasPrefix("【注意】") || line.hasPrefix("【软性要求】") {
                lines.append(line)
            } else {
                lines.append("【注意】" + line)
            }
        }
        return lines
    }

    /// 去掉行首的阿拉伯数字 / 点 / 空格（对应官方 `lstrip("0123456789. ")`）。
    private static func strippingLeadingNumbering(_ line: String) -> String {
        var result: String = line
        while let first: Character = result.first, "0123456789. ".contains(first) {
            result.removeFirst()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// `instruction` 为用户在 ⓘ → 翻译需求 里选/写的内容（空字符串 = 不加需求）。
    static func full(text: String, source: SpeechLanguage, target: OutputLanguage,
                     instruction: String = "") -> String {
        let content: String = userPrompt(text: text, source: source, target: target,
                                         instruction: instruction)
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
