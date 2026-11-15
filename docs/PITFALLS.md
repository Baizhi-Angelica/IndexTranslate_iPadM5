# 踩坑记录

> 格式统一为 **现象 → 原因 → 解法**。都是这轮真实踩到的，不是"可能会遇到"。
> 环境：Windows 10 开发机（无 Xcode）+ GitHub Actions `macos-26` + iPad Pro M5（iPadOS 26）。

---

## 1. GitHub Actions：job 根本没启动，报"账号被账单锁"

**现象**

```
The job was not started because your account is locked due to a billing issue.
```

运行记录里 job 4–5 秒就 `failure`，没有任何 step 日志。换成 `ubuntu-latest` 的探测 workflow，**同样是这个错**。

**原因**

账号级锁定（缺账单信息/未清付），不是仓库权限问题，也不是 macOS runner 特有：连免费的 ubuntu 也跑不了。仓库的 Actions 权限本身是 `enabled: true`。

**解法**

去 <https://github.com/settings/billing> 补「Payment information」（账单地址就够，不用绑卡）。补完立刻重跑 `diagnose.yml` 验证：

```powershell
& $gh workflow run diagnose.yml --repo Baizhi-Angelica/IndexTranslate_iPadM5
& $gh run list --repo Baizhi-Angelica/IndexTranslate_iPadM5 --limit 3
```

**预防**：新仓库第一次上 CI，先用一个 15 行的 `diagnose.yml`（ubuntu + macos 各一个 echo job）确认 runner 能起来，再排查代码问题——否则会把"平台没跑"误判成"代码挂了"。

---

## 2. ipa 只有 0.21 MB，装上就闪退（dyld）

**现象**

CI 全绿，产物 `ITXTranslate-unsigned.ipa` 只有约 210 KB。Sideloadly 装完点开，图标闪一下就退。

**原因**

`llama.xcframework` 是**动态库**（`llama.framework/llama` 的 Mach-O 类型是 `MH_DYLIB`），主二进制里有：

```
LC_LOAD_DYLIB   @rpath/llama.framework/llama
LC_RPATH        @executable_path/Frameworks
```

也就是说运行时必须能在 `.app/Frameworks/llama.framework/llama` 找到它。XcodeGen 的 `dependencies: - framework: ... embed: true` 实测**没有生成 Embed Frameworks 阶段**，于是 framework 根本没进 bundle。

**解法**

不依赖 XcodeGen 的 embed，在打包步骤里做确定性拷贝 + 校验：

```yaml
- name: Package IPA
  run: |
    APP="build/Build/Products/Release-iphoneos/ITXTranslate.app"
    if [ ! -d "$APP/Frameworks/llama.framework" ]; then
      mkdir -p "$APP/Frameworks"
      cp -R "build/Build/Products/Release-iphoneos/llama.framework" "$APP/Frameworks/" \
        || cp -R "Frameworks/llama.xcframework/ios-arm64/llama.framework" "$APP/Frameworks/"
    fi
- name: Verify bundle (防 dyld 崩溃)
  run: |
    test -f "Payload/ITXTranslate.app/Frameworks/llama.framework/llama"
    size=$(stat -f%z ITXTranslate-unsigned.ipa)
    if [ "$size" -lt 3000000 ]; then echo "::error::ipa 太小，framework 没嵌入"; exit 1; fi
```

修复后 ipa = 4,035,451 字节。

**预防**：任何"静态/动态"的判断都不要靠猜，直接看产物：

```bash
file build/Build/Products/Release-iphoneos/llama.framework/llama   # MH_DYLIB / MH_OBJECT
otool -L build/Build/Products/Release-iphoneos/ITXTranslate.app/ITXTranslate | grep llama
```

---

## 3. 构建失败时看不到真正的报错

**现象**

`xcodebuild` 挂了，但日志里只有一行 `Error: Process completed with exit code 65.`，看不到任何 `error:` 行，只能反复猜。

**原因**

GitHub Actions 的 `run:` 默认用 `bash -e` 执行。脚本里写了 `xcodebuild ... | tee log`，一旦 xcodebuild 非零退出，`-e` 立刻让脚本结束——后面那段"grep 错误摘要"永远执行不到（死代码）。另外只加 `set -o pipefail` 而不关 `-e` 也没用。

