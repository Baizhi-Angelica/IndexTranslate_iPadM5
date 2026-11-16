# AGENTS.md

> **动手前先读 [docs/HANDOFF.md](docs/HANDOFF.md)**：现状、为什么这么选、哪些路已证伪、哪些地方其实**没验证过**、下次接手的命令清单。那份是交接给下一个模型/开发者的，语气更直白。

面向自动化 agent 的仓库说明。人类读者请看 [README.md](README.md)；装机照 [docs/INSTALL-IPAD.md](docs/INSTALL-IPAD.md) 执行。

## 这是什么

在 **iPad Pro M5（iPadOS 26）** 上跑**全离线**语音翻译：麦克风 → Apple `SpeechAnalyzer`（设备端流式转写）→ `Index-Translate-2B` 移动端 GGUF（Q4_K_M，1.22 GB）→ 译文。输入 7 种语言之一或「自动」（自动只跑 zh-CN + en-US 两路），输出 7 种语言，**中英混说时英文词原样保留**。

本机是 **Windows，没有 Xcode**：iOS 侧改动**无法本地编译**，一律靠 GitHub Actions 的 `macos-26` runner，产物是**未签名 ipa**，再由 Windows 上的 Sideloadly + 免费 Apple ID 重签安装（7 天有效期）。

## 硬约束（改代码时必须保持）

| 约束 | 原因 |
|---|---|
| ChatML 结尾必须逐字节是 `<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n` | 形状错了模型会打开思考模式，把推理内容写进译文；`<think>` 与 `</think>` 之间必须正好两个换行 |
| 中文 → 非英语目标必须用**身份术语表**（`专名/术语对照: X→X、Y→Y`），不得回退成"请保留英文原样"式软约束 | A/B 实测（`tools/ab_english.py`，240 次调用）：软约束按词保留 61.8%、整句全中 40.0%；术语表 99.4% / 98.3% |
| 中文 → 非英语**不要**用占位符方案（`{0}` 替换再还原） | 实测 97.0% / 91.7%，还会丢占位符（S3 丢 2 个、S4 丢 4 个），而且要多一层还原逻辑 |
| 中文 → 英语**不要**套术语表或占位符 | 目标就是英语，硬约束会把英文词按语义改译（占位符方案在 en 上反而掉到 97.0%） |
| `llama.framework` 是**动态库**，必须出现在 `ITXTranslate.app/Frameworks/` | 主二进制的 `LC_LOAD_DYLIB` 是 `@rpath/llama.framework/llama`；缺了就是启动瞬间 dyld 崩溃。XcodeGen 的 `embed: true` 实测不生效，所以 CI 里显式拷贝 + `Verify bundle` 步骤兜底 |
| ipa 小于 3 MB 直接判失败 | 这个阈值专门用来抓"framework 没被嵌进 app"（build-7 是 4,035,451 字节） |
| `CODE_SIGNING_ALLOWED=NO / CODE_SIGNING_REQUIRED=NO` 不得去掉 | CI 只产出未签名包，签名统一交给 Sideloadly；在 CI 里配开发者证书既无必要也拿不到 |
| 部署目标 17.0，iOS 26 的 Speech API 必须写在 `if #available(iOS 26.0, *)` 里 | `SpeechAnalyzer` / `SpeechTranscriber` 是 iPadOS 26 才有的；裸露引用会让 iOS 17/18 设备直接崩 |
| 推理必须离开主线程，UI 状态只在 `@MainActor` 改 | 2B 模型一次 0.5–1.5 s，放主线程会卡死界面；ASR 事件和推理结果都要回主线程再写 |
| 翻译队列**丢最旧、保最新**，最多 3 条；每次请求必须带 `max_tokens` | 连续说话时优先显示最新一句；不带上限时解码跑飞能把一句拖成几十秒 |
| 每句翻译前 `llama_memory_clear` | 复用 context 不清 KV，上下文会串味，多句之后译错语言 |
| 模型文件**不进 ipa** | Q4_K_M 1.22 GB，塞进 ipa 会让签名/安装变成几分钟；App 内下载或文件 App 导入 |
| `Frameworks/`、`Sources/MT/include/`、`build/`、`tools/out/` 不提交 | 前两个由 CI 下载，后两个是产物 |
| 不要提交 Apple ID、密码、`*.ipa`、token | —— |
| 改 prompt 必须跑 `python tools\ab_english.py`（或 `regress_prompts.py`）并记录数字 | 否则"英文保留"会悄悄退化，这是本项目最容易回退的指标 |
| 不要照搬小米版"Q4 已否决"的结论 | 那条针对的是 Index-Echo 语音模型；Index-Translate 官方把 Q4_K_M 作为推荐默认档（COMET -0.15） |
| Windows 沙箱里 push 用 token URL，推完还原 remote | `gh` 的 credential helper 在沙箱里会因 Cygwin 信号管道失败（`Win32 error 5`）；不要用 `~`（HOME） |

