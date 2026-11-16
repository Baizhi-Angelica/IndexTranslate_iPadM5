//
//  ModelStore.swift
//  IndexTranslate
//
//  GGUF 模型的定位 / 导入 / 下载。模型统一放在 App 沙盒的 Documents 根目录。
//  Documents 里可以同时放多个 .gguf（Q4_K_M / Q8_0 ...）：
//  默认用哪个由 UserDefaults 的 ITXSelectedModel 决定；没选就取体积最大的。
//

import Foundation

// MARK: - 模型列表条目

/// Documents 里的一个 GGUF 模型。
struct ModelEntry: Identifiable, Equatable {
    let url: URL
    /// 文件名（lastPathComponent，也是 Documents 里的唯一名）
    let name: String
    let sizeBytes: Int64

    var id: String { name }

    /// 给界面显示的大小（一位小数 GB/MB）
    var displaySize: String { ModelStore.humanSize(sizeBytes) }
}

enum ModelStore {

    // MARK: - 常量

    /// 默认模型文件名（官方 Q4_K_M，下载回退用）
    static let modelFileName: String = "Index-Translate-2B.Q4_K_M.gguf"

    /// 兼容旧文件名：早前从 mobile 仓库下的是同名不同哈希（体积一样 1,251.4 MB，实测都能跑）
    static let legacyModelFileName: String = "Index-Translate-2B-Q4_K_M.gguf"

    /// Q4_K_M（官方默认档，约 1.22 GB）
    static let q4FileName: String = "Index-Translate-2B.Q4_K_M.gguf"

    /// 首选源：ModelScope。国内 CDN 直连（会 302 到 cdn-lfs-cn-1.modelscope.cn），
    /// 实测支持 Range、文件与官方 HF 完全一致（LFS 哈希 044b313d…，1,312,164,352 字节）。
    static let q4DownloadURLString: String = "https://www.modelscope.cn/models/IndexTeam/Index-Translate-2B-GGUF/resolve/master/Index-Translate-2B.Q4_K_M.gguf"

    /// 备用源一：hf-mirror（国内镜像）
    static let hfMirrorQ4URLString: String = "https://hf-mirror.com/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf?download=true"

    /// 备用源二：HuggingFace 官方
    static let hfOfficialQ4URLString: String = "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf"

    /// 下载顺序：ModelScope → hf-mirror → HuggingFace
    static let q4DownloadCandidates: [String] = [q4DownloadURLString, hfMirrorQ4URLString, hfOfficialQ4URLString]

    /// Q8_0（官方高质量档，约 2 GB；M 系列实测延迟和 Q4 几乎一样，可直接当默认）
    static let q8FileName: String = "Index-Translate-2B.Q8_0.gguf"
    static let q8DownloadURLString: String = "https://www.modelscope.cn/models/IndexTeam/Index-Translate-2B-GGUF/resolve/master/Index-Translate-2B.Q8_0.gguf"
    static let hfMirrorQ8URLString: String = "https://hf-mirror.com/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q8_0.gguf?download=true"
    static let hfOfficialQ8URLString: String = "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q8_0.gguf"
    static let q8DownloadCandidates: [String] = [q8DownloadURLString, hfMirrorQ8URLString, hfOfficialQ8URLString]

    /// 模型页（给「手动下载」用，浏览器打开可直接点下载）
    static let modelScopePageURLString: String = "https://www.modelscope.cn/models/IndexTeam/Index-Translate-2B-GGUF"
    static let huggingFacePageURLString: String = "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF"

    /// 官方直连（不走镜像），镜像不通时可在 App 里粘这个
    static let officialDownloadURLString: String = "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf?download=true"
    static let officialQ8DownloadURLString: String = "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q8_0.gguf?download=true"

    /// 默认下载地址，保持等于 q4DownloadURLString
    static let defaultDownloadURLString: String = "https://hf-mirror.com/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf?download=true"

    /// 用户选中的模型文件名存这个 key
    private static let selectedModelDefaultsKey: String = "ITXSelectedModel"

    // MARK: - 位置

