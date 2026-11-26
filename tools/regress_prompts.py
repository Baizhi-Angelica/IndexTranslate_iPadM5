#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""翻译 prompt 回归测试脚本。

对 tools/segments.py 里的每条语料 × 每个合法目标语言，按当前 App 的
PromptBuilder（Sources/MT/Prompts.swift）逐字节拼出 chatml prompt，直接打本机
llama.cpp 的 /completion（不套 chat template，正好验证“我们自己拼的 prompt”），
记录延迟/token 统计、清洗输出，并自动判定：

- english_kept：中文源 + 非英语目标时，english_terms 是否原样（不区分大小写）保留；
- empty：清洗后输出为空；
- has_chinese_leak：非中文目标但输出汉字占比 > 20%。

结果写入 <out-dir>/report.md 和 <out-dir>/raw.json。

用法::

    python tools/regress_prompts.py                    # 全量 160 次调用
    python tools/regress_prompts.py --only zh          # 只跑中文源（96 次）
    python tools/regress_prompts.py --only en --limit 12
    python tools/regress_prompts.py --targets it,ru    # 只测新增的输出语言
    python tools/regress_prompts.py --preset formalMeeting   # 带「严肃会议」翻译需求
    python tools/regress_prompts.py --instruction "回答尽量简短"
    python tools/regress_prompts.py --base-url http://127.0.0.1:8089

`--preset` / `--instruction` 模拟 App 里「翻译需求」菜单；不传时是 App 的默认路径。
只用 Python 标准库（urllib），不要 pip install。本脚本不会重启/占用服务端，只发请求。
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

import segments as corpus  # noqa: E402  （同目录数据文件）

DEFAULT_BASE_URL = "http://127.0.0.1:8089"
DEFAULT_OUT_DIR = TOOLS_DIR / "out"
DEFAULT_N_PREDICT = 192
DEFAULT_TIMEOUT = 180.0

# (target_key, 官方 prompt 里的中文语言名)
TARGETS = [
    ("en", "英语"),
    ("ja", "日语"),
    ("ko", "韩语"),
    ("fr", "法语"),
    ("de", "德语"),
    ("es", "西班牙语"),
    ("it", "意大利语"),
    ("ar", "阿拉伯语"),
    ("ru", "俄语"),
    ("zh", "中文"),
]
TARGET_NAME = dict(TARGETS)
TARGET_ORDER = [key for key, _ in TARGETS]

# 每条语料的合法目标语言：中文源不出中文，英文源不出英文
TARGETS_BY_SOURCE = {
    "chinese": ["en", "ja", "ko", "fr", "de", "es", "it", "ar", "ru"],
    "english": ["zh", "ja", "ko", "fr", "de", "es", "it", "ar", "ru"],
}

# 内置「翻译需求」场景（与 Sources/InstructionPresets.swift 逐字一致）
INSTRUCTION_PRESETS = {
    "formalMeeting": "请使用正式、准确、克制的语气，适合商务会议或正式场合，避免口语化表达。",
    "friends": "请使用轻松自然、口语化的语气，像朋友之间聊天，句子简短亲切。",
    "newFriends": "请使用礼貌、友善、适度正式的语气，适合初次见面交谈，保持得体和尊重。",
    "travelHelp": "请使用礼貌、直接、简短的语气，清楚说明需要什么帮助，方便对方立刻理解。",
    "smallTalk": "请使用中性、自然、友好但不过分熟络的语气，适合和陌生人闲聊。",
}

# 约束行前缀：已经带标签的行原样保留（对齐官方 build_prompt / PromptBuilder.constraintLines）
CONSTRAINT_TAGS = ("【硬性要求】", "【注意】", "【软性要求】")

LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1", "0.0.0.0"}

# chatml 外壳：thinking 关闭（<think> 后两个换行、</think> 后两个换行）
CHATML_HEAD = "<|im_start|>user\n"
CHATML_TAIL = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"


# ---------------------------------------------------------------------------
# 环境：本地请求必须绕开 127.0.0.1:7890 代理
# ---------------------------------------------------------------------------
def ensure_no_proxy_env() -> None:
    for var in ("no_proxy", "NO_PROXY"):
        parts = [p.strip() for p in os.environ.get(var, "").split(",") if p.strip()]
        lowered = {p.lower() for p in parts}
        for host in ("127.0.0.1", "localhost"):
            if host not in lowered:
                parts.append(host)
                lowered.add(host)
        os.environ[var] = ",".join(parts)


ensure_no_proxy_env()


# ---------------------------------------------------------------------------
# prompt 拼装（与 Sources/MT/Prompts.swift 的 PromptBuilder 保持一致）
# ---------------------------------------------------------------------------
_ENGLISH_TERM_RE = re.compile(
    r"[A-Za-z][A-Za-z0-9'’\-.&]*(?:[ \t]+[A-Za-z][A-Za-z0-9'’\-.&]*)*")


