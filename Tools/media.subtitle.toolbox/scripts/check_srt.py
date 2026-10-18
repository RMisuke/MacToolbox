#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SRT 质量门禁：行宽 / 行数 / 时长 / 时序 / 越界 / 覆盖率。

用法:
  python3 check_srt.py out.srt [视频总秒数] [--line-char 18] [--min-dur 1.0] [--max-dur 7]

阈值默认与 make_srt.py 同口径；流水线会把 config 里的 lineChar/minDur/maxDur 传进来，
避免"生成器按 22 排、质检按 18.6 判"这种两套标准互相打架。

不做任何修改，只报告；硬门禁不通过时 exit 1，并打印 FAIL 原因。
"""
import argparse
import re
import sys
import unicodedata

LINE_TOL = 0.6         # 行宽容差（留给不可拆的英文单词），与 make_srt.py 一致
DUR_TOL = 0.8          # 时长下限容差：生成器保证 min_dur，质检按 min_dur*0.8 判
MAX_LINES = 2
MAX_DUR_RATIO = 1.3    # 时长上限容差


def disp_w(s: str) -> float:
    """显示宽度：CJK/全角 = 1，其余 = 0.5"""
    return sum(1.0 if unicodedata.east_asian_width(c) in ("W", "F") else 0.5 for c in s)


def parse(path: str):
    blocks = re.split(r"\n\s*\n", open(path, encoding="utf-8").read().strip())
    subs = []
    for b in blocks:
        lines = b.split("\n")
        if len(lines) < 3 or "-->" not in lines[1]:
            continue
        a, z = [x.strip() for x in lines[1].split("-->")]

        def sec(t):
            h, m, r = t.replace(",", ".").split(":")
            return int(h) * 3600 + int(m) * 60 + float(r)

        subs.append({"i": lines[0].strip(), "a": sec(a), "z": sec(z), "lines": lines[2:]})
    return subs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("total", nargs="?", type=float)
    ap.add_argument("--line-char", type=float, default=18)
    ap.add_argument("--min-dur", type=float, default=1.0)
    ap.add_argument("--max-dur", type=float, default=7.0)
    ap.add_argument("--max-lines", type=int, default=MAX_LINES)
    args = ap.parse_args()

    path, total = args.path, args.total
    max_line_w = args.line_char + LINE_TOL
    min_dur = max(0.3, args.min_dur * DUR_TOL)
    max_dur = args.max_dur * MAX_DUR_RATIO

    subs = parse(path)
    if not subs:
        print("FAIL: 没有解析到任何字幕块")
        sys.exit(1)

    bad_w = [s for s in subs if max(disp_w(x) for x in s["lines"]) > max_line_w]
    bad_l = [s for s in subs if len(s["lines"]) > args.max_lines]
    too_short = [s for s in subs if s["z"] - s["a"] < min_dur]
    too_long = [s for s in subs if s["z"] - s["a"] > max_dur]
    overlap = [subs[i] for i in range(1, len(subs)) if subs[i]["a"] < subs[i - 1]["z"] - 0.01]
    disorder = [subs[i] for i in range(1, len(subs)) if subs[i]["a"] < subs[i - 1]["a"]]
    durs = [s["z"] - s["a"] for s in subs]

    print(f"条数 {len(subs)}")
    print(f"时长 均值 {sum(durs)/len(durs):.2f}s  最短 {min(durs):.2f}s  最长 {max(durs):.2f}s")
    print(f"行宽超 {max_line_w:.1f}: {len(bad_w)}")
    print(f"超过 {args.max_lines} 行: {len(bad_l)}")
    print(f"时长 <{min_dur:.2f}s: {len(too_short)}  >{max_dur:.2f}s: {len(too_long)}")
    print(f"时间重叠: {len(overlap)}  乱序: {len(disorder)}")
    overrun = bool(total is not None and subs[-1]["z"] > total + 0.5)
    if total is not None:
        print(f"末条结束 {subs[-1]['z']:.2f}s / 视频总长 {total:.2f}s")
        covered = sum(min(s["z"], total) - s["a"] for s in subs if s["a"] < total)
        print(f"字幕覆盖 {covered / total * 100:.1f}% 的时间轴")

    for name, arr in (("行宽超限（建议项，不阻断）", bad_w), ("超行数（硬门禁）", bad_l),
                      ("时长过短（硬门禁）", too_short), ("时长过长（建议项，不阻断）", too_long)):
        if arr:
            print(f"\n-- {name} --")
            for s in arr[:5]:
                print(f"  #{s['i']} [{s['a']:.2f}-{s['z']:.2f}] "
                      f"w={max(disp_w(x) for x in s['lines']):.1f} | {''.join(s['lines'])[:45]}")

    reasons = []
    if bad_l:
        reasons.append(f"超过 {args.max_lines} 行 {len(bad_l)} 条")
    if too_short:
        reasons.append(f"时长 <{min_dur:.2f}s {len(too_short)} 条")
    if overlap:
        reasons.append(f"时间重叠 {len(overlap)} 处")
    if disorder:
        reasons.append(f"乱序 {len(disorder)} 处")
    if overrun:
        reasons.append(f"末条超出视频时长 {subs[-1]['z'] - total:.2f}s")

    if reasons:
        print("\nFAIL: " + "；".join(reasons))
        sys.exit(1)
    if bad_w or too_long:
        print("\nPASS（存在建议项，未阻断）")


if __name__ == "__main__":
    main()
