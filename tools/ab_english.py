#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A/B 实验：4 种“保住英文词”策略在中→日/韩/法/西/英 上的效果对比。

对同一批中文语料 zh-01..zh-12 × 5 个目标语言 × 4 种策略各跑一次 llama.cpp /completion：

- S1 基线：现有方案（中文源→非英语目标用「约束翻译」+ 软性一句“保留英文单词”，
  中文源→英语用「普通翻译」）。
- S2 术语表（glossary identity）：自动抽取源文英文片段，拼成硬约束
  “专名/术语对照: dining hall→dining hall、library→library”（其余同 S1）。
- S3 占位符保护：把英文片段替换成 {0} {1}…，用普通翻译 prompt + 一句
  “保留 {n} 占位符原样”，译文里把占位符（容忍 { 0 } / {0 } 这类空格变体）还原成原英文片段。
- S4 占位符 + 术语表：S3 的占位符替换 + S2 的术语表（术语表按还原后的英文形式书写），两者叠加。

判定：按词保留率（english_terms 有多少原样出现）、整句全中率、空输出、
占位符残留/丢失/重复/空格变体数（S3/S4），并抽 6 组样本做四策略译文并排对照。

结果写 <out-dir>/ab_english.md 与 <out-dir>/ab_raw.json。只读服务端，不重启不占端口。

用法::

    python tools/ab_english.py
    python tools/ab_english.py --strategies s1,s2 --targets ja,ko
    python tools/ab_english.py --targets ja --limit 8        # 冒烟
    python tools/ab_english.py --base-url http://127.0.0.1:8089

