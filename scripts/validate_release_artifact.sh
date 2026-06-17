#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/AgenticFortress.app}"

test -d "$APP_PATH/Contents/MacOS"
test -f "$APP_PATH/Contents/Info.plist"
test -x "$APP_PATH/Contents/MacOS/AgenticFortress"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-shim"
test -x "$APP_PATH/Contents/MacOS/agentic-fortressd-core"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-proxyd"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-bwsd"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-mcpd"
codesign --verify --strict --deep --verbose=4 "$APP_PATH"
"$ROOT/scripts/check_entitlements_diff.sh" "$APP_PATH"

find "$APP_PATH/Contents/MacOS" -type f -perm +111 -print | while IFS= read -r binary; do
  codesign --verify --strict --verbose=4 "$binary" >/dev/null
  codesign -dvvv "$binary" 2>&1 | grep -q 'flags=.*runtime'
done
codesign -dvvv "$APP_PATH" 2>&1 | grep -q 'flags=.*runtime'