    /// App 沙盒的 Documents 目录。
    static var documentsDirectory: URL {
        let urls: [URL] = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        if let first: URL = urls.first {
            return first
        }
        let home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home.appendingPathComponent("Documents", isDirectory: true)
    }

    // MARK: - 多模型列表与选择

    /// Documents 下所有 .gguf，按体积降序（同体积按文件名升序，保证顺序稳定）。
    static func listModels() -> [ModelEntry] {
        let fileManager: FileManager = FileManager.default
        let directory: URL = documentsDirectory

        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let entries: [URL] = try? fileManager.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else {
            return []
        }

        var models: [ModelEntry] = []
        models.reserveCapacity(entries.count)
        for entry: URL in entries {
            if entry.pathExtension.lowercased() != "gguf" {
                continue
            }
            let values: URLResourceValues? = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == false {
                continue
            }
            let fileSize: Int64 = Int64(values?.fileSize ?? 0)
            models.append(ModelEntry(url: entry,
                                     name: entry.lastPathComponent,
                                     sizeBytes: fileSize))
        }

        models.sort { (lhs: ModelEntry, rhs: ModelEntry) -> Bool in
            if lhs.sizeBytes != rhs.sizeBytes {
                return lhs.sizeBytes > rhs.sizeBytes
            }
            return lhs.name < rhs.name
        }
        return models
    }

    /// 用户选中的模型文件名（UserDefaults key "ITXSelectedModel"，空串视为未选）。
    static func selectedModelName() -> String? {
        let stored: String? = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        guard let name: String = stored else {
            return nil
        }
        if name.isEmpty {
            return nil
        }
        return name
    }

    /// 记住用户选中的模型文件名。
    static func selectModel(name: String) {
        UserDefaults.standard.set(name, forKey: selectedModelDefaultsKey)
    }

    /// 找模型：有选中且文件仍在 → 它；否则 → 体积最大的 .gguf；再否则 nil。
    static func locateModel() -> URL? {
        let fileManager: FileManager = FileManager.default
        let directory: URL = documentsDirectory

        // 1) 用户选中的模型（文件被删了就忽略，走回退）
        if let selectedName: String = selectedModelName() {
            let selectedURL: URL = directory.appendingPathComponent(selectedName, isDirectory: false)
            if fileManager.fileExists(atPath: selectedURL.path) {
                return selectedURL
            }
        }

        // 2) 回退：体积最大的 .gguf（Q8 比 Q4 大，用户放进 Q8 后自然成为默认）
        if let largest: ModelEntry = listModels().first {
            return largest.url
        }

        return nil
    }

    // MARK: - 导入

