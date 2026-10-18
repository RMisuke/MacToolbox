#!/bin/bash
# 构建 MacToolboxDemo.app（自用 ad-hoc 签名）
# 说明：本机 DSH 沙箱下 swift build 会触发嵌套沙箱限制，因此 demo 直接用 swiftc
# 编译单模块可执行文件；工程仍保留 Package.swift 供 Xcode / 后续迁移使用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/MacToolboxDemo.app"
BIN="$APP/Contents/MacOS/MacToolboxDemo"
CACHE="$ROOT/.build/modulecache"
TMP="$ROOT/.build/tmp"
mkdir -p "$CACHE" "$TMP" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> collecting sources"
SOURCES=()
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' -print0)

SDK="$(xcrun --show-sdk-path)"
echo "==> compiling ${#SOURCES[@]} Swift files"
TMPDIR="$TMP" CLANG_MODULE_CACHE_PATH="$CACHE" xcrun swiftc \
    -O -parse-as-library -disable-sandbox \
    -target arm64-apple-macos14.0 \
    -sdk "$SDK" \
    -module-cache-path "$CACHE" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Vision \
    -framework VisionKit \
    -framework ImageIO \
    -o "$BIN" \
    "${SOURCES[@]}"

echo "==> compiling assets"
rm -f "$APP/Contents/Resources/Assets.car"
ASSETS_TMP="$(mktemp -d /tmp/mactoolbox-assets.XXXXXX)"
if TMPDIR="$TMP" xcrun actool "$ROOT/App/Assets.xcassets" \
    --compile "$ASSETS_TMP" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSETS_TMP/partial.plist" \
    > "$ROOT/.build/actool.log" 2>&1; then
    cp "$ASSETS_TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
    cp "$ASSETS_TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    warning: actool failed; using App/AppIcon.icns fallback (see .build/actool.log)"
    cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
rm -rf "$ASSETS_TMP"

echo "==> bundling"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/Resources/Tools"
cp -R "$ROOT/Tools" "$APP/Contents/Resources/Tools"
find "$APP/Contents/Resources/Tools" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

rm -rf "$APP/Contents/Resources/Scripts"
mkdir -p "$APP/Contents/Resources/Scripts"
cp "$ROOT/scripts/new_tool.py" "$APP/Contents/Resources/Scripts/new_tool.py"
cp "$ROOT/scripts/tool_lint.py" "$APP/Contents/Resources/Scripts/tool_lint.py"
cp "$ROOT/scripts/toolbox_spec.py" "$APP/Contents/Resources/Scripts/toolbox_spec.py"
cp "$ROOT/scripts/agent_jobs.py" "$APP/Contents/Resources/Scripts/agent_jobs.py"
cp "$ROOT/scripts/mct.py" "$APP/Contents/Resources/Scripts/mct.py"
cp "$ROOT/bin/mct" "$APP/Contents/Resources/Scripts/mct"
chmod +x "$APP/Contents/Resources/Scripts/mct.py" "$APP/Contents/Resources/Scripts/mct"
cp "$ROOT/docs/新工具开发指南.md" "$APP/Contents/Resources/新工具开发指南.md" 2>/dev/null || true
cp "$ROOT/docs/工具接口审计与Agent适配-2026-10.md" "$APP/Contents/Resources/工具接口审计与Agent适配-2026-10.md" 2>/dev/null || true

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> built: $APP"
echo "    open \"$APP\""
