# 装机指南：把 App 装到 iPad 上（Windows 侧）

> 目标：在 Windows 上把 GitHub Actions 编出来的 `ITXTranslate-unsigned.ipa`，用 Sideloadly
> 以 **免费 Apple ID** 重签并装进 iPad Pro M5。全程不需要 Mac。
>
> 一次准备约 15 分钟；之后每次安装/续签约 3 分钟。

---

## 0. 需要准备

| 东西 | 说明 |
|---|---|
| USB-C 数据线 | 必须能传数据（只能充电的线不行） |
| Apple ID + 密码 | 免费账号即可，不需要 $99 开发者账号 |
| iPad 解锁密码 | 配对时会输 |
| 网络 | Sideloadly 要连 Apple 服务器登录，本机需开代理 `127.0.0.1:7890` |

---

## 1. 一次性准备

### 1.1 装 Apple 设备驱动

Windows 上二选一：

- **Microsoft Store → 搜索「Apple 设备」**（Apple Devices，推荐，轻量）
- 或 Apple 官网下载 iTunes（Windows 版）

> Sideloadly 靠这些驱动组件（usbmuxd / AFC）跟 iPad 通信。装完**不用打开**。

### 1.2 装 Sideloadly

1. 打开 <https://sideloadly.io/>
2. 下载 Windows 版（`SideloadlySetup.exe`），安装
3. 若 Windows 提示"未知发布者"，选「仍要运行」

### 1.3 iPad 打开「开发者模式」

1. iPad 先**用数据线连一次电脑**，并在 iPad 上点「信任」+ 输密码
2. iPad → **设置 → 隐私与安全性 → 开发者模式** → 打开
3. 系统要求重启 → 重启后**再确认一次**「打开」

> iPadOS 16 起才有这个开关；它通常要插过电脑才会出现。

### 1.4 确认能连上

打开 Sideloadly，左上角 `iDevice` 下拉应能看到你的 iPad 名字。
看不到就：换根线 / 换 USB 口 / 重新点 iPad 上的「信任」。

---

## 2. 拿到 ipa

每次 GitHub Actions 构建成功都会在 Releases 里挂一个文件：

<https://github.com/Baizhi-Angelica/IndexTranslate_iPadM5/releases>

下载最新的 `ITXTranslate-unsigned.ipa`（约 30–60 MB）。

---

## 3. 安装（每次 3 分钟）

1. 打开 Sideloadly，iPad 用线连上
2. `Apple Account` 填 Apple ID
3. 把 `.ipa` 拖进 `IPA` 框（或点文件夹图标选）
4. 点 **Start**
5. 第一次会弹出登录：输 Apple ID 密码 + 手机上/iPad 上收到的 **6 位双重认证码**
   - 如果提示 "Sign in with app-specific password"，说明账号开了双重认证但 Sideloadly 版本旧，
     升级 Sideloadly 到最新版即可（0.70+）
6. 进度条走完 → iPad 桌面出现 **ITX 翻译**
7. 首次打开若提示「不受信任的开发者」：
   **设置 → 通用 → VPN 与设备管理 → 你的 Apple ID → 信任**
8. 打开 App，允许麦克风、语音识别

---

## 4. 模型文件（1.22 GB）

App 只带界面，模型要单独放进 App 的 Documents 目录。两种办法：

### A. App 内下载（最省事）

启动后在卡片里点 **「下载模型 Q4_K_M（约 1.22 GB）」**。
默认走 `hf-mirror.com` 镜像；如果镜像不通，把地址改成：

```
https://huggingface.co/mrfakename/Index-Translate-2B-mobile-GGUF/resolve/main/Index-Translate-2B-Q4_K_M.gguf
```

### B. 文件 App 手动放

1. 在 iPad 上把模型下好（Safari 下载，或从 iCloud/局域网传进来）
2. 打开「文件」App → **我的 iPad → ITX 翻译**
3. 把 `Index-Translate-2B-Q4_K_M.gguf` 拷进这个文件夹
4. 回到 App，点「重新扫描」或重启 App

> App 的 Info.plist 已开 `UIFileSharingEnabled`，所以「文件」App 能看到这个目录。
> 也可以点 App 里的「从文件导入…」直接选任意位置的 `.gguf`。

---

## 5. 7 天限制怎么处理

免费 Apple ID 签名的 App **有效期 7 天**，到期后打开会闪退或提示"无法验证"。

- 处理：重新打开 Sideloadly，再点一次 **Start**（同样的 ipa 即可）
- 数据不会丢：模型文件在 App 沙盒 Documents 里，覆盖安装会保留
- 想彻底免掉 7 天：买 $99/年开发者账号 + 走 TestFlight，另开路线（见 `docs/PLAN.md`）

---

## 6. 排障

| 现象 | 原因 / 处理 |
|---|---|
| Sideloadly 看不到 iPad | 没装 Apple Devices 驱动 / 线只能充电 / 没点"信任" |
| `Provisioning profile` 报错 | 免费账号 7 天内签太多次设备？等一会重试；或检查 Apple ID 是否能正常登录 <appleid.apple.com> |
| 安装完闪退 | 开发者模式没开；或证书已被吊销（重新 Start 一次） |
| 打开后一片空白/卡在"启动中" | 模型没找到；按第 4 步放模型 |
| 说「需要 iPadOS 26 及以上」 | iPad 系统版本太低，升级到 iPadOS 26 |
| 识别没反应 | 检查 iPad 设置 → 隐私与安全性 → 麦克风/语音识别 是否给了 App 权限 |
| 想换模型（Q6_K / Q8_0） | 换成对应 gguf 放进同一目录，App 会挑体积最大的那个（或精确匹配文件名） |
