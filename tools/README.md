# 翻译 Prompt 回归测试（tools/）

用本机已经跑着的 llama.cpp server 验证 **Index-Translate 翻译 prompt** 的效果：
7 种目标语言的翻译质量、英文词原样保留（english_kept）、空输出、汉字泄漏、延迟/生成速度。

不下载模型、不重启服务、不 pip install（只用 Python 3.9 标准库 urllib）。

## 文件

| 路径 | 说明 |
| --- | --- |
| `tools/segments.py` | 20 条测试语料：12 条中文（每条含 1–3 个英文词/短语）+ 8 条英文日常口语。可直接运行自检：`python tools\segments.py` |
| `tools/regress_prompts.py` | 回归脚本：拼官方 prompt → 调 `/completion` → 清洗输出 → 自动判定 → 写报告 |
| `tools/out/report.md` | 最近一次运行的 Markdown 报告（`tools/out/` 已在 `.gitignore` 里） |
| `tools/out/raw.json` | 最近一次运行的逐条原始数据（含拼好的完整 prompt、原始输出、timings） |

## 前置条件：llama-server 要在 8089 上跑着

脚本只发 HTTP 请求，**不负责起服务、不重启、不杀进程、不占 8089 端口**。当前这台机器上：

- 二进制：`C:\Users\Angelica\Desktop\works\DeepSeek\.dsh-tmp\llama\llama-server.exe`
- 模型：`C:\Users\Angelica\Desktop\works\DeepSeek\.dsh-tmp\dl\Index-Translate-2B-Q4_K_M.gguf`
- 当前实例（`GET /props` 记录）：Q4_K_M，`n_ctx=2048`，`total_slots=4`；14:15 启动，现在活着，**不要重复启动**。

确认服务在：

```powershell
$env:no_proxy = '127.0.0.1,localhost'
Invoke-RestMethod http://127.0.0.1:8089/props | Select-Object model_path, total_slots
```

如果确实没在跑，用下面这条起（等它打印 listening 再用）：

```powershell
$root = 'C:\Users\Angelica\Desktop\works\DeepSeek'
& "$root\.dsh-tmp\llama\llama-server.exe" `
    -m "$root\.dsh-tmp\dl\Index-Translate-2B-Q4_K_M.gguf" `
    --host 127.0.0.1 --port 8089 `
    -c 2048 -np 4
# 有 GPU 想多卸载几层可以加 -ngl 99；只想给这个脚本用，-np 不加也行
```

> 上面的 `-c/-np` 是按当前实例 `/props` 的 `n_ctx=2048`、`total_slots=4` 组合出来的，
> 不保证和当前进程的启动参数逐字一致；本机现在已经有实例在跑时不要再起第二个。

> 本地请求必须绕开代理 `http://127.0.0.1:7890`。脚本内部已经做了两层处理：
> 把 `127.0.0.1/localhost` 加进 `no_proxy`，且对本地 base-url 使用 `ProxyHandler({})`
> 的 opener，所以不用手动设环境变量。用 curl/Invoke-RestMethod 手工测时才需要设 `no_proxy`。

## 怎么跑

在仓库根目录（`IndexTranslate_iPadM5`）执行：

```powershell
python tools\regress_prompts.py                          # 全量：12*6 + 8*6 = 120 次调用
python tools\regress_prompts.py --only zh                # 只跑中文源（72 次）
python tools\regress_prompts.py --only en                # 只跑英文源（48 次）
python tools\regress_prompts.py --limit 12               # 只跑前 12 次（调试/冒烟）
python tools\regress_prompts.py --base-url http://127.0.0.1:8089
python tools\regress_prompts.py --out-dir tools\out-2    # 另存一份，方便和旧报告对比
python tools\regress_prompts.py --n-predict 192 --timeout 180   # 可选参数
```

- 默认 `--base-url http://127.0.0.1:8089`、`--out-dir tools\out`。
- 全量 120 次在本机约 1.5–2 分钟（2B Q4_K_M，40+ tok/s），每 10 条打印一行进度
  （当前累计 PASS/MISS/空输出、最近 10 条平均延迟），不会静默跑。
- 退出码：全部调用成功 → 0；有失败调用 → 1；参数/首条连接失败 → 1/2。
  某个请求失败时会**打印服务端返回体**，并继续跑后面的（第一条就失败则终止）。

