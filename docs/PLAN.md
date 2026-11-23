# 架构与决策记录

> 这份文档回答两个问题：**为什么这么做**，以及**哪些路已经证明走不通**。
> 数字都来自本仓库的实测（`tools/out/`，Windows CPU + Q4_K_M），真机数据一旦拿到会补在这里。

## 0. 边界

- 目标设备：iPad Pro M5 / iPadOS 26（`SpeechAnalyzer` 要求 iOS 26；llama.cpp 的 xcframework 最低 iOS 16.4）。
- 只做**语音 → 文本翻译**，不做语音合成（TTS）、不做悬浮字幕、不做双人对话分离。
- 输入 8 种语言（中/英/日/韩/法/德/西/意）或「自动」（自动只跑中/英两路）；输出 9 种语言（多一个俄语）。
  俄语之所以只做输出：iPadOS 26 的 `SpeechTranscriber.supportedLocales` 真机返回 31 个语言区，里面有 `it-IT`
  但没有 `ru-RU`（见 `REALMACHINE-NOTES.md`），所以「说俄语」暂时做不了；「翻成俄语」只依赖模型，能做。
- 全程离线：模型、推理、转写都在设备上；只有"首次下载模型 / 首次下载语音资产"需要网络。
- 交付形态：未签名 ipa + Sideloadly 重签装机（免费 Apple ID，7 天有效）。

## 1. 决策表

