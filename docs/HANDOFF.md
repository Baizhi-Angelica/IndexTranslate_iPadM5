# 交接笔记：写给下一个接手这个项目的人（或模型）

> 最后更新：2026-11-16，对应 `index-translate v1.0.2`。
> 先读这份，再读 `AGENTS.md`（硬约束）、`PLAN.md`（决策）、`PITFALLS.md`（踩坑）。
> 这份的语气会比较直白：它记的是"当时为什么这么做"，以及"哪些地方我其实没把握"。

---

## 1. 一句话现状

**iPad Pro M5 上已经有一个能用的、全离线的语音翻译 App**：说中文/英文 → 系统 `SpeechAnalyzer` 转写 → `Index-Translate-2B`（GGUF, llama.cpp + Metal）翻译 → 7 种语言输出，中英混说时英文词原样保留。代码在 GitHub，ipa 在 Releases，装机靠 Windows + Sideloadly + 免费 Apple ID。

- 仓库：<https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5>
- 最新版：`v1.0.2`（另有 `build-*` 预发布记录每次 CI）
- 演示视频：<https://www.bilibili.com/video/BV151sH6EE81>
- 前一代（先导实验，Android）：<https://github.com/Baizhi-Angelica/IndexTranslate_OnXiaomi>

真机基线数据（iPad Pro M5，Q4_K_M，26/26 层 Metal offload）：

| 指标 | 实测 |
|---|---|
| prefill | 44,000–48,000 tok/s |
| decode | 40–73 tok/s（20–30 token 的译文约 70） |
| 单句翻译（prefill+decode） | **166–430 ms** |
| 首次启动 Metal 内核编译 | 约 173 s（一次性），之后冷启动约 0.3 s |
| Q8_0 vs Q4_K_M | 延迟几乎相同（1.98 GB vs 1.25 GB） |

---

## 2. 这个项目是怎么造出来的（关键：本机没有 Mac）

整条链路是围绕"**Windows-only**"设计的，别绕回头去折腾 Mac：

```
Windows（本机）                          GitHub Actions（macos-26 / Xcode 26）
  ├─ 写 Swift / C / XcodeGen 描述 ───────▶ xcodegen generate
  ├─ git push ───────────────────────────▶ xcodebuild（CODE_SIGNING_ALLOWED=NO）
  │                                         → Payload/ITXTranslate.app
  │                                         → Verify bundle（ipa < 3 MB 直接失败）
  │                                         → ITXTranslate-unsigned.ipa
  └─ 下载 ipa ◀───────────────────────────  ← Releases / artifact
       │
       └─ Sideloadly + 免费 Apple ID 重签 → USB → iPad（7 天有效）
```

**改一行 Swift 也要走一次 CI**（约 1–2 分钟）。所以本地写代码的唯一纪律是：**一次只改一簇相关的逻辑**，让编译器帮你一次报完错。历史上这个项目第一次 CI 就编过了，原因不是运气，是写之前把 Apple API 签名、llama.h 的函数原型全都抓下来核过（见 `PLAN.md`）。

---

## 3. 那些"看起来可以，但其实不行"的路（别再试）

| 想法 | 为什么不行 |
|---|---|
| 用 `xtool` 在 Windows 本地编 iOS | 实际要 WSL2 + USB 直通 + 下整个 Xcode.xip（10 GB+），前置成本远高于收益；GitHub Actions 免费且稳 |
| 让模型自己猜语种（中/英方向） | 上一代踩过：61 条字幕 26 条没译文。方向必须锚定**转写文本里有没有汉字** |
| 只用"请保留英文原样"这类软约束 | 实测按词保留率只有 52%；换成身份术语表 `X→X` 后到 99% |
| 用占位符 `{0}` 替换英文词再还原 | 实测 97%/91%，还会丢占位符，且多了还原逻辑；不如术语表 |
| 把模型打进 ipa | 1.25 GB 的包，签名/安装都要多花几分钟，而且换模型要重新出包 |
| 短句切得更碎来降延迟 | 上一代实测：切到 2–3 秒模型会自己补全甚至编造后半句 |
| `URLSession.download(from:delegate:)` 的 async 版拿下载进度 | **在真机上不回调 `didWriteData`**（服务端明明有 Content-Length）。见 `PITFALLS.md`，改成自己收流写盘 |
| 给手动导入的模型加校验 | 会挡住以后换模型/换格式；校验只放在两个下载按钮里 |