def extract_english_terms(text: str, limit: int = 12) -> list:
    """与 PromptBuilder.englishTerms 相同：连续拉丁词（允许空格/连字符/撇号/点/&），
    去尾部标点、去重保序（不区分大小写）、长度 ≥ 2、最多 limit 个。"""
    ordered = []
    seen = set()
    for match in _ENGLISH_TERM_RE.finditer(text):
        term = match.group(0)
        while term and term[-1] in ".-'":
            term = term[:-1]
        term = term.strip()
        if len(term) < 2:
            continue
        key = term.lower()
        if key in seen:
            continue
        seen.add(key)
        ordered.append(term)
        if len(ordered) >= limit:
            break
    return ordered


def constraint_lines(instruction: str) -> list:
    """与 PromptBuilder.constraintLines 一致：按行拆、去空行、去行首序号、补【注意】。"""
    if not instruction:
        return []
    lines = []
    for raw in instruction.strip().splitlines():
        line = raw.strip()
        if not line:
            continue
        line = line.lstrip("0123456789. ").strip()
        if not line:
            continue
        if line.startswith(CONSTRAINT_TAGS):
            lines.append(line)
        else:
            lines.append("【注意】" + line)
    return lines


def build_user_message(segment: dict, target_key: str, instruction: str = "") -> str:
    """按当前 App 的 PromptBuilder.userPrompt 拼「用户消息」。"""
    source = segment["source"]
    target_prompt_name = TARGET_NAME[target_key]
    text = segment["text"]
    source_prompt_name = corpus.SOURCE_PROMPT_NAMES[source]
    instruction_lines = constraint_lines(instruction)
    uses_glossary = source == "chinese" and target_key != "en"

    if not uses_glossary and not instruction_lines:
        # 通用翻译：无任何约束需求时保持原样（不给 prompt 增重）
        return (
            "请将以下{src}文本翻译为{target}，直接输出翻译结果，不要进行任何解释。\n\n{text}"
        ).format(src=source_prompt_name, target=target_prompt_name, text=text)

    constraints = []
    if uses_glossary:
        terms = extract_english_terms(text)
        if terms:
            constraints.append(
                "【硬性要求】专名/术语对照: " + "、".join(term + "→" + term for term in terms))
        else:
            constraints.append(
                "【硬性要求】保留源文中的英文单词、专有名词、品牌名和缩写原样输出，"
                "不要翻译、不要改写、不要音译。")

    if instruction_lines:
        constraints.extend(instruction_lines)
    else:
        constraints.append("【注意】自然口语风格。")

    reqs = "\n".join("%d. %s" % (index + 1, constraint)
                     for index, constraint in enumerate(constraints))
    return (
        "请将以下{src}文本翻译成{target}，并且严格遵循所有约束要求。\n\n"
        "【源文】\n{text}\n\n"
        "【约束要求】\n{reqs}\n\n"
        "只输出译文，不要有任何额外说明。"
    ).format(src=source_prompt_name, target=target_prompt_name, text=text, reqs=reqs)


def build_prompt(segment: dict, target_key: str, instruction: str = "") -> str:
    return CHATML_HEAD + build_user_message(segment, target_key, instruction) + CHATML_TAIL


def prompt_type(segment: dict, target_key: str, instruction: str = "") -> str:
    if constraint_lines(instruction):
        return "constrained"
    return "constrained" if segment["source"] == "chinese" and target_key != "en" else "plain"


# ---------------------------------------------------------------------------
# 输出清洗 & 判定
# ---------------------------------------------------------------------------
PAIRED_QUOTES = {
    ('"', '"'),
    ("'", "'"),
    ("“", "”"),
    ("‘", "’"),
    ("「", "」"),
    ("『", "』"),
    ("《", "》"),
}


def _strip_leading_think_tokens(text: str) -> str:
    while True:
        stripped = text.lstrip()
        for token in ("<think>", "</think>"):
            if stripped.startswith(token):
                text = stripped[len(token):]
                break
        else:
            return stripped


def strip_paired_quotes(text: str) -> str:
    text = text.strip()
    for _ in range(5):
        if len(text) >= 2 and any(text[0] == a and text[-1] == b for a, b in PAIRED_QUOTES):
            text = text[1:-1].strip()
        else:
            break
    return text


def clean_output(raw: str) -> str:
    """去掉 </think> 之前的推理段、开头残留 <think>/</think>、首尾空白、成对引号。"""
    text = raw or ""
    marker = "</think>"
    pos = text.rfind(marker)
    if pos != -1:
        text = text[pos + len(marker):]
    text = _strip_leading_think_tokens(text)
    return strip_paired_quotes(text.strip())


def _in_ranges(code: int, ranges) -> bool:
    return any(low <= code <= high for low, high in ranges)


