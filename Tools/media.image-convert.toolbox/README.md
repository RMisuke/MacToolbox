# 图片格式转换

`media.image-convert` 是 MacToolbox 的普通 Protocol 工具，不是原生 SwiftUI 工具。
一个表单完成单张转换，也可以从工具卡片进入批量转换。

## CLI / Agent

```bash
bin/mct run media.image-convert --input image=/tmp/a.png --input format=webp --json
bin/mct batch media.image-convert --input image=/tmp/images --output-dir /tmp/out --json
```

`bin/mct describe media.image-convert --json` 可查看完整输入 Schema 和示例。

## 支持范围

输出格式：

```text
JPEG / PNG / WebP / AVIF / HEIC / TIFF / BMP / GIF / ICO / APNG / JPEG XL
```

输入格式：

```text
JPEG / PNG / WebP / HEIC / HEIF / AVIF / TIFF / BMP / GIF / APNG / ICO
PSD / SVG / PDF（第一页）/ ICNS / JPEG XL / QOI / JP2 / EXR / TGA
DNG / CR2 / CR3 / NEF / ARW / RAF / ORF / RW2 / PEF / SRW
```

其中 RAW、SVG、PDF、ICNS、HEIC、AVIF 走 macOS 原生 `sips`；PSD 用 ffmpeg 读合成图，
不保留图层；PDF 只取第一页；动图默认只取第一帧，GIF → WebP 在无缩放时会保留动画。

## 依赖

```bash
brew install ffmpeg webp libavif exiftool
brew install jpeg-xl      # 可选：JPEG XL 输出
```

`sips` 是 macOS 自带，不需要安装。

工具里的「环境检测 / 自动修复」会检查并安装缺失项。`exiftool` 缺失时仍能转换像素，
但不会复制 EXIF / ICC；JPEG XL 缺失时只有 JXL 输出不可用。

## 引擎分工

| 目标 / 场景 | 引擎 |
|---|---|
| JPEG / PNG / TIFF / BMP / GIF / ICO / APNG / QOI / JP2 / EXR / TGA | ffmpeg |
| WebP | cwebp；GIF 动画在无缩放时用 gif2webp |
| AVIF | avifenc；缺失时回退 sips |
| HEIC | sips |
| JPEG XL | cjxl |
| HEIC / AVIF / SVG / PDF / ICNS / RAW 输入 | sips |
| JPEG XL 输入 | djxl |
| EXIF / ICC | exiftool |

## 关键行为

- **原图只读**：输出先写目标目录的隐藏临时文件，成功后才 `os.replace`；
- **同名文件**：默认自动加 `-1`、`-2`，也可以覆盖或直接报错；
- **透明图**：WebP / AVIF / HEIC / JXL / PNG / TIFF / GIF / ICO 保留 alpha；
  JPEG / BMP 没有 alpha，会按「背景」选项合成白底或黑底；
- **长边缩放**：等比缩小，不放大；0 表示保持原尺寸；
- **EXIF**：复制 EXIF / GPS / XMP / IPTC / ICC，按 ffmpeg 的旋转结果把
  `Orientation` 归为 1，更新 `ExifImageWidth/Height`，不复制旧缩略图；
- **动图**：GIF → WebP 无缩放时保留动画；GIF / WebP / APNG → GIF/APNG 也保留动画；
  其他静态输出只取第一帧，并在日志里提示；
- **不支持的元数据**：GIF / BMP / ICO / APNG 没有 EXIF 写入能力，会跳过并提示。

## 无头运行

```bash
python3 Tools/media.image-convert.toolbox/scripts/tool.py doctor \
  --config /tmp/image-job/config.json

python3 Tools/media.image-convert.toolbox/scripts/tool.py run \
  --config /tmp/image-job/config.json
```

`config.json` 示例：

```json
{
  "image": "/Users/me/Pictures/photo.heic",
  "format": "webp",
  "quality": 85,
  "maxSize": 2400,
  "background": "white",
  "preserveMetadata": true,
  "conflict": "rename",
  "outputDir": "/Users/me/Pictures/out",
  "_meta": {
    "toolDir": "/abs/media.image-convert.toolbox",
    "jobDir": "/abs/job",
    "toolID": "media.image-convert",
    "toolVersion": "0.1.0"
  }
}
```

## 已知限制

- JPEG 的 EXIF 由 exiftool 在编码后写入；没有 exiftool 时只能保留像素和 ICC（若编码器支持）。
- JPEG XL 的 ICC 写入取决于 cjxl / ExifTool 的支持范围；EXIF 会复制。
- PSD 只读合成图，不支持图层；RAW 由 ImageIO 解码，不提供显影参数。
- ICO 输出固定为 256×256 单尺寸；多尺寸图标需要后续扩展。
- 动图跨格式（例如 animated WebP → JXL）目前只取第一帧。
