//
//  ContentView.swift
//  ITXTranslate
//
//  iPad 全屏界面（白底、大字）：
//  顶部标题与状态 → 中部译文 / 原文 / 性能 → 底部语言选择 + 麦克风与清空。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var model: AppModel = AppModel()

    @State private var showInfoSheet: Bool = false
    @State private var showFileImporter: Bool = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 12) {
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
            .padding(.horizontal, 34)
            .padding(.top, 20)
            .padding(.bottom, 16)
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
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(model.statusText)
                        .font(.system(size: 14))
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
            .fill(Color.red.opacity(0.07)))
    }

    // MARK: - 中部：译文 / 原文 / 性能

    private var translationArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // 上一句译文：小一号、灰色
                    if !model.previousTranslation.isEmpty {
                        Text(model.previousTranslation)
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    // 上一句原文：更小一号、更淡；没有就完全不占位
                    if !model.previousSource.isEmpty {
                        Text(model.previousSource)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    // 当前句译文：保持大字
                    Text(translationDisplayText)
                        .font(.system(size: 40, weight: .semibold))
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(model.translation.isEmpty ? Color.secondary.opacity(0.55) : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    // 当前句原文：18pt 灰色小字
                    Text(currentSourceText)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 340, alignment: .topLeading)

            metricsRow
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

    private var transcriptPreview: String {
        let text: String = model.transcript
        guard !text.isEmpty else { return "" }
        let maxLength: Int = 160
        if text.count <= maxLength {
            return text
        }
        return "…" + String(text.suffix(maxLength))
    }

    /// 当前句原文：聆听时显示实时转写，停下后显示刚翻译那句的原文。
    private var currentSourceText: String {
        if model.isListening {
            return transcriptPreview
        }
        if !model.sourceText.isEmpty {
            return model.sourceText
        }
        return transcriptPreview
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
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 120, height: 6)
                Capsule()
                    .fill(Color.red)
                    .frame(width: max(4, 120 * CGFloat(model.level)), height: 6)
            }
        }
    }

    // MARK: - 模型缺失 / 下载中卡片

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text("未找到本地模型")
                    .font(.system(size: 19, weight: .semibold))
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

                Text("正在下载 \(ModelStore.modelFileName)（约 1.22 GB），完成后会自动加载，不用重启 App。")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("需要模型文件 \(ModelStore.modelFileName)（Q4_K_M 量化，约 1.22 GB）。下载后完全离线运行，音频和文字都不会上传。")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button {
                        model.downloadModel()
                    } label: {
                        Text("下载模型 Q4_K_M（约 1.22 GB）")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从文件导入…", systemImage: "folder")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color(.systemGray5)))
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 14) {
                    Text("也可以把 .gguf 放进 文件 App → 我的 iPad → ITX 翻译")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        model.rescanModel()
                    } label: {
                        Text("已放好文件？重新扫描")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(.systemGray6).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color(.systemGray4), lineWidth: 1))
    }

    // MARK: - 输入 / 输出语言选择

    private var languageSelectors: some View {
        HStack(spacing: 14) {
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
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Capsule().fill(Color(.systemGray6)))
        .contentShape(Capsule())
    }

    // MARK: - 底部：麦克风 + 清空

    private var bottomControls: some View {
        HStack(spacing: 16) {
            Color.clear
                .frame(width: 118, height: 1)

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
                    .fill(model.isListening ? Color.red.opacity(0.12) : Color(.systemGray6))
                    .frame(width: 108, height: 108)

                if model.isListening {
                    Circle()
                        .trim(from: 0.0, to: max(0.03, CGFloat(model.level)))
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 108, height: 108)
                        .rotationEffect(Angle(degrees: -90))
                }

                Circle()
                    .fill(model.isListening ? Color.red : Color.accentColor)
                    .frame(width: 86, height: 86)

                Image(systemName: model.isListening ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.white)
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
                .font(.system(size: 17, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color(.systemGray6)))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .frame(width: 118, alignment: .trailing)
        .accessibilityLabel("清空译文与原文")
    }
}

// MARK: - 信息面板

private struct InfoSheet: View {

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var didCopyDiagnostics: Bool = false
    @State private var copyToken: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    Text("关于")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    Button("完成") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                }

                infoBlock(title: "模型",
                          value: model.modelName.isEmpty ? "未加载" : model.modelName)

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
                    Text("每句话定稿后，App 用 PromptBuilder.full(text:source:target:) 生成「把这段{源语言}翻译成{目标语言}，只输出译文」的 ChatML 提示词，交给本地 Index-Translate-2B（Q4_K_M）推理；输出再经 PromptBuilder.clean(_:) 去掉思考段、引号和多余空行后显示。全程离线，音频与文字都不会上传。")
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
                            .fill(didCopyDiagnostics ? Color.green.opacity(0.15) : Color(.systemGray6)))
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
                            .fill(Color.red.opacity(0.08)))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
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
