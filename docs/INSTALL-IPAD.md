# 装机指南：把 App 装到 iPad 上（Windows 侧）

> 目标：在 Windows 电脑上把 GitHub Actions 编出来的 `ITXTranslate-unsigned.ipa`，用 Sideloadly
> 以**免费 Apple ID** 重签并装进 iPad（iPadOS 26+）。全程不需要 Mac。
>
> 一次准备约 15 分钟；之后每次安装 / 7 天续签约 3 分钟。

## 0. 需要准备

| 东西 | 说明 |
|---|---|
| iPad | 系统 **iPadOS 26 或更新**（`SpeechAnalyzer` 要求；老系统会降级到旧识别器，功能受限） |
| USB-C 数据线 | 必须能传数据（只能充电的线不行） |
| Apple ID + 密码 | 免费账号即可，不需要 $99/年 开发者账号 |
| iPad 解锁密码 | 配对时要输 |
| Windows 电脑 | 需要能联网（Sideloadly 要登录 Apple 服务器） |

---

## 1. 一次性准备

### 1.1 装 Apple 设备驱动（从 Apple 官网下）

Sideloadly 本身不带驱动，它依赖 Apple 的移动设备驱动（usbmuxd / AFC）跟 iPad 通信。Windows 上装下面**任一**即可：

| 装什么 | 下载地址 | 说明 |
|---|---|---|
| **iTunes（Windows 版）** | <https://www.apple.com/itunes/download/win64> | 最常用；装完不用打开 |
| **iCloud for Windows（新版驱动）** | <https://support.apple.com/zh-cn/downloads> | 同样会装 Apple 设备驱动；不想装 iTunes 就选它 |

> 装完**不需要**打开 iTunes/iCloud，也不用登录。只要驱动装上了就行。

### 1.2 装 Sideloadly

1. 打开 <https://sideloadly.io/>
2. 下载 Windows 版（`SideloadlySetup.exe`）并安装
3. 若 Windows 提示"未知发布者"，选「仍要运行」

### 1.3 iPad 打开「开发者模式」

1. 先用数据线把 iPad 连一次电脑，iPad 上点「信任」，输入解锁密码
2. iPad → **设置 → 隐私与安全性 → 开发者模式** → 打开
3. 系统要求重启 → 重启后再**确认一次**「打开」

> iPadOS 16 起才有这个开关，而且通常是插过电脑之后才会出现。

### 1.4 确认能连上

打开 Sideloadly，左上角 `iDevice` 下拉里应能看到你的 iPad 名字。

看不到就依次试：换一根数据线 → 换一个 USB 口 → 拔插后重新点 iPad 上的「信任」 → 重启 Sideloadly。

---

## 2. 下载 ipa

两个来源，内容一样：

1. **GitHub Releases（推荐）**：<https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5/releases>
   下载 `ITXTranslate-unsigned.ipa`（约 5–10 MB）
2. 仓库里的 `release/ITXTranslate-unsigned.ipa`

这个包是**未签名**的，下一步用你的 Apple ID 重签。

---

## 3. 安装（每次约 3 分钟）

1. 打开 Sideloadly，iPad 用数据线连上
2. `Apple Account` 填你的 Apple ID
3. 把 `.ipa` 拖进 `IPA` 框（或点文件夹图标选择）
4. 点 **Start**
5. 首次会弹登录：输入 Apple ID 密码 + 收到的 **6 位双重认证码**
   - 若提示需要 "app-specific password"，把 Sideloadly 升级到最新版（0.70+）即可
6. 进度条走完 → iPad 桌面出现 **index-translate**
7. **首次打开**若提示「不受信任的开发者」：
   **设置 → 通用 → VPN 与设备管理 → 你的 Apple ID → 信任**
8. 打开 App，允许**麦克风**权限

> 「语音识别」权限不会出现在设置里，这是正常的：本 App 用的 `SpeechAnalyzer` 不需要那个权限，
> 只有降级到旧的 `SFSpeechRecognizer` 时才会申请。

---

## 4. 放模型（App 不自带模型）

