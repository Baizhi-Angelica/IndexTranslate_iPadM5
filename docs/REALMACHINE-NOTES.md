# 真机验收记录（iPad Pro M5 / iPadOS 26）

> 本文件只记**实测数据**，不写推测。每次真机改动后追加一节。

## 2026-11-15 · build-11 / 13 / 14

### 环境

| 项 | 值 |
|---|---|
| 设备 | iPad Pro M5（iPadOS 26） |
| App 引擎 | `SpeechAnalyzer`（新 API，未降级） |
| 模型 | `qwen35 2B Q4_K - Medium`（llama.cpp 的 `llama_model_desc` 原样输出） |
| 模型文件 | `Index-Translate-2B-Q4_K_M.gguf`（mobile 仓库版，1,251.4 MB） |
| 运行方式 | GitHub Actions `macos-26` 构建 → Sideloadly + 免费 Apple ID 侧载 |

### 关键结论

1. **SpeechAnalyzer 支持中文**。`SpeechTranscriber.supportedLocales` 在 iPad 上返回 31 个语言：
   `ar-SA, de-AT, de-CH, de-DE, en-AU, en-CA, en-GB, en-IE, en-IN, en-NZ, en-SG, en-US, en-ZA,
   es-CL, es-ES, es-MX, es-US, fr-BE, fr-CA, fr-CH, fr-FR, it-CH, it-IT, ja-JP, ko-KR,
   pt-BR, pt-PT, yue-CN, zh-CN, zh-HK, zh-TW`
   → 中文（普通话/粤语/港台）、日、韩、法、德、西、意、葡、阿 全在列，输出语言矩阵可放心扩。
2. **它不走「语音识别」权限**。设置 → 隐私与安全性 → 语音识别 里没有本 App，属正常：
   SpeechAnalyzer 是新框架，无需该权限；只有降级的 `SFSpeechRecognizer` 才会申请。
3. **Metal 全量 offload 生效**。`prefill 88 tok / 2 ms` ≈ 44,000 tok/s；抽 token 延迟在 40–70 tok/s。
4. **端到端延迟**：说完到出译文 166–319 ms（翻译本身），感知延迟主要来自 ASR 定稿。
5. **英文词保留**：`dining hall` / `library` / `presebtation` / `deadline` / `slides` /
   `bug` / `debug` / `API` / `timeout` 在 中→英/日/德 测试中均未被改写（术语表方案生效）。

### 发现并修复的问题

| 现象 | 根因 | 修复 |
|---|---|---|
| 说中文却出现「巨型 APP 无法侧滑的舌头」这种译文 | 自动模式同时跑 zh-CN 与 en-US，en-US 对中文音频幻觉出一句英文，且比中文 final 先到被当成英文源 | 双识别器时等两路到齐（≤1200 ms），只翻选中的一路，另一路整条丢弃；默认只跑 zh-CN |
| 原文行挂着整场累积的转写 | `sourceText` 累积 | 改成按句 `currentSource` |
| 电平表说话不跳 / 喊也只到半格 | 原始 RMS 直接当 0…1（正常话音 0.01–0.05） | 对数刻度 + 峰值自校准 |
| 聆听按钮带斜杠像静音、外圈圆环多余 | UI 图标/装饰 | `mic.fill` + 实心红 + 外发光 |

### 待验

- 中→法/日/韩/西 在真机上的质量与延迟（Windows CPU 上的基线见 `tools/out/ab_english.md`）
- 长时间连续说话时队列「丢旧保新」的实际观感
- 免费账号 7 天到期重签流程（模型与设置是否保留）
