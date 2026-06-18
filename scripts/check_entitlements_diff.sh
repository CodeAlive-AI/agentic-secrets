#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/AgenticSecrets.app}"
APPROVED="$ROOT/packaging/approved-entitlements.plist"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

check_entitlements() {
  artifact="$1"
  approved="$2"
  label="$3"
  actual="$TMP_DIR/$label.actual.plist"
  normalized_approved="$TMP_DIR/$label.approved.plist"
  normalized_actual="$TMP_DIR/$label.normalized.plist"
  codesign -d --entitlements :- "$artifact" > "$actual" 2>/dev/null
  plutil -convert xml1 -o "$normalized_approved" "$approved"
  plutil -convert xml1 -o "$normalized_actual" "$actual"
  diff -u "$normalized_approved" "$normalized_actual"
}

check_entitlements "$APP_PATH" "$APPROVED" "app"

find "$APP_PATH/Contents/MacOS" -type f -perm +111 -print | while IFS= read -r binary; do
  check_entitlements "$binary" "$APPROVED" "$(basename "$binary")"
done