---

## 4. 我留下的、你可以直接用的东西

| 位置 | 内容 |
|---|---|
| `.github/workflows/build-ipa.yml` | 下载 xcframework → XcodeGen → 编译 → 打 ipa → 校验 bundle → 发预发布 |
| `.github/workflows/probe-speech.yml` | 在 macOS runner 上探测 `SpeechTranscriber.supportedLocales`（装机前确认语言支持用） |
| `Sources/` | App 全量源码；`AppModel.swift`（~950 行）是最复杂的状态机，改动要先读它 |
| `tools/regress_prompts.py`、`tools/ab_english.py` | 用本机 llama-server 跑 120 次 prompt 回归 / 4 种策略 A/B；**改 prompt 必须跑** |
| `docs/REALMACHINE-NOTES.md` | 真机实测数据、31 个 ASR 语言、Metal 编译开销、Q8/Q4 对比 |
| `IndexTranslate_iPadM5视频/` | 视频流水线：`script.py`（分镜）→ `make_tts.py`（小米 MiMo 茉莉）→ `make_slides.py`（Chrome 渲染幻灯片）→ `align_subs.py` → `make_video.py`；`tools/srt2bcc.py` 是修好空格 bug 的 BCC 转换器（原作者的 PR：<https://github.com/justCwhite/SRT_TO_BCC/pull/1>） |
| `.dsh-tmp/README.md` | 本机临时目录（模型、llama 二进制、视频输入、素材）的结构与重建命令 |

---

## 5. 我其实没完全验证过的地方（诚实清单）

别把它们当"已完成"：

1. **自动模式的双识别器**（ⓘ 里那个实验开关）：逻辑写好了（两路到齐或 1200 ms 后按字符集选一路），但只在真机上试过少数几句。默认是关的，默认路径只跑 zh-CN。
2. **SFSpeechRecognizer 降级后端**：`SpeechAnalyzer` 在 macOS VM 上探测为 `isAvailable = false`，真机上是 true，所以降级路径**从没被真实触发过**。要测，可以临时在 `ASRFactory` 里强制返回 `LegacyASR()`。
3. **下载不完整/断点续传**：现在只有"字节数够不够"的校验，没有断点续传；网络断了要整包重下。
4. **SHA-256 校验**：官方仓库有 `SHA256SUMS.txt`，App 里没做（下载源可能被中间替换，虽然目前三个源都验过是同一份文件）。
5. **iPhone 布局**：按 `horizontalSizeClass` 做了紧凑档，但**没有真机跑过**。
6. **Metal 首次编译 173 s**：只在真机日志里观测到，没有做前置预热或进度提示；第二次启动 0.3 s（管线缓存命中），但缓存会不会被系统清掉没测。
7. **免费签名 7 天**：Sideloadly 的 auto-refresh 需要电脑开机 + 同 Wi-Fi；这条是用户侧的，代码无关。
8. **长会话上下文**：每句都 `llama_memory_clear`，句与句之间无上下文，模型不会"串味"，但也翻不了指代依赖前文的长对话。

---

## 6. 下次接手怎么跑（可直接复制的命令）

```powershell
$repo = 'Baizhi-Angelica/IndexTranslate_iPadM5'
$gh   = "$env:LOCALAPPDATA\Programs\GitHub CLI\bin\gh.exe"

# 改动 → 推 → 看 CI（push 用 token URL，见 PITFALLS）
& $gh run list --repo $repo --limit 3
& $gh run view <run-id> --repo $repo --log     # 需要把 LOCALAPPDATA 指到工作区内，否则沙箱拒绝写缓存

# 发正式版
& $gh release create vX.Y.Z <ipa> --repo $repo --title "..." --notes-file notes.md --latest

# 本机 prompt 回归（先起服务，模型在 .dsh-tmp\models）
& "$root\.dsh-tmp\deps\llama-windows\llama-server.exe" -m "$root\.dsh-tmp\models\Index-Translate-2B.Q4_K_M.gguf" --port 8089 -c 2048 -t 8 --jinja
python ..\IndexTranslate_iPadM5\tools\regress_prompts.py --limit 12
python ..\IndexTranslate_iPadM5\tools\ab_english.py --strategies s1,s2 --targets ja,ko

# 重出视频（改了 script.py 之后）
cd ..\IndexTranslate_iPadM5视频
python make_tts.py; python make_slides.py --force; python make_video.py
```

