# 交接笔记：写给下一个接手这个项目的人（或模型）

> 最后更新：2026-11-23，对应 `index-translate v1.2.0-beta.1`（稳定版仍是 v1.1.0）。
> 先读这份，再读 `AGENTS.md`（硬约束）、`PLAN.md`（决策）、`PITFALLS.md`（踩坑）。
> 这份的语气会比较直白：它记的是"当时为什么这么做"，以及"哪些地方我其实没把握"。

---

## 1. 一句话现状

**iPad Pro M5 上已经有一个能用的、全离线的语音翻译 App**：说 8 种语言之一（中/英/日/韩/法/德/西/意）→ 系统 `SpeechAnalyzer` 转写 → `Index-Translate-2B`（GGUF, llama.cpp + Metal）翻译 → 9 种语言输出（多一个俄语，仅输出），中英混说时英文词原样保留。ⓘ 里还能选「翻译需求」（说话场景 / 自定义要求）。代码在 GitHub，ipa 在 Releases，装机靠 Windows + Sideloadly + 免费 Apple ID。

- 仓库：<https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5>
- 最新版：`v1.2.0-beta.1`（翻译需求 + 意大利语输入输出 + 俄语输出；预发布，<https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5/releases/tag/v1.2.0-beta.1>）；稳定版 `v1.1.0`（7 种输入语言 + 配对窗口 0.7 s）
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

1. **自动模式的双识别器**（ⓘ 里那个实验开关）：逻辑写好了（两路到齐或 700 ms 后按字符集选一路），但只在真机上试过少数几句。默认是关的，默认路径只跑 zh-CN。「自动」在界面上已明确标注为「自动（中/Eng）」，因为它确实只覆盖中英两路。
2. **SFSpeechRecognizer 降级后端**：`SpeechAnalyzer` 在 macOS VM 上探测为 `isAvailable = false`，真机上是 true，所以降级路径**从没被真实触发过**。要测，可以临时在 `ASRFactory` 里强制返回 `LegacyASR()`。
3. **下载不完整/断点续传**：现在只有"字节数够不够"的校验，没有断点续传；网络断了要整包重下。
4. **SHA-256 校验**：官方仓库有 `SHA256SUMS.txt`，App 里没做（下载源可能被中间替换，虽然目前三个源都验过是同一份文件）。
5. **iPhone 布局**：按 `horizontalSizeClass` 做了紧凑档，但**没有真机跑过**。
6. **Metal 首次编译 173 s**：只在真机日志里观测到，没有做前置预热或进度提示；第二次启动 0.3 s（管线缓存命中），但缓存会不会被系统清掉没测。
7. **免费签名 7 天**：Sideloadly 的 auto-refresh 需要电脑开机 + 同 Wi-Fi；这条是用户侧的，代码无关。
8. **长会话上下文**：每句都 `llama_memory_clear`，句与句之间无上下文，模型不会"串味"，但也翻不了指代依赖前文的长对话。
9. **意大利语输入**（v1.2.0 新增）：`it-IT` 在真机 `supportedLocales` 的 31 个语言里（2026-11-15 实测），代码路径与日/法/德/西完全一致，但**没有真机说过意大利语**。
10. **俄语输出**（v1.2.0 新增）：只依赖翻译模型，Windows CPU 回归里 12 条中文语料 → 俄语 11/12 全中（丢的 1 条是 `clone` 被译成 `клонировал`）；真机质量和排版没验过。
11. **「翻译需求」的语气效果**：Windows CPU 上 5 个场景各跑了 96 次中文源回归（见 §11），但「听起来是不是真的更正式/更亲切」必须真机人耳判断；模型只是软约束，不保证 100% 遵守。

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
6. **能量 VAD 自切句**（2026-11-16 评估后决定**先不做**）：收益是把"等系统识别器定稿"的尾部 0.5–1.5 s 压到约 0.4 s。
   代价是要动核心时序、且必须真机调三个参数（静音阈值 / 最短语音时长 / 冷却），停顿稍长就会切半句。
   若要做，做成 ⓘ 里的开关（默认关）。关键未知：`SpeechAnalyzer.finalize(through:)` 能否稳定把当前 partial 收成 final；
   不行就退化成"直接翻译 partial、等真 final 来了丢弃"，可用但会有偶发重复。

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
- [ ] 改了 `PromptBuilder` / 语言枚举 → `verify-prompts.yml` 绿（396 条 case 逐字节一致）
- [ ] 下载 ipa 后核对：`Info.plist` 里 `CFBundleShortVersionString` 与 release tag 一致
- [ ] ipa 里 `Payload/ITXTranslate.app/Frameworks/llama.framework/llama` 存在（否则装上必崩）
- [ ] 手机上如有 crispasr 残留进程/临时目录，已清理
- [ ] 改了 prompt → 跑过 `tools/regress_prompts.py` 与 `tools/ab_english.py` 并记下数字
- [ ] 改了视频文案 → `script.py` 与成片时间轴（`投稿信息.md`）同步
- [ ] 新增的"没验证"项，写进本文第 5 节