只用 Python 标准库；请求/清洗/代理绕行等复用 tools/regress_prompts.py 里的实现。
"""
from __future__ import annotations

import argparse
import json
import platform
import re
import statistics
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

import segments as corpus  # noqa: E402
from regress_prompts import (  # noqa: E402  （复用上一轮的实现）
    CHATML_HEAD,
    CHATML_TAIL,
    DEFAULT_BASE_URL,
    DEFAULT_N_PREDICT,
    DEFAULT_TIMEOUT,
    TARGET_NAME,
    build_user_message,
    clean_output,
    extract_timings,
    http_get,
    make_opener,
    post_completion,
)

DEFAULT_OUT_DIR = TOOLS_DIR / "out"
ALL_TARGETS = ["ja", "ko", "fr", "es", "en"]
ALL_STRATEGIES = ["s1", "s2", "s3", "s4"]
STRATEGY_LABELS = {
    "s1": "S1 基线（软约束）",
    "s2": "S2 术语表",
    "s3": "S3 占位符",
    "s4": "S4 占位符+术语表",
}
SOURCE_NAME = "中文"

# 英文片段：连续拉丁字母/空格/连字符（长度≥2；数字、标点、汉字会截断）
SPAN_RE = re.compile(r"[A-Za-z][A-Za-z \-]*[A-Za-z]")
# 占位符：容忍 {0} / { 0 } / {0 } / { 0} 等空格变体
PLACEHOLDER_RE = re.compile(r"\{\s*(\d+)\s*\}")
BRACE_CHARS = "{}｛｝"

# 官方约束翻译模板里的原始“保留英文”要求（S1 使用）
OFFICIAL_REQ1 = (
    "1. 【硬性要求】保留源文中的英文单词、专有名词、品牌名和缩写原样输出，"
    "不要翻译、不要改写、不要音译。"
)


# ---------------------------------------------------------------------------
# 英文片段抽取 / 占位符保护 / 还原
# ---------------------------------------------------------------------------
def extract_spans(text: str) -> list:
    """抽取源文里的英文片段（连续拉丁字母/空格/连字符，长度≥2，去重保序）。"""
    spans = []
    seen = set()
    for match in SPAN_RE.finditer(text):
        span = re.sub(r"[ \t]+", " ", match.group(0)).strip()
        if len(span) < 2 or span in seen:
            continue
        seen.add(span)
        spans.append(span)
    return spans


def protect_english(text: str, spans: list):
    """把每个英文片段按首次出现顺序替换成 {0} {1}…，返回 (mapping, protected_text)。"""
    mapping = {index: span for index, span in enumerate(spans)}
    if not spans:
        return mapping, text
    index_of = {span: index for index, span in enumerate(spans)}
    ordered = sorted(spans, key=len, reverse=True)  # 长片段优先，避免前缀互相截断
    pattern = re.compile("|".join(re.escape(span) for span in ordered))
    protected = pattern.sub(lambda m: "{%d}" % index_of[m.group(0)], text)
    return mapping, protected


def restore_placeholders(text: str, mapping: dict):
    """把译文里的 {n}（容忍空格变体）还原成英文片段，并统计占位符健康度。"""
    stats = {
        "placeholders_total": len(mapping),
        "restored": 0,
        "variants": 0,
        "variant_examples": [],
        "residual": 0,
        "unknown": [],
        "lost": [],
        "lost_ids": [],
        "duplicated": [],
        "duplicated_ids": [],
        "stray_braces": 0,
    }
    counts = Counter()

    def repl(match):
        raw = match.group(0)
        index = int(match.group(1))
        if index not in mapping:
            stats["unknown"].append(raw)
            return raw
        counts[index] += 1
        stats["restored"] += 1
        expected = "{%d}" % index
        if raw != expected:
            stats["variants"] += 1
            if len(stats["variant_examples"]) < 10:
                stats["variant_examples"].append(raw)
        return mapping[index]

    restored = PLACEHOLDER_RE.sub(repl, text)
    stats["residual"] = len(PLACEHOLDER_RE.findall(restored))
    stats["lost_ids"] = [index for index in sorted(mapping) if counts[index] == 0]
    stats["lost"] = [mapping[index] for index in stats["lost_ids"]]
    stats["duplicated_ids"] = [index for index in sorted(mapping) if counts[index] > 1]
    stats["duplicated"] = [mapping[index] for index in stats["duplicated_ids"]]
    stats["stray_braces"] = sum(restored.count(ch) for ch in BRACE_CHARS)
    return restored, stats


# ---------------------------------------------------------------------------
# 4 种策略的 prompt 拼装
# ---------------------------------------------------------------------------
def wrap_chatml(user_message: str) -> str:
    return CHATML_HEAD + user_message + CHATML_TAIL


def _glossary_line(spans: list) -> str:
    pairs = "、".join("%s→%s" % (span, span) for span in spans)
    return "1. 【硬性要求】专名/术语对照: " + pairs


def _placeholder_sentence(mapping: dict) -> str:
    tokens = "、".join("{%d}" % index for index in sorted(mapping))
    return "保留 %s 占位符原样，不要翻译或删除。" % tokens


def _constrained_user_message(target_key: str, text: str, requirement_lines) -> str:
    """类官方“约束翻译”模板；requirement_lines 已带 1./2./3. 编号。"""
    return (
        "请将以下中文文本翻译成{target}，并且严格遵循所有约束要求。\n\n"
        "【源文】\n{text}\n\n"
        "【约束要求】\n{reqs}\n\n"
        "只输出译文，不要有任何额外说明。"
    ).format(target=TARGET_NAME[target_key], text=text, reqs="\n".join(requirement_lines))


def build_s1(segment: dict, target_key: str):
    """S1 基线：沿用上一轮方案（官方模板）。"""
    prompt = wrap_chatml(build_user_message(segment, target_key))
    prompt_type = "constrained+official" if target_key != "en" else "plain"
    return prompt, {"prompt_type": prompt_type, "spans": []}


def build_s2(segment: dict, target_key: str):
    """S2 术语表：S1 的约束模板 + 身份术语表硬约束。"""
    spans = extract_spans(segment["text"])
    req1 = _glossary_line(spans) if spans else OFFICIAL_REQ1
    reqs = [req1, "2. 【注意】自然口语风格。"]
    prompt = wrap_chatml(_constrained_user_message(target_key, segment["text"], reqs))
    return prompt, {"prompt_type": "constrained+glossary", "spans": spans}


def build_s3(segment: dict, target_key: str):
    """S3 占位符：英文片段换成占位符，普通翻译 prompt + 一句占位符约束。"""
    spans = extract_spans(segment["text"])
    mapping, protected = protect_english(segment["text"], spans)
    user_message = (
        "请将以下中文文本翻译为{target}，直接输出翻译结果，不要进行任何解释。\n\n"
        "{text}\n\n"
        "【约束要求】\n{sentence}"
    ).format(target=TARGET_NAME[target_key], text=protected,
             sentence=_placeholder_sentence(mapping))
    prompt = wrap_chatml(user_message)
    return prompt, {"prompt_type": "plain+placeholder", "spans": spans,
                    "mapping": mapping, "protected_text": protected}


def build_s4(segment: dict, target_key: str):
    """S4 占位符 + 术语表：S3 的替换 + S2 的术语表（术语表用还原后的英文形式）。"""
    spans = extract_spans(segment["text"])
    mapping, protected = protect_english(segment["text"], spans)
    reqs = [
        _glossary_line(spans) if spans else OFFICIAL_REQ1,
        "2. 【硬性要求】" + _placeholder_sentence(mapping),
        "3. 【注意】自然口语风格。",
    ]
    prompt = wrap_chatml(_constrained_user_message(target_key, protected, reqs))
    return prompt, {"prompt_type": "constrained+glossary+placeholder", "spans": spans,
                    "mapping": mapping, "protected_text": protected}


BUILDERS = {"s1": build_s1, "s2": build_s2, "s3": build_s3, "s4": build_s4}


# ---------------------------------------------------------------------------
# 单次调用 + 判定
# ---------------------------------------------------------------------------
def run_one(opener, base_url: str, segment: dict, target_key: str, strategy: str,
            n_predict: int, timeout: float) -> dict:
    prompt, meta = BUILDERS[strategy](segment, target_key)
    wall_ms, obj = post_completion(opener, base_url, prompt, n_predict, timeout)
    timings = extract_timings(obj)
    raw_output = obj.get("content")
    if not isinstance(raw_output, str):
        raw_output = "" if raw_output is None else str(raw_output)
    cleaned = clean_output(raw_output)

    placeholder = None
    final_output = cleaned
    if strategy in ("s3", "s4"):
        restored, placeholder = restore_placeholders(cleaned, meta["mapping"])
        final_output = restored.strip()

    terms = list(segment["english_terms"])
    lowered = final_output.lower()
    missing = [term for term in terms if term.lower() not in lowered]
    kept = len(terms) - len(missing)

    record = {
        "strategy": strategy,
        "strategy_label": STRATEGY_LABELS[strategy],
        "target": target_key,
        "target_name": TARGET_NAME[target_key],
        "id": segment["id"],
        "source": segment["source"],
        "text": segment["text"],
        "prompt_type": meta["prompt_type"],
        "prompt": prompt,
        "spans": meta.get("spans", []),
        "protected_text": meta.get("protected_text"),
        "wall_ms": wall_ms,
        "prompt_n": timings["prompt_n"],
        "predicted_n": timings["predicted_n"],
        "prompt_ms": timings["prompt_ms"],
        "predicted_ms": timings["predicted_ms"],
        "tok_per_s": timings["tok_per_s"],
        "raw_output": raw_output,
        "cleaned_output": cleaned,
        "final_output": final_output,
        "empty": len(final_output) == 0,
        "english_terms": terms,
        "terms_total": len(terms),
        "terms_kept": kept,
        "sentence_pass": kept == len(terms),
        "missing_terms": missing,
        "placeholder": placeholder,
        "placeholder_total": (placeholder or {}).get("placeholders_total", 0),
        "placeholder_residual": (placeholder or {}).get("residual", 0),
        "placeholder_lost": (placeholder or {}).get("lost", []),
        "placeholder_duplicated": (placeholder or {}).get("duplicated", []),
        "placeholder_variants": (placeholder or {}).get("variants", 0),
        "placeholder_variant_examples": (placeholder or {}).get("variant_examples", []),
        "placeholder_stray_braces": (placeholder or {}).get("stray_braces", 0),
        "error": None,
    }
    return record


# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
def _mean(values):
    return statistics.mean(values) if values else None


def _median(values):
    return statistics.median(values) if values else None


def _ms(value):
    return "%.0f" % value if value is not None else "—"


def _num(value, digits=1):
    return ("%." + str(digits) + "f") % value if value is not None else "—"


def fmt_pct(part: int, whole: int) -> str:
    if not whole:
        return "—"
    return "%d/%d (%.1f%%)" % (part, whole, 100.0 * part / whole)


def summarize(records, strategies, targets):
    ok = [r for r in records if r.get("error") is None]
    groups = {}
    for strategy in strategies:
        for target in targets:
            group = [r for r in ok if r["strategy"] == strategy and r["target"] == target]
            if not group:
                continue
            terms_total = sum(r["terms_total"] for r in group)
            terms_kept = sum(r["terms_kept"] for r in group)
            ph = [r for r in group if r["placeholder_total"]]
            groups[(strategy, target)] = {
                "calls": len(group),
                "terms_total": terms_total,
                "terms_kept": terms_kept,
                "word_retention": terms_kept / terms_total if terms_total else None,
                "pass": sum(1 for r in group if r["sentence_pass"]),
                "sentence_pass_rate": (sum(1 for r in group if r["sentence_pass"]) / len(group)),
                "empty": sum(1 for r in group if r["empty"]),
                "avg_ms": _mean([r["wall_ms"] for r in group]),
                "median_ms": _median([r["wall_ms"] for r in group]),
                "avg_tok_s": _mean([r["tok_per_s"] for r in group if r["tok_per_s"]]),
                "placeholder_calls": len(ph),
                "placeholder_total": sum(r["placeholder_total"] for r in ph),
                "placeholder_residual": sum(r["placeholder_residual"] for r in ph),
                "placeholder_lost": sum(len(r["placeholder_lost"]) for r in ph),
                "placeholder_duplicated": sum(len(r["placeholder_duplicated"]) for r in ph),
                "placeholder_variants": sum(r["placeholder_variants"] for r in ph),
                "placeholder_stray_braces": sum(r["placeholder_stray_braces"] for r in ph),
                "placeholder_anomaly_calls": sum(
                    1 for r in ph
                    if r["placeholder_residual"] or r["placeholder_lost"]
                    or r["placeholder_duplicated"] or r["placeholder_stray_braces"]
                ),
            }

    agg = {}
    for strategy in strategies:
        group = [r for r in ok if r["strategy"] == strategy]
        terms_total = sum(r["terms_total"] for r in group)
        terms_kept = sum(r["terms_kept"] for r in group)
        agg[strategy] = {
            "calls": len(group),
            "terms_total": terms_total,
            "terms_kept": terms_kept,
            "word_retention": terms_kept / terms_total if terms_total else None,
            "pass": sum(1 for r in group if r["sentence_pass"]),
            "sentence_pass_rate": sum(1 for r in group if r["sentence_pass"]) / len(group) if group else None,
            "empty": sum(1 for r in group if r["empty"]),
            "placeholder_residual": sum(r["placeholder_residual"] for r in group),
            "placeholder_lost": sum(len(r["placeholder_lost"]) for r in group),
            "placeholder_duplicated": sum(len(r["placeholder_duplicated"]) for r in group),
            "placeholder_variants": sum(r["placeholder_variants"] for r in group),
            "placeholder_stray_braces": sum(r["placeholder_stray_braces"] for r in group),
            "avg_ms": _mean([r["wall_ms"] for r in group]),
            "avg_tok_s": _mean([r["tok_per_s"] for r in group if r["tok_per_s"]]),
        }
    return {"groups": groups, "agg": agg,
            "calls_total": len(records), "calls_ok": len(ok),
            "errors": len(records) - len(ok)}


def summary_for_json(summary):
    """summary 内部用 (strategy, target) 元组做 key，落盘 JSON 前转成 "s1|ja" 字符串。"""
    return {
        "calls_total": summary["calls_total"],
        "calls_ok": summary["calls_ok"],
        "errors": summary["errors"],
        "agg": summary["agg"],
        "groups": {"%s|%s" % key: value for key, value in summary["groups"].items()},
    }


# ---------------------------------------------------------------------------
# 样本挑选 + Markdown 报告
# ---------------------------------------------------------------------------
def pick_samples(records, strategies, targets, limit=6):
    lookup = {(r["strategy"], r["target"], r["id"]): r
              for r in records if r.get("error") is None}
    combos = []
    for segment in corpus.CHINESE_SEGMENTS:
        for target in targets:
            outcomes = []
            for strategy in strategies:
                record = lookup.get((strategy, target, segment["id"]))
                if record is None:
                    outcomes.append("ERR")
                elif record["sentence_pass"]:
                    outcomes.append("PASS")
                else:
                    outcomes.append("MISS")
            distinct = len(set(outcomes))
            combos.append((distinct, segment["id"], target))
    picked = []
    for target in targets:  # 每个目标语言至少抽 1 条（差异大的优先）
        candidates = [c for c in combos if c[2] == target and c not in picked]
        if not candidates:
            continue
        picked.append(max(candidates, key=lambda c: (c[0], -int(c[1].split("-")[1]))))
    rest = sorted([c for c in combos if c not in picked],
                  key=lambda c: (-c[0], c[1], c[2]))
    for combo in rest:
        if len(picked) >= limit:
            break
        picked.append(combo)
    return [(segment_id, target) for _, segment_id, target in picked[:limit]]


def md_cell(value, limit=120):
    text = "" if value is None else str(value)
    text = text.replace("\r", " ").replace("\n", " ").replace("|", "\\|").strip()
    if len(text) > limit:
        text = text[: max(1, limit - 1)] + "…"
    return text or "∅"


def pick_recommendation(summary, strategies, targets):
    non_en = [target for target in targets if target != "en"] or list(targets)
    rows = []
    for strategy in strategies:
        terms_total = sum(summary["groups"][(strategy, t)]["terms_total"] for t in non_en
                          if (strategy, t) in summary["groups"])
        terms_kept = sum(summary["groups"][(strategy, t)]["terms_kept"] for t in non_en
                         if (strategy, t) in summary["groups"])
        pass_count = sum(summary["groups"][(strategy, t)]["pass"] for t in non_en
                         if (strategy, t) in summary["groups"])
        calls = sum(summary["groups"][(strategy, t)]["calls"] for t in non_en
                    if (strategy, t) in summary["groups"])
        residual = sum(summary["groups"][(strategy, t)]["placeholder_residual"] for t in non_en
                       if (strategy, t) in summary["groups"])
        lost = sum(summary["groups"][(strategy, t)]["placeholder_lost"] for t in non_en
                   if (strategy, t) in summary["groups"])
        rows.append({
            "strategy": strategy,
            "word_retention": terms_kept / terms_total if terms_total else 0.0,
            "sentence_pass_rate": pass_count / calls if calls else 0.0,
            "residual": residual,
            "lost": lost,
        })
    healthy = [row for row in rows if row["residual"] == 0 and row["lost"] == 0]
    pool = healthy or rows
    best = max(pool, key=lambda row: (row["word_retention"], row["sentence_pass_rate"]))
    return best, rows


def render_report(records, summary, meta, strategies, targets, samples):
    lines = []
    add = lines.append

    add("# 英文词保留 A/B 实验（S1–S4）")
    add("")
    add("- 生成时间：%s" % meta["generated_at"])
    add("- 服务端：`%s`；模型：`%s`" % (meta["base_url"], meta.get("model_path") or "?"))
    add("- 调用：%d 次（%d 语料 × %d 目标语言 × %d 策略），成功 %d / 失败 %d，耗时 %.1fs" % (
        summary["calls_total"], len(corpus.CHINESE_SEGMENTS), len(targets), len(strategies),
        summary["calls_ok"], summary["errors"], meta["elapsed_s"]))
    add("- 目标语言：%s" % "、".join(TARGET_NAME[t] for t in targets))
    add("- 请求参数：n_predict=%d，temperature=0，stop=[\"<|im_end|>\"]；chatml thinking 关闭" % meta["n_predict"])
    add("- 判定口径：`english_terms` 不区分大小写、按子串出现在最终译文里算保留；"
        "“按词保留率”= 保留词数/总词数，“整句全中率”= 该句所有英文词都保留的记录占比。")
    add("")

    # ---------- 策略说明 ----------
    add("## 策略定义")
    add("")
    add("| 策略 | 做法 | 目标语言适用 |")
    add("|---|---|---|")
    add("| S1 基线 | 中文源→非英语目标：官方「约束翻译」+ 软性保留英文要求；中文源→英语：官方「普通翻译」 | 全部 |")
    add("| S2 术语表 | S1 的约束模板，但要求 1 换成身份术语表 hard constraint：`专名/术语对照: X→X、Y→Y`（X/Y 为自动抽取的英文片段） | 全部（en 为对照，同样套约束模板） |")
    add("| S3 占位符 | 英文片段替换成 `{0}` `{1}`…，先用普通翻译 prompt，再附一句“保留占位符原样”，译文后把占位符还原 | 全部 |")
    add("| S4 占位符+术语表 | S3 替换 + S2 术语表（术语表按还原后的英文形式书写）+ 占位符保留要求 | 全部（en 为对照） |")
    add("")
    add("> 自动抽取规则：源文中连续“拉丁字母/空格/连字符”且长度≥2 的片段，去重保序；"
        "数字、标点、汉字会截断片段（例如 `Room 305` 只抽到 `Room`，`Dr. Chen` 抽到 `Dr`、`Chen`）。")
    add("> zh→en 在 App 里本来走普通翻译；为了做对照，S2/S4 对 en 也套用约束模板（报告结论以 ja/ko/fr/es 为主）。")
    add("")

    # ---------- 主表 ----------
    add("## 主结果：策略 × 目标语言")
    add("")
    add("| 策略 | 目标语言 | 调用 | 按词保留率 | 整句全中率 | 空输出 | 残留占位符 | 丢失占位符 | 占位符变体 | 平均延迟 ms | 平均 tok/s |")
    add("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for strategy in strategies:
        for target in targets:
            info = summary["groups"].get((strategy, target))
            if not info:
                continue
            add("| %s | %s | %d | %s | %s | %d | %s | %s | %s | %s | %s |" % (
                STRATEGY_LABELS[strategy], TARGET_NAME[target], info["calls"],
                fmt_pct(info["terms_kept"], info["terms_total"]),
                fmt_pct(info["pass"], info["calls"]),
                info["empty"],
                info["placeholder_residual"] if info["placeholder_calls"] else "—",
                info["placeholder_lost"] if info["placeholder_calls"] else "—",
                info["placeholder_variants"] if info["placeholder_calls"] else "—",
                _ms(info["avg_ms"]), _num(info["avg_tok_s"])))
    add("")
    add("**策略汇总（全部选中目标语言合并）**")
    add("")
    add("| 策略 | 调用 | 按词保留率 | 整句全中率 | 空输出 | 残留占位符 | 丢失占位符 | 重复占位符 | 占位符变体 | 平均延迟 ms | 平均 tok/s |")
    add("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for strategy in strategies:
        info = summary["agg"][strategy]
        add("| %s | %d | %s | %s | %d | %d | %d | %d | %d | %s | %s |" % (
            STRATEGY_LABELS[strategy], info["calls"],
            fmt_pct(info["terms_kept"], info["terms_total"]),
            fmt_pct(info["pass"], info["calls"]), info["empty"],
            info["placeholder_residual"], info["placeholder_lost"],
            info["placeholder_duplicated"], info["placeholder_variants"],
            _ms(info["avg_ms"]), _num(info["avg_tok_s"])))
    add("")

    # ---------- 矩阵 ----------
    add("### 按词保留率矩阵（行=策略，列=目标语言）")
    add("")
    add("| 策略 | " + " | ".join(TARGET_NAME[t] for t in targets) + " |")
    add("|---|" + "---:|" * len(targets))
    for strategy in strategies:
        cells = []
        for target in targets:
            info = summary["groups"].get((strategy, target))
            cells.append(fmt_pct(info["terms_kept"], info["terms_total"]) if info else "—")
        add("| %s | %s |" % (STRATEGY_LABELS[strategy], " | ".join(cells)))
    add("")
    add("### 整句全中率矩阵")
    add("")
    add("| 策略 | " + " | ".join(TARGET_NAME[t] for t in targets) + " |")
    add("|---|" + "---:|" * len(targets))
    for strategy in strategies:
        cells = []
        for target in targets:
            info = summary["groups"].get((strategy, target))
            cells.append(fmt_pct(info["pass"], info["calls"]) if info else "—")
        add("| %s | %s |" % (STRATEGY_LABELS[strategy], " | ".join(cells)))
    add("")

    # ---------- 与 S1 对比 ----------
    if "s1" in strategies:
        add("### 相对 S1 的按词保留率变化（非英语目标）")
        add("")
        non_en = [t for t in targets if t != "en"]
        add("| 策略 | " + " | ".join(TARGET_NAME[t] for t in non_en) + " |")
        add("|---|" + "---:|" * len(non_en))
        s1_info = summary["groups"]
        for strategy in strategies:
            if strategy == "s1":
                continue
            cells = []
            for target in non_en:
                base = s1_info.get(("s1", target))
                curr = s1_info.get((strategy, target))
                if not base or not curr or not base["calls"]:
                    cells.append("—")
                    continue
                delta = curr["word_retention"] - base["word_retention"]
                cells.append("%+.1f pp" % (100.0 * delta))
            add("| %s | %s |" % (STRATEGY_LABELS[strategy], " | ".join(cells)))
        add("")

    # ---------- 占位符健康度 ----------
    if any(group["placeholder_calls"] for group in summary["groups"].values()):
        add("## S3/S4 占位符健康度")
        add("")
        add("| 策略 | 目标语言 | 占位符总数 | 成功还原 | 残留 {n} | 丢失 | 重复 | 空格变体（如 `{ 0 }`） | 异常记录数 |")
        add("|---|---|---:|---:|---:|---:|---:|---:|---:|")
        for strategy in strategies:
            for target in targets:
                info = summary["groups"].get((strategy, target))
                if not info or not info["placeholder_calls"]:
                    continue
                add("| %s | %s | %d | %d | %d | %d | %d | %d | %d |" % (
                    STRATEGY_LABELS[strategy], TARGET_NAME[target], info["placeholder_total"],
                    info["placeholder_total"] - info["placeholder_lost"] - info["placeholder_residual"],
                    info["placeholder_residual"], info["placeholder_lost"],
                    info["placeholder_duplicated"], info["placeholder_variants"],
                    info["placeholder_anomaly_calls"]))
        add("")
        add("> “残留 {n}”= 还原后最终译文里仍残留的 `{数字}` 占位符（必须为 0）；"
            "“丢失”= 模型把占位符删了/改成无法识别的形式；“变体”= 占位符被写成 `{ 0 }`、`{0 }` 等带空格形式"
            "（还原逻辑容忍并计数，不算错误）。")
        add("")

    # ---------- 异常样本 ----------
    anomalies = [r for r in records
                 if r.get("error") is None
                 and (r["placeholder_residual"] or r["placeholder_lost"]
                      or r["placeholder_duplicated"] or r["placeholder_stray_braces"])]
    add("## 占位符异常样本（残留 / 丢失 / 重复 / 残留花括号）")
    add("")
    if not anomalies:
        add("无。S3/S4 所有样本的占位符都能完整还原，没有残留 `{n}`、丢失或重复。")
    else:
        add("| 策略 | 目标 | 语料 | 问题 | 占位符替换后源文 | 最终译文（截断） |")
        add("|---|---|---|---|---|---|")
        for record in anomalies[:20]:
            issues = []
            if record["placeholder_residual"]:
                issues.append("残留 %d 个" % record["placeholder_residual"])
            if record["placeholder_lost"]:
                issues.append("丢失 `%s`" % "、".join(record["placeholder_lost"]))
            if record["placeholder_duplicated"]:
                issues.append("重复 `%s`" % "、".join(record["placeholder_duplicated"]))
            if record["placeholder_stray_braces"]:
                issues.append("残留花括号 %d" % record["placeholder_stray_braces"])
            add("| %s | %s | %s | %s | %s | %s |" % (
                record["strategy"].upper(), record["target_name"], record["id"],
                "；".join(issues), md_cell(record.get("protected_text"), 80),
                md_cell(record["final_output"], 100)))
        if len(anomalies) > 20:
            add("")
            add("（共 %d 条异常，此处列前 20 条，完整数据见 ab_raw.json）" % len(anomalies))
    add("")

    variant_records = [r for r in records
                       if r.get("error") is None and r.get("placeholder_variants")]
    add("## 占位符空格变体")
    add("")
    if not variant_records:
        add("没有出现 `{ 0 }` / `{0 }` 之类的空格变体，模型都按 `{n}` 原样输出。")
    else:
        total_variants = sum(r["placeholder_variants"] for r in variant_records)
        add("共 %d 条记录出现空格变体、合计 %d 处；还原逻辑全部成功处理（计入“变体”而非残留）。示例：" % (
            len(variant_records), total_variants))
        add("")
        shown = 0
        for record in variant_records:
            if shown >= 10:
                break
            add("- `%s` → %s %s：%s" % (
                record["id"], record["strategy"].upper(), record["target_name"],
                "、".join("`%s`" % example for example in record["placeholder_variant_examples"][:4])))
            shown += 1
    add("")

    # ---------- 6 条并排样本 ----------
    add("## 6 组样本：同一语料的四策略译文并排")
    add("")
    lookup = {(r["strategy"], r["target"], r["id"]): r
              for r in records if r.get("error") is None}
    for index, (segment_id, target) in enumerate(samples, 1):
        segment = next(s for s in corpus.CHINESE_SEGMENTS if s["id"] == segment_id)
        add("### 样本 %d：%s → %s" % (index, segment_id, TARGET_NAME[target]))
        add("")
        add("- 源文：%s" % md_cell(segment["text"], 200))
        add("- 要求保留：%s" % "、".join("`%s`" % term for term in segment["english_terms"]))
        add("")
        for strategy in strategies:
            record = lookup.get((strategy, target, segment_id))
            if record is None:
                continue
            kept = "%d/%d" % (record["terms_kept"], record["terms_total"])
            status = "整句全中" if record["sentence_pass"] else "缺 %s" % "、".join(record["missing_terms"])
            add("- **%s**（保留 %s · %s）：%s" % (
                STRATEGY_LABELS[strategy], kept, status, md_cell(record["final_output"], 320)))
        add("")

    # ---------- 决策建议 ----------
    best, rows = pick_recommendation(summary, strategies, targets)
    add("## 决策建议（自动指标）")
    add("")
    non_en = [t for t in targets if t != "en"] or list(targets)
    add("按非英语目标（%s）合计：" % "、".join(TARGET_NAME[t] for t in non_en))
    add("")
    add("| 策略 | 按词保留率 | 整句全中率 | 残留占位符 | 丢失占位符 |")
    add("|---|---:|---:|---:|---:|")
    for row in rows:
        add("| %s | %.1f%% | %.1f%% | %d | %d |" % (
            STRATEGY_LABELS[row["strategy"]], 100.0 * row["word_retention"],
            100.0 * row["sentence_pass_rate"], row["residual"], row["lost"]))
    add("")
    add("**自动指标建议：%s**（按词保留率 %.1f%%、整句全中率 %.1f%%，占位符残留 %d / 丢失 %d）。" % (
        STRATEGY_LABELS[best["strategy"]], 100.0 * best["word_retention"],
        100.0 * best["sentence_pass_rate"], best["residual"], best["lost"]))
    add("")
    add("> 最终选型还需看上方 6 组样本的译文自然度（占位符方案是把英文词“贴回”译文，"
        "语法格/词序在部分语言里可能变生硬）；自动化指标只量化“英文是否原样保留”。")
    add("")

    # ---------- 每策略 prompt 示例 ----------
    add("## 各策略 prompt 示例（zh-01 → ja）")
    add("")
    sample_segment = next(s for s in corpus.CHINESE_SEGMENTS if s["id"] == "zh-01")
    for strategy in strategies:
        prompt, _ = BUILDERS[strategy](sample_segment, "ja")
        add("### %s" % STRATEGY_LABELS[strategy])
        add("")
        add("```text")
        add(prompt.rstrip("\n"))
        add("```")
        add("")

    # ---------- 逐语料 MISS 清单 ----------
    add("## 附录：每个（策略, 目标）未全中的语料")
    add("")
    add("| 策略 | 目标语言 | 未全中语料（缺哪些词） |")
    add("|---|---|---|")
    for strategy in strategies:
        for target in targets:
            group = [r for r in records
                     if r.get("error") is None and r["strategy"] == strategy and r["target"] == target]
            misses = [r for r in group if not r["sentence_pass"]]
            if not misses:
                add("| %s | %s | 全部全中 |" % (STRATEGY_LABELS[strategy], TARGET_NAME[target]))
                continue
            detail = "；".join("%s（缺 %s）" % (r["id"], "、".join(r["missing_terms"]))
                               for r in misses)
            add("| %s | %s | %s |" % (STRATEGY_LABELS[strategy], TARGET_NAME[target],
                                      md_cell(detail, 500)))
    add("")

    add("## 复现方式")
    add("")
    add("```powershell")
    add("cd C:\\Users\\Angelica\\Desktop\\works\\DeepSeek\\IndexTranslate_iPadM5")
    add("python tools\\ab_english.py")
    add("python tools\\ab_english.py --strategies s1,s2,s3,s4 --targets ja,ko,fr,es,en")
    add("```")
    add("")
    add("逐条原始数据（含完整 prompt、原始输出、占位符统计）见 `tools/out/ab_raw.json`。")
    add("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def parse_csv(value: str, allowed, name: str):
    items = [item.strip().lower() for item in (value or "").split(",") if item.strip()]
    unknown = [item for item in items if item not in allowed]
    if unknown:
        raise argparse.ArgumentTypeError("%s 不支持: %s（可选: %s）" % (
            name, ",".join(unknown), ",".join(allowed)))
    deduped = []
    for item in items:
        if item not in deduped:
            deduped.append(item)
    return deduped


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="英文词保留 A/B 实验：S1 基线 / S2 术语表 / S3 占位符 / S4 占位符+术语表。")
    parser.add_argument("--strategies", default="s1,s2,s3,s4",
                        help="逗号分隔，默认 s1,s2,s3,s4（可选：%s）" % ",".join(ALL_STRATEGIES))
    parser.add_argument("--targets", default="ja,ko,fr,es,en",
                        help="逗号分隔，默认 ja,ko,fr,es,en（可选：%s）" % ",".join(ALL_TARGETS))
    parser.add_argument("--limit", type=int, default=None,
                        help="最多跑 N 次调用（调试/冒烟）")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL,
                        help="llama.cpp server 地址，默认 %s" % DEFAULT_BASE_URL)
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR),
                        help="输出目录，默认 tools/out")
    parser.add_argument("--n-predict", type=int, default=DEFAULT_N_PREDICT,
                        help="n_predict，默认 %d" % DEFAULT_N_PREDICT)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="单次请求超时秒数，默认 %.0f" % DEFAULT_TIMEOUT)
    args = parser.parse_args(argv)
    try:
        args.strategies = parse_csv(args.strategies, ALL_STRATEGIES, "strategies")
        args.targets = parse_csv(args.targets, ALL_TARGETS, "targets")
    except argparse.ArgumentTypeError as exc:
        parser.error(str(exc))
    if not args.strategies:
        parser.error("--strategies 不能为空")
    if not args.targets:
        parser.error("--targets 不能为空")
    return args


def build_call_list(strategies, targets):
    calls = []
    for segment in corpus.CHINESE_SEGMENTS:
        for target in targets:
            for strategy in strategies:
                calls.append((segment, target, strategy))
    return calls


def main(argv=None) -> int:
    args = parse_args(argv)
    base_url = args.base_url.rstrip("/")
    out_dir = Path(args.out_dir)

    calls = build_call_list(args.strategies, args.targets)
    if args.limit is not None:
        if args.limit <= 0:
            print("--limit 必须为正整数", file=sys.stderr)
            return 2
        calls = calls[: args.limit]
    if not calls:
        print("没有可跑的调用", file=sys.stderr)
        return 2

    opener = make_opener(base_url)
    props = None
    props_error = None
    try:
        status, body = http_get(opener, base_url + "/props", timeout=15.0)
        if status == 200:
            props = json.loads(body)
        else:
            props_error = "GET /props -> HTTP %s" % status
    except Exception as exc:
        props_error = "GET /props 失败: %s" % exc

    print("=" * 78)
    print("英文词保留 A/B 实验（S1/S2/S3/S4）")
    print("  base_url   : %s" % base_url)
    if props:
        print("  model      : %s" % (props.get("model_path") or props.get("model_alias") or "?"))
    else:
        print("  /props     : 不可用（%s）" % props_error)
    print("  strategies : %s" % ",".join(args.strategies))
    print("  targets    : %s" % ",".join(args.targets))
    print("  调用数     : %d（%d 语料 × %d 目标 × %d 策略）" % (
        len(calls), len(corpus.CHINESE_SEGMENTS), len(args.targets), len(args.strategies)))
    print("  输出       : %s" % out_dir)
    print("=" * 78)
    sys.stdout.flush()

    records = []
    errors = 0
    started_at = time.time()
    last_ten_ms = []

    for index, (segment, target, strategy) in enumerate(calls, 1):
        try:
            record = run_one(opener, base_url, segment, target, strategy,
                             args.n_predict, args.timeout)
        except Exception as exc:
            errors += 1
            print("[%03d/%03d] ERROR %s %s→%s: %s" % (
                index, len(calls), strategy.upper(), segment["id"], target, exc))
            sys.stdout.flush()
            records.append({
                "strategy": strategy, "strategy_label": STRATEGY_LABELS[strategy],
                "target": target, "target_name": TARGET_NAME[target],
                "id": segment["id"], "source": segment["source"],
                "text": segment["text"], "english_terms": list(segment["english_terms"]),
                "error": str(exc),
            })
            if index == 1:
                print("第一条就失败了，终止（服务端可能没在 %s 监听）。" % base_url, file=sys.stderr)
                return 1
            continue

        records.append(record)
        last_ten_ms.append(record["wall_ms"])
        if index % 10 == 0 or index == len(calls):
            ok_records = [r for r in records if r.get("error") is None]
            sentence_pass = sum(1 for r in ok_records if r["sentence_pass"])
            kept = sum(r["terms_kept"] for r in ok_records)
            total = sum(r["terms_total"] for r in ok_records)
            residual = sum(r["placeholder_residual"] for r in ok_records)
            print("[%03d/%03d] 整句全中=%d 按词=%d/%d 残留占位符=%d empty=%d | 平均 %.0fms" % (
                index, len(calls), sentence_pass, kept, total, residual,
                sum(1 for r in ok_records if r["empty"]),
                sum(last_ten_ms) / len(last_ten_ms)))
            sys.stdout.flush()
            last_ten_ms = []

    elapsed = time.time() - started_at
    summary = summarize(records, args.strategies, args.targets)
    samples = pick_samples(records, args.strategies, args.targets, limit=6)

    meta = {
        "generated_at": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z"),
        "base_url": base_url,
        "model_path": (props or {}).get("model_path") or (props or {}).get("model_alias"),
        "total_slots": (props or {}).get("total_slots"),
        "n_predict": args.n_predict,
        "temperature": 0,
        "stop": ["<|im_end|>"],
        "prompt_shell": "chatml, thinking off",        "strategies": args.strategies,
        "targets": args.targets,
        "samples": [{"id": sample_id, "target": target} for sample_id, target in samples],
        "elapsed_s": round(elapsed, 1),
        "python": platform.python_version(),
        "platform": platform.platform(),
        "limit": args.limit,
        "props_error": props_error,
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    raw_path = out_dir / "ab_raw.json"
    report_path = out_dir / "ab_english.md"

    with open(raw_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"meta": meta, "summary": summary_for_json(summary), "results": records},
                  handle, ensure_ascii=False, indent=2)

    report = render_report(records, summary, meta, args.strategies, args.targets, samples)
    with open(report_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(report)

    best, _ = pick_recommendation(summary, args.strategies, args.targets)
    non_en = [t for t in args.targets if t != "en"] or list(args.targets)
    print("-" * 78)
    print("完成：%d 次调用，成功 %d / 失败 %d，耗时 %.1fs" % (
        len(records), summary["calls_ok"], summary["errors"], elapsed))
    print("自动指标建议：%s（按词保留率 %.1f%%，整句全中率 %.1f%%）" % (
        STRATEGY_LABELS[best["strategy"]], 100.0 * best["word_retention"],
        100.0 * best["sentence_pass_rate"]))
    print("报告: %s" % report_path)
    print("原始: %s" % raw_path)

    return 1 if (summary["errors"] or not summary["calls_ok"]) else 0


if __name__ == "__main__":
    sys.exit(main())
