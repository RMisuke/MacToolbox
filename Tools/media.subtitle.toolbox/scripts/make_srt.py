#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
whisper.cpp segment 级 JSON -> 可读 SRT 字幕
处理：幻觉过滤 / 碎片合并 / 长段按标点切分 / 行长与行数控制 / 时长下限
用法:
  python3 make_srt.py --src raw.json --out out.srt [--max-char 36] [--line-char 18]
"""
import argparse, json, os, re, sys, tempfile, unicodedata

# jieba 支持外置盘路径，由 App / 环境变量注入
_LIB = os.environ.get("SUBTITLE_JIEBA_LIB", "/Volumes/APPLE 1TB/Whisper/lib")
if os.path.isdir(_LIB):
    sys.path.insert(0, _LIB)
try:
    _TMP = os.environ.get("SUBTITLE_TMPDIR") or tempfile.mkdtemp(prefix="mactoolbox-srt-")
    os.makedirs(_TMP, exist_ok=True)
    os.environ["TMPDIR"] = _TMP
except Exception:
    pass
try:
    import jieba
    jieba.setLogLevel(60)
    HAVE_JIEBA = True
except Exception:
    HAVE_JIEBA = False

def word_bounds(text):
    """返回允许断行的字符下标集合（词边界）"""
    if not HAVE_JIEBA:
        return set(range(1, len(text)))
    bounds, pos = set(), 0
    for w in jieba.cut(text, HMM=False):
        pos += len(w)
        bounds.add(pos)
    return bounds

# whisper 常见幻觉（中文训练数据污染 + 片尾样板话）
HALLUCINATION_PATTERNS = [
    r"优优独播剧场", r"YoYo Television", r"字幕由.{0,12}(提供|制作|翻译)",
    r"请不吝(点赞|订阅|打赏)", r"订阅(我的)?频道", r"amara\.org",
    r"感谢观看", r"下期再见", r"明镜与点点栏目", r"中文字幕",
    r"^\s*[\[\(（【]?\s*(音乐|掌声|笑声|silence|music|applause)\s*[\]\)）】]?\s*$",
]
HALLU_RE = re.compile("|".join(HALLUCINATION_PATTERNS), re.I)

def disp_w(s):
    """显示宽度：CJK/全角=1，ASCII=0.5"""
    w = 0.0
    for ch in s:
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            w += 1.0
        elif ch == " ":
            w += 0.5
        else:
            w += 0.5
    return w

def clean_text(t):
    t = re.sub(r"\s+", " ", t).strip()
    t = t.replace(" ,", ",").replace(" .", ".")
    return t

def is_noise(t):
    if not t:
        return True
    if HALLU_RE.search(t):
        return True
    if re.fullmatch(r"[\s\.,;:!?，。；：！？、…\-—_*·♪\[\]\(\)（）]+", t):
        return True
    return False

# 停顿标点（强 → 弱），半角逗号在 whisper 中文输出里等同于中文逗号
STRONG = "。！？!?；;"
WEAK = "，,、：:"

# 行宽容差：与 check_srt.py 的 MAX_LINE_W 同一个口径（line_char + 0.6）
LINE_TOL = 0.6
def split_sentences(t):
    """按标点切小句，保留标点；英文句点仅在后面跟空格/结尾时视为句末"""
    parts, buf = [], ""
    for i, ch in enumerate(t):
        buf += ch
        if ch in STRONG:
            parts.append(buf); buf = ""
        elif ch in WEAK:
            parts.append(buf); buf = ""
        elif ch == "." and (i + 1 == len(t) or t[i + 1] == " "):
            parts.append(buf); buf = ""
    if buf.strip():
        parts.append(buf)
    return [p.strip() for p in parts if p.strip()]

def hard_split_by_width(t, max_w):
    """按显示宽度切分，只允许在词边界切；单个超宽词才硬切"""
    bounds = word_bounds(t)
    out, start, n = [], 0, len(t)
    while start < n:
        best = None
        for i in range(start + 1, n + 1):
            if disp_w(t[start:i]) > max_w:
                break
            if i == n:
                best = i
            elif i in bounds:
                # 不在两个英文单词之间切（accounting|standards）
                if not (t[i-1].isascii() and t[i].isascii()
                        and t[i-1].isalpha() and t[i].isalpha()):
                    best = i
        if best is None:
            best = start + 1
            while best < n and disp_w(t[start:best + 1]) <= max_w:
                best += 1
        out.append(t[start:best].strip())
        start = best
    return [x for x in out if x]

def balanced_split(t, max_w):
    """把超宽单句按词边界对半切，直到每片不超 max_w（避免贪心切出很短的尾巴）"""
    if disp_w(t) <= max_w:
        return [t]
    bounds = [i for i in sorted(word_bounds(t)) if 0 < i < len(t)]
    # 不在两个英文单词之间切（accounting|standards）
    bounds = [i for i in bounds
              if not (t[i-1].isascii() and t[i].isascii()
                      and t[i-1].isalpha() and t[i].isalpha())]
    if not bounds:
        return hard_split_by_width(t, max_w)
    half = disp_w(t) / 2.0
    cut = min(bounds, key=lambda i: abs(disp_w(t[:i]) - half))
    a, b = t[:cut].strip(), t[cut:].strip()
    if not a or not b:
        return hard_split_by_width(t, max_w)
    return balanced_split(a, max_w) + balanced_split(b, max_w)

def pack_sentences(sents, max_w):
    """贪心装箱：把若干小句合成不超过 max_w 的字幕条"""
    out, cur = [], ""
    for s in sents:
        if disp_w(s) > max_w:
            if cur:
                out.append(cur); cur = ""
            out.extend(balanced_split(s, max_w))
            continue
        if cur and disp_w(cur + s) > max_w:
            out.append(cur); cur = s
        else:
            cur += s
    if cur:
        out.append(cur)
    return out

FUNC_WORDS = set("的了着地得们和与及或在是不很个这那就都也还把被让给对从到而但因所以为要会有能可每各其之而且并则若虽")

def safe_cut(text, i):
    """判断在 i 处断行是否安全：不切英文单词、不切数字、不在虚词后断"""
    if i <= 0 or i >= len(text):
        return False
    a, b = text[i - 1], text[i]
    if a.isascii() and a.isalpha() and b.isascii() and b.isalpha():
        return False
    if a.isdigit() and b.isdigit():
        return False
    if a in FUNC_WORDS:
        return False
    if b in "，,。、；;：:！？!?…":
        return False
    return True

def wrap_two_lines(t, line_w):
    """折成两行：只在词边界切，优先标点后，且第二行不以标点开头"""
    t = re.sub(r"^[,，。、；;：:]\s*", "", t).strip()
    if disp_w(t) <= line_w:
        return t
    bounds = word_bounds(t)
    n = len(t)

    def collect(limit):
        cs = []
        for i in range(1, n):
            if i not in bounds:
                continue
            a, b = t[:i].strip(), t[i:].strip()
            if not a or not b or b[0] in "，,。、；;：:！？!?…":
                continue
            if disp_w(a) <= limit and disp_w(b) <= limit:
                rank = 0 if a[-1] in "，,。、；;：:！？!?" else (1 if a[-1] == " " else (2 if safe_cut(t, i) else 3))
                cs.append((rank, -min(disp_w(a), disp_w(b)), i))
        return cs

    cands = collect(line_w) or collect(line_w * 1.25)
    if not cands:
        return t
    cands.sort()
    cut = cands[0][2]
    a, b = t[:cut].strip(), t[cut:].strip()
    b = re.sub(r"^[,，、；;：:]\s*", "", b) or b
    return a + "\n" + b

# 需要删除的标点（保留英文词间空格、% & / + - 等有语义的符号）
PUNCT_CHARS = "，。、；：？！“”‘’（）《》〈〉【】…—·,.!?;:\"'()[]{}<>"

# 口头禅/语气词（按长度倒序匹配，避免短词先吃掉长词）
FILLERS = ["对不对呀", "对不对", "对吧呀", "对吧", "是吧", "好吗", "好吧", "行吧",
           "可以吧", "对不啦"]

# 明确的叠词口误（只列高置信的，不做通用叠词删除，避免误伤"看看/常常"）
DUP_PAIRS = ["这个这个", "那个那个", "我们我们", "就是就是", "然后然后",
             "所以所以", "因为因为", "其实其实", "但是但是", "那个那个"]

SINGLE_FILLER_RE = re.compile(r"([，。、；：？！,.;:!?])\s*(?:嗯|呃|诶|额|哦|噢)+(?=[，。、；：？！,.;:!?]|$)")

def drop_fillers(t):
    """删除语气词、口头禅与高置信重复，返回清洗后的文本"""
    # 整条只剩一个语气单字（好/嗯/啊…）→ 无信息量，整条丢弃
    if re.fullmatch(r"[好嗯啊哦噢诶喂对行]", t.strip()):
        return ""
    for p in sorted(FILLERS, key=len, reverse=True):
        t = t.replace(p, "")
    for p in DUP_PAIRS:
        t = t.replace(p, p[:len(p)//2])
    t = SINGLE_FILLER_RE.sub(lambda m: m.group(1), t)
    t = re.sub(r"^(?:呃|嗯|诶)+\s*", "", t)   # 句首语气词
    t = re.sub(r"[，。、；：？！,.;:!?]{2,}", "，", t)
    t = re.sub(r"^[，。、；：？！,.;:!?]\s*", "", t).strip()
    # 清理后只剩语气单字 → 丢弃
    if re.fullmatch(r"[好嗯啊哦噢诶喂对行是]", t):
        return ""
    return t

def strip_punct(s):
    # 先把数字串整体保护起来（保留小数点与千分位逗号）
    nums = []
    def _protect(m):
        nums.append(m.group(0))
        return f"\x01{len(nums)-1}\x02"
    s = re.sub(r"\d+(?:,\d{3})+(?:\.\d+)?|\d+\.\d+|\d+", _protect, s)
    # 英文之间的标点改空格，避免缩写粘连（FA、FR → FA FR）
    s = re.sub(r"(?<=[A-Za-z])[、，,;；:：/]\s*(?=[A-Za-z])", " ", s)
    s = s.translate({ord(c): None for c in PUNCT_CHARS})
    s = re.sub(r"\x01(\d+)\x02", lambda m: nums[int(m.group(1))], s)
    return re.sub(r"\s+", " ", s).strip()

def ts(sec):
    if sec < 0:
        sec = 0
    h = int(sec // 3600); m = int((sec % 3600) // 60)
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",")

def repair_min_dur(out, min_dur):
    """时长下限：不足时向相邻条借时间（先向后借、再向前借），返回仍不达标的条数。

    以前这里只是把 end 钳到下一条 start-0.01，遇到"开场问候 + 下一条紧邻"就什么都延不了，
    0.7 秒的条照样写进 SRT，然后被质检硬门禁判死。
    """
    unresolved = 0
    for i, s in enumerate(out):
        need = min_dur - (s["end"] - s["start"])
        if need <= 1e-6:
            continue
        nxt = out[i + 1] if i + 1 < len(out) else None
        prev = out[i - 1] if i > 0 else None
        if nxt and (nxt["end"] - nxt["start"]) - need >= min_dur:
            s["end"] = s["start"] + min_dur
            nxt["start"] = s["end"] + 0.01
        elif prev and (prev["end"] - prev["start"]) - need >= min_dur:
            prev["end"] = prev["end"] - need - 0.02
            s["start"] = prev["end"] + 0.01
        elif nxt:
            s["end"] = nxt["start"] - 0.01
            unresolved += 1
        else:
            s["end"] = s["start"] + min_dur
    return unresolved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-char", type=float, default=36, help="单条字幕最大显示宽度(全角)")
    ap.add_argument("--line-char", type=float, default=18, help="单行最大显示宽度(全角)")
    ap.add_argument("--max-dur", type=float, default=7.0, help="单条字幕最长秒数")
    ap.add_argument("--min-dur", type=float, default=1.0, help="单条字幕最短秒数")
    ap.add_argument("--merge-gap", type=float, default=0.35, help="碎片合并的最大间隔秒")
    ap.add_argument("--fix", help="术语修正 JSON 文件（{错词: 正确写法}）")
    ap.add_argument("--strip-punct", action="store_true", help="输出时删除所有标点（断句仍用原文标点计算）")
    ap.add_argument("--drop-fillers", action="store_true", help="删除语气词/口头禅/高置信重复")
    args = ap.parse_args()

    d = json.load(open(args.src, encoding="utf-8"))
    segs = []
    dropped = []
    for s in d.get("transcription", []):
        text = clean_text(s.get("text", ""))
        start, end = s["offsets"]["from"] / 1000.0, s["offsets"]["to"] / 1000.0
        if is_noise(text):
            dropped.append((start, end, text)); continue
        # 幻觉特征：超长时段却几乎无字（正常语速约 4-6 字/秒）
        dur = end - start
        if dur > 8 and len(text) / dur < 1.2:
            dropped.append((start, end, text)); continue
        segs.append({"start": start, "end": end, "text": text})

    # 1) 碎片合并：间隔小且合并后不超限；英文被段边界切断的强制接回
    merged = []
    for s in segs:
        if merged:
            p = merged[-1]
            gap = s["start"] - p["end"]
            joined = p["text"] + s["text"]
            cross_word = bool(re.search(r"[A-Za-z]$", p["text"]) and re.match(r"^[A-Za-z]", s["text"]))
            if cross_word and gap <= 0.6:
                p["text"] = p["text"] + " " + s["text"]; p["end"] = s["end"]; continue
            if (gap <= args.merge_gap and disp_w(joined) <= args.max_char
                    and (s["end"] - p["start"]) <= args.max_dur
                    and not re.search(r"[。！？!?；;]$", p["text"])):
                p["text"] = joined; p["end"] = s["end"]; continue
        merged.append(dict(s))

    # 1.5) 术语修正（高置信同音错词，逐条精确替换）
    if args.fix and os.path.exists(args.fix):
        fixes = json.load(open(args.fix, encoding="utf-8"))
        hits = {}
        for s in merged:
            for bad, good in fixes.items():
                if bad in s["text"]:
                    n = s["text"].count(bad)
                    s["text"] = s["text"].replace(bad, good)
                    hits[bad] = hits.get(bad, 0) + n
        if hits:
            print("术语修正: " + ", ".join(f"{k}→{v}" for k, v in hits.items()))

    # 1.8) 语气词/口头禅/重复句清理（整条变空则移除，时间轴留白）
    if args.drop_fillers:
        cleaned, removed = [], 0
        for s in merged:
            t = drop_fillers(s["text"])
            if not t:
                removed += 1
                continue
            s["text"] = t
            cleaned.append(s)
        merged = cleaned
        print(f"语气词清理: 剩余 {len(merged)} 条, 整条删除 {removed} 条")

    # 2) 超长/超字数段切分，时间按字数比例分摊
    out = []
    for s in merged:
        text, dur = s["text"], s["end"] - s["start"]
        need = disp_w(text) > args.max_char or dur > args.max_dur
        if not need:
            out.append(dict(s)); continue
        pieces = pack_sentences(split_sentences(text), args.max_char)
        if len(pieces) == 1 and disp_w(pieces[0]) > args.max_char:
            pieces = balanced_split(pieces[0], args.max_char)
        # 字数不多但语速慢导致超长 → 按词边界对半切
        if len(pieces) == 1 and dur > args.max_dur:
            t0 = pieces[0]
            bounds = word_bounds(t0)
            mid = len(t0) // 2
            cuti = min(bounds, key=lambda i: abs(i - mid)) if bounds else mid
            if 0 < cuti < len(t0):
                pieces = [t0[:cuti].strip(), t0[cuti:].strip()]
        total_w = sum(max(disp_w(p), 1e-6) for p in pieces)
        t = s["start"]
        for p in pieces:
            share = dur * (disp_w(p) / total_w)
            out.append({"start": t, "end": t + share, "text": p})
            t += share

    # 2.2) 纯英文短条（如 standards / governance）并入前条，避免孤立单词成屏
    en_fixed = []
    for s in out:
        if (en_fixed and disp_w(s["text"]) <= 10
                and not re.search(r"[\u4e00-\u9fa5]", s["text"])):
            p = en_fixed[-1]
            if disp_w(p["text"] + " " + s["text"]) <= args.max_char:
                p["text"] = p["text"] + " " + s["text"]
                p["end"] = s["end"]
                continue
        en_fixed.append(dict(s))
    out = en_fixed

    # 2.5) 超短条（<0.8s）无法独立成屏：能并入前条就并，否则稍后延长
    fixed = []
    for s in out:
        short = (s["end"] - s["start"]) < 0.8
        if short and fixed:
            p = fixed[-1]
            if (disp_w(p["text"] + s["text"]) <= args.max_char
                    and s["end"] - p["start"] <= args.max_dur):
                p["text"] += s["text"]; p["end"] = s["end"]; continue
        fixed.append(dict(s))
    out = fixed

    # 2.55) 先修一次时长：能靠"借时间"补到 min_dur 的短条就保持独立成屏，
    #       不再为了消除短条把"同学们好"这类完整小句硬并进下一条
    unresolved = repair_min_dur(out, args.min_dur)

    # 2.6) 瞬时语气短句（借不到时间、且 <0.8s 且 ≤6 字）并入下一条开头
    final = []
    i = 0
    while i < len(out):
        s = out[i]
        if ((s["end"] - s["start"]) < 0.8 and len(s["text"]) <= 6 and i + 1 < len(out)):
            nxt = out[i + 1]
            if disp_w(s["text"] + nxt["text"]) <= args.max_char:
                nxt["text"] = s["text"] + nxt["text"]
                nxt["start"] = s["start"]
                i += 1
                continue
        final.append(s)
        i += 1
    out = final

    # 2.7) 极短碎片（<0.5s 且 ≤4 字）并入前条
    frag = []
    for s in out:
        if frag and (s["end"] - s["start"]) < 0.5 and len(s["text"]) <= 4:
            p = frag[-1]
            if disp_w(p["text"] + s["text"]) <= args.max_char:
                p["text"] += s["text"]; p["end"] = s["end"]
                continue
        frag.append(s)
    out = frag

    # 3) 行宽自检：两行折不进 line_char 容差的条，按词边界拆成两条
    #    （以前这里靠 wrap_two_lines 内部 1.25 倍放宽蒙混过去，直接踩穿质检门禁）
    tol = args.line_char + LINE_TOL

    def body_width(t):
        body = wrap_two_lines(t, args.line_char)
        return max((disp_w(x) for x in body.split("\n")), default=0.0)

    split_out, split_n = [], 0
    for s in out:
        if body_width(s["text"]) <= tol:
            split_out.append(s); continue
        t, dur = s["text"], s["end"] - s["start"]
        cands = []
        for c in sorted(word_bounds(t)):
            if c <= 0 or c >= len(t):
                continue
            if t[c - 1].isascii() and t[c].isascii() and t[c - 1].isalpha() and t[c].isalpha():
                continue
            a = t[:c].strip()
            b = re.sub(r"^[,，。、；：:！？!?…]\s*", "", t[c:].strip())
            if not a or not b:
                continue
            wa, wb = body_width(a), body_width(b)
            if wa > tol or wb > tol:
                continue
            cands.append((abs(disp_w(a) - disp_w(b)), c, a, b))
        if not cands or dur < 2 * args.min_dur:
            split_out.append(s); continue    # 单条无法再拆（如超长英文单词）→ 保留并告警
        cands.sort()
        _, _, a, b = cands[0]
        mid = s["start"] + dur * disp_w(a) / max(disp_w(a) + disp_w(b), 1e-6)
        split_out.append({"start": s["start"], "end": mid, "text": a})
        split_out.append({"start": mid, "end": s["end"], "text": b})
        split_n += 1
    out = split_out
    if split_n:
        print(f"行宽自检: 拆分 {split_n} 条超限条")

    # 3.5) 拆条后可能又切出短条，再修一次时长下限
    unresolved += repair_min_dur(out, args.min_dur)
    if unresolved:
        print(f"时长告警: {unresolved} 条因相邻条无余量仍短于 {args.min_dur}s")

    # 4) 输出
    over_w = 0
    with open(args.out, "w", encoding="utf-8") as f:
        n = 0
        for s in out:
            body = wrap_two_lines(s["text"], args.line_char)
            if args.strip_punct:
                lines = [strip_punct(x) for x in body.split("\n")]
                lines = [x for x in lines if x]
                if not lines:
                    continue
                body = "\n".join(lines)
            # 切分后可能产生只剩语气单字的碎片条，直接跳过
            if args.drop_fillers and re.fullmatch(r"[好嗯啊哦噢诶喂对行是]{1,2}", body.replace("\n", "")):
                continue
            out_lines = body.split("\n")
            worst = max(disp_w(x) for x in out_lines)
            if worst > tol:
                over_w += 1
                print(f"  [行宽告警] {s['start']:.2f}s 宽 {worst:.1f} 无合法折点: {out_lines[0][:40]}")
            n += 1
            f.write(f"{n}\n{ts(s['start'])} --> {ts(s['end'])}\n{body}\n\n")

    # 统计
    durs = [s["end"] - s["start"] for s in out]
    print(f"输入段 {len(segs) + len(dropped)} → 丢弃 {len(dropped)} → 合并/切分后 {len(out)} 条")
    for st, en, tx in dropped:
        print(f"  [丢弃 {st:.1f}-{en:.1f}s] {tx[:50]}")
    print(f"时长: 均值 {sum(durs)/len(durs):.2f}s 最短 {min(durs):.2f}s 最长 {max(durs):.2f}s")
    print(f"字数: 均值 {sum(len(s['text']) for s in out)/len(out):.1f}")
    print(f"行宽: 超 {tol:.1f} 的 {over_w} 条；时长下限 {args.min_dur:g}s 未达标 {unresolved} 条")

if __name__ == "__main__":
    main()
