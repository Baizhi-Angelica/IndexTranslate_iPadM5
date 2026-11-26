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

## Metal 首次编译开销（重要）

真机 `Documents/llama.log`（156 KB）里除了 `offloaded 26/26 layers to GPU`，还有一段容易被忽略的：

```
ggml_metal_library_init: using embedded metal library
ggml_metal_library_compile_all: compiled 'fa_aux' library in 1.981 sec
ggml_metal_library_compile_all: compiled 'fa_f16' library in 9.101 sec
...
```

36 个 Metal 库合计 **173.5 秒**。也就是说模型加载阶段除了读 1.2 GB 权重，还要现场编译 Metal 内核。

- 这是 llama.cpp 的 `GGML_METAL_EMBED_LIBRARY` + 运行时特化管线机制，不是我们的代码问题
- 若表现成「每次冷启动要等几分钟」：优先确认是否只是首次（Metal 管线缓存落在 App 的 Library/Caches）
- 备选优化（未做）：启动时先加载模型并显示进度；或研究 llama.cpp 是否能跳过 compile_all 走惰性编译

## 2026-11-15 · 模型档位实测（用户真机）

| 模型 | 体积 | 真机延迟 | 结论 |
|---|---:|---|---|
| `Index-Translate-2B.Q4_K_M.gguf` | 1,251.4 MB | 166–319 ms/句 | 默认档 |
| `Index-Translate-2B.Q8_0.gguf` | 1,980.5 MB | **与 Q4 接近** | M 系列设备推荐档（质量更高） |

App 因此支持多模型并存与切换；导入时保留原文件名，不再改名成 Q4。

## 2026-11-23 · v1.2.0（翻译需求 / 意大利语 / 俄语输出）

> 结果：用户在 iPad Pro M5 上装 `v1.2.0-beta.1` 后确认**整体测试 OK**，`v1.2.0` 正式版已发布。
> **诚实提醒**：用户只回了"测试 ok"这一句，下面清单里的每一项**没有逐条回传细节**
> （没有延迟数字、没有日志、没有译文样本）。这些"验收项"留作以后复测的清单，不代表已逐项取过证。

| 验收项 | 怎么验 |
|---|---|
| 意大利语输入 | 输入切 `Italiano`，说一句意大利语（如 `Dov'è la stazione?`）：首次会下载 it-IT 语音资产，之后出中文译文 |
| 俄语输出 | 输入中文/English，输出 `Русский`：出俄语译文，`Documents/llama.log` 无异常 |
| 翻译需求语气 | ⓘ →「翻译需求」选「严肃会议」说一句中文，再切「朋友小聚」说同一句：语气应有可见差异 |
| 翻译需求持久化 | 不勾保存 → 杀 App 重开应回到「默认（不额外要求）」；勾选☑️保存 → 重开仍是该场景 |
| 翻译需求与术语表共存 | 中文→日语 + 「严肃会议」+ 带 `dining hall` 的句子：英文词应原样保留 |
| 布局 | iPad 竖屏打开 ⓘ 二级页面不截断；iPhone 未测 |

已知证据（Windows CPU，Q4_K_M，见 `tools/out/` 与 `docs/HANDOFF.md` §11）：
默认路径 160 次调用 english_kept 83/84 (98.8%)、term 230/231、空输出 0、平均 683 ms；
意大利语目标 12/12、俄语目标 11/12（`clone` 被译成 `клонировал`）。

## 2026-11-26 · v1.3.0（阿拉伯语输出 RTL / 深色模式 / 长句自动滚底 / 识别语言占用上限）

> 结果：在 iPad Pro M5（iPadOS 26）上经 `v1.3.0-beta.1` → `v1.3.0-beta.2` 真机验证后定稿 `v1.3.0` 正式版。

| 验证项 | 真机实测结果 |
|---|---|
| 阿拉伯语输出 + RTL 排版 | ✅ **OK**。真机实拍见 `docs/images/output-arabic.jpg`（中文 → العربية，`prefill 105 tok/2 ms · decode 20 tok/416 ms · 48.1 tok/s · 418 ms`），译文按从右到左排版、右对齐 |
| 长句连续输出自动滚底 | ✅ **OK**。连续两句长阿拉伯语译文时自动滚到最底，当前句底部的中文原文小字完整可见（见同张截图） |
| 深色模式跟随系统 | ✅ **OK**。跟随系统浅色 / 深色外观切换 |
| 5 语种占用上限 + 一键清除 | ✅ **OK**。`beta.1` 切换多个输入语种后触发 `Too many allocated locales, 5 maximum.`；`beta.2` 加入 `AssetInventory` 一键释放非中/英语种（错误横幅右侧 + ⓘ 面板常驻），真机实测可顺利释放并恢复启动 |
| 阿拉伯语输入（`ar-SA`） | ❌ **系统下载失败**。释放占用名额后实测选择阿拉伯语输入，系统在下载语音资产阶段报错 `transcription.ar asset not found after attemped download`（尽管 `ar-SA` 在 `SpeechTranscriber.supportedLocales` 的 31 个列表里）。因此 `v1.3.0` 正式版将阿拉伯语改为**仅输出**（与俄语一致） |