---

## 10. 2026-11-16 收尾：v1.1.0（7 种输入语言）

这一版把输入语言从 2 种扩到 7 种，并修了两个体验问题。真机已验证的部分：

| 验证项 | 结果 |
|---|---|
| English → 日本語 | ✅ 截图见 `docs/images/input-english-japanese.jpg`（prefill 58 tok/1 ms、decode 21 tok/418 ms、50.2 tok/s） |
| Français → 中文 | ✅ 截图见 `docs/images/input-french-chinese.jpg`（prefill 42 tok/2 ms、decode 9 tok/216 ms、41.7 tok/s） |
| 中文/English 原路径 | 行为与 1.0.x 一致（自动模式默认仍只跑 zh-CN） |
| 下载进度条 | 已修（分块下载 + 字节级进度），用户确认"可以下载了" |

**设计取舍**：这 5 种新增源语言用的是**普通 prompt**，只有中文源才套「身份术语表」硬约束。
所以它们夹带的英文词可能被翻掉——这是有意的简化（避免 prompt 变长、也避免给未经 A/B 的语言套约束）。
如果以后要把术语表推广到全部源语言，只需改 `PromptBuilder.userPrompt` 里那个 `source == .chinese` 条件，
但**必须先跑 `tools/ab_english.py` 看数字**，别凭感觉改。

**自动模式**只覆盖 zh-CN + en-US 两路，界面上已标成「自动（中/Eng）」。
不要把它扩展成"按字符集猜 7 种语言"：日语有汉字、韩语有谚文、法德西都是拉丁字母，
靠脚本判断会在边界上反复误判，比让用户明确选一个更糟。

**能量 VAD 自切句**：评估过（见第 7 节第 6 条），本轮决定不做。

### 给下一个接手的人

这个项目已经跑到"用户自己愿意天天用"的程度了。接下来的价值不在加功能，而在：
- 把那 5 种新源语言的**英文词保留**补上（有 A/B 脚本，改完能验证）
- SHA-256 校验、断点续传（都是小而明确的活）
- TestFlight（要花钱，但能彻底解决 7 天重签）

改任何东西之前，先跑一遍 `tools/regress_prompts.py` 存个基线，然后才动手。
这个仓库里"看起来没问题但真机不工作"的坑已经踩过四次（动态库、embed、下载进度、PowerShell 编码），
**永远先取证，再下结论**。

---

## 11. 2026-11-23：v1.2.0-beta.1（翻译需求 + 意大利语 / 俄语输出）

对应 issue #4。这一轮只动了 UI + prompt 拼装 + 语言枚举，**没动**推理/ASR/下载链路。

### 做了什么

1. **「翻译需求」**（ⓘ → 翻译需求）：
   - 一级菜单只显示当前已选/已输入的内容（默认 / 场景名 / `自定义：…`），点进二级页面。
   - 二级页面：5 个中文场景（严肃会议 / 朋友小聚 / 初见新朋友 / 旅行中求助 / 陌生人随便聊聊）
     + 自定义文本框（多行）+ 「实际加进 prompt 的约束」预览。
     场景与自定义**二选一**：点场景覆盖文本，改文本就变成自定义（和用户确认过）。
   - 底部 ☑️ + 蓝色文字「保存这次的需求，下次默认使用」：勾选才写 `UserDefaults`
     （`itx.instruction.save` / `itx.instruction.text`）；不勾选 = 退出即清空（issue #4 的要求）。
   - prompt 侧：对齐官方 `inference/llm/call_api.py::build_prompt`——自由文本按行渲染成
     `【注意】…`（行首序号会去掉；已带【硬性要求】/【注意】/【软性要求】的行原样保留），
     中文源→非英语时身份术语表仍是第一条【硬性要求】。`instruction` 为空时 prompt 与 v1.1.0 逐字节一致。
2. **语言**：输入 + `Italiano`（`it-IT`），输出 + `Italiano` / `Русский`。
   俄语**只做输出**：真机 `supportedLocales` 31 个语言区里没有 `ru-RU`（有 `it-IT`），
   用户也确认这版先不做俄语输入（未来要走 `DictationTranscriber`，见 PLAN §2）。