**解法**

先把 `-e` 关掉，再自己判退出码：

```yaml
run: |
  set +e
  set -o pipefail
  xcodebuild ... build 2>&1 | tee /tmp/build.log
  status=$?
  if [ "$status" -ne 0 ]; then
    grep -n -E "error:|error;|fatal error|The following build commands failed" /tmp/build.log | head -120 || true
    exit "$status"
  fi
```

**预防**：CI 里所有"跑一个可能失败的长命令 + 事后分析日志"的步骤，都用 `set +e` 显式接管退出码。

---

## 4. `git push` 在沙箱里报 `couldn't create signal pipe, Win32 error 5`

**现象**

```
git :       0 [main] sh (13008) ... *** fatal error - couldn't create signal pipe, Win32 error 5
```

push 结果不确定（有时成功、有时错误码为 0 但没推上去），`gh auth status` 却一切正常。

**原因**

`gh` 的 git credential helper 在受限沙箱里起不了 Cygwin 的信号管道。git 走 helper 取凭据那一步就挂了。

**解法**

临时把 token 塞进 URL 推一次，推完把 remote 还原（**不要把 token 留在 `.git/config`**）：

```powershell
$tok = & $gh auth token
git push -q "https://x-access-token:$tok@github.com/Baizhi-Angelica/IndexTranslate_iPadM5.git" main
git remote set-url origin https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5.git
```

**预防**：脚本里不要用 `~` 表示 HOME（PowerShell 里 `$HOME` 是只读自动变量，且与 `~` 语义不同），一律写绝对路径。

---

## 5. "保留英文原样"写了等于没写

**现象**

中文里夹英文词，翻成日语/韩语后英文词全变成外来语（`library` → 図書館 / 도서관，`presentation` → プレゼン）。60 条样本里只有 40% 的句子把英文词原样保住。

**原因**

"保留英文单词，不要翻译"是**软约束**，模型在"翻译"任务里天然倾向把一切目标语言化；日/韩更严重（它们本来就用外来语拼写英文词）。

**解法**

换成模型官方支持的**硬约束 = 专名/术语对照**，并且让程序自动从源文抽英文片段，生成身份映射 `X→X`：

```
【约束要求】
1. 【硬性要求】专名/术语对照: dining hall→dining hall、library→library
```

结果：按词保留 61.8% → **99.4%**，整句全中 40.0% → **98.3%**。

**预防**：这类"模型不听话"的问题，先看模型卡有没有对应的**约束机制**（这个模型明确支持术语表/占位符/JSON 保护），别急着堆自然语言要求。

---

## 6. 占位符方案看着更"工程"，实际更差

**现象**

把英文词替换成 `{0}` `{1}`，翻完再还原——听起来万无一失。实测：按词保留 97.0%、整句 91.7%，**比术语表还差**，而且 S3 丢 2 个占位符、S4 丢 4 个。

**原因**

1. 模型会按语义改占位符（尤其目标语言是英语时，`{0}` 被"翻译"成具体英文词）；
2. 自动抽取会把 `Dr. Chen` 拆成 `Dr` 和 `Chen`，`Room 305` 只抽到 `Room`，替换粒度就不对；
3. 多一层还原逻辑 = 多一类 bug（残留学面量、空格变体、重复）。

**解法**

放弃占位符，用术语表（见上一条）。占位符只适合**结构化数据保护**（JSON/代码块），不适合"夹在自然语言里的英文词"。

**预防**：任何"包一层再还原"的方案，先在小样本上数**残留/丢失**，别只看主指标。

---

## 7. 不能把 1.22 GB 的 GGUF 打进 ipa

**现象**

第一版设计想过把模型放进 bundle，一次装好就不用下载。

**原因**

- ipa 变成 1.23 GB，Sideloadly 每次重签/安装从 30 秒变成几分钟（免费账号 7 天就要重签一次）；
- 换量化档（Q4_K_M ↔ Q6_K）就得重新出包；
- iOS 对单文件大 bundle 的校验/解压也更慢。

**解法**

模型走 App 沙盒 `Documents`，三条入口：

1. App 内下载（默认 `hf-mirror.com`，可在界面里改 URL）；
2. 「文件」App → 我的 iPad → ITX 翻译（`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`）；
3. App 内「从文件导入…」（`fileImporter` + security-scoped resource）。