**这台机器的坑**（都写在 `AGENTS.md` / `PITFALLS.md` 里，这里只提醒最容易忘的）：
- 走代理 `127.0.0.1:7890`；本机 TLS 走 Schannel 会失败，下载用 Node 的 `fetch` 而不是 curl。
- Chrome headless 需要 `danger-full-access`，否则 crashpad 起不来。
- `gh run view --log` 会写 `%LOCALAPPDATA%` 缓存，沙箱里要临时把它指到工作区内。
- PowerShell 5：`Get-Content`/`Set-Content` 会把 UTF-8 中文读成 GBK 再写坏（本仓库踩过一次，页脚的 `·` 变成了「路」）。**改含中文的文件用 Python，别用 PS 的字符串替换。**

---

## 7. 如果继续做，我会先做这几件

1. **SHA-256 校验**（下载完成后对比官方 `SHA256SUMS.txt`）——成本极低，能挡住镜像被换/被投毒的极端情况。
2. **断点续传 + 失败重试**（`Range` 请求，ModelScope 的 CDN 实测支持 `accept-ranges: bytes`）。
3. **把双识别器测明白**：如果 zh-CN 对纯英文句子的产物稳定为空，就用"zh 为空 → 立刻转 en 再听一遍"的两段式，比并行两路更省电。
4. **首次启动预热**：在 App 启动后后台先跑一次 1 token 的推理，把 Metal 内核编译摊到用户还没点麦克风的时候（现在这 173 s 落在"点下载/打开 App"那一步）。
5. **TestFlight 路线**（$99/年），彻底摆脱 7 天重签。

---

## 8. 给后续模型的几句话

- **这个用户会用真机验，而且验得很细**。她用两张截图就能指出"英文识别器幻觉被翻译"这种逻辑漏洞。所以别拿"应该能跑"交差，先自己找证据（日志、Mach-O、哈希、实测数字）。
- **她的审美很具体**：要数字 + 单位（`48,000 tok/s`），不要汉字数字；旁白要口语；界面要白底大字；不要花哨但要有质感。改 UI 时按她给过的截图和原话改，别自由发挥。
- **先验证再动手**。这个项目里每一个"想当然"都被现实打过：xcframework 其实是动态库、XcodeGen 的 `embed` 不生效、async download 不回调进度、PowerShell 会把中文写坏。花 2 分钟取证，比返工一轮便宜得多。
- **别一次改太多**。CI 1 分半，但用户装机 + 验证是她的时间。把改动按"可独立验证"切块，一块一版。
- **不确定就说不确定**。这份文档第 5 节就是范本：越是"没验证"，越要写清楚。用户在意的是"你到底确不确定"，不是"你看起来多厉害"。
- **小心越过边界**：她的机器上有别的项目（Android 那代、视频工程），改之前先读 `AGENTS.md`；手机上的东西用完要 restore（这项目里做过一次：跑完转写就 `pkill crispasr` + 删临时目录）。
- **最后**：这个项目真正有意思的地方不是"跑通了一个模型"，而是"把一整条云端链路搬到了个人设备上，而且用户自己就能装"。如果下次要往这个方向推，优先级是**离线可靠性**和**可维护性**，不是再堆功能。

---

## 9. 交接检查清单

- [ ] `gh run list` 最新一次是 success；`gh release list` 最新是正式版
- [ ] 下载 ipa 后核对：`Info.plist` 里 `CFBundleShortVersionString` 与 release tag 一致
- [ ] ipa 里 `Payload/ITXTranslate.app/Frameworks/llama.framework/llama` 存在（否则装上必崩）
- [ ] 手机上如有 crispasr 残留进程/临时目录，已清理
- [ ] 改了 prompt → 跑过 `tools/regress_prompts.py` 与 `tools/ab_english.py` 并记下数字
- [ ] 改了视频文案 → `script.py` 与成片时间轴（`投稿信息.md`）同步
- [ ] 新增的"没验证"项，写进本文第 5 节
