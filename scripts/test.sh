#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/swift-module-cache"
/usr/bin/xcrun swift test --disable-sandbox --scratch-path "$PROJECT_ROOT/.build" \
  --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/configuration" \
  --security-path "$PROJECT_ROOT/.build/security" --manifest-cache local "$@"
