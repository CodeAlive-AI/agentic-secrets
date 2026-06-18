#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/AgenticSecrets.app}"
PRODUCTS="AgenticSecrets agentic-secrets agentic-secrets-shim agentic-secrets-brokerd agentic-secrets-api-sessiond agentic-secrets-bitwarden-providerd agentic-secrets-mcpd"

test -d "$APP_PATH/Contents/MacOS"
test -f "$APP_PATH/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$APP_PATH/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$APP_PATH/Contents/Info.plist")" = "NSApplication"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist")" = "AgenticSecrets"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP_PATH/Contents/Info.plist")" = "Agentic Secrets"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Contents/Info.plist")" = "Agentic Secrets"
test -n "$(/usr/libexec/PlistBuddy -c 'Print :BuildTimestamp' "$APP_PATH/Contents/Info.plist")"
test -n "$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "$APP_PATH/Contents/Info.plist")"
test -f "$APP_PATH/Contents/Resources/AgenticSecrets.icns"
test -x "$APP_PATH/Contents/MacOS/AgenticSecrets"
test -x "$APP_PATH/Contents/MacOS/agentic-secrets"
test -x "$APP_PATH/Contents/MacOS/agentic-secrets-shim"
test -x "$APP_PATH/Contents/MacOS/agentic-secrets-brokerd"
test -x "$APP_PATH/Contents/MacOS/agentic-secrets-api-sessiond"
test -x "$APP_PATH/Contents/MacOS/agentic-secrets-bitwarden-providerd"
test -x "$APP_PATH/Contents/MacOS/agentic-secrets-mcpd"
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
