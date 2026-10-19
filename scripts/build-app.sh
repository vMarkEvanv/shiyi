#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Respect a toolchain selected by the caller; otherwise use the selected full
# Xcode installation, falling back to /Applications/Xcode.app when necessary.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED_DEVELOPER_DIR="$(/usr/bin/xcode-select --print-path 2>/dev/null || true)"
  if [[ "$SELECTED_DEVELOPER_DIR" == *.app/Contents/Developer ]]; then
    export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi

BUILD_ROOT="$PROJECT_ROOT/.build"
OUTPUT_ROOT="$PROJECT_ROOT/build"
APP_PATH="$OUTPUT_ROOT/拾译.app"
# Replacing a live executable can leave macOS checking an old code identity.
if /usr/bin/pgrep -f "^${APP_PATH}/Contents/MacOS/Shiyi$" >/dev/null; then
  printf '请先从菜单栏退出拾译，再重新构建，避免覆盖运行中的应用。\n' >&2
  exit 1
fi

SIGNING_IDENTITY="${SHIYI_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
  printf '未发现开发签名证书，将使用临时签名；重建后可能需要移除旧辅助功能记录并重新授权。\n' >&2
fi
mkdir -p "$BUILD_ROOT/clang-module-cache" "$BUILD_ROOT/swift-module-cache" "$OUTPUT_ROOT"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/swift-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swift-module-cache"

SWIFT_BUILD_OPTIONS=(
  --configuration release
  --scratch-path "$BUILD_ROOT"
  --cache-path "$BUILD_ROOT/cache"
  --config-path "$BUILD_ROOT/configuration"
  --security-path "$BUILD_ROOT/security"
  --manifest-cache local
  --disable-sandbox
)

/usr/bin/xcrun --sdk macosx swift build "${SWIFT_BUILD_OPTIONS[@]}" --product Shiyi
BINARY_DIRECTORY="$(/usr/bin/xcrun --sdk macosx swift build "${SWIFT_BUILD_OPTIONS[@]}" --show-bin-path)"

/usr/bin/xcrun --sdk macosx swift -module-cache-path "$BUILD_ROOT/swift-module-cache" \
  "$PROJECT_ROOT/scripts/make-icon.swift" "$OUTPUT_ROOT/AppIcon-1024.png" "$OUTPUT_ROOT/AppIcon.icns"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/bin/cp "$BINARY_DIRECTORY/Shiyi" "$APP_PATH/Contents/MacOS/Shiyi"
/bin/cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/bin/cp "$OUTPUT_ROOT/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf '\n已构建：%s\n' "$APP_PATH"
printf '手动打开：open "%s"\n' "$APP_PATH"