### prompt 拼装规则（脚本内）

每条语料 × 合法目标语言（中文源 → 英语/日语/韩语/法语/德语/西班牙语；英文源 → 中文/日语/韩语/法语/德语/西班牙语）：

1. **普通翻译**：中文源 → 英语、英文源 → 任意目标：
   `请将以下{源语言}文本翻译为{目标语言}，直接输出翻译结果，不要进行任何解释。\n\n{正文}`
2. **约束翻译**：仅中文源 → 非英语目标：
   `请将以下中文文本翻译成{目标语言}，并且严格遵循所有约束要求。` + `【源文】` / `【约束要求】` 段落
3. 再套 chatml 外壳（thinking 关闭）：

```
<|im_start|>user\n{用户消息}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n
```

请求体固定：`{"prompt": ..., "n_predict": 192, "temperature": 0, "stop": ["<|im_end|>"]}`。
`/completion` 不套 chat template，所以测的就是我们自己拼的 prompt。

### 输出清洗

对服务端返回的 `content` 依次做：取最后一个 `</think>` 之后的内容（去掉推理段）→
去掉开头残留的 `<think>`/`</think>` → `strip` → 去掉成对引号（`"` `'` `“”` `「」` `『』` `《》`）。
清洗后的文本用于 english_kept / 空输出 / 泄漏判定，原始 `content` 也保留在报告和 raw.json 里。

## 自动判定规则

| 指标 | 规则 |
| --- | --- |
| `english_kept` | 只对**中文源 + 非英语目标**（12 条语料 × 5 个非英语目标 = 60 条）。每个 `english_terms` 不区分大小写、按子串出现在**清洗后输出**里算保留；全中 PASS，缺任意一个 MISS 并列出缺失项。另按 term 逐项统计保留率（一条语料有 2–4 个 term，PASS 要求全中，所以 PASS 率会低于 term 保留率） |
| `empty` | 清洗后输出为空 |
| `has_chinese_leak` | 非中文目标，且输出**汉字数 / 非空白字符数 > 20%**。按严格规则计数 |
| `likely_real_leak` / 报告里的“真实泄漏” | 在 `has_chinese_leak` 基础上排除“日语目标且输出含假名”的正常日语（日语本来就用汉字）。其余情况与严格规则一致 |
| 延迟 | 客户端墙钟时间（含网络/排队），按 target 分组给平均 + 中位 |
| tok/s | 服务端 `timings`：`predicted_n / (predicted_ms/1000)`（生成阶段速度） |

> **日语注意**：日语本来就大量使用汉字（kanji），日译输出汉字占比超过 20% 是正常的，不能据此判定"没翻译"。
> 报告里同时记录 `has_kana`（是否出现平假名/片假名）作为辅助证据：有假名 = 正常日语输出；摘要的
> "关键结论"里会单独给出日语目标全部输出（12 条中文源 + 8 条英文源 = 20 条）的假名命中数，
> 以及剔除日语假名后的“真实中文泄漏”条数。其他非中文目标若汉字占比高，才更可能是真的中文泄漏。

## 怎么读 `tools/out/report.md`

1. **关键结论**：最上面几条直接回答 english_kept 通过率（单条全中 + 按 term 逐项）、空输出条数、汉字泄漏条数（严格 / 真实）、平均/中位延迟与平均 tok/s。
2. **按目标语言汇总表**：每个目标语言的调用数、english_kept（仅中文源）、term 保留率（仅中文源）、平均/中位延迟、平均 tok/s、空输出数、汉字泄漏数。
   横向对比可以看哪个语言最慢、哪个语言最容易丢英文词。
3. **按源语言汇总**：中文源 72 条 vs 英文源 48 条的整体表现。
4. **中文源逐语料 english_kept**：哪条语料在多个语言上丢词（例如品牌名被音译）一眼可见，并列出缺失 term。
5. **MISS 对照**：每条失败的源文 / 要求保留的 term / 缺失项 / 清洗后输出 / 原始输出，用来判断是模型问题还是 prompt 问题。
6. **抽样输出**：每个目标语言抽中文源、英文源各 1 条，用肉眼快速看译文质量与语气。
7. **全部调用明细**：120 行逐条记录（序号、语料、源→目标、模板、延迟、prompt_n、predicted_n、tok/s、保留/空/泄漏、截断输出）；
   失败调用会在该表里显示错误信息。

