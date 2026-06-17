#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/version.env"

CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/packaging/AgenticFortress.entitlements"

swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$ROOT/.build/$CONFIGURATION/agentic-fortress" "$MACOS/AgenticFortress"
cp "$ROOT/.build/$CONFIGURATION/agentic-fortress-shim" "$MACOS/agentic-fortress-shim"
cp "$ROOT/.build/$CONFIGURATION/agentic-fortressd-core" "$MACOS/agentic-fortressd-core"
cp "$ROOT/.build/$CONFIGURATION/agentic-fortress-proxyd" "$MACOS/agentic-fortress-proxyd"
cp "$ROOT/.build/$CONFIGURATION/agentic-fortress-bwsd" "$MACOS/agentic-fortress-bwsd"
cp "$ROOT/.build/$CONFIGURATION/agentic-fortress-mcpd" "$MACOS/agentic-fortress-mcpd"
cp "$ROOT/.build/$CONFIGURATION/agentic-fortress-contract-tests" "$MACOS/agentic-fortress-contract-tests"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AgenticFortress</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST

find "$MACOS" -type f -perm +111 -print | while IFS= read -r binary; do
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$binary"
done
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"

echo "$APP_DIR"
