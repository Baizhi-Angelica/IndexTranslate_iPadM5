#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Prompt 字节级校验：本地 Python 镜像 vs App 里的 Swift PromptBuilder。

为什么需要：本机是 Windows，没有 Xcode，Swift 侧改了 prompt 也不能本地跑。
这个脚本生成一批 case（语料 × 目标语言 × 翻译需求），Python 侧算出期望 prompt；
CI 里的 `verify-prompts.yml` 用同样的 case 编译并运行
`Sources/Core.swift` + `Sources/MT/Prompts.swift` + `Sources/InstructionPresets.swift`，
输出实际 prompt，两边逐字节比较。任何一边漂移都会让 CI 变红。

用法::

    # 生成 case + Python 侧期望值（CI 第一步）
    python tools/verify_prompts.py --cases /tmp/cases.json --expect /tmp/expected.json

    # 拿 Swift 侧输出与期望值比较（CI 最后一步）
    python tools/verify_prompts.py --expected /tmp/expected.json --actual /tmp/actual.json

只依赖 Python 3 标准库 + 同目录的 segments.py / regress_prompts.py（prompt 拼装以它们为准）。
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

import regress_prompts as prompts  # noqa: E402
import segments as corpus  # noqa: E402

# 额外构造的边界语料（没有英文词 / 纯英文 / 多英文片段），覆盖 glossary 分支的两侧
SYNTHETIC_SEGMENTS = [
    {"id": "syn-empty-terms", "source": "chinese", "text": "好的，我明白了，谢谢。",
     "english_terms": []},
    {"id": "syn-multi-terms", "source": "chinese",
     "text": "明天 10:30 在 Room 305 用 Zoom 开会，记得带 slides 和 laptop。",
     "english_terms": []},
    {"id": "syn-english", "source": "english",
     "text": "Could you book a table for two at 7 pm, please?", "english_terms": []},
]

# 自定义需求：覆盖多行、行首序号、自带标签、纯空白（应视为没有需求）
CUSTOM_INSTRUCTIONS = [
    "回答尽量简短。",
    "1. 语气正式，用敬语。\n2. 数字保留阿拉伯数字。",
    "【硬性要求】专名/术语对照: API→API\n【注意】语气友好一些。",
    "   \n\n  ",
]

PRESET_TARGETS = ("en", "ja", "it", "ru", "zh")
CUSTOM_TARGETS = ("en", "ja", "ru")


def _segment_with_terms(segment: dict) -> dict:
    """补齐 english_terms（合成语料没写，按 App 的规则抽出来）。"""
    item = dict(segment)
    if "english_terms" not in item:
        item["english_terms"] = prompts.extract_english_terms(item["text"])
    return item


def build_cases() -> list:
    """case 结构必须与 tools/verify_prompt_swift/PromptVerify.swift 的 Decodable 对齐。"""
    cases = []
    base_segments = [_segment_with_terms(segment) for segment in corpus.SEGMENTS]
    synthetic = [_segment_with_terms(segment) for segment in SYNTHETIC_SEGMENTS]
    all_segments = base_segments + synthetic

    # 1) 默认路径（无翻译需求）：每条语料 × 每个合法目标语言
    for segment in all_segments:
        for target in prompts.TARGETS_BY_SOURCE[segment["source"]]:
            cases.append({
                "name": "default/%s/%s" % (segment["id"], target),
                "source": segment["source"],
                "target": target,
                "text": segment["text"],
                "instruction": "",
            })

    # 2) 内置场景：语料子集 × 几个方向（覆盖术语表 + 非术语表 + 新增语言）
    subset = [segment for segment in all_segments
              if segment["id"] in ("zh-01", "zh-02", "zh-06", "zh-12", "en-01", "en-02",
                                   "syn-empty-terms", "syn-multi-terms", "syn-english")]
    for preset_name in sorted(prompts.INSTRUCTION_PRESETS):
        instruction = prompts.INSTRUCTION_PRESETS[preset_name]
        for segment in subset:
            for target in PRESET_TARGETS:
                if target not in prompts.TARGETS_BY_SOURCE[segment["source"]]:
                    continue
                cases.append({
                    "name": "preset/%s/%s/%s" % (preset_name, segment["id"], target),
                    "source": segment["source"],
                    "target": target,
                    "text": segment["text"],
                    "instruction": instruction,
                })

    # 3) 自定义需求：验证多行 / 序号 / 自带标签 / 纯空白
    for index, instruction in enumerate(CUSTOM_INSTRUCTIONS):
        for segment in ("zh-01", "zh-04", "en-03"):
            segment_data = next(item for item in all_segments if item["id"] == segment)
            for target in CUSTOM_TARGETS:
                if target not in prompts.TARGETS_BY_SOURCE[segment_data["source"]]:
                    continue
                cases.append({
                    "name": "custom/%d/%s/%s" % (index, segment_data["id"], target),
                    "source": segment_data["source"],
                    "target": target,
                    "text": segment_data["text"],
                    "instruction": instruction,
                })

    return cases


