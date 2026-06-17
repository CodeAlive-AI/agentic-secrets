#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/AgenticFortress.app}"
APPROVED="$ROOT/packaging/approved-entitlements.plist"
ACTUAL="$(mktemp)"
NORMALIZED_APPROVED="$(mktemp)"
NORMALIZED_ACTUAL="$(mktemp)"
trap 'rm -f "$ACTUAL" "$NORMALIZED_APPROVED" "$NORMALIZED_ACTUAL"' EXIT

codesign -d --entitlements :- "$APP_PATH" > "$ACTUAL" 2>/dev/null
plutil -convert xml1 -o "$NORMALIZED_APPROVED" "$APPROVED"
plutil -convert xml1 -o "$NORMALIZED_ACTUAL" "$ACTUAL"
diff -u "$NORMALIZED_APPROVED" "$NORMALIZED_ACTUAL"