    /// 从文件选择器拿到的 URL 导入模型：保留源文件名（只做清洗），拷贝到 Documents，
    /// 同名文件先删除。返回 Documents 里的新 URL。
    static func importModel(from source: URL) throws -> URL {
        let fileManager: FileManager = FileManager.default
        let directory: URL = documentsDirectory
        let fileName: String = sanitizedModelFileName(from: source.lastPathComponent)
        let destination: URL = directory.appendingPathComponent(fileName, isDirectory: false)

        if source.standardizedFileURL == destination.standardizedFileURL {
            return destination
        }

        let accessing: Bool = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: - 下载

    /// 依次尝试多个下载源（默认顺序 ModelScope → hf-mirror → HuggingFace），
    /// 任一成功即返回；全失败时抛出的错误里带上每个源的失败原因，方便在 App 里直接看到。
    static func downloadModel(candidates: [String],
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard !candidates.isEmpty else {
            throw modelError("没有可用的下载源")
        }
        var failures: [String] = []
        for (index, urlString) in candidates.enumerated() {
            do {
                return try await downloadModel(from: urlString, progress: progress)
            } catch {
                let host: String = URL(string: urlString)?.host ?? urlString
                failures.append("源 \(index + 1)（\(host)）：\(error.localizedDescription)")
                progress(0)
            }
        }
        throw modelError("模型下载失败，已尝试 \(candidates.count) 个源：\n" + failures.joined(separator: "\n"))
    }

    /// 下载模型（URLSession async 版 + 进度回调）。
    /// 目标文件名从 URL 的 lastPathComponent 推导（忽略 ?download=true 这类 query），
    /// 完成后替换 Documents 里的同名文件，并自动选中这个模型。
    /// 失败抛 domain 为 "ITXModelStore" 的中文 NSError。
    static func downloadModel(from urlString: String,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url: URL = URL(string: urlString),
              let scheme: String = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw modelError("下载地址无效")
        }

        // URL.path 不含 query，所以 ?download=true 不会混进文件名。
        let rawName: String = url.lastPathComponent
        let fileName: String = rawName.isEmpty ? modelFileName : sanitizedModelFileName(from: rawName)

        let delegate: ProgressDelegate = ProgressDelegate(progress: progress)

        let result: (URL, URLResponse)
        do {
            result = try await URLSession.shared.download(from: url, delegate: delegate)
        } catch {
            throw modelError("模型下载失败：\(error.localizedDescription)")
        }

        let temporaryURL: URL = result.0
        let response: URLResponse = result.1
        if let httpResponse: HTTPURLResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                throw modelError("模型下载失败（HTTP \(httpResponse.statusCode)）")
            }
        }

        let fileManager: FileManager = FileManager.default
        let directory: URL = documentsDirectory
        let destination: URL = directory.appendingPathComponent(fileName, isDirectory: false)

        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            do {
                try fileManager.moveItem(at: temporaryURL, to: destination)
            } catch {
                // 兜底：跨卷之类 move 失败时改为复制
                try fileManager.copyItem(at: temporaryURL, to: destination)
                try? fileManager.removeItem(at: temporaryURL)
            }
        } catch {
            throw modelError("模型文件保存失败：\(error.localizedDescription)")
        }

        // 下载完成自动把新文件设为选中，App 重新 locate 时就直接用它。
        selectModel(name: fileName)
        progress(1.0)
        return destination
    }

    // MARK: - 展示

    /// 把字节数显示成一位小数的 GB / MB。
    static func humanSize(_ bytes: Int64) -> String {
        let mb: Double = 1024.0 * 1024.0
        let gb: Double = mb * 1024.0
        let value: Double = Double(max(0, bytes))
        if value >= gb {
            return String(format: "%.1f GB", value / gb)
        }
        return String(format: "%.1f MB", value / mb)
    }

    // MARK: - 内部

    /// 文件名清洗：去掉路径分隔符，只保留 [A-Za-z0-9._ -]，其余替换成 "_"；
    /// 清理后没有有效名字就用 "model"；后缀不是 .gguf 时补 ".gguf"。
    private static func sanitizedModelFileName(from proposedName: String) -> String {
        var name: String = proposedName

        // 1) 去掉路径分隔符（正常来自 lastPathComponent，这里再兜一层）
        name = name.replacingOccurrences(of: "/", with: "")
        name = name.replacingOccurrences(of: "\\", with: "")

        // 2) 非 [A-Za-z0-9._ -] 的字符替换成 "_"
        name = name.replacingOccurrences(of: "[^A-Za-z0-9._ -]",
                                         with: "_",
                                         options: .regularExpression)

        // 3) 去首尾空白
        name = name.trimmingCharacters(in: .whitespaces)

        // 4) 空名 / 只剩点号、下划线、空格 → 用 "model" 兜底
        let stem: String = name.trimmingCharacters(in: CharacterSet(charactersIn: ". _"))
        if stem.isEmpty {
            name = "model"
        }

        // 5) 后缀不是 .gguf → 补上
        if !name.lowercased().hasSuffix(".gguf") {
            name = name + ".gguf"
        }
        return name
    }

    private static func modelError(_ message: String, code: Int = -1) -> NSError {
        return NSError(domain: "ITXModelStore",
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 下载进度代理。只关心 didWriteData，临时文件的搬运交给 async download 的返回值。
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {

        private let onProgress: @Sendable (Double) -> Void

        init(progress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = progress
            super.init()
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite <= 0 {
                return
            }
            let fraction: Double = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let clamped: Double = min(max(fraction, 0.0), 1.0)
            self.onProgress(clamped)
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // 空实现：async 版 download(from:delegate:) 会把临时文件位置通过返回值给出。
        }
    }
}