`raw.json` 结构：

```json
{
  "meta":    {"generated_at": "...", "base_url": "...", "model_path": "...", "n_predict": 192,
              "total_slots": 4, "python": "3.9.13", "elapsed_s": 100.5, ...},
  "summary": {"calls_total": 120, "calls_ok": 120, "english_checked": 60, "english_pass": 17,
              "terms_checked": 165, "terms_kept": 93, "miss": 43, "empty": 0,
              "leak": 7, "real_leak": 0, "avg_ms": ..., "per_target": {...}, "per_segment": {...}},
  "results": [{"id": "zh-01", "source": "chinese", "target": "ja", "target_name": "日语",
               "prompt_type": "constrained", "prompt": "<拼好的完整 prompt>",
               "wall_ms": 812.3, "prompt_n": 210, "predicted_n": 35,
               "prompt_ms": ..., "predicted_ms": ..., "tok_per_s": 43.2,
               "raw_output": "...", "cleaned_output": "...",
               "empty": false, "english_kept": "MISS", "missing_terms": ["library"],
               "has_chinese_leak": false, "likely_real_leak": false,
               "han_ratio": 0.31, "kana_ratio": 0.42}, ...]
}
```

## 回归用法建议

- 改 prompt 前后各跑一次，把 `tools/out/raw.json` 复制成 `raw.before.json` / `raw.after.json`，
  直接对比 `summary.english_pass`、`summary.miss`、`avg_ms`、`avg_tok_s` 和逐 target 的 pass 数。
- 语料想加/改就编辑 `tools/segments.py`（保持 id 唯一，中文语料 `english_terms` 必须真的出现在 text 里），
  改完跑一下 `python tools\segments.py` 自检。
- 同一台机器上不要并发跑多个回归（服务端只有 4 slots，并发会污染延迟统计），脚本内部本来就是顺序请求。

## A/B 实验：英文词保留策略（ab_english.py）

对比 4 种“保住英文词”的 prompt 策略（同一批中文语料 zh-01..zh-12 × 目标语言 ja/ko/fr/es/en）：

| 策略 | 做法 |
| --- | --- |
| S1 基线 | 现有官方方案（中文源→非英语目标用「约束翻译」+ 软性保留要求；zh→en 用普通翻译） |
| S2 术语表 | 自动抽取源文英文片段，拼成硬约束 `专名/术语对照: X→X、Y→Y`（其余同 S1） |
| S3 占位符 | 英文片段换成 `{0}` `{1}`…，普通翻译 prompt + 一句“保留占位符原样”，译文后还原 |
| S4 占位符+术语表 | S3 替换 + S2 术语表（术语表按还原后的英文形式写）+ 占位符保留要求 |

```powershell
python tools\ab_english.py                                     # 4 策略 × 5 目标 × 12 语料 = 240 次调用
python tools\ab_english.py --strategies s1,s2,s3,s4 --targets ja,ko,fr,es,en
python tools\ab_english.py --strategies s1,s2 --targets ja --limit 8   # 冒烟
```

- 产物：`tools/out/ab_english.md`（主表 + 按词保留率/整句全中率矩阵 + 占位符健康度 + 6 组四策略并排样本 + 自动决策建议）、
  `tools/out/ab_raw.json`（含完整 prompt、原始输出、还原后输出、占位符统计）。
- 判定：按词保留率（`english_terms` 保留词数/总词数）、整句全中率、空输出；S3/S4 还统计
  **残留 `{n}`、丢失、重复、空格变体（`{ 0 }`/`{0 }`）**——还原逻辑用 `\{\s*(\d+)\s*\}` 容忍空格变体，
  最终译文里仍残留 `{数字}` 才算残留（必须为 0）。
- 英文片段抽取规则：连续“拉丁字母/空格/连字符”且长度≥2，去重保序（数字/标点/汉字会截断片段）。
- 与回归脚本一样：只发请求、不重启服务；默认同样是 `--base-url http://127.0.0.1:8089`、`--out-dir tools\out`。