`ModelStore.locateModel()` 优先精确文件名，否则取体积最大的 `*.gguf`，所以换档位只要把文件丢进去。

---

## 8. `SpeechAnalyzer` 是 actor，不是 class

**现象**

按"`final class SpeechAnalyzer`"写代码，实例方法直接调用 → 编译报 `actor-isolated instance method cannot be referenced from a non-isolated context`。

**原因**

Apple 文档的 API 摘要里它是 `final actor`（`start(inputSequence:)`、`prepareToAnalyze(in:)`、`finalizeAndFinishThroughEndOfInput()` 都是 actor 隔离的）。

**解法**

所有实例方法调用都写 `await`；构造器是 nonisolated 同步 init，不能加 `await`：

```swift
let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
try await analyzer.prepareToAnalyze(in: format)
try await analyzer.start(inputSequence: stream)
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

**预防**：新框架落地前，用 `https://developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json` 直接取 `declarations` 字段核对，比看网页摘要准。

---

## 9. 第一次点麦克风"卡"十几秒

**现象**

真机首次启动，点麦克风后长时间没反应，以为死机。

**原因**

`SpeechTranscriber` 的语音模型是**按语言下载的系统资产**。首次使用某语言时，`start()` 里要 `AssetInventory.assetInstallationRequest(...).downloadAndInstall()`，几十 MB，视网络几十秒。

**解法**

- 启动时先查 `AssetInventory.status(forModules:)`，界面显示「正在准备语音模型…」；
- `AppModel` 用 `isStartingListening` 之类的过程态，避免用户重复点；
- 文档里明确写"首次使用需要网络"。

**预防**：把"首次运行需要的网络操作"当成产品的一部分写进 UI 与文档，而不是当成异常。

---

## 10. 加载日志里一堆 `unused tensor blk.24.*` 警告

**现象**

```
W model has unused tensor blk.24.attn_norm.weight (size = 8192 bytes) -- ignoring
... （十几行）
```

**原因**

这个 GGUF 保留了 1 层 MTP（multi-token prediction）块，llama.cpp 默认不加载（`llama_model_params.load_mtp` 默认 false），所以把这些 tensor 全部忽略。

**解法**

不用管。模型卡片也写了：MTP draft 模式在 CPU 上实测没有加速。真要用需要显式开 `load_mtp` 并配 MTP context，收益不明。

**预防**：`--verbose` 级别的 `W` 不等于是故障；判故障看有没有 `E`、以及 `llama_init_from_model` 是否返回 NULL。

---

## 11. 设备上没有控制台，报错只能靠猜

**现象**

iPad 上模型加载失败/推理返回负值，界面只有"加载失败"，Windows 上没有任何日志可看。

**原因**

iOS App 的 stderr 只有在 Xcode 里跑或连 Console.app（需要 Mac）时才看得到。

**解法**

在 C 桥里接管 llama.cpp 的日志回调，同时写内存环和文件：

```c
llama_log_set(itx_log_callback, NULL);   // 内存 8 KB 环 + fputs(stderr) + fputs(文件)
...
itx_set_log_path(".../Documents/llama.log");
```

Swift 侧在 `LlamaTranslator.init()` 里把路径设成 `Documents/llama.log`，并先清空文件。这样用户可以在「文件」App 里直接把 `llama.log` 发出来。

**预防**：任何"在无调试器设备上跑原生库"的项目，第一版就把日志落盘做进去，不要等出事再加。

---

## 12. Windows 上直接改 Info.plist / YAML，可能写出转义坏文件

**现象**

`Info.plist` 里出现 `&lt;?xml version="1.0"`——整个文件被 HTML 转义了，Xcode 解析直接失败。

**原因**

生成文件时对 XML 做了 HTML 转义（把 `<` `>` 写成 `&lt;` `&gt;`）。

**解法**

写完立刻回读校验：`Get-Content Info.plist -TotalCount 3`，第一行必须是 `<?xml version="1.0" encoding="UTF-8"?>`；或用 Python 校验：

```powershell
python -c "import plistlib;plistlib.load(open(r'Sources\Info.plist','rb'));print('plist ok')"
```

**预防**：写结构化文件（plist / yaml / json）后一律做一次 parse 校验，再提交。