3. **工具**：
   - `regress_prompts.py` 的 prompt 拼装补齐成当前 App 的**术语表**版本（此前脚本还停在软约束版本，
     历史报告的 28.3% 是软约束数字，不是 App 行为），新增 `--preset` / `--instruction` / `--targets`。
   - 新增 `tools/verify_prompts.py` + `tools/verify_prompt_swift/PromptVerify.swift` +
     `.github/workflows/verify-prompts.yml`：在 macos-26 上把 `Core.swift` + `InstructionPresets.swift` +
     `Prompts.swift` 编成小可执行文件，跑 396 条 case，和 Python 镜像**逐字节**比对。
     以后 Swift 或 Python 任意一边漂移，CI 会红——这是本轮最值钱的基础设施。

### 回归数字（Windows CPU，Q4_K_M，`tools/regress_prompts.py`）

| 场景 | 调用 | english_kept | term 保留 | 空输出 | 平均延迟 |
|---|---:|---:|---:|---:|---:|
| 默认（无翻译需求） | 160（中文 96 / 英文 64） | **83/84 (98.8%)** | 230/231 | 0 | 683 ms（中文源 786 ms） |
| 严肃会议（中文源） | 96 | 82/84 (97.6%) | 229/231 | 0 | 912 ms |
| 朋友小聚（中文源） | 96 | 82/84 (97.6%) | 229/231 | 0 | 899 ms |
| 初见新朋友（中文源） | 96 | 82/84 (97.6%) | 229/231 | 0 | 922 ms |
| 旅行中求助（中文源） | 96 | 83/84 (98.8%) | 230/231 | 0 | 902 ms |
| 陌生人随便聊聊（中文源） | 96 | 82/84 (97.6%) | 229/231 | 0 | 903 ms |

按目标语言（默认路径）：意大利语 12/12（33/33 term）、俄语 11/12（32/33，唯一 MISS 是
`zh-12` 的 `clone` 被译成 `клонировал`），日韩法德西全部 12/12；日语目标的 5 条"严格汉字泄漏"
都是正常的日语汉字（有假名），真实中文泄漏 0。

5 个场景各自的 MISS（除共同的 `zh-12→ru / clone` 外）：
严肃会议多丢 `zh-12→it / clone`；朋友小聚多丢 `zh-02→ru / debug`；初见新朋友多丢 `zh-11→fr / HR`；
陌生人随便聊聊多丢 `zh-07→ko / meeting`。都是 84 条里的 1–2 条，和场景没有系统性关系（默认路径也有 1 条）。

**成本**：翻译需求让中文源的 prompt 从平均 91 token 涨到 110–113 token（+约 20 token），
Windows CPU 上平均延迟 +约 110 ms；真机 prefill 44,000 tok/s，折算不到 1 ms，可忽略。

**语气对照**（同一句中文 `zh-07` → 日语，肉眼可见场景生效）：

| 场景 | 译文 |
|---|---|
| 默认 | 午後の3時のmeetingはZoomに切り替わったので、calendarを更新するのを忘れずに。 |
| 严肃会议 | 午後の3時のmeetingはZoomに変更になりました。calendarを更新するのを忘れないようにしてください。 |
| 朋友小聚 | 午後の3時のmeetingがZoomに変わったから、calendarを更新するのを忘れずに。 |
| 陌生人随便聊聊 | 午後の3時のmeetingはZoomに切り替わりました。calendarを更新するのを忘れないように。 |

> 注意：这轮的中文源→非英语 english_kept 是 **98.8%**，因为脚本终于和 App 一样用了术语表。
> 历史上 `tools/out/report.md` 里的 28.3% 是旧脚本的"软约束"模板，别拿两个数字直接比。

### 没验证的地方

- 意大利语输入没在真机上说过；俄语输出没在真机上看过质量/排版；「翻译需求」的语气效果只能人耳判断。
- `verify-prompts.yml` 首次跑通要确认 macOS 侧 swiftc 编译没问题（本地 Windows 无法预演）。
- 场景文案是这一轮临时拟的（5 句中文），用户如果觉得语气不对，改
  `Sources/InstructionPresets.swift` + `tools/regress_prompts.py::INSTRUCTION_PRESETS`（两处逐字一致），
  再跑回归 + verify-prompts 即可，不用动 UI 结构。

### 下次可以直接接着做

1. 俄语输入：`DictationTranscriber` 兜底（Apple 听写引擎，社区项目验证过 ru-RU）。
   需要把 `SpeechAnalyzerASR` 的 transcriber 泛化成 Speech/Dictation 两种（都 conform `SpeechModule`）。
2. SHA-256 校验 / 断点续传（v1.1.0 遗留）。
3. 术语表可编辑（和「翻译需求」共用 UI 形态）。
