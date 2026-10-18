# 图片 OCR

`media.image-ocr` 是 MacToolbox 的原生 SwiftUI 工具（`nativeView=imageOCR`）：
GUI 直接调用 macOS **VisionKit Live Text**；CLI/Agent 通过 `scripts/tool.py` +
`scripts/ocr.swift`（Vision `VNRecognizeTextRequest`）走同一份 `tool.json`。

## 功能

- 拖拽图片到框内，或点击「选择图片…」；
- 从剪贴板粘贴图片（按钮或 ⇧⌘V）；
- 自动识别，图片预览 + 文件名 / 类型 / 像素尺寸 / 耗时；
- 识别结果放在下方文本框，可直接编辑；
- 一键复制、保存 TXT、清空；
- 语言：自动 / 简体中文 / 繁体中文 / 英语 / 日语 / 韩语；
- 重新识别；
- 字符数、行数统计；
- 无网络请求，图片不离开本机。

## 支持图片

```text
PNG / JPEG / HEIC / HEIF / TIFF / GIF / WebP / BMP
```

动图只取第一帧。

## 实现

- `ImageOCRView.swift`：拖拽/粘贴/预览/结果编辑/复制/保存；
- `ImageAnalyzer` + `ImageAnalyzer.Configuration([.text])`：系统 OCR；
- 文件通过 `imageAt:orientation:` 保留 EXIF 方向；
- 剪贴板图片转 TIFF Data 后识别；
- 识别任务可取消；新图片/新语言会取消旧任务；
- 结果只在内存和用户选择的 TXT 文件里，不写任务记录。

## CLI / Agent

```bash
bin/mct run media.image-ocr \
  --input image=/tmp/screenshot.png \
  --input language=zh-Hans \
  --input format=both --json

bin/mct batch media.image-ocr \
  --input image=/tmp/images --output-dir /tmp/ocr-out --json
```

- 首次运行会用 `swiftc` 编译 `ocr.swift`，缓存到
  `~/Library/Caches/MacToolboxDemo/ocr/`（或 `$MCT_DATA_DIR/Cache/ocr/`）；
- `format=txt|json|both`；JSON 含每行文本、置信度和归一化包围盒；
- 当前系统 `accurate` 模型不可用时会自动回退 `fast`，并在日志提示；
- PDF 输入先用 `sips` 转 PNG（只取第一页）。

## 前置条件

- macOS 13+（VisionKit `ImageAnalyzer`）；
- 无需额外安装依赖。

## 已知限制

- 只做文字识别，不做版面分析/表格结构/PDF 多页；
- 阅读顺序由系统 Live Text 决定，多栏排版可能需要手动整理；
- 不做图片预处理（旋转/增强/去噪），原图质量决定识别效果；
- 系统不支持的语言无法通过本工具补装。
