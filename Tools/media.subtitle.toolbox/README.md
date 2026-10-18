# 视频字幕生成

`media.subtitle` 是 MacToolbox 的 Protocol 工具：本地 whisper.cpp 或
OpenAI 兼容云端转写，可选人工检查点 / LLM 校对，最终输出 SRT / VTT。

## CLI / Agent

```bash
# 本地转写，不校对
bin/mct run media.subtitle \
  --input video=/tmp/course.mp4 \
  --input backend=local \
  --input reviewMode=off \
  --input language=zh --json

# 人工检查点：非 TTY 下退出 6，修改 jobDir/fixes.json 后续跑
bin/mct run media.subtitle \
  --input video=/tmp/course.mp4 --input reviewMode=manual
bin/mct resume --job <jobDir> --checkpoint auto --json
```

- `agent.checkpoint=manual`：CLI/Agent 默认在检查点暂停并保留 jobDir。
- `resume` 会复用 probe / audio / raw / fixes / final，只补缺失步骤。
- 声明 `resources: ["gpu"]`；`mct batch` 会强制串行。
- `bin/mct doctor media.subtitle --json` 检查 ffmpeg / whisper-cli / 模型 / jieba。

## 环境

- ffmpeg / ffprobe：`brew install ffmpeg`
- whisper-cli（本地）：`brew install whisper.cpp`
- 模型：`ggml-large-v3-turbo.bin` 等，通过工具参数 `modelPath` 指定
- 云端：任何 OpenAI 兼容 `/audio/transcriptions` 与 `/chat/completions`

## 已知限制

- 本地 GPU 串行；批量仍逐项执行。
- 人工检查点依赖用户编辑 `fixes.json`；非交互 Agent 用 `checkpoint=auto` 或 `reviewMode=off`。
- 字幕工程与质检规则在 `scripts/make_srt.py` / `scripts/check_srt.py`。

