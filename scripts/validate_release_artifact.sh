#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/AgenticFortress.app}"
PRODUCTS="AgenticFortress agentic-fortress agentic-fortress-shim agentic-fortressd-core agentic-fortress-proxyd agentic-fortress-bwsd agentic-fortress-mcpd"

test -d "$APP_PATH/Contents/MacOS"
test -f "$APP_PATH/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$APP_PATH/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$APP_PATH/Contents/Info.plist")" = "NSApplication"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist")" = "AgenticFortress"
test -n "$(/usr/libexec/PlistBuddy -c 'Print :BuildTimestamp' "$APP_PATH/Contents/Info.plist")"
test -n "$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "$APP_PATH/Contents/Info.plist")"
test -f "$APP_PATH/Contents/Resources/AgenticFortress.icns"
test -x "$APP_PATH/Contents/MacOS/AgenticFortress"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-shim"
test -x "$APP_PATH/Contents/MacOS/agentic-fortressd-core"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-proxyd"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-bwsd"
test -x "$APP_PATH/Contents/MacOS/agentic-fortress-mcpd"
codesign --verify --strict --deep --verbose=4 "$APP_PATH"
"$ROOT/scripts/check_entitlements_diff.sh" "$APP_PATH"

for product in $PRODUCTS; do
  binary="$APP_PATH/Contents/MacOS/$product"
  codesign --verify --strict --verbose=4 "$binary" >/dev/null
  codesign -dvvv "$binary" 2>&1 | grep -q 'flags=.*runtime'
  if [ -n "${REQUIRED_ARCHS:-}" ]; then
    for arch in $REQUIRED_ARCHS; do
      lipo "$binary" -verify_arch "$arch" >/dev/null
    done
  fi
done
codesign -dvvv "$APP_PATH" 2>&1 | grep -q 'flags=.*runtime'