模型是 IndexTeam / bilibili 以 Apache-2.0 发布的 [Index-Translate-2B](https://huggingface.co/IndexTeam/Index-Translate-2B) GGUF，**不在 ipa 里**，需要你自己放进去。

| 档位 | 文件名 | 体积 | 下载地址 |
|---|---|---:|---|
| **Q4_K_M** | `Index-Translate-2B.Q4_K_M.gguf` | 1,251.4 MB | <https://www.modelscope.cn/models/IndexTeam/Index-Translate-2B-GGUF/resolve/master/Index-Translate-2B.Q4_K_M.gguf> |
| **Q8_0** | `Index-Translate-2B.Q8_0.gguf` | 1,980.5 MB | <https://www.modelscope.cn/models/IndexTeam/Index-Translate-2B-GGUF/resolve/master/Index-Translate-2B.Q8_0.gguf> |

M 系列 iPad 推荐 **Q8_0**（真机实测延迟与 Q4 几乎一样，质量更高）；较老的设备用 Q4_K_M。

### A. App 内下载（最省事）

打开 App，在模型卡片里点 **「下载 Q4_K_M」** 或 **「下载 Q8_0」**。默认走 **ModelScope 国内 CDN**，失败会自动依次回退到 `hf-mirror.com` 和 `huggingface.co`；全部失败时 App 会把每个源的错误原因显示出来。

### B. 手动下载（Safari 里点两下就行）

1. Safari 打开 <https://www.modelscope.cn/models/IndexTeam/Index-Translate-2B-GGUF>
2. 在「模型文件」列表里点 `Index-Translate-2B.Q4_K_M.gguf`（或 `Q8_0`）→ 下载
3. 打开「文件」App → **我的 iPad → index-translate**
4. 把刚下载的 `.gguf` 拖进去（在「下载」文件夹里长按 → 移动）
5. 回到 App，它会自己发现；没发现就点 ⓘ 面板的「刷新」或重启 App

> 文件名不用改，`Index-Translate-2B.Q4_K_M.gguf` 就是 App 认的官方名。ModelScope 的文件与 HuggingFace 官方逐字节一致（LFS 哈希 `044b313d…`）。

### B. 用「文件」App 手动放

1. 在 iPad 上把 `.gguf` 下载好（Safari 下载，或从 iCloud / 局域网 / 另一台电脑传进来）
2. 打开「文件」App → **我的 iPad → index-translate**
3. 把 `.gguf` 拷进这个文件夹
4. 回到 App：它会自动发现；没发现就点 ⓘ 里的「重新扫描」

> 也可以点 App 里的 **「从文件导入…」**，直接从任意位置选 `.gguf`，App 会把它拷进自己的目录。
>
> 文件名不必精确：App 会列出目录下所有 `.gguf`，可选多个并存，**没手动选过时默认用体积最大的那个**。
> 切换模型在右上角 **ⓘ → 模型** 区。

---

## 5. 首次启动会慢一次（正常）

第一次加载模型时，llama.cpp 要现场特化 36 个 Metal 内核，合计约 **173 秒**（实测 iPad Pro M5）。

- 这是一次性的：管线缓存写进 App 的 Caches 后，之后冷启动约 **0.3 秒**
- 期间界面会停在"加载模型"，不是卡死
- 若每次都要等几分钟，进 ⓘ →「复制诊断」，把日志尾部发出来排查

另外，**首次使用某个语种**时，系统会下载该语种的识别资源（几十 MB，系统级），也需要网络。

---

## 6. 7 天有效期怎么续

免费 Apple ID 签名的 App **7 天后失效**（点开闪退或提示无法验证）。

1. 重新打开 Sideloadly，iPad 连上
2. 同样的 ipa 拖进去，点 **Start**
3. 覆盖安装完成后即可继续用

数据不会丢：模型在 App 沙盒的 `Documents` 里，覆盖安装会保留。想彻底免掉 7 天，需要 $99/年开发者账号（转 TestFlight），见 [PLAN.md](PLAN.md) 的 roadmap。

---

## 7. 排障

| 现象 | 原因 / 处理 |
|---|---|
| Sideloadly 看不到 iPad | 没装 Apple 驱动（iTunes / iCloud for Windows）/ 线只能充电 / 没点「信任」/ 换个 USB 口 |
| `Provisioning profile`、证书相关报错 | Apple ID 登录异常：先在 <https://appleid.apple.com> 确认能登录；免费账号签名次数有限，等一会再试 |
| 装完点开闪退 | 开发者模式没开；或证书过期（重签一次） |
| 「未受信任的开发者」 | 设置 → 通用 → VPN 与设备管理 → 你的 Apple ID → 信任 |
| 打开后一直「未找到本地模型」 | 模型没放对：要放进 **文件 App → 我的 iPad → index-translate**，或点 ⓘ 里的下载按钮 |
| 设置里找不到「语音识别」权限项 | 正常，`SpeechAnalyzer` 不需要它；只要有麦克风权限 |
| 说了话没反应 | 看按钮外圈电平表是否跳动（不跳 = 麦克风权限/输入设备问题）；看「正在听」行是否有文字（有文字但没译文 = 这句还没定稿） |
| 第一次打开等很久 | Metal 内核首次编译约 173 秒，一次性；之后 0.3 秒 |
| 想换 Q8_0 / Q4_K_M | 把另一个 `.gguf` 也放进同一目录，回 App → ⓘ → 模型 里切换 |
| 提示「需要 iPadOS 26 及以上」 | 系统版本不够，升级到 iPadOS 26+ |
| 日语输出里夹汉字 | 正常，日语本来就用汉字 |
