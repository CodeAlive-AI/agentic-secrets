#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/version.env"

CONFIGURATION="${CONFIGURATION:-release}"
ARCHS="${ARCHS:-$(uname -m)}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/packaging/AgenticFortress.entitlements"
ICON_PATH="${AGENTIC_FORTRESS_ICON_PATH:-$BUILD_DIR/AgenticFortress.icns}"
GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
PRODUCTS="AgenticFortress agentic-fortress agentic-fortress-shim agentic-fortressd-core agentic-fortress-proxyd agentic-fortress-bwsd agentic-fortress-mcpd"
SIGNING_PRODUCTS="agentic-fortress agentic-fortress-shim agentic-fortressd-core agentic-fortress-proxyd agentic-fortress-bwsd agentic-fortress-mcpd AgenticFortress"

build_for_arch() {
  arch="$1"
  scratch="$ROOT/.build/$CONFIGURATION-$arch"
  swift build -c "$CONFIGURATION" --arch "$arch" --scratch-path "$scratch"
  swift build -c "$CONFIGURATION" --arch "$arch" --scratch-path "$scratch" --show-bin-path
}

BIN_PATHS=""
for arch in $ARCHS; do
  bin_path="$(build_for_arch "$arch" | tail -n 1)"
  BIN_PATHS="$BIN_PATHS $arch:$bin_path"
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

for product in $PRODUCTS; do
  inputs=""
  for entry in $BIN_PATHS; do
    bin_path="${entry#*:}"
    inputs="$inputs $bin_path/$product"
  done
  # shellcheck disable=SC2086
  if [ "$(printf '%s\n' $ARCHS | wc -l | tr -d ' ')" -gt 1 ]; then
    # shellcheck disable=SC2086
    lipo -create $inputs -output "$MACOS/$product"
  else
    # shellcheck disable=SC2086
    cp $inputs "$MACOS/$product"
  fi
  chmod +x "$MACOS/$product"
done

if [ ! -f "$ICON_PATH" ]; then
  swift "$ROOT/packaging/make_icon.swift" "$ICON_PATH"
  iconutil -c icns "${ICON_PATH%.icns}.iconset" -o "$ICON_PATH"
fi
cp "$ICON_PATH" "$RESOURCES/AgenticFortress.icns"

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
  <key>CFBundleIconFile</key>
  <string>AgenticFortress</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleGetInfoString</key>
  <string>$APP_NAME $MARKETING_VERSION $RELEASE_CHANNEL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>BuildTimestamp</key>
  <string>$BUILD_TIMESTAMP</string>
  <key>GitCommit</key>
  <string>$GIT_COMMIT</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR"
find "$APP_DIR" -name '._*' -delete

for product in $SIGNING_PRODUCTS; do
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$MACOS/$product"
done
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"

echo "$APP_DIR"
