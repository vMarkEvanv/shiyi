#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$PROJECT_ROOT/build/拾译.app}"
DIST_ROOT="$PROJECT_ROOT/dist"
PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$PLIST" && -x "$APP_PATH/Contents/MacOS/Shiyi" ]] || {
  printf '找不到完整应用，请先运行 scripts/build-app.sh。\n' >&2
  exit 1
}
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  printf '应用版本格式不正确。\n' >&2
  exit 1
}
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/Shiyi")"
case "$ARCHITECTURES" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *arm64*x86_64*|*x86_64*arm64*) ARCH=universal ;;
  *) printf '无法识别架构：%s\n' "$ARCHITECTURES" >&2; exit 1 ;;
esac

mkdir -p "$DIST_ROOT"
STAGING_DIR="$(mktemp -d "$PROJECT_ROOT/build/release-staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
PACKAGE_NAME="Shiyi-v${VERSION}-macOS-${ARCH}"
PACKAGE_ROOT="$STAGING_DIR/$PACKAGE_NAME"
mkdir -p "$PACKAGE_ROOT"
/usr/bin/ditto "$APP_PATH" "$PACKAGE_ROOT/拾译.app"
# Release staging never changes the working app or exports a private signing key.
# Default to a local preview signature without embedding the machine's developer certificate.
/usr/bin/codesign --force --sign "${SHIYI_RELEASE_SIGNING_IDENTITY:--}" --timestamp=none "$PACKAGE_ROOT/拾译.app"
/usr/bin/codesign --verify --deep --strict "$PACKAGE_ROOT/拾译.app"
cat > "$PACKAGE_ROOT/安装说明.txt" <<'INSTALL'
拾译 · macOS 预览版

需要 macOS 15 或更高版本。arm64 包适用于 Apple Silicon；x64 包适用于 Intel。

1. 解压后，将“拾译.app”拖到“应用程序”文件夹，再打开。
2. 在“系统设置 → 隐私与安全性 → 辅助功能”中添加并开启拾译。
3. 在拾译中选择“原文语言 → 目标语言”，默认英语 → 简体中文，不自动识别语言。
4. 按 Option + Command + T 唤出常驻浮窗，再在其他应用中划词，译文会在固定位置更新。
5. 系统翻译首次使用需下载相应语言包；AI 语境翻译需在偏好设置中配置自己的模型接口。
6. 浮窗默认穿透，右上角操作点可展开/收起；右键提供复制、重试及浏览。透明度、位置、显示屏幕、快捷键与隐藏操作都在拾译主窗口修改。

这是未经 Apple 公证的预览构建。系统若阻止启动，请按 macOS 的提示检查“隐私与安全性”中的启动选项；不需要关闭系统安全保护。
如重装后辅助功能开关已开却无法取词，请移除旧记录，再添加当前应用。
不同应用对选区与上下文的支持不同；请确保所选的原文语言与文字相符。
INSTALL
ARCHIVE="$DIST_ROOT/$PACKAGE_NAME.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_ROOT" "$ARCHIVE"
(
  cd "$DIST_ROOT"
  /usr/bin/shasum -a 256 "$PACKAGE_NAME.zip" > "$PACKAGE_NAME.sha256"
)
printf '已打包：%s\n校验文件：%s\n' "$ARCHIVE" "$DIST_ROOT/$PACKAGE_NAME.sha256"