HAN_RANGES = [
    (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF),
    (0xF900, 0xFAFF),
    (0x20000, 0x2FA1F),
]
KANA_RANGES = [
    (0x3040, 0x309F),   # 平假名
    (0x30A0, 0x30FF),   # 片假名
    (0x31F0, 0x31FF),
    (0xFF66, 0xFF9D),
]
HANGUL_RANGES = [
    (0x1100, 0x11FF),
    (0x3130, 0x318F),
    (0xA960, 0xA97F),
    (0xAC00, 0xD7AF),
]


def is_han(ch: str) -> bool:
    return _in_ranges(ord(ch), HAN_RANGES)


def is_kana(ch: str) -> bool:
    return _in_ranges(ord(ch), KANA_RANGES)


def is_hangul(ch: str) -> bool:
    return _in_ranges(ord(ch), HANGUL_RANGES)


def script_ratios(text: str) -> dict:
    """返回汉字/假名/谚文占“非空白字符”的比例。"""
    chars = [ch for ch in text if not ch.isspace()]
    total = len(chars) or 1
    han = sum(1 for ch in chars if is_han(ch))
    kana = sum(1 for ch in chars if is_kana(ch))
    hangul = sum(1 for ch in chars if is_hangul(ch))
    return {
        "chars": len(chars),
        "han": han,
        "kana": kana,
        "hangul": hangul,
        "han_ratio": han / total,
        "kana_ratio": kana / total,
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class ServerError(RuntimeError):
    pass


def make_opener(base_url: str):
    host = (urllib.parse.urlsplit(base_url).hostname or "").lower()
    if host in LOCAL_HOSTS:
        # 本地服务：显式禁用所有代理，避免被 127.0.0.1:7890 拦截
        return urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener()


def http_get(opener, url: str, timeout: float):
    req = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")


def post_completion(opener, base_url: str, prompt: str, n_predict: int, timeout: float):
    """调 /completion，返回 (wall_ms, response_json)。失败时把服务端返回体带进异常。"""
    url = base_url.rstrip("/") + "/completion"
    payload = {
        "prompt": prompt,
        "n_predict": n_predict,
        "temperature": 0,
        "stop": ["<|im_end|>"],
    }
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    started = time.perf_counter()
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise ServerError(
            "HTTP %s %s（服务端返回体）: %s" % (exc.code, exc.reason, detail[:4000])
        ) from None
    except urllib.error.URLError as exc:
        raise ServerError(
            "连接失败: %s（llama-server 是否在 %s 监听？）" % (exc.reason, base_url)
        ) from None
    except TimeoutError as exc:  # pragma: no cover - 网络超时
        raise ServerError("请求超时（%.0fs）: %s" % (timeout, exc)) from None

    wall_ms = (time.perf_counter() - started) * 1000.0
    try:
        obj = json.loads(body)
    except ValueError:
        raise ServerError("返回体不是合法 JSON（服务端返回体）: %s" % body[:4000]) from None
    return wall_ms, obj


def extract_timings(obj: dict) -> dict:
    timings = obj.get("timings") or {}
    prompt_n = int(timings.get("prompt_n") or 0)
    predicted_n = int(timings.get("predicted_n") or 0)
    prompt_ms = float(timings.get("prompt_ms") or 0.0)
    predicted_ms = float(timings.get("predicted_ms") or 0.0)
    tok_per_s = None
    if timings.get("predicted_per_second"):
        tok_per_s = float(timings["predicted_per_second"])
    elif predicted_ms > 0:
        tok_per_s = predicted_n / (predicted_ms / 1000.0)
    return {
        "prompt_n": prompt_n,
        "predicted_n": predicted_n,
        "prompt_ms": prompt_ms,
        "predicted_ms": predicted_ms,
        "tok_per_s": tok_per_s,
    }


# ---------------------------------------------------------------------------
# 单条测试
# ---------------------------------------------------------------------------
def run_one(opener, base_url: str, segment: dict, target_key: str,
            n_predict: int, timeout: float, instruction: str = "") -> dict:
    prompt = build_prompt(segment, target_key, instruction)
    wall_ms, obj = post_completion(opener, base_url, prompt, n_predict, timeout)
    timings = extract_timings(obj)
    raw_output = obj.get("content")
    if raw_output is None:
        raw_output = ""
    if not isinstance(raw_output, str):
        raw_output = str(raw_output)
    cleaned = clean_output(raw_output)
    ratios = script_ratios(cleaned)

    missing = []
    english_kept = None
    if segment["source"] == "chinese" and target_key != "en":
        lowered = cleaned.lower()
        missing = [term for term in segment["english_terms"] if term.lower() not in lowered]
        english_kept = "PASS" if not missing else "MISS"

    record = {
        "id": segment["id"],
        "source": segment["source"],
        "source_name": corpus.SOURCE_PROMPT_NAMES[segment["source"]],
        "target": target_key,
        "target_name": TARGET_NAME[target_key],
        "text": segment["text"],
        "english_terms": list(segment["english_terms"]),
        "prompt_type": prompt_type(segment, target_key, instruction),
        "prompt": prompt,
        "instruction": instruction,
        "wall_ms": wall_ms,
        "prompt_n": timings["prompt_n"],
        "predicted_n": timings["predicted_n"],
        "prompt_ms": timings["prompt_ms"],
        "predicted_ms": timings["predicted_ms"],
        "tok_per_s": timings["tok_per_s"],
        "raw_output": raw_output,
        "cleaned_output": cleaned,
        "empty": len(cleaned) == 0,
        "english_kept": english_kept,
        "missing_terms": missing,
        "has_chinese_leak": target_key != "zh" and ratios["han_ratio"] > 0.20,
        # 日语天然使用汉字：汉字占比高但同时有假名 → 正常日语输出，不算真实中文泄漏
        "likely_real_leak": (
            target_key not in ("zh",)
            and ratios["han_ratio"] > 0.20
            and not (target_key == "ja" and ratios["kana"] > 0)
        ),
        "han_ratio": ratios["han_ratio"],
        "kana_ratio": ratios["kana_ratio"],
        "has_kana": ratios["kana"] > 0,
        "chars": ratios["chars"],
    }
    return record


# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
def _mean(values):
    return statistics.mean(values) if values else None


def _median(values):
    return statistics.median(values) if values else None


def _ms(value) -> str:
    return "%.0f" % value if value is not None else "—"


def _num(value, digits=1) -> str:
    return ("%." + str(digits) + "f") % value if value is not None else "—"


def summarize(records) -> dict:
    ok = [r for r in records if "error" not in r]
    errors = [r for r in records if "error" in r]
    checked = [r for r in ok if r["english_kept"] in ("PASS", "MISS")]
    miss = [r for r in ok if r["english_kept"] == "MISS"]

    summary = {
        "calls_total": len(records),
        "calls_ok": len(ok),
        "errors": len(errors),
        "empty": sum(1 for r in ok if r["empty"]),
        "leak": sum(1 for r in ok if r["has_chinese_leak"]),
        "real_leak": sum(1 for r in ok if r.get("likely_real_leak")),
        "english_checked": len(checked),
        "english_pass": sum(1 for r in checked if r["english_kept"] == "PASS"),
        "terms_checked": sum(len(r["english_terms"]) for r in checked),
        "terms_kept": sum(len(r["english_terms"]) - len(r["missing_terms"]) for r in checked),
        "miss": len(miss),
        "avg_ms": _mean([r["wall_ms"] for r in ok]),
        "median_ms": _median([r["wall_ms"] for r in ok]),
        "avg_tok_s": _mean([r["tok_per_s"] for r in ok if r["tok_per_s"]]),
        "per_target": {},
        "per_source": {},
        "per_segment": {},
    }

    for key in TARGET_ORDER:
        group = [r for r in ok if r["target"] == key]
        if not group:
            continue
        kept_group = [r for r in group if r["english_kept"] in ("PASS", "MISS")]
        summary["per_target"][key] = {
            "target_name": TARGET_NAME[key],
            "calls": len(group),
            "checked": len(kept_group),
            "pass": sum(1 for r in kept_group if r["english_kept"] == "PASS"),
            "terms_checked": sum(len(r["english_terms"]) for r in kept_group),
            "terms_kept": sum(
                len(r["english_terms"]) - len(r["missing_terms"]) for r in kept_group
            ),
            "avg_ms": _mean([r["wall_ms"] for r in group]),
            "median_ms": _median([r["wall_ms"] for r in group]),
            "avg_tok_s": _mean([r["tok_per_s"] for r in group if r["tok_per_s"]]),
            "empty": sum(1 for r in group if r["empty"]),
            "leak": sum(1 for r in group if r["has_chinese_leak"]),
            "real_leak": sum(1 for r in group if r.get("likely_real_leak")),
            "kana": sum(1 for r in group if r["has_kana"]),
        }

    for source in ("chinese", "english"):
        group = [r for r in ok if r["source"] == source]
        if not group:
            continue
        summary["per_source"][source] = {
            "source_name": corpus.SOURCE_PROMPT_NAMES[source],
            "calls": len(group),
            "avg_ms": _mean([r["wall_ms"] for r in group]),
            "median_ms": _median([r["wall_ms"] for r in group]),
            "avg_tok_s": _mean([r["tok_per_s"] for r in group if r["tok_per_s"]]),
            "empty": sum(1 for r in group if r["empty"]),
            "leak": sum(1 for r in group if r["has_chinese_leak"]),
            "real_leak": sum(1 for r in group if r.get("likely_real_leak")),
        }

    for segment in corpus.CHINESE_SEGMENTS:
        group = [r for r in ok if r["id"] == segment["id"] and r["english_kept"] in ("PASS", "MISS")]
        if not group:
            continue
        summary["per_segment"][segment["id"]] = {
            "calls": len(group),
            "pass": sum(1 for r in group if r["english_kept"] == "PASS"),
            "miss": sum(1 for r in group if r["english_kept"] == "MISS"),
            "missing_terms": sorted({t for r in group for t in r["missing_terms"]}),
        }

    return summary


# ---------------------------------------------------------------------------
# Markdown 报告
# ---------------------------------------------------------------------------
def md_cell(value, limit: int = 60) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\r", " ").replace("\n", " ").replace("|", "\\|")
    text = text.strip()
    if not text:
        return "∅"
    if len(text) > limit:
        text = text[: max(1, limit - 1)] + "…"
    return text


def fmt_pct(part: int, whole: int) -> str:
    return "%d/%d (%.1f%%)" % (part, whole, 100.0 * part / whole) if whole else "—"


def render_report(records, summary, meta) -> str:
    lines = []
    add = lines.append

    add("# 翻译 Prompt 回归测试报告")
    add("")
    add("- 生成时间：%s" % meta["generated_at"])
    add("- 服务端：`%s`" % meta["base_url"])
    if meta.get("model_path"):
        add("- 模型：`%s`（llama.cpp `/props`）" % meta["model_path"])
    else:
        add("- 模型：`/props` 不可用（未记录）")
    if meta.get("total_slots") is not None:
        add("- 服务端 slots：%s" % meta["total_slots"])
    add("- 调用：%d 条（成功 %d / 失败 %d）" % (
        summary["calls_total"], summary["calls_ok"], summary["errors"]))
    add("- prompt 外壳：chatml，thinking 关闭：`<|im_start|>assistant\\n<think>\\n\\n</think>\\n\\n`")
    if meta.get("instruction"):
        preset = meta.get("preset")
        prefix = "场景 `%s`：" % preset if preset else ""
        add("- 翻译需求：%s`%s`" % (prefix, meta["instruction"]))
    else:
        add("- 翻译需求：无（App 默认路径）")
    add("- 模板：中文源→非英语目标用「约束翻译」+ 身份术语表；有翻译需求时所有方向都走「约束翻译」；"
        "其余用「普通翻译」")
    add("- 请求参数：n_predict=%d，temperature=0，stop=[\"<|im_end|>\"]" % meta["n_predict"])
    add("- 机器：Python %s / %s" % (platform.python_version(), platform.platform()))
    add("")

    # ---------- 关键结论 ----------
    add("## 关键结论")
    add("")
    checked = summary["english_checked"]
    if checked:
        add("1. **english_kept**：中文源→非英语目标共 %d 条，PASS %s，MISS %d 条。" % (
            checked, fmt_pct(summary["english_pass"], checked), summary["miss"]))
        add("   - 按英文词逐项计：%s 个 term 原样保留（共 %d 个）。单条 PASS 要求一条语料里的英文词全保住，"
            "所以 PASS 率天然低于 term 保留率。" % (
                fmt_pct(summary["terms_kept"], summary["terms_checked"]), summary["terms_checked"]))
        if summary["miss"]:
            misses = [r for r in records if r.get("english_kept") == "MISS"]
            detail = "、".join("`%s→%s`" % (r["id"], r["target_name"]) for r in misses[:10])
            if len(misses) > 10:
                detail += " 等 %d 条（完整见下方明细表）" % len(misses)
            add("   - MISS 明细：%s" % detail)
    else:
        add("1. **english_kept**：本轮没有中文源→非英语目标的调用（被过滤）。")
    add("2. **空输出**：%d 条。" % summary["empty"])
    add("3. **汉字泄漏**（严格规则：非中文目标且汉字数/非空白字符 > 20%%）：%d 条；"
        "按假名辅助修正后的真实中文泄漏 %d 条。" % (summary["leak"], summary["real_leak"]))
    ja = summary["per_target"].get("ja")
    if ja and ja["calls"]:
        add("   - 注：日语天然大量使用汉字。本轮 %d 条日语输出中 %d 条含假名，"
            "这 %d 条严格规则下的“泄漏”均属正常日语输出，不是中文漏翻。" % (
                ja["calls"], ja["kana"], ja["leak"]))
    add("4. **延迟**：平均 %s ms，中位 %s ms，平均生成速度 %s tok/s（全部成功调用）。" % (
        _ms(summary["avg_ms"]), _ms(summary["median_ms"]), _num(summary["avg_tok_s"])))
    if summary["errors"]:
        add("5. **失败调用**：%d 条，见下方明细表。" % summary["errors"])
    add("")

    # ---------- 按目标语言 ----------
    add("## 按目标语言汇总")
    add("")
    add("| 目标语言 | 调用数 | english_kept（中文源） | term 保留（中文源） | 平均延迟 ms | 中位延迟 ms | 平均 tok/s | 空输出 | 汉字泄漏 |")
    add("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for key in TARGET_ORDER:
        info = summary["per_target"].get(key)
        if not info:
            continue
        if info["checked"]:
            kept = fmt_pct(info["pass"], info["checked"])
            term_kept = fmt_pct(info["terms_kept"], info["terms_checked"])
        else:
            kept = "—（无中文源）"
            term_kept = "—"
        add("| %s | %d | %s | %s | %s | %s | %s | %d | %d |" % (
            info["target_name"], info["calls"], kept, term_kept, _ms(info["avg_ms"]),
            _ms(info["median_ms"]), _num(info["avg_tok_s"]), info["empty"], info["leak"]))
    add("")
    add("> english_kept / term 保留只对“中文源→非英语目标”有意义；英文源没有英文保留要求，记为 —。")
    add("> 汉字泄漏列是严格规则计数；日语含假名的输出实际是正常日语（见关键结论第 3 条）。")
    add("")

    # ---------- 按源语言 ----------
    add("## 按源语言汇总")
    add("")
    add("| 源语言 | 调用数 | 平均延迟 ms | 中位延迟 ms | 平均 tok/s | 空输出 | 汉字泄漏 |")
    add("|---|---:|---:|---:|---:|---:|---:|")
    for source in ("chinese", "english"):
        info = summary["per_source"].get(source)
        if not info:
            continue
        add("| %s | %d | %s | %s | %s | %d | %d |" % (
            info["source_name"], info["calls"], _ms(info["avg_ms"]),
            _ms(info["median_ms"]), _num(info["avg_tok_s"]), info["empty"], info["leak"]))
    add("")

    # ---------- 中文源逐语料 ----------
    if summary["per_segment"]:
        add("## 中文源逐语料 english_kept")
        add("")
        add("| 语料 | 检查目标数 | PASS | MISS | 缺失 term |")
        add("|---|---:|---:|---:|---|")
        for segment in corpus.CHINESE_SEGMENTS:
            info = summary["per_segment"].get(segment["id"])
            if not info:
                continue
            missing = "、".join("`%s`" % t for t in info["missing_terms"]) if info["missing_terms"] else "—"
            add("| %s | %d | %d | %d | %s |" % (
                segment["id"], info["calls"], info["pass"], info["miss"], missing))
        add("")

    # ---------- MISS 对照 ----------
    misses = [r for r in records if r.get("english_kept") == "MISS"]
    add("## MISS 对照（英文词未原样保留）")
    add("")
    if not misses:
        add("无。所有中文源的英文词都在译文里原样出现。")
    else:
        for record in misses:
            add("### %s → %s（%s模板）" % (
                record["id"], record["target_name"],
                "约束" if record["prompt_type"] == "constrained" else "普通"))
            add("")
            add("- 源文：%s" % md_cell(record["text"], 200))
            add("- 要求原样保留：%s" % "、".join("`%s`" % t for t in record["english_terms"]))
            add("- 缺失：%s" % "、".join("`%s`" % t for t in record["missing_terms"]))
            add("")
            add("清洗后输出：")
            add("")
            add("```text")
            add(record["cleaned_output"])
            add("```")
            add("")
            add("原始输出：")
            add("")
            add("```text")
            add(record["raw_output"])
            add("```")
            add("")
    if not misses:
        add("")

    # ---------- 抽样输出 ----------
    add("## 抽样输出（每条目标语言：中文源 1 条 + 英文源 1 条）")
    add("")
    for key in TARGET_ORDER:
        group = [r for r in records if r.get("target") == key and "error" not in r]
        if not group:
            continue
        add("### %s" % TARGET_NAME[key])
        add("")
        picks = []
        for source in ("chinese", "english"):
            picked = next((r for r in group if r["source"] == source), None)
            if picked:
                picks.append(picked)
        for record in picks:
            add("**%s → %s**（%s）" % (record["source_name"], record["target_name"], record["id"]))
            add("")
            add("- 源文：%s" % md_cell(record["text"], 200))
            add("- 译文：%s" % md_cell(record["cleaned_output"], 240))
            add("")
    add("")

    # ---------- 全部明细 ----------
    add("## 全部调用明细")
    add("")
    add("| # | 语料 | 源→目标 | 模板 | 延迟 ms | prompt_n | predicted_n | tok/s | 保留 | 空 | 泄漏 | 清洗后输出（截断） |")
    add("|---:|---|---|---|---:|---:|---:|---:|---|---|---|---|")
    for index, record in enumerate(records, 1):
        if "error" in record:
            add("| %d | %s | %s→%s | %s |— | — | — | — | ⚠ | — | — | 错误：%s |" % (
                index, record.get("id", "?"), record.get("source_name", "?"),
                record.get("target_name", "?"), record.get("prompt_type", "?"),
                md_cell(record["error"], 120)))
            continue
        kept = record["english_kept"] or "—"
        add("| %d | %s | %s→%s | %s | %s | %d | %d | %s | %s | %s | %s | %s |" % (
            index, record["id"], record["source_name"], record["target_name"],
            "约束" if record["prompt_type"] == "constrained" else "普通",
            _ms(record["wall_ms"]), record["prompt_n"], record["predicted_n"],
            _num(record["tok_per_s"]), kept,
            "YES" if record["empty"] else "no",
            "YES" if record["has_chinese_leak"] else "no",
            md_cell(record["cleaned_output"], 60)))
    add("")

    add("## 复现方式")
    add("")
    add("```powershell")
    add("cd C:\\Users\\Angelica\\Desktop\\works\\DeepSeek\\IndexTranslate_iPadM5")
    if meta.get("preset"):
        add("python tools\\regress_prompts.py --preset %s" % meta["preset"])
    elif meta.get("instruction"):
        add('python tools\\regress_prompts.py --instruction "%s"' % meta["instruction"])
    else:
        add("python tools\\regress_prompts.py")
    add("```")
    add("")
    add("原始逐条数据（含拼好的完整 prompt、原始输出、timings）见 `tools/out/raw.json`。")
    add("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def build_call_list(only_source, target_filter=None):
    calls = []
    for segment in corpus.SEGMENTS:
        if only_source and segment["source"] != only_source:
            continue
        for target_key in TARGETS_BY_SOURCE[segment["source"]]:
            if target_filter and target_key not in target_filter:
                continue
            calls.append((segment, target_key))
    return calls


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="翻译 prompt 回归测试：对每条语料 × 每个合法目标语言调用本机 llama.cpp /completion。")
    parser.add_argument("--only", choices=["zh", "en", "chinese", "english"], default=None,
                        help="只跑某一源语言：zh=中文源（96 次），en=英文源（64 次）")
    parser.add_argument("--targets", default=None,
                        help="只跑这些目标语言（逗号分隔，如 it,ru）；默认跑全部 8 个")
    parser.add_argument("--instruction", default="",
                        help="模拟 App 的「翻译需求」：自由文本会渲染成【注意】约束")
    parser.add_argument("--preset", choices=sorted(INSTRUCTION_PRESETS.keys()), default=None,
                        help="模拟 App 的内置场景（与 Sources/InstructionPresets.swift 一致）")
    parser.add_argument("--limit", type=int, default=None,
                        help="最多跑 N 次调用（过滤后从前往后截断），调试用")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL,
                        help="llama.cpp server 地址，默认 %s" % DEFAULT_BASE_URL)
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR),
                        help="报告输出目录，默认 tools/out")
    parser.add_argument("--n-predict", type=int, default=DEFAULT_N_PREDICT,
                        help="n_predict，默认 %d" % DEFAULT_N_PREDICT)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="单次请求超时秒数，默认 %.0f" % DEFAULT_TIMEOUT)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    only_source = {"zh": "chinese", "chinese": "chinese",
                   "en": "english", "english": "english"}.get(args.only)
    base_url = args.base_url.rstrip("/")
    out_dir = Path(args.out_dir)

    if args.preset and args.instruction:
        print("--preset 和 --instruction 只能二选一", file=sys.stderr)
        return 2
    instruction = INSTRUCTION_PRESETS[args.preset] if args.preset else args.instruction

    target_filter = None
    if args.targets:
        target_filter = [item.strip().lower() for item in args.targets.split(",") if item.strip()]
        unknown = [key for key in target_filter if key not in TARGET_NAME]
        if unknown:
            print("未知目标语言：%s（可选：%s）" % (",".join(unknown), ",".join(TARGET_ORDER)),
                  file=sys.stderr)
            return 2

    calls = build_call_list(only_source, target_filter)
    if args.limit is not None:
        if args.limit <= 0:
            print("--limit 必须为正整数", file=sys.stderr)
            return 2
        calls = calls[: args.limit]
    if not calls:
        print("没有可跑的调用（检查 --only / --targets / --limit）", file=sys.stderr)
        return 2

    opener = make_opener(base_url)
    props = None
    props_error = None
    try:
        status, body = http_get(opener, base_url + "/props", timeout=15.0)
        if status == 200:
            props = json.loads(body)
        else:
            props_error = "GET /props -> HTTP %s: %s" % (status, body[:500])
    except Exception as exc:  # 服务没起来时后面会给出更明确的错误
        props_error = "GET /props 失败: %s" % exc

    print("=" * 78)
    print("翻译 prompt 回归测试")
    print("  base_url : %s" % base_url)
    if props:
        print("  model    : %s" % (props.get("model_path") or props.get("model_alias") or "?"))
        print("  slots    : %s" % props.get("total_slots", "?"))
    else:
        print("  /props   : 不可用（%s）" % props_error)
    print("  调用数   : %d（n_predict=%d, temperature=0）" % (len(calls), args.n_predict))
    if instruction:
        print("  翻译需求 : %s%s" % (
            ("场景 " + args.preset + " → ") if args.preset else "", instruction))
    else:
        print("  翻译需求 : 无（App 默认路径）")
    print("  输出     : %s" % out_dir)
    print("=" * 78)
    sys.stdout.flush()

    records = []
    error_count = 0
    pass_count = 0
    miss_count = 0
    empty_count = 0
    last_ten_ms = []
    started_at = time.time()

    for index, (segment, target_key) in enumerate(calls, 1):
        try:
            record = run_one(opener, base_url, segment, target_key,
                             args.n_predict, args.timeout, instruction)
        except ServerError as exc:
            error_count += 1
            print("[%03d/%03d] ERROR %s -> %s: %s" % (
                index, len(calls), segment["id"], TARGET_NAME[target_key], exc))
            sys.stdout.flush()
            records.append({
                "id": segment["id"],
                "source": segment["source"],
                "source_name": corpus.SOURCE_PROMPT_NAMES[segment["source"]],
                "target": target_key,
                "target_name": TARGET_NAME[target_key],
                "text": segment["text"],
                "english_terms": list(segment["english_terms"]),
                "prompt_type": prompt_type(segment, target_key, instruction),
                "error": str(exc),
            })
            if index == 1:
                print("第一条就失败了，终止（服务端可能没在 %s 监听）。" % base_url, file=sys.stderr)
                return 1
            continue
        except Exception as exc:  # 兜底，避免中途静默崩溃
            error_count += 1
            print("[%03d/%03d] UNEXPECTED %s -> %s: %r" % (
                index, len(calls), segment["id"], TARGET_NAME[target_key], exc))
            sys.stdout.flush()
            records.append({
                "id": segment["id"], "source": segment["source"],
                "source_name": corpus.SOURCE_PROMPT_NAMES[segment["source"]],
                "target": target_key, "target_name": TARGET_NAME[target_key],
                "text": segment["text"], "english_terms": list(segment["english_terms"]),
                "prompt_type": prompt_type(segment, target_key, instruction),
                "error": "%r" % exc,
            })
            continue

        records.append(record)
        if record["english_kept"] == "PASS":
            pass_count += 1
        elif record["english_kept"] == "MISS":
            miss_count += 1
        if record["empty"]:
            empty_count += 1
        last_ten_ms.append(record["wall_ms"])

        if index % 10 == 0 or index == len(calls):
            print("[%03d/%03d] ok=%d miss=%d empty=%d | %s -> %s %s kept=%s %sms %stok/s | 平均 %.0fms" % (
                index, len(calls), pass_count, miss_count, empty_count,
                segment["id"], target_key, "约束" if record["prompt_type"] == "constrained" else "普通",
                record["english_kept"] or "—", _ms(record["wall_ms"]),
                _num(record["tok_per_s"]),
                sum(last_ten_ms) / len(last_ten_ms)))
            sys.stdout.flush()

    elapsed = time.time() - started_at
    summary = summarize(records)

    generated_at = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    meta = {
        "generated_at": generated_at,
        "base_url": base_url,
        "model_path": (props or {}).get("model_path") or (props or {}).get("model_alias"),
        "total_slots": (props or {}).get("total_slots"),
        "n_predict": args.n_predict,
        "temperature": 0,
        "stop": ["<|im_end|>"],
        "python": platform.python_version(),
        "platform": platform.platform(),
        "only": only_source,
        "targets": target_filter,
        "instruction": instruction,
        "preset": args.preset,
        "limit": args.limit,
        "elapsed_s": round(elapsed, 1),
        "props_error": props_error,
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    raw_path = out_dir / "raw.json"
    report_path = out_dir / "report.md"

    with open(raw_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"meta": meta, "summary": summary, "results": records},
                  handle, ensure_ascii=False, indent=2)

    report = render_report(records, summary, meta)
    with open(report_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(report)

    print("-" * 78)
    print("完成：%d 次调用，成功 %d / 失败 %d，耗时 %.1fs" % (
        len(records), summary["calls_ok"], summary["errors"], elapsed))
    print("english_kept：%s，MISS %d；空输出 %d；汉字泄漏 %d" % (
        fmt_pct(summary["english_pass"], summary["english_checked"]),
        summary["miss"], summary["empty"], summary["leak"]))
    print("延迟：平均 %s ms / 中位 %s ms；生成速度平均 %s tok/s" % (
        _ms(summary["avg_ms"]), _ms(summary["median_ms"]), _num(summary["avg_tok_s"])))
    print("报告: %s" % report_path)
    print("原始: %s" % raw_path)

    return 1 if (summary["errors"] or not summary["calls_ok"]) else 0


if __name__ == "__main__":
    sys.exit(main())
