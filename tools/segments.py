#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""翻译回归测试语料（20 条）。

- 12 条中文：每条含 1-3 个英文词/短语（专有名词、技术词、课程/地点名、品牌名、缩写），
  用来验证“约束翻译” prompt 能否让英文词原样保留。
- 8 条英文：日常口语，验证中英反向翻译。

数据结构::

    {"id": "zh-01", "source": "chinese", "text": "...", "english_terms": ["dining hall", "library"]}

`english_terms` 只对中文语料有意义（英文语料留空）。
直接运行本文件会自检语料数量与约束：``python tools/segments.py``。
"""
from __future__ import annotations

import sys

# 源语言 key -> 官方 prompt 里使用的语言名
SOURCE_PROMPT_NAMES = {
    "chinese": "中文",
    "english": "英文",
}

SEGMENTS = [
    # ---------------- 中文语料（12 条） ----------------
    {
        "id": "zh-01",
        "source": "chinese",
        "text": "我明天早上九点去 dining hall，然后去 library 自习。",
        "english_terms": ["dining hall", "library"],  # 地点名
    },
    {
        "id": "zh-02",
        "source": "chinese",
        "text": "这个 bug 我 debug 了一整天，最后发现是 API 的 timeout 设置错了。",
        # 示例原文含 4 个英文词，故本条 english_terms 为 4 个（其余中文语料 1-3 个）
        "english_terms": ["bug", "debug", "API", "timeout"],  # 技术词 + 缩写
    },
    {
        "id": "zh-03",
        "source": "chinese",
        "text": "下周三的 presentation 记得交 slides，deadline 不能拖。",
        "english_terms": ["presentation", "slides", "deadline"],  # 校园/技术词
    },
    {
        "id": "zh-04",
        "source": "chinese",
        "text": "帮我点一杯 Starbucks 的 caramel macchiato，少冰，谢谢。",
        "english_terms": ["Starbucks", "caramel macchiato"],  # 品牌名 + 饮品名
    },
    {
        "id": "zh-05",
        "source": "chinese",
        "text": "请问去 Central Station 怎么走？坐 Metro 要换乘吗？",
        "english_terms": ["Central Station", "Metro"],  # 地点专名 + 交通词
    },
    {
        "id": "zh-06",
        "source": "chinese",
        "text": "这学期的 Machine Learning 课每周二在 Room 305 上，教授是 Dr. Chen。",
        "english_terms": ["Machine Learning", "Room 305", "Dr. Chen"],  # 课程/地点/专有名词
    },
    {
        "id": "zh-07",
        "source": "chinese",
        "text": "下午三点的 meeting 改到 Zoom 上了，记得 update 一下 calendar。",
        "english_terms": ["meeting", "Zoom", "calendar"],  # 品牌名 + 技术词
    },
    {
        "id": "zh-08",
        "source": "chinese",
        "text": "我每周去 gym 三次，最近在练 deadlift，感觉 core 力量强了。",
        "english_terms": ["gym", "deadlift", "core"],  # 健身词
    },
    {
        "id": "zh-09",
        "source": "chinese",
        "text": "医生建议我先拍个 X-ray，然后去 pharmacy 拿药，每天两次。",
        "english_terms": ["X-ray", "pharmacy"],  # 缩写 + 地点名
    },
    {
        "id": "zh-10",
        "source": "chinese",
        "text": "这款 iPhone 的手机壳在 Amazon 上只卖 20 美元，比 Apple Store 便宜。",
        "english_terms": ["iPhone", "Amazon", "Apple Store"],  # 品牌名
    },
    {
        "id": "zh-11",
        "source": "chinese",
        "text": "麻烦把报告发到我的 email，顺便 CC 给 HR。",
        "english_terms": ["email", "CC", "HR"],  # 缩写
    },
    {
        "id": "zh-12",
        "source": "chinese",
        "text": "我在 GitHub 上 clone 了这个 repo，但是一直报错。",
        "english_terms": ["GitHub", "clone", "repo"],  # 技术词 + 品牌名
    },
    # ---------------- 英文语料（8 条） ----------------
    {
        "id": "en-01",
        "source": "english",
        "text": "Can you help me move this desk to the third floor? My back is killing me.",
        "english_terms": [],
    },
    {
        "id": "en-02",
        "source": "english",
        "text": "I'd like to grab a coffee before the meeting. Do you want anything from the café?",
        "english_terms": [],
    },
    {
        "id": "en-03",
        "source": "english",
        "text": "The train is delayed again, so I might be late for dinner.",
        "english_terms": [],
    },
    {
        "id": "en-04",
        "source": "english",
        "text": "Could you send me the slides by Friday? I need some time to review them.",
        "english_terms": [],
    },
    {
        "id": "en-05",
        "source": "english",
        "text": "I'm looking for a pharmacy around here. Is it within walking distance?",
        "english_terms": [],
    },
    {
        "id": "en-06",
        "source": "english",
        "text": "My laptop keeps freezing, and I have no idea how to fix it.",
        "english_terms": [],
    },
    {
        "id": "en-07",
        "source": "english",
        "text": "Let's try that new noodle place for lunch next week.",
        "english_terms": [],
    },
    {
        "id": "en-08",
        "source": "english",
        "text": "I left my umbrella at the gym again. It always rains when I do that.",
        "english_terms": [],
    },
]

# 导出给脚本使用的便捷视图
CHINESE_SEGMENTS = [s for s in SEGMENTS if s["source"] == "chinese"]
ENGLISH_SEGMENTS = [s for s in SEGMENTS if s["source"] == "english"]


def iter_segments(source: str | None = None):
    """按 source 过滤（"chinese"/"english"/None=全部）。"""
    if source is None:
        return list(SEGMENTS)
    return [s for s in SEGMENTS if s["source"] == source]


def _self_check() -> int:
    errors = []
    if len(CHINESE_SEGMENTS) != 12:
        errors.append("中文语料应为 12 条，实际 %d 条" % len(CHINESE_SEGMENTS))
    if len(ENGLISH_SEGMENTS) != 8:
        errors.append("英文语料应为 8 条，实际 %d 条" % len(ENGLISH_SEGMENTS))
    ids = [s["id"] for s in SEGMENTS]
    if len(set(ids)) != len(ids):
        errors.append("存在重复 id: %s" % ids)
    for seg in SEGMENTS:
        text_low = seg["text"].lower()
        if seg["source"] == "chinese":
            n = len(seg["english_terms"])
            if not 1 <= n <= 4:
                errors.append("%s: english_terms 数量 %d 不合法（1-3，示例原文允许 4）" % (seg["id"], n))
            for term in seg["english_terms"]:
                if term.lower() not in text_low:
                    errors.append("%s: 语料里找不到 term %r" % (seg["id"], term))
        elif seg["source"] == "english":
            if seg["english_terms"]:
                errors.append("%s: 英文语料 english_terms 应为空" % seg["id"])
            if not seg["text"].strip():
                errors.append("%s: 文本为空" % seg["id"])
        else:
            errors.append("%s: 未知 source %r" % (seg["id"], seg["source"]))
    if errors:
        print("语料自检失败:")
        for err in errors:
            print("  -", err)
        return 1
    print("语料自检通过: %d 条（中文 %d / 英文 %d）" % (
        len(SEGMENTS), len(CHINESE_SEGMENTS), len(ENGLISH_SEGMENTS)))
    return 0


if __name__ == "__main__":
    sys.exit(_self_check())
