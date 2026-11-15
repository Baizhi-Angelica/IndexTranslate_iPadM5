# IndexTranslate_iPadM5

在 **iPad Pro M5（iPadOS 26）** 上跑的**全离线**语音翻译 App：说完一句话，屏幕上直接出现译文。

- 语音 → Apple [`SpeechAnalyzer`](https://developer.apple.com/documentation/speech/speechanalyzer)（iPadOS 26 新增，设备端流式转写）
- 文本 → [`Index-Translate-2B`](https://huggingface.co/IndexTeam/Index-Translate-2B) 的移动端 GGUF（[`mrfakename/Index-Translate-2B-mobile-GGUF`](https://huggingface.co/mrfakename/Index-Translate-2B-mobile-GGUF) / Q4_K_M / 1.22 GB），用 llama.cpp + Metal 推理
- 输入语言：中文 / English / 自动；输出语言：中文 / 英语 / 日语 / 韩语 / 法语 / 德语 / 西班牙语
- 中英混说时**英文词原样保留**（身份术语表硬约束，实测按词保留 99.4%）
- 全程不联网、不上传音频；**不需要 Mac**——构建在 GitHub Actions，装机在 Windows 上用 Sideloadly

> 上一代 Android 版（小米 15 + Termux + CrispASR + Index-Echo-2B）：<https://github.com/Baizhi-Angelica/IndexTranslate_OnXiaomi>

## 当前状态

| 项 | 状态 |
|---|---|
| 代码 | v0.1，GitHub Actions 编译通过 |
| 产物 | [build-7 未签名 ipa](https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5/releases)（4,035,451 字节） |
| 真机 | ⏳ 还没装（下一步：Sideloadly + 免费 Apple ID） |
| 性能数据 | 只有 **Windows CPU** 数据；M5 上的 tok/s、首 token 延迟待真机验证 |
| 待验证 | `SpeechTranscriber` 对 zh-CN 的支持（CI 里有 `probe-speech.yml` 探测）、内嵌动态 framework 的重签、双识别器资源上限 |

## 快速开始（三步，不需要 Mac）

1. **拿 ipa**：到 [Releases](https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5/releases) 下载最新的 `ITXTranslate-unsigned.ipa`
2. **装机**：Windows 上用 [Sideloadly](https://sideloadly.io/) + 免费 Apple ID 重签安装 → [docs/INSTALL-IPAD.md](docs/INSTALL-IPAD.md)
3. **放模型**：App 里点「下载模型 Q4_K_M（约 1.22 GB）」，或把 `.gguf` 放进「文件」App → 我的 iPad → ITX 翻译 → 同上文档

## 工作方式

```
麦克风（AVAudioEngine tap，设备原生采样率）
   │ AVAudioConverter → SpeechAnalyzer.bestAvailableAudioFormat
   ▼
SpeechAnalyzer（iPadOS 26，设备端）
   ├─ SpeechTranscriber(locale: zh-CN, preset: .progressiveTranscription)
   └─ SpeechTranscriber(locale: en-US)              ← 仅「自动」模式才起
   │  partial（实时显示）/ final（一句话定稿）
   ▼
AppModel（@MainActor）
   │  自动模式：final 先攒 700 ms，按「含不含汉字」挑一条（方向锚定文本，不猜音频语种）
   │  翻译队列：丢最旧保最新，最多 3 条；推理跑在 Task.detached
   ▼
PromptBuilder.full()   Qwen3.5 ChatML + thinking 关闭（+ 中文→非英语时加身份术语表）
   ▼
ITXLlama.c → llama.cpp（Metal，n_gpu_layers=999）
   │  每句 llama_memory_clear 清 KV、greedy 解码、max_tokens=192
   ▼
PromptBuilder.clean() → 大字译文 + 小字原文 + 耗时/速度
```

### Prompt 形状

外壳逐字节固定（关闭 thinking，`<think>` 后是两个换行）：

```
<|im_start|>user
{用户消息}<|im_end|>
<|im_start|>assistant
<think>

</think>

```

用户消息分两种：

| 场景 | 模板 | 例子 |
|---|---|---|
| 中文 → 英语；英文 → 任意目标 | 普通翻译 | `请将以下中文文本翻译为英语，直接输出翻译结果，不要进行任何解释。\n\n我明天去 dining hall。` |
| 中文 → 非英语目标 | 约束翻译 + **身份术语表** | `请将以下中文文本翻译成日语，并且严格遵循所有约束要求。` + `【源文】…` + `【约束要求】1. 【硬性要求】专名/术语对照: dining hall→dining hall` |

身份术语表由 `PromptBuilder.englishTerms(in:)` 从源文里自动抽（连续拉丁字母/空格/连字符，长度 ≥2，去重保序，最多 12 个），拼成 `X→X` 的硬约束。

## 实测数据

> 环境：Windows 10 / Python 3.9 / llama.cpp b12397 CPU 8 线程 / Q4_K_M。
> **这不是 M5 的数据**，只用来验证 prompt 与模型行为；M5 上的 Metal 数据待真机补。

### prompt 策略 A/B（`tools/ab_english.py`，240 次调用，195 s）

| 策略 | 按词保留率 | 整句全中率 | 平均延迟 | 备注 |
|---|---:|---:|---:|---|
| S1 官方式软约束（"请保留英文原样"） | 102/165 (61.8%) | 24/60 (40.0%) | 615 ms | 日/韩最差（39.4%） |
| **S2 身份术语表（采用）** | **164/165 (99.4%)** | **59/60 (98.3%)** | 808 ms | 日 100%、韩 97%、法/西/英 100% |
| S3 占位符保护 `{0}` | 160/165 (97.0%) | 55/60 (91.7%) | 837 ms | 丢 2 个占位符 |
| S4 占位符 + 术语表 | 161/165 (97.6%) | 56/60 (93.3%) | 993 ms | 丢 4 个占位符 |

S2 唯一未全中的样本：`zh-07 → 韩语`，`meeting` 被译成 `회의`。S3/S4 更差的原因：占位符会被模型按语义改写、自动抽取会把 `Dr. Chen` 拆成 `Dr` / `Chen`。

### 端到端（`tools/regress_prompts.py`，120 次调用）

- 平均 **609 ms**、中位 605 ms、平均生成 **42.7 tok/s**（纯 CPU；含 1 句 ~40 token 的生成）
- 空输出 0 条；严格规则下的"汉字泄漏" 7 条全部是日语正常汉字，剔除假名后真实泄漏 0 条
- 本仓库 `tools/out/report.md`、`tools/out/ab_english.md` 有逐条明细（`tools/out/` 不入库）

## 参数表

| 参数 | 值 | 位置 | 说明 |
|---|---|---|---|
| `n_ctx` | 2048 | `LlamaTranslator.load` | 短句翻译远用不满 |
| `n_gpu_layers` | 999（真机）/ 0（模拟器） | `LlamaTranslator.recommendedGPULayers` | 全量 offload 到 Metal |
| 线程数 | `max(2, min(8, 核数-2))` | `recommendedThreadCount` | 只影响 CPU 侧算子 |
| `max_tokens` | 192 | `AppModel` | 防解码跑飞 |
| 采样 | 贪心（temperature 0） | `ITXLlama.c` | 模型卡片推荐 |
| 翻译队列 | 最多 3 条，丢最旧 | `AppModel.maxQueuedJobs` | 优先显示最新一句 |
| 自动模式配对窗口 | 700 ms | `AppModel` | 同一句只翻一次 |
| 输出缓冲 | 8192 字节 | `ITXLlama.c` | 一句字幕足够 |
| 日志 | `Documents/llama.log`（8 KB 内存环 + 落盘） | `ITXLlama.c` | 设备上没有控制台，出错靠它 |

## 已知限制

- **尚未真机验证**：`SpeechTranscriber` 是否支持 zh-CN、M5 上 Metal 的实际速度、双 analyzer 是否撞系统资源上限、`AVAudioConverter` 停止时尾帧可能丢几十毫秒。
- **不是超低延迟流式字幕**：按"一句话定稿后翻译"工作，端到端从说完到出译文取决于 ASR 定稿速度 + 推理（Windows CPU 约 0.6–1.3 s/句）。
- **自动模式可能丢句**：700 ms 窗口内连续说多句，只会翻最新挑中的一条。
- 免费 Apple ID 签名的 App **7 天有效**，到期用 Sideloadly 重签一次（模型不丢）。
- 首次使用需要网络：下载模型（1.22 GB）+ 下载语音识别资产（系统级，几十 MB）。
- MTP 块（`blk.24.*`）未启用，加载日志里会看到 "unused tensor" 警告，属正常。

## 目录结构

```
Sources/
  Core.swift                     语言枚举 / ASREvent / 接口契约
  AppModel.swift                 状态机：权限、模型、ASR 配对、翻译队列
  ContentView.swift              SwiftUI 界面（白底大字 + 麦克风按钮 + 模型卡片）
  ITXApp.swift                   @main
  Info.plist                     麦克风/语音识别用途、文件共享
  ASR/SpeechAnalyzerASR.swift    SpeechAnalyzer + SpeechTranscriber 多 locale
  MT/Prompts.swift               ChatML / 约束模板 / 术语表 / 输出清洗
  MT/LlamaTranslator.swift       Swift 侧推理封装
  MT/ITXLlama.{h,c}              llama.cpp C 桥（tokenize/decode/sampler/日志）
  MT/include/                    CI 下载的 llama.cpp 头文件（不入库）
  ModelStore.swift               模型发现 / 导入 / 下载
tools/                           Windows 侧 prompt 回归与 A/B 脚本（不参与 App 构建）
docs/                            PLAN / PITFALLS / INSTALL-IPAD
project.yml                      XcodeGen 工程描述
.github/workflows/               build-ipa.yml（构建）、diagnose.yml、probe-speech.yml
Frameworks/                      CI 下载的 llama.xcframework（不入库）
```

## 相关文档

- [docs/PLAN.md](docs/PLAN.md) —— 架构决策、已证伪的路线、roadmap
- [docs/PITFALLS.md](docs/PITFALLS.md) —— 踩坑记录（现象 → 原因 → 解法）
- [docs/INSTALL-IPAD.md](docs/INSTALL-IPAD.md) —— Windows 侧装机与 7 天续签
- [tools/README.md](tools/README.md) —— 回归脚本怎么跑、报告怎么读
- [AGENTS.md](AGENTS.md) —— 给后续 AI agent 的硬约束