| # | 决策 | 选项 | 为什么选它 |
|---|---|---|---|
| 1 | 翻译模型 | `Index-Translate-2B` 而不是 `Index-Echo-S2TT-2B` | Index-Echo 是语音到文本翻译模型，音频塔是模型的一部分，去掉后文本解码器不能独立工作；Index-Translate 是纯文本翻译模型，语音识别交给 Apple 的 `SpeechAnalyzer` 更灵活（可以换 locale、可以用系统自定义词汇） |
| 2 | 量化档位 | Q4_K_M（1.22 GB） | 官方推荐默认档：COMET -0.15 / chrF++ -0.25，12 项约束检查全过；Q8_0 要 1.98 GB 只换来 ~0 提升，Q2_K-QAT（0.78 GB）虽快 1.5× 但在 en-hi/en-bn 等方向掉 5 COMET 且会翻坏 `{name}` 占位符 |
| 3 | 推理框架 | llama.cpp（预编译 `llama.xcframework`，b12397） | 直接用官方 GGUF，零转换；xcframework 自带 Metal（`GGML_METAL_EMBED_LIBRARY=ON`，shader 嵌在二进制里，不需要 Xcode 参与编译）；MLX Swift 要先把 GGUF 转成 MLX 格式（成本高、工具链在 Windows 上不可控），Core ML 要整模型转换与额外 kernel 工作 |
| 4 | 语音识别 | iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` | 系统级设备端流式转写，不消耗自建引擎的算力/内存；`preset: .progressiveTranscription` 提供实时 partial；老方案 `SFSpeechRecognizer` 作为降级路线保留（真机验证后再决定要不要接） |
| 5 | 方向判定 | 手动选输入语言（中文/English）+ 自动模式按**转写文本含不含汉字**挑 | 沿用小米版教训：让模型猜音频语种会把中文听成英文、再"翻译"成中文（61 条字幕里 26 条没译文）。锚定文本是唯一稳的判据 |
| 6 | 英文词保留 | 中文→非英语时用**身份术语表**（`X→X` 硬约束） | A/B 实测：软约束按词 61.8% / 整句 40.0%，术语表 99.4% / 98.3%，代价只是 prompt 变长（平均延迟 615 → 808 ms，Windows CPU） |
| 7 | 状态与并发 | 所有 UI 状态 `@MainActor`；推理在 `Task.detached`；C 侧用 `NSLock` 串行 | 2B 模型一句 0.5–1.5 s，放主线程必卡；ASR 回调在音频线程，必须显式回主线程 |
| 8 | 队列 | 丢最旧保最新，最多 3 条 | 连续说话时"显示 15 秒前那句"没有意义；这是小米版实测过的策略 |
| 9 | 构建 | GitHub Actions `macos-26` + XcodeGen | 本机是 Windows 且没有 Xcode；XcodeGen 让工程描述（`project.yml`）可 review、可 diff，不用手写 `.pbxproj` |
| 10 | 装机 | Windows + Sideloadly + 免费 Apple ID | 不需要 $99 开发者账号；TestFlight 需要付费账号（见 roadmap P2） |
| 11 | 模型分发 | App 内下载（hf-mirror 默认）+「文件」App 导入 | 1.22 GB 塞进 ipa 会让每次重签都变成几分钟；`UIFileSharingEnabled` 打开后 Documents 在「文件」App 里可见 |
| 12 | 可观测性 | llama.cpp 日志写 `Documents/llama.log`（8 KB 内存环 + 落盘） | 设备上没有 Xcode 控制台，出问题只能靠用户把日志文件发回来 |
| 13 | 输入/输出语言（v1.2.0） | 输入 8 种、输出 9 种（俄语仅输出） | 输入语言必须先在真机 `SpeechTranscriber.supportedLocales` 里确认：31 个语言区含 `it-IT`、不含 `ru-RU`。俄语输出只依赖翻译模型（官方 `LANG_NAMES` 里有 ru），所以单独放行输出 |
| 14 | 「翻译需求」的 prompt 写法 | 走官方 **instTrans 约束格式**：自由文本按行渲染成 `【注意】…`，中文源→非英语时身份术语表仍是第一条【硬性要求】 | 官方 `inference/llm/call_api.py::build_prompt` 就是这么拼的（`--instruction` / `--glossary`），模型是按这个格式训练的；自定义 system prompt 没有依据。5 个内置场景文案见 `Sources/InstructionPresets.swift`，空需求时 prompt 与 v1.1.0 逐字节一致（`verify-prompts.yml` 卡着） |
| 15 | 「翻译需求」的留/清策略 | 默认退出即清空；二级页面勾选「保存这次的需求，下次默认使用」才写 UserDefaults | issue #4 的原始要求；只影响 UI 状态，模型侧无状态。用「勾选才落盘」实现"退出清空"，不需要监听 App 生命周期（iOS 也不保证有退出回调） |

## 2. 已证伪 / 已否决的路线

| 路线 | 结论 | 证据 |
|---|---|---|
| 用 `Index-Echo-S2TT` 改造成纯文本模型 | ❌ 不可行 | 音频塔是模型结构的一部分，剥离后解码器不能独立工作 |
| "请保留原文英文单词，不要翻译" 这类软约束 | ❌ 效果太差 | 60 条中文→非英语目标：按词 61.8%、整句全中 40.0%；日/韩只有 39.4%（模型会把英文词写成假名/谚文外来语） |
| 占位符保护（`{0}` 替换 → 翻译 → 还原） | ❌ 比术语表差 | 97.0% / 91.7%，S3 丢 2 个占位符、S4 丢 4 个；还多一层还原逻辑和"模型把 `{0}` 按语义改写"的风险 |
| 让模型自己判断源语言 | ❌ 已证伪（小米版） | Index-Echo 上 61 条字幕 26 条无译文；本项目的方向判定因此改为锚定转写文本的字符集 |
| 把 Q4 量化当作"精度不可接受"（照搬小米结论） | ❌ 结论不适用 | 那条针对 Index-Echo 语音模型（99% → 90%）；Index-Translate 官方把 Q4_K_M 作为推荐档，A/B 里所有 165 个英文 term 保留 164 个 |
| MLX Swift 作为 MVP 框架 | ⏸ 推迟 | GGUF → MLX 需要转换（权重 + 配置 + 可能的算子差异），且在无 Mac 的环境里无法可靠调试转换产物；llama.cpp 现成 xcframework 已经能用 Metal |
| Core ML | ⏸ 推迟 | 需要把 2B 翻译模型整体转换、还要自己处理 tokenizer/采样，工作量按周计，收益不明 |
| NPU / ANE 专项加速 | ⏸ 不做 | 没有公开的 GGUF→ANE 通道；llama.cpp 的 Metal 后端已能吃满 GPU，CPU 侧只做少量算子 |
| WSL + `xtool` 全本地构建 | ⏸ 备用 | 需要 WSL2 + usbipd USB 直通 + Swift 6.4 Linux 工具链 + 约 10 GB 的 `Xcode.xip`（要 Apple ID 登录下载），前置步骤和失败点都比 CI 多。GitHub Actions 恢复后没有理由再走它 |
| Cirrus CI（`ghcr.io/cirruslabs/macos-tahoe-xcode`） | ⏸ 备用 | GitHub Actions 因账号账单锁无法启动时准备过等价配置（同一个 macOS 26 + Xcode 26 镜像），账单修复后删除了 |
| 把 `.gguf` 打进 ipa | ❌ 否决 | 1.22 GB 会让 Sideloadly 每次重签都变成几分钟，且换模型要重新出包 |
| 用 `SpeechTranscriber` 做俄语输入 | ❌ 当前系统不支持 | 真机 `supportedLocales` 31 个语言区里没有 `ru-RU`（有 `it-IT`）。`supportedLocale(equivalentTo:)` 单独调用会返回 `ru_RU`，但只代表"语言等价"，不代表装了模型——必须看 `supportedLocales` 数组本身 |
| 用 `DictationTranscriber` 兜底俄语输入 | ⏸ 本轮不做（可行路线） | Apple 的「听写」引擎与 `SFSpeechRecognizer` 离线模型同源，社区项目（swift-speech-lanes）在真机上验证过 `ru-RU` 走 `DictationTranscriber`。本轮按用户选择只做俄语输出；要做时把 `SpeechAnalyzerASR` 的 transcriber 泛化成 Speech/Dictation 两种（`SpeechModule` 协议一致），需真机验证 |

## 3. 分层

```
Core.swift ──────────── 语言枚举、ASREvent、ASREngine 协议、LlamaTiming（接口契约）
   │
   ├─ ASR 层  SpeechAnalyzerASR（iOS 26 专属；一个 locale 一个 analyzer + 一条 AsyncStream）
   ├─ 数据层  Prompts / LlamaTranslator / ModelStore（不依赖 UI）
   └─ UI 层   AppModel（状态机）+ ContentView（SwiftUI）