## 关键路径

```
Sources/Core.swift                  语言枚举 + ASREvent + 接口契约（改契约先改这里）
Sources/AppModel.swift              状态机：权限 / 模型 / ASR 配对 / 队列（约 950 行，最复杂）
Sources/ContentView.swift           SwiftUI 界面
Sources/ASR/SpeechAnalyzerASR.swift SpeechAnalyzer + SpeechTranscriber（iOS 26）
Sources/MT/Prompts.swift            ChatML / 约束模板 / 术语表抽取 / 输出清洗
Sources/MT/LlamaTranslator.swift    Swift ↔ C 封装（锁、线程数、GPU 层数）
Sources/MT/ITXLlama.c               llama.cpp C 桥 + 日志落盘
Sources/ModelStore.swift            模型定位 / 导入 / 下载（ModelScope → hf-mirror → HF，自带分块下载器）
project.yml                         XcodeGen 工程描述（新增源文件不用改，Sources 目录自动收编）
.github/workflows/build-ipa.yml     构建 → 打 ipa → Verify → 发 prerelease
tools/(segments|regress_prompts|ab_english).py   本地提示词回归 / A/B
docs/PLAN.md, docs/PITFALLS.md      决策记录 / 踩坑
docs/HANDOFF.md                     交接笔记（现状 / 已证伪 / 未验证 / 命令清单）
```

## 常用命令（Windows PowerShell，可直接复制）

```powershell
# 环境
$gh   = "$env:LOCALAPPDATA\Programs\GitHub CLI\bin\gh.exe"
$repo = 'Baizhi-Angelica/IndexTranslate_iPadM5'
$root = 'C:\Users\Angelica\Desktop\works\DeepSeek\IndexTranslate_iPadM5'

# 看构建
& $gh run list --repo $repo --limit 5
& $gh run view <run-id> --repo $repo --log            # 全量日志
& $gh release view build-<N> --repo $repo --json assets

# 触发一次构建（改了 workflow 或想重建）
& $gh workflow run build-ipa.yml --repo $repo

# 探测 SpeechTranscriber 是否支持 zh-CN / en-US（不装机也能查）
& $gh workflow run probe-speech.yml --repo $repo

# 本地提示词回归（需要 8089 上跑着 llama-server，见 tools/README.md）
Set-Location $root
python tools\segments.py                                # 语料自检
python tools\regress_prompts.py --limit 12              # 冒烟
python tools\regress_prompts.py                         # 全量 120 次，约 1.5–2 分钟
python tools\ab_english.py --strategies s1,s2 --targets ja --limit 8
```

## 验收

**构建侧**（每次改动后）

```powershell
& $gh run list --repo $repo --limit 3        # 最新一次必须 success
& $gh release view build-<N> --repo $repo --json assets   # ipa 必须 > 3 MB
```

日志里应出现 `BUILD OK`、`bundle check OK`、`ipa bytes: 4xxxxxx`。

**真机侧**（装到 iPad 之后）

1. 中文 → 英语：说「我明天早上九点去 dining hall」，译文里 `dining hall` 保持英文
2. 英文 → 中文：切换输入为 English，说 `Can you help me move this desk?`，应出中文
3. 中文 → 日语：输出日语，但 `dining hall` / `library` 仍为英文
4. 连说三句：只显示最近一句的译文（丢旧保新），不卡界面
5. 单句端到端（说完到出译文）建议 < 2 s；`Documents/llama.log` 里无 Metal 初始化错误

## 不要做

- 不要在没有 macOS 的情况下尝试本地 `xcodebuild` / `swiftc`（本机没有工具链，浪费时间）
- 不要把 `Frameworks/`、`Sources/MT/include/`、`tools/out/`、`build/` 提交进仓库
- 不要在 CI 里配置签名证书、修改 `CODE_SIGNING_ALLOWED`
- 不要为了一次实验改动 `PromptBuilder.chat(_:)` 的外壳（改了就没法跟前后的回归数据对比）
- 不要把模型文件、ipa、Apple ID 凭据写进仓库或日志
- 不要删除 `probe-speech.yml`：装机前它是唯一能确认 zh-CN 支持的途径
