//
//  PromptVerify.swift
//  在 macOS CI 上编译 Sources/Core.swift + Sources/MT/Prompts.swift 的 PromptBuilder，
//  按 tools/verify_prompts.py 生成的 case 输出 prompt JSON，供 Python 侧逐字节比对。
//
//  用法：promptcheck <cases.json> <actual.json>
//

import Foundation

private struct PromptCase: Decodable {
    let name: String
    let source: String
    let target: String
    let text: String
    let instruction: String
}

private struct PromptResult: Encodable {
    let name: String
    let prompt: String
}

@main
struct PromptVerifyMain {

    static func main() {
        let arguments: [String] = CommandLine.arguments
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("用法: promptcheck <cases.json> <actual.json>\n".utf8))
            exit(2)
        }

        let inputURL: URL = URL(fileURLWithPath: arguments[1])
        let outputURL: URL = URL(fileURLWithPath: arguments[2])

        do {
            let data: Data = try Data(contentsOf: inputURL)
            let payload: [String: Any] = try decodeObject(data)
            guard let rawCases: [[String: Any]] = payload["cases"] as? [[String: Any]] else {
                FileHandle.standardError.write(Data("cases.json 里没有 cases 数组\n".utf8))
                exit(2)
            }

            var results: [PromptResult] = []
            results.reserveCapacity(rawCases.count)

            for rawCase: [String: Any] in rawCases {
                let name: String = rawCase["name"] as? String ?? "?"
                let sourceRaw: String = rawCase["source"] as? String ?? ""
                let targetRaw: String = rawCase["target"] as? String ?? ""
                let text: String = rawCase["text"] as? String ?? ""
                let instruction: String = rawCase["instruction"] as? String ?? ""

                guard let source: SpeechLanguage = SpeechLanguage(rawValue: sourceRaw) else {
                    FileHandle.standardError.write(Data("case \(name): 未知源语言 \(sourceRaw)\n".utf8))
                    exit(2)
                }
                guard let target: OutputLanguage = OutputLanguage(rawValue: targetRaw) else {
                    FileHandle.standardError.write(Data("case \(name): 未知目标语言 \(targetRaw)\n".utf8))
                    exit(2)
                }

                let prompt: String = PromptBuilder.full(text: text,
                                                        source: source,
                                                        target: target,
                                                        instruction: instruction)
                results.append(PromptResult(name: name, prompt: prompt))
            }

            let encoder: JSONEncoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let outputData: Data = try encoder.encode(results)
            try outputData.write(to: outputURL, options: .atomic)
            print("Swift 侧生成 prompt \(results.count) 条 -> \(outputURL.path)")
        } catch {
            FileHandle.standardError.write(Data("失败：\(error)\n".utf8))
            exit(1)
        }
    }

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        let object: Any = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary: [String: Any] = object as? [String: Any] else {
            throw NSError(domain: "PromptVerify", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cases.json 顶层不是对象"])
        }
        return dictionary
    }
}
