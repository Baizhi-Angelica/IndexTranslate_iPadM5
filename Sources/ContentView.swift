//
//  ContentView.swift
//  ITXTranslate
//
//  iPad / iPhone 自适应界面（支持浅色/深色外观、大字）：
//  顶部标题与状态 → 中部译文 / 原文 / 性能 → 底部语言选择 + 麦克风与清空。
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct TranslationContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DirectionalBlockModifier: ViewModifier {
    let isRTL: Bool

    func body(content: Content) -> some View {
        content
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }
}

struct ContentView: View {

    private static let translationBottomID: String = "translationBottomAnchor"

    @StateObject private var model: AppModel = AppModel()

    @State private var showInfoSheet: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var scrollTask: Task<Void, Never>?

    /// iPhone 竖屏等紧凑宽度下自动缩字号 / 缩边距
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.colorScheme) private var colorScheme

    private var isCompact: Bool {
        return hSize == .compact
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: isCompact ? 8 : 12) {
                header

                if !model.errorMessage.isEmpty {
                    errorBanner
                }

                Spacer(minLength: 0)

                translationArea

                if !model.isModelReady && !model.isLoadingModel {
                    modelCard
                }

                Spacer(minLength: 0)

                languageSelectors
                bottomControls
            }
            .padding(.horizontal, isCompact ? 16 : 32)
            .padding(.top, isCompact ? 12 : 20)
            .padding(.bottom, isCompact ? 12 : 16)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showInfoSheet) {
            InfoSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [UTType.data],
                      allowsMultipleSelection: false,
                      onCompletion: { (result: Result<[URL], Error>) in
                          switch result {
                          case .success(let urls):
                              if let url = urls.first {
                                  model.importModel(url: url)
                              }
                          case .failure(let error):
                              model.reportError("选择文件失败：" + error.localizedDescription)
                          }
                      })
        .task {
            await model.bootstrap()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("本地语音翻译 · Index-Translate-2B")
                    .font(.system(size: isCompact ? 22 : 26, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(model.statusText)
                        .font(.system(size: isCompact ? 13 : 14))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Button {
                showInfoSheet = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关于、模型与性能信息")
        }
    }

    private var statusColor: Color {
        if model.isModelReady {
            return Color.green
        }
        if model.isDownloading || model.isLoadingModel {
            return Color.orange
        }
        return Color.red
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.red)

            Text(model.errorMessage)
                .font(.system(size: 15))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                model.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.red.opacity(colorScheme == .dark ? 0.18 : 0.08)))
    }

    // MARK: - 中部：译文 / 原文 / 性能

    private func isRTLText(_ text: String) -> Bool {
        SpeechLanguage.containsArabic(text)
    }

    private var translationScrollSignature: String {
        [
            model.previousTranslation,
            model.previousSource,
            model.translation,
            model.currentSource,
        ].joined(separator: "\u{001F}")
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            // 等 SwiftUI / UIKit 提交新的 contentSize 后再滚到底部锚点，
            // 防止连续两句长句时停在末尾前而遮住当前句原文小字
            await Task.yield()
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.translationBottomID, anchor: .bottom)
            }
        }
    }

    private var translationArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        // 上一句译文：与当前句同字号，只变灰
                        if !model.previousTranslation.isEmpty {
                            Text(model.previousTranslation)
                                .font(.system(size: isCompact ? 30 : 40, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                                .modifier(DirectionalBlockModifier(isRTL: isRTLText(model.previousTranslation)))
                        }

                        // 上一句原文：更小一号、更淡；没有就完全不占位
                        if !model.previousSource.isEmpty {
                            Text(model.previousSource)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.secondary.opacity(0.75))
                                .lineLimit(1)
                                .modifier(DirectionalBlockModifier(isRTL: isRTLText(model.previousSource)))
                        }

                        // 当前句译文：保持大字（空状态提示为中文，仅在有实际译文时按文本语种切 RTL）
                        Text(translationDisplayText)
                            .font(.system(size: isCompact ? 30 : 40, weight: .semibold))
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(model.translation.isEmpty ? Color.secondary.opacity(0.55) : Color.primary)
                            .modifier(DirectionalBlockModifier(
                                isRTL: !model.translation.isEmpty && isRTLText(model.translation)
                            ))

                        // 当前句原文：灰色小字（只显示这一句，不累积整场）
                        if !model.currentSource.isEmpty {
                            Text(model.currentSource)
                                .font(.system(size: isCompact ? 16 : 18))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(3)
                                .modifier(DirectionalBlockModifier(isRTL: isRTLText(model.currentSource)))
                        }

                        // 底部锚点：确保 scrollTo(..., anchor: .bottom) 滚到最新句原文小字之后
                        Color.clear
                            .frame(height: 1)
                            .id(Self.translationBottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { (geometry: GeometryProxy) in
                            Color.clear.preference(key: TranslationContentHeightKey.self,
                                                   value: geometry.size.height)
                        }
                    )
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity,
                       minHeight: isCompact ? 50 : 90,
                       maxHeight: isCompact ? 220 : 320,
                       alignment: .topLeading)
                .onPreferenceChange(TranslationContentHeightKey.self) { _ in
                    scheduleScrollToBottom(proxy: proxy)
                }
                .onChange(of: translationScrollSignature) { _, _ in
                    scheduleScrollToBottom(proxy: proxy)
                }
                .onChange(of: model.livePartial.isEmpty) { _, _ in
                    scheduleScrollToBottom(proxy: proxy)
                }
            }

            metricsRow

            // 正在说话（未定稿）的实时文本：放在 metrics 行下面，不占「当前句原文」的位置
            if !model.livePartial.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: isCompact ? 12 : 13, weight: .medium))
                        .foregroundStyle(Color.blue)
                        .padding(.top, 3)
                    Text(model.livePartial)
                        .font(.system(size: isCompact ? 16 : 18))
                        .italic()
                        .foregroundStyle(Color.blue)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .environment(\.layoutDirection,
                             (model.inputMode == .arabic || isRTLText(model.livePartial)) ? .rightToLeft : .leftToRight)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
    }

    private var translationDisplayText: String {
        if !model.translation.isEmpty {
            return model.translation
        }
        if model.isListening {
            return "正在聆听…"
        }
        return "点下方麦克风开始说话，全部在 iPad 本地运行"
    }

    private var metricsRow: some View {
        HStack(spacing: 14) {
            if model.isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("翻译中…")
                }
            }

            if !model.metrics.isEmpty {
                Text(model.metrics)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if model.lastLatencyMS > 0 {
                Text("\(model.lastLatencyMS) ms")
            }

            Spacer(minLength: 8)

            if model.isListening {
                listeningIndicator
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.secondary)
        .frame(height: 20)
    }

    private var listeningIndicator: some View {
        HStack(spacing: 8) {
            Text("聆听中")
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.red.opacity(colorScheme == .dark ? 0.25 : 0.18))
                    .frame(width: 120, height: 6)
                Capsule()
                    .fill(Color.red)
                    .frame(width: max(4, 120 * CGFloat(model.level)), height: 6)
            }
        }
    }

    // MARK: - 模型缺失 / 下载中卡片

    private func modelDownloadButton(title: String, candidates: [String], primary: Bool) -> some View {
        Button {
            model.downloadModel(candidates: candidates)
        } label: {
            Text(title)
                .font(.system(size: isCompact ? 14 : 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, isCompact ? 10 : 12)
                .background(Capsule().fill(primary ? Color.accentColor : Color(.systemGray5)))
                .foregroundStyle(primary ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text("未找到本地模型")
                    .font(.system(size: isCompact ? 16 : 19, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                if model.isDownloading {
                    Text("\(Int(model.downloadProgress * 100))%")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }

            if model.isDownloading {
                ProgressView(value: model.downloadProgress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)

                Text("正在下载：已收到 \(ModelStore.humanSize(model.downloadReceivedBytes))\(model.downloadTotalBytes > 0 ? " / " + ModelStore.humanSize(model.downloadTotalBytes) : "") —— 约 1.25 GB（Q4_K_M）或 2 GB（Q8_0），完成后自动加载，不用重启 App。")
                    .font(.system(size: isCompact ? 13 : 14))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("需要 Index-Translate-2B 模型（基于 Qwen3.5-2B）：Q4_K_M 约 1.25 GB（省空间），Q8_0 约 2 GB（质量最好）。下载后完全离线运行，音频和文字都不会上传。")
                    .font(.system(size: isCompact ? 13 : 14))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("M 系列 iPad / iPhone Pro 推荐 Q8_0——实测解码速度与 Q4 接近，质量更高；较老的设备建议 Q4_K_M。")
                    .font(.system(size: isCompact ? 11 : 13))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isCompact {
                    HStack(spacing: 10) {
                        modelDownloadButton(title: "Q4_K_M · 1.25 GB",
                                            candidates: ModelStore.q4DownloadCandidates,
                                            primary: false)
                        modelDownloadButton(title: "Q8_0 · 2 GB",
                                            candidates: ModelStore.q8DownloadCandidates,
                                            primary: true)
                    }
                } else {
                    modelDownloadButton(title: "下载 Q4_K_M（约 1.25 GB，省空间）",
                                        candidates: ModelStore.q4DownloadCandidates,
                                        primary: false)
                    modelDownloadButton(title: "下载 Q8_0（约 2 GB，质量最好）",
                                        candidates: ModelStore.q8DownloadCandidates,
                                        primary: true)
                }

                Text("下载优先走 ModelScope（国内直连），失败会自动换 hf-mirror / HuggingFace。也可以手动下：Safari 打开 ModelScope 模型页 → 点 Q4_K_M 或 Q8_0 下载 → 在「文件」App 里把它拖进「我的 iPad → index-translate」。")
                    .font(.system(size: isCompact ? 11 : 13))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let msURL: URL = URL(string: ModelStore.modelScopePageURLString) {
                    Link(destination: msURL) {
                        Label("ModelScope 模型页（可手动下载）", systemImage: "arrow.up.right.square")
                            .font(.system(size: isCompact ? 12 : 14, weight: .medium))
                    }
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入…", systemImage: "folder")
                        .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, isCompact ? 8 : 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemBackground)))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)

                HStack(spacing: 14) {
                    Text("也可以把 .gguf 放进 文件 App → 我的 iPad → index-translate")
                        .font(.system(size: isCompact ? 11 : 13))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        model.rescanModel()
                    } label: {
                        Text("已放好文件？重新扫描")
                            .font(.system(size: isCompact ? 11 : 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(isCompact ? 14 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.85 : 0.70)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color(.separator), lineWidth: 1))
    }

    // MARK: - 输入 / 输出语言选择

    private var languageSelectors: some View {
        HStack(spacing: isCompact ? 10 : 14) {
            Menu {
                ForEach(InputMode.allCases) { (mode: InputMode) in
                    Button {
                        model.selectInputMode(mode)
                    } label: {
                        if mode == model.inputMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                selectorLabel(title: "输入", value: model.inputMode.title, systemImage: "character.bubble")
            }
            .disabled(model.isListening)

            Menu {
                ForEach(OutputLanguage.allCases) { (language: OutputLanguage) in
                    Button {
                        model.selectTarget(language)
                    } label: {
                        if language == model.target {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            } label: {
                selectorLabel(title: "输出", value: model.target.displayName, systemImage: "text.bubble")
            }

            Spacer(minLength: 0)
        }
    }

    private func selectorLabel(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: isCompact ? 6 : 8) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? 14 : 15, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Text(title)
                .font(.system(size: isCompact ? 13 : 14))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: isCompact ? 16 : 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, isCompact ? 14 : 18)
        .padding(.vertical, isCompact ? 9 : 11)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .contentShape(Capsule())
    }

    // MARK: - 底部：麦克风 + 清空

    private var bottomControls: some View {
        HStack(spacing: isCompact ? 10 : 16) {
            Color.clear
                .frame(width: isCompact ? 96 : 118, height: 1)

            Spacer(minLength: 0)

            micButton

            Spacer(minLength: 0)

            clearButton
        }
    }

    private var micButton: some View {
        Button {
            model.toggleListening()
        } label: {
            ZStack {
                Circle()
                    .fill(model.isListening ? Color.red : Color(.systemGray5))
                    .frame(width: isCompact ? 96 : 108, height: isCompact ? 96 : 108)
                    .shadow(color: model.isListening ? Color.red.opacity(0.35) : Color.clear,
                            radius: 18)

                Image(systemName: "mic.fill")
                    .font(.system(size: isCompact ? 30 : 34, weight: .semibold))
                    .foregroundStyle(model.isListening ? Color.white : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .opacity(model.isModelReady ? 1.0 : 0.55)
        .disabled(model.isDownloading)
        .accessibilityLabel(model.isListening ? "停止聆听" : "开始聆听")
    }

    private var clearButton: some View {
        Button {
            model.clearAll()
        } label: {
            Label("清空", systemImage: "trash")
                .font(.system(size: isCompact ? 16 : 17, weight: .medium))
                .padding(.horizontal, isCompact ? 14 : 18)
                .padding(.vertical, isCompact ? 9 : 11)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .frame(width: isCompact ? 96 : 118, alignment: .trailing)
        .accessibilityLabel("清空译文与原文")
    }
}

// MARK: - 信息面板

private struct InfoSheet: View {

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var didCopyDiagnostics: Bool = false
    @State private var copyToken: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("关于")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Color.primary)
                            Text("index-translate " + appVersionText)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("完成") {
                            dismiss()
                        }
                        .font(.system(size: 16, weight: .semibold))
                    }

                    // 翻译需求：一级菜单只显示已选/已输入的内容，点进二级页面选择或输入
                    instructionSection

                    // 模型：当前选择、引导、已安装列表、下载
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    Text(model.currentModelName.isEmpty ? "Index-Translate-2B" : model.currentModelName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("基于 Qwen3.5-2B · Q4_K_M / Q8_0 量化，全离线推理")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    if !model.modelName.isEmpty {
                        Text("已加载：" + model.modelName)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("M 系列 iPad / iPhone Pro 推荐 Q8_0——实测解码速度与 Q4 接近，质量更高；较老的设备建议 Q4_K_M。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 已安装模型列表：点一下切换
                VStack(alignment: .leading, spacing: 8) {
                    if model.models.isEmpty {
                        Text("Documents 里还没有可用的 .gguf 模型。")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary)
                    } else {
                        ForEach(model.models) { (entry: ModelEntry) in
                            Button {
                                model.switchModel(to: entry.name)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: model.currentModelName == entry.name
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(model.currentModelName == entry.name
                                                         ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(entry.displaySize)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if model.isModelReady && model.currentModelName == entry.name {
                                        Text("使用中")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(model.currentModelName == entry.name
                                          ? Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.10)
                                          : Color(.secondarySystemBackground)))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isDownloading || model.isListening)
                        }
                    }
                }

                // 下载：进度条复用 downloadProgress
                VStack(alignment: .leading, spacing: 8) {
                    if model.isDownloading {
                        HStack(spacing: 8) {
                            Text(model.downloadTotalBytes > 0
                                 ? "正在下载 \(ModelStore.humanSize(model.downloadReceivedBytes)) / \(ModelStore.humanSize(model.downloadTotalBytes))"
                                 : "正在下载 \(ModelStore.humanSize(model.downloadReceivedBytes))")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.secondary)
                            Spacer(minLength: 0)
                            Text("\(Int(model.downloadProgress * 100))%")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.primary)
                        }
                        ProgressView(value: model.downloadProgress)
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
                    } else {
                        Button {
                            model.downloadModel(candidates: ModelStore.q4DownloadCandidates)
                        } label: {
                            Text("下载 Q4_K_M（约 1.25 GB，省空间）")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground)))
                                .foregroundStyle(Color.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isListening)

                        Button {
                            model.downloadModel(candidates: ModelStore.q8DownloadCandidates)
                        } label: {
                            Text("下载 Q8_0（约 2 GB，质量最好）")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12)))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isListening)

                        Text("优先 ModelScope（国内直连），失败自动换 hf-mirror / HuggingFace。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("相关链接")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    if let siteURL = URL(string: "https://index-translate.bilibili.com") {
                        Link(destination: siteURL) {
                            Label("模型官网 · index-translate.bilibili.com",
                                  systemImage: "arrow.up.right.square")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let repoURL = URL(string: ModelStore.modelScopePageURLString) {
                        Link(destination: repoURL) {
                            Label("ModelScope 模型页 · modelscope.cn/IndexTeam/Index-Translate-2B-GGUF",
                                  systemImage: "arrow.up.right.square")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let repoURL = URL(string: ModelStore.huggingFacePageURLString) {
                        Link(destination: repoURL) {
                            Label("模型仓库 · huggingface.co/IndexTeam/Index-Translate-2B-GGUF",
                                  systemImage: "arrow.up.right.square")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                infoBlock(title: "识别引擎",
                          value: model.asrEngineName.isEmpty ? "未启动" : model.asrEngineName)

                infoBlock(title: "支持的语言（前 8 个）",
                          value: supportedLocalesPreview)

                infoBlock(title: "最近一次性能",
                          value: model.metrics.isEmpty ? "暂无" : model.metrics)

                infoBlock(title: "最近一次延迟",
                          value: model.lastLatencyMS > 0 ? "\(model.lastLatencyMS) ms" : "暂无")

                Toggle(isOn: $model.dualRecognizer) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动模式双识别器（实验）")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.primary)
                        Text("打开后「自动」会同时跑中/英两路识别并配对；默认关闭（只用中文识别器）。改动在下次开始聆听时生效。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Color.accentColor)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt 说明")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text("每句话定稿后，App 用 PromptBuilder.full(text:source:target:instruction:) 生成「把这段{源语言}翻译成{目标语言}，只输出译文」的 ChatML 提示词，交给本地 Index-Translate-2B（基于 Qwen3.5-2B，Q4_K_M / Q8_0 量化）推理；输出再经 PromptBuilder.clean(_:) 去掉思考段、引号和多余空行后显示。若设置了翻译需求，会按官方 instTrans 格式额外加一条【注意】约束（中文源→非英语时身份术语表仍是第一条【硬性要求】）。全程离线，音频与文字都不会上传。")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    UIPasteboard.general.string = model.diagnosticReport
                    didCopyDiagnostics = true
                    copyToken += 1
                    let token: Int = copyToken
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard token == copyToken else { return }
                        didCopyDiagnostics = false
                    }
                } label: {
                    Label(didCopyDiagnostics ? "已复制" : "复制诊断",
                          systemImage: didCopyDiagnostics ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(didCopyDiagnostics
                                  ? Color.green.opacity(colorScheme == .dark ? 0.22 : 0.15)
                                  : Color(.secondarySystemBackground)))
                        .foregroundStyle(didCopyDiagnostics ? Color.green : Color.primary)
                }
                .buttonStyle(.plain)

                Divider()

                Button {
                    model.clearAll()
                    dismiss()
                } label: {
                    Label("清空译文与原文", systemImage: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red.opacity(colorScheme == .dark ? 0.18 : 0.08)))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("关于这个项目")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text("v1.3.0 新增：阿拉伯语输入输出（从右到左排版）、深色模式跟随系统、长句连续输出时自动滚到最底（能看到最新一句的原文小字）。\nv1.2.0：ⓘ →「翻译需求」（场景 / 自定义要求，可勾选记住到下次启动）、意大利语输入输出、俄语输出。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let repoURL: URL = URL(string: "https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5") {
                        Link(destination: repoURL) {
                            Label("GitHub · Baizhi-Angelica/IndexTranslate_iPadM5",
                                  systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let videoURL: URL = URL(string: "https://www.bilibili.com/video/BV151sH6EE81") {
                        Link(destination: videoURL) {
                            Label("B 站演示视频 · BV151sH6EE81",
                                  systemImage: "play.rectangle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("欢迎 star、fork 这个项目，也欢迎在 B 站投币点赞，让更多需要本地语音翻译的人看到。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                model.refreshModels()
            }
        }
    }

    // MARK: 翻译需求（一级菜单：只显示已选/已输入的内容）

    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("翻译需求")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.secondary)

            NavigationLink {
                InstructionPickerView(model: model)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.instructionDisplayText)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("选择说话场景或写自己的要求，会作为【注意】约束加进 prompt")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(.plain)

            Text(model.saveInstruction
                 ? "已勾选保存：下次启动仍会用这条需求。"
                 : "未勾选保存：退出 App 后这条需求会被清空。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
        }
    }

    /// 读 Info.plist 里的版本号（CFBundleShortVersionString / CFBundleVersion）
    private var appVersionText: String {
        let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
        let shortVersion: String = info["CFBundleShortVersionString"] as? String ?? "?"
        let build: String = info["CFBundleVersion"] as? String ?? "?"
        return "v" + shortVersion + "（build " + build + "）"
    }

    private var supportedLocalesPreview: String {
        let raw: String = model.supportedLocalesText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "读取中…"
        }
        let parts: [String] = raw.components(separatedBy: "、").filter { !$0.isEmpty }
        if parts.isEmpty {
            return raw
        }
        if parts.count <= 8 {
            return parts.joined(separator: "、")
        }
        return parts.prefix(8).joined(separator: "、") + "…（共 " + String(parts.count) + " 种）"
    }

    private func infoBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 翻译需求（二级页面：选择场景 / 自定义 / 保存）

private struct InstructionPickerView: View {

    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sceneSection
                customSection
                saveSection
                promptPreviewSection
            }
            .padding(24)
        }
        .navigationTitle("翻译需求")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: 场景（单选，和自定义二选一）

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选一个场景")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)

            optionRow(title: "默认（不额外要求）",
                      detail: "不加任何额外要求，和以前完全一样",
                      selected: model.activeInstruction.isEmpty) {
                model.clearTranslationInstruction()
            }

            ForEach(TranslationInstructionPreset.allCases) { (preset: TranslationInstructionPreset) in
                optionRow(title: preset.title,
                          detail: preset.instruction,
                          selected: model.selectedInstructionPreset == preset) {
                    model.selectInstructionPreset(preset)
                }
            }
        }
    }

    private func optionRow(title: String, detail: String, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected
                      ? Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.10)
                      : Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 自定义需求

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("或者写自己的需求")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { model.translationInstruction },
                    set: { (text: String) in model.updateTranslationInstruction(text) }
                ))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemBackground)))

                if model.translationInstruction.isEmpty {
                    Text("例如：回答要简短；称呼对方为「老师」；数字保留阿拉伯数字。")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 96)

            Text("和上面的场景二选一：点场景会覆盖这里的文字；改了这里的文字就变成「自定义」。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 保存（☑️ + 蓝色文字）

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.setSaveInstruction(!model.saveInstruction)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.saveInstruction ? "checkmark.square.fill" : "square")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(model.saveInstruction ? Color.accentColor : Color.secondary)
                    Text("保存这次的需求，下次默认使用")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Text("不勾选（默认）：这条需求只在本次打开 App 期间生效，退出就清空。勾选后写入本机，下次打开自动沿用；随时可以回来取消。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.secondarySystemBackground)))
    }

    // MARK: 实际进 prompt 的约束预览

    private var promptPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实际加进 prompt 的约束")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)

            let lines: [String] = PromptBuilder.constraintLines(from: model.translationInstruction)
            if lines.isEmpty {
                Text("无（走默认 prompt，不加额外约束）")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
            } else {
                Text(renderedConstraints(lines))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("中文 → 非英语目标时，这条【注意】前面还会自动加一条【硬性要求】专名/术语对照，保证英文词原样保留。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.85 : 0.70)))
    }

    private func renderedConstraints(_ lines: [String]) -> String {
        var numbered: [String] = []
        for (index, line) in lines.enumerated() {
            numbered.append(String(index + 1) + ". " + line)
        }
        return numbered.joined(separator: "\n")
    }
}
