//
//  ModelStore.swift
//  IndexTranslate
//
//  GGUF 模型的定位 / 导入 / 下载。模型统一放在 App 沙盒的 Documents 根目录。
//

import Foundation

enum ModelStore {

    // MARK: - 常量

    /// 当前模型文件名
    static let modelFileName: String = "Index-Translate-2B-Q4_K_M.gguf"

    /// 默认下载地址（HuggingFace 镜像，带 ?download=true）
    static let defaultDownloadURLString: String = "https://hf-mirror.com/mrfakename/Index-Translate-2B-mobile-GGUF/resolve/main/Index-Translate-2B-Q4_K_M.gguf?download=true"

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

    /// 找模型：Documents 下优先精确文件名，否则取体积最大的 *.gguf。
    static func locateModel() -> URL? {
        let fileManager: FileManager = FileManager.default
        let directory: URL = documentsDirectory

        let exactURL: URL = directory.appendingPathComponent(modelFileName, isDirectory: false)
        if fileManager.fileExists(atPath: exactURL.path) {
            return exactURL
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let entries: [URL] = try? fileManager.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else {
            return nil
        }

        var bestURL: URL?
        var bestSize: Int64 = -1
        for entry: URL in entries {
            if entry.pathExtension.lowercased() != "gguf" {
                continue
            }
            let values: URLResourceValues? = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == false {
                continue
            }
            let fileSize: Int = values?.fileSize ?? 0
            let size: Int64 = Int64(fileSize)
            if size > bestSize {
                bestSize = size
                bestURL = entry
            }
        }
        return bestURL
    }

    // MARK: - 导入

    /// 从文件选择器拿到的 URL 导入模型：拷贝到 Documents，同名文件先删除。
    /// 返回 Documents 里的新 URL。
    static func importModel(from source: URL) throws -> URL {
        let fileManager: FileManager = FileManager.default
        let directory: URL = documentsDirectory
        let destination: URL = directory.appendingPathComponent(modelFileName, isDirectory: false)

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

    /// 下载模型（URLSession async 版 + 进度回调），完成后替换 Documents 里的同名文件。
    /// 失败抛 domain 为 "ITXModelStore" 的中文 NSError。
    static func downloadModel(from urlString: String,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url: URL = URL(string: urlString),
              let scheme: String = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw modelError("下载地址无效")
        }

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
        let destination: URL = directory.appendingPathComponent(modelFileName, isDirectory: false)

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
