#!/bin/bash
# 生成用于 demo 的中文测试视频（10 秒左右）
set -euo pipefail

OUT="${1:-/tmp/mactoolbox-demo/sample.mp4}"
mkdir -p "$(dirname "$OUT")"

TEXT="ACCA 财务会计，折现率是百分之十，每股收益很重要。管理会计强调公司治理。"

say -v Tingting -o /tmp/mactoolbox-demo/speech.aiff "$TEXT"
ffmpeg -y -v error \
  -f lavfi -i "color=c=0x111827:s=960x540:r=25" \
  -i /tmp/mactoolbox-demo/speech.aiff \
  -shortest -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart \
  "$OUT"

echo "$OUT"
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT"
