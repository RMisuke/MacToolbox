# 字幕语言误判排查（2026-10-18）

## 现象

`09-Macroeconomic targets.mp4` 是中文课程，但成品字幕里出现整段英文：

```
6
00:00:29,080 --> 00:00:32,191
Now lets talk about the

7
00:00:32,191 --> 00:00:36,340
environment and the environment
```

原任务：`20261018-200115-media.subtitle-036109`。

## 证据链

1. 旧任务 `config.json` 里语言是 `auto`：

   ```json
   "language" : "auto"
   ```

2. 旧 `job.log` 第 56 行显示 whisper 实际按英文运行：

   ```
   main: processing ... lang = en, task = transcribe ...
   ```

3. 英文在 ASR 原始结果里已经存在，不是 LLM 翻译出来的：

   - `raw.txt` 第 2–11 行连续是英文；
   - `fixes.json` 只有 14 条词表规则；
   - `job.log`：`LLM 片段 1/1：新增 0 条`、`LLM 校对完成：共 14 条规则`。
   - 旧成品 194 条里，26 条是纯英文块；中文/拉丁字符占比约 71% / 29%。

4. 同批 `12-Summary of chapter 2.mp4` 也用了 `auto`，旧日志同样是 `lang = en`；
   旧成品 35 条里有 12 条纯英文。

## 根因

`whisper-cli` 不传 `-l` 时默认是 **英文**，不是自动检测。

`tool.py` 原来写的是：

```python
if language and language != "auto":
    cmd += ["-l", language]
```

选「自动」时反而没有传 `-l auto`，于是 whisper 按 `en` 转写。中文语音被英文
语言 token 强行解码，就出现中文、英文混杂和整段英文幻觉。

## 修复

- 任何情况下都显式传 `-l`；`auto` 映射为 `-l auto`。
- 记录并输出 whisper 自动检测结果（语言 + 概率）。
- 增加兜底：自动检测为 `en`，但 raw 正文中文占比 ≥ 20% 且中文字数 ≥ 80 时，
  保留 `raw.autodetect-en.*`，自动改用 `zh` 重跑。
- 语言选项改为「中文（推荐） / 英文 / 自动检测」，帮助文案说明自动检测只采样开头 30 秒。
- 工具版本 `0.1.0 → 0.1.1`；App 版本 `0.1.0 → 0.1.1`。

修改文件：

- `Tools/media.subtitle.toolbox/scripts/tool.py`
- `Tools/media.subtitle.toolbox/tool.json`
- `App/Info.plist`

## 验证

| 素材 | 修复前 | 修复后 |
|---|---|---|
| 09（16.5 分钟） | 310 段，26 条纯英文，194 条成品 | 432 段，1 条英文（疑似课件原句），181 条成品 |
| 12（2.5 分钟） | 45 段，12 条纯英文，35 条成品 | 57 段，0 条纯英文，28 条成品 |

两次完整重跑都通过质检：

- 09：181 条，0 行宽超限，0 重叠/乱序，覆盖 99.9%；
- 12：28 条，0 行宽超限，0 重叠/乱序，覆盖 99.7%。

视频目录里的成品已替换为修正版，旧成品备份在 `backup/`。

## 文件

- `evidence/09-old-job.log`：旧任务日志（`lang = en`）
- `evidence/09-old-config.json`：旧配置（`language = auto`）
- `evidence/09-old-raw.txt`：旧 ASR 原始文本（含整段英文）
- `evidence/09-old-fixes.json`：旧校对规则（14 条，未翻译）
- `backup/09-old.srt` / `backup/12-old.srt`：旧成品
- `09/out/` / `12/out/`：修正版成品
- `09/run.jsonl` / `12/run.jsonl`：修复后完整流水线日志