```

- **ASR 层**只往外抛 `partial / final / level / error`，不认识"句子""队列"这些概念。
- **数据层**是纯函数 + 单个 C context，方便在 Windows 上用 Python 脚本复现同一套 prompt（`tools/` 就是干这个的）。
- **UI 层**负责把事件拼成"一句"，决定翻哪一条、丢了哪些。

### 一次翻译的完整路径

1. `SpeechTranscriber` 吐出 `final(text)`（一句话）
2. `AppModel` 判断方向：手动模式用所选语言；自动模式按"含汉字 → 中文，否则英文"
3. 若目标语言 == 源语言（例如输入英文、目标是 English），自动改成对应的另一方
4. `PromptBuilder.full(text:source:target:)` 生成 ChatML（中文→非英语时插入身份术语表）
5. 队列（最多 3 条，丢最旧）→ `Task.detached` → `LlamaTranslator.translate`
6. `ITXLlama.c`：tokenize → `llama_memory_clear` → decode prompt → greedy 采样到 EOG
7. `PromptBuilder.clean`：去思考段、去引号、压空行 → 更新 UI 与 metrics

## 4. Roadmap

### P0（装机第一轮必须完成）

- [ ] 真机装上，确认 `SpeechTranscriber` 支持 zh-CN（`probe-speech.yml` 先查，App 里也会显示支持语言）
- [ ] 测 M5 上的 prefill / decode 速度与单句端到端延迟，补进 README
- [ ] 验证 `llama.framework` 被 Sideloadly 正确重签（不闪退）
- [ ] 自动模式双 analyzer 是否报 `insufficientResources`

### P1（体验）

- [ ] 能量 VAD 自动停止（说完 1.2 s 静音自动收句），减少"点两次按钮"
- [ ] 译文流式追加显示（现在等整句译完才出）
- [ ] 术语表可编辑（课程名/人名这类专有名词让用户自己加）
- [ ] Q6_K / Q8_0 与 Q4_K_M 的真机对比（质量 vs 速度）
- [ ] 出错时在界面上直接给"复制日志"按钮

### P2（可选）

- [ ] TestFlight 分发（需要 $99/年，免掉 7 天重签）
- [ ] 连续字幕模式（长听 + 逐句滚动，而不是点一次翻一句）
- [ ] MLX Swift 版本做性能对照（只有在 llama.cpp 速度不达标时才值得做）

### v1.2.0（2026-11-23，正式版）

- [x] 输入 + 意大利语（`it-IT`）、输出 + 意大利语 / 俄语（俄语仅输出）；用户真机测试 OK 后转正式版
- [x] ⓘ →「翻译需求」：5 个中文场景 + 自定义文本，按官方 instTrans 格式加【注意】约束；
      默认退出清空，勾选☑️「保存这次的需求，下次默认使用」才持久化
- [x] ⓘ 面板显示版本号，并在「关于这个项目」里加 v1.2.0 更新说明
- [x] 回归脚本补齐术语表模板，新增 `--preset` / `--instruction` / `--targets`
- [x] `verify-prompts.yml`：Swift `PromptBuilder` 与 Python 镜像 396 条 case 逐字节比对

## 5. 风险登记

| 风险 | 影响 | 现状 |
|---|---|---|
| `SpeechTranscriber` 不支持 zh-CN | 整个 ASR 方案要换回 `SFSpeechRecognizer` | 待 `probe-speech.yml` 结果 |
| 免费签名 7 天到期 | 每周要重签一次 | 已知，文档已写流程；付费账号可解 |
| 双 analyzer 撞系统资源上限 | 自动模式不可用 | 有降级预案：单个 analyzer 挂两个 transcriber，或只留单语言 |
| `AVAudioConverter` 停止时不 flush | 最后几十毫秒音频丢失 | 影响极小；若真机发现吃字，再补 `endOfStream` |
| 1.22 GB 模型 + 语音资产的内存压力 | 老设备 jetsam | M5 是 12/16 GB，问题不大；后续可加内存警告回调卸模型 |
| 未签名 ipa 换 Apple ID 后包名冲突 | 装机失败 | Bundle ID 固定 `com.baizhiangelica.itxtranslate`，同一账号下没问题 |
| 「翻译需求」只是软约束 | 模型可能不完全遵守语气要求 | 官方 instTrans 格式 + 场景文案短；已在 Windows CPU 上跑回归（见 `docs/HANDOFF.md` 第 11 节），真机验收第 7 条 |
| 意大利语识别器首次使用要下系统语音资产 | 第一次点麦克风等几十秒 | 与日/韩/法/德/西相同，界面已有"正在启动语音识别"过程态 |
