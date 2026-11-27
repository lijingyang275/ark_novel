#!/usr/bin/env bash
set -euo pipefail

# Ark Novel 统一本地校验与编译脚本
# 用法：
#   ./tool/build.sh check
#   ./tool/build.sh android [--install]
#   ./tool/build.sh macos
#   ./tool/build.sh windows
#
# 可选环境变量：
#   FLUTTER_BIN   指定 flutter 可执行文件（默认 flutter）
#   ANDROID_SERIAL 指定 adb 安装目标设备（仅 --install 时生效）

FLUTTER="${FLUTTER_BIN:-flutter}"
ENTRY="lib/next/main.dart"
SYMBOLS_DIR="build/app/outputs/symbols"

usage() {
  cat <<'EOF'
Usage: ./tool/build.sh <check|android|macos|windows> [--install]
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  check)
    "$FLUTTER" analyze
    "$FLUTTER" test
    ;;
  android)
    "$FLUTTER" build apk --release \
      --target-platform android-arm64 \
      --dart-define=cronetHttpNoPlay=true \
      --split-debug-info="$SYMBOLS_DIR" \
      -t "$ENTRY"
    apk="build/app/outputs/flutter-apk/app-release.apk"
    ls -lh "$apk"
    if [[ "${1:-}" == "--install" ]]; then
      if [[ -n "${ANDROID_SERIAL:-}" ]]; then
        adb -s "$ANDROID_SERIAL" install -r "$apk"
      else
        adb install -r "$apk"
      fi
    fi
    ;;
  macos)
    "$FLUTTER" build macos --release \
      --split-debug-info="$SYMBOLS_DIR" \
      -t "$ENTRY"
    ;;
  windows)
    "$FLUTTER" build windows --release \
      --split-debug-info="$SYMBOLS_DIR" \
      -t "$ENTRY"
    ;;
  *)
    usage
    exit 1
    ;;
esac
