# 视频格式转换

`media.video-convert` 是 MacToolbox 的普通 Protocol 工具，负责封装/编码转换，
支持单条和批量。默认输出通用 MP4（H.264 + AAC），也可以做 WebM、AV1、ProRes、
GIF 和纯复制流 remux。

## CLI / Agent

```bash
bin/mct run media.video-convert --input video=/tmp/a.mov --input preset=mp4-h264 --json
bin/mct batch media.video-convert --input video=/tmp/videos --output-dir /tmp/out --json
```

## 支持范围

封装：

```text
MP4 / MOV / MKV / WebM / AVI / GIF
```

视频编码：

```text
H.264 (libx264) / H.265 (libx265) / AV1 (libsvtav1)
VP9 (libvpx-vp9) / ProRes 422 HQ (prores_ks) / 复制原视频流
```

音频编码：

```text
AAC / Opus / MP3 / FLAC / ALAC / PCM / 复制原音频流 / 无音频
```

常用预设：

| 预设 | 输出 |
|---|---|
| 通用 MP4 | H.264 + AAC，兼容性最好 |
| Apple HEVC | H.265 + AAC，MP4，`hvc1` tag |
| WebM | VP9 + Opus |
| AV1 MKV | AV1 + Opus，高压缩 |
| ProRes 422 MOV | ProRes 422 HQ + PCM，剪辑中间码 |
| GIF | 480p / 12fps / 无音频 |
| 仅换封装 | `-map 0 -c copy`，保留全部流 |

## 行为

- **默认重编码**：只保留首条视频 + 首条音频，字幕和多余音轨会丢弃；
- **仅换封装**：视频/音频都选「复制」时，使用 `-map 0 -c copy` 保留全部流和字幕；
- **质量**：1–100 映射到 H.264/H.265/AV1/VP9 的 CRF；ProRes 固定 422 HQ；
  GIF 映射到调色板颜色数；
- **分辨率**：按显示方向限制高度，等比缩小，不放大；宽高自动取偶数；
- **帧率**：只降不升（选择目标帧率时 ffmpeg 会按目标输出）；
- **音频**：AAC/Opus/MP3 使用音频码率；FLAC/ALAC/PCM 忽略码率；
- **元数据**：默认 `-map_metadata 0 -map_chapters 0`，MP4/MOV 加 `+faststart`；
- **安全交付**：临时文件写在目标目录，成功后原子替换；同名默认加 `-1`。

## 兼容性校验

工具会在编码前检查封装和编码组合，例如：

- WebM 只允许 VP8/VP9/AV1 + Opus/Vorbis；
- MP4 不允许 ProRes / PCM；
- AVI 不允许 AV1/VP9/ProRes/AAC；
- 复制流时必须清空分辨率和帧率修改；
- 复制音频时源编码必须能进目标封装。

不兼容会直接报错，而不是让 ffmpeg 在编码中途失败。

## 依赖

```bash
brew install ffmpeg
```

只依赖 ffmpeg / ffprobe。当前使用软件编码（libx264/libx265 等），优先画质和可控性；
没有启用 VideoToolbox 硬件编码。

## 无头运行

```bash
python3 Tools/media.video-convert.toolbox/scripts/tool.py run \
  --config /tmp/video-job/config.json
```

`config.json` 示例：

```json
{
  "video": "/Users/me/Movies/input.mov",
  "preset": "mp4-h264",
  "format": "mp4",
  "videoCodec": "h264",
  "audioCodec": "aac",
  "quality": 80,
  "resolution": "original",
  "fps": "original",
  "audioBitrate": 192,
  "preserveMetadata": true,
  "conflict": "rename",
  "outputDir": "/Users/me/Movies/out",
  "_meta": {
    "toolDir": "/abs/media.video-convert.toolbox",
    "jobDir": "/abs/job",
    "toolID": "media.video-convert",
    "toolVersion": "0.1.0"
  }
}
```

## 已知限制

- 重编码模式只保留首条视频/音频，字幕会丢弃；需要保留字幕/多音轨请用「仅换封装」。
- 复制流的容器兼容性由源编码决定；例如 H.264 不能复制进 WebM。
- 不支持 HDR 元数据、杜比视界、10-bit 输出配置；默认转成 8-bit yuv420p。
- 没有硬件编码开关；4K 长视频会比较慢。
- GIF 会显著增大文件，默认 480p / 12fps 只是折中。