def build_expected(cases: list) -> list:
    expected = []
    for case in cases:
        segment = {
            "id": case["name"],
            "source": case["source"],
            "text": case["text"],
            "english_terms": prompts.extract_english_terms(case["text"]),
        }
        prompt = prompts.build_prompt(segment, case["target"], case["instruction"])
        expected.append({"name": case["name"], "prompt": prompt})
    return expected


def _load_json(path: Path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def emit(cases_path: Path, expect_path: Path) -> int:
    cases = build_cases()
    expected = build_expected(cases)
    cases_path.parent.mkdir(parents=True, exist_ok=True)
    expect_path.parent.mkdir(parents=True, exist_ok=True)
    with open(cases_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"generated_at": datetime.now().astimezone().isoformat(),
                   "cases": cases}, handle, ensure_ascii=False, indent=2)
    with open(expect_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"generated_at": datetime.now().astimezone().isoformat(),
                   "results": expected}, handle, ensure_ascii=False, indent=2)
    print("生成 case %d 条" % len(cases))
    print("  cases    : %s" % cases_path)
    print("  expected : %s" % expect_path)
    return 0


def compare(expect_path: Path, actual_path: Path) -> int:
    expected = {item["name"]: item["prompt"] for item in _load_json(expect_path)["results"]}
    actual_payload = _load_json(actual_path)
    actual = {item["name"]: item["prompt"] for item in actual_payload}

    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    diffs = []
    for name in sorted(set(expected) & set(actual)):
        if expected[name] != actual[name]:
            diffs.append(name)

    print("比较 %d 条 case（Swift 输出 %d 条）" % (len(expected), len(actual)))
    if missing:
        print("!! Swift 侧缺少 %d 条：%s" % (len(missing), ", ".join(missing[:10])))
    if extra:
        print("!! Swift 侧多出 %d 条：%s" % (len(extra), ", ".join(extra[:10])))
    if diffs:
        print("!! %d 条 prompt 不一致：" % len(diffs))
        for name in diffs[:5]:
            print("-" * 70)
            print("case:", name)
            print("expected:", repr(expected[name]))
            print("actual  :", repr(actual[name]))
        return 1

    print("OK：Swift PromptBuilder 与 Python 镜像逐字节一致。")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Swift / Python prompt 字节级校验")
    parser.add_argument("--cases", metavar="PATH", help="生成 case JSON 到该路径（配合 --expect）")
    parser.add_argument("--expect", metavar="PATH", help="生成 Python 侧期望 prompt JSON 到该路径")
    parser.add_argument("--expected", metavar="PATH", help="比较模式：Python 期望 prompt JSON")
    parser.add_argument("--actual", metavar="PATH", help="比较模式：Swift 实际输出 JSON")
    args = parser.parse_args(argv)

    if args.cases and args.expect:
        return emit(Path(args.cases), Path(args.expect))
    if args.expected and args.actual:
        return compare(Path(args.expected), Path(args.actual))
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
