#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Install.sh is for macOS. Use Install.ps1 on Windows.\n' >&2
  exit 1
fi

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ROOT="$HOME/.codex/mobile-notifier"
TARGET_BRIDGE="$TARGET_ROOT/bridge"

mkdir -p "$TARGET_BRIDGE/tests"
for name in bridge.js bridge-admin.js CodexFeishuBridge.sh package.json package-lock.json; do
  cp "$SOURCE_ROOT/bridge/$name" "$TARGET_BRIDGE/$name"
done
cp "$SOURCE_ROOT/bridge/tests/bridge.test.js" "$TARGET_BRIDGE/tests/bridge.test.js"
cp "$SOURCE_ROOT/bridge/tests/bridge-admin.test.js" "$TARGET_BRIDGE/tests/bridge-admin.test.js"
cp "$SOURCE_ROOT/bridge/tests/run-macos-tests.sh" "$TARGET_BRIDGE/tests/run-macos-tests.sh"
chmod 700 "$TARGET_BRIDGE/CodexFeishuBridge.sh" "$TARGET_BRIDGE/tests/run-macos-tests.sh"

exec "$TARGET_BRIDGE/CodexFeishuBridge.sh" install "$@"
