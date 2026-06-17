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

