#!/bin/zsh
set -e
cd "$(dirname "$0")"

app_bundle="Codex 历史同步工具.app"
binary="$app_bundle/Contents/MacOS/CodexHistorySync"

build_local_app() {
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "未找到 Swift 编译器。请先安装 Apple Command Line Tools："
    echo "xcode-select --install"
    exit 1
  fi
  cache_dir="${TMPDIR:-/tmp}/codex-history-sync-swift-cache"
  mkdir -p "$cache_dir"
  mkdir -p "$app_bundle/Contents/MacOS"
  cp Info.plist "$app_bundle/Contents/Info.plist"
  cp sync_backend.py "$app_bundle/Contents/MacOS/sync_backend.py"
  target_arch="$(uname -m)"
  if [[ "$target_arch" == "x86_64" ]]; then
    deployment_target="10.15"
  else
    deployment_target="11.0"
  fi
  CLANG_MODULE_CACHE_PATH="$cache_dir" SWIFT_MODULE_CACHE_PATH="$cache_dir" \
    xcrun swiftc -swift-version 5 -O \
      -target "${target_arch}-apple-macos${deployment_target}" \
      launch_ui_macos.swift -o "$binary"
  codesign --force --deep --sign - "$app_bundle" >/dev/null 2>&1 || true
}

if [[ ! -x "$binary" || launch_ui_macos.swift -nt "$binary" || sync_backend.py -nt "$binary" ]]; then
  build_local_app
fi

if ! open "$app_bundle"; then
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "当前预编译版本与本机系统不兼容，且未找到 Swift 编译器。"
    echo "请安装 Apple Command Line Tools 后重试：xcode-select --install"
    exit 1
  fi
  echo "预编译版本与当前系统不兼容，正在为本机重新构建（macOS ${deployment_target:-自动检测}）..."
  build_local_app
  open "$app_bundle"
fi
