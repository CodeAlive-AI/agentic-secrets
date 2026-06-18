#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgenticSecrets"
APP_DISPLAY_NAME="Agentic Secrets"
APP_EXECUTABLE_NAME="AgenticSecrets"
BUNDLE_ID="com.agenticsecrets.AgenticSecrets"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/version.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/version.env"
fi
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Agentic Secrets}"
APP_EXECUTABLE_NAME="${APP_EXECUTABLE_NAME:-$APP_NAME}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_PATH="${AGENTIC_SECRETS_ICON_PATH:-$DIST_DIR/AgenticSecrets.icns}"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

pkill -x "$APP_EXECUTABLE_NAME" >/dev/null 2>&1 || true

swift build --product "$APP_EXECUTABLE_NAME"
BUILD_BINARY="$(swift build --show-bin-path)/$APP_EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -n "${AGENTIC_SECRETS_ICON_PATH:-}" ]]; then
  test -f "$ICON_PATH"
else
  rm -rf "$ICON_PATH" "${ICON_PATH%.icns}.iconset"
  swift "$ROOT_DIR/packaging/make_icon.swift" "$ICON_PATH"
  iconutil -c icns "${ICON_PATH%.icns}.iconset" -o "$ICON_PATH"
fi
cp "$ICON_PATH" "$APP_RESOURCES/AgenticSecrets.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AgenticSecrets</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${MARKETING_VERSION:-0.1.0}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER:-1}</string>
  <key>CFBundleGetInfoString</key>
  <string>$APP_DISPLAY_NAME ${MARKETING_VERSION:-0.1.0} ${RELEASE_CHANNEL:-dev}</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>BuildTimestamp</key>
  <string>$BUILD_TIMESTAMP</string>
  <key>GitCommit</key>
  <string>$GIT_COMMIT</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app_window() {
  local pid="$1"
  /usr/bin/swift - "$pid" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    fputs("missing pid\n", stderr)
    exit(2)
}

let deadline = Date().addingTimeInterval(5)
while Date() < deadline {
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let found = windows.contains { item in
        guard (item[kCGWindowOwnerPID as String] as? Int) == pid,
              (item[kCGWindowLayer as String] as? Int) == 0,
              (item[kCGWindowIsOnscreen as String] as? Int) == 1,
              let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double
        else { return false }
        return width >= 640 && height >= 360
    }
    if found {
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.25)
}

fputs("Agentic Secrets launched but no visible main window was found.\n", stderr)
exit(1)
SWIFT
}

wait_for_app_pid() {
  local deadline=$((SECONDS + 8))
  local pid args
  while (( SECONDS < deadline )); do
    while IFS= read -r pid; do
      args="$(/bin/ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$args" == *"$APP_BINARY"* ]]; then
        printf '%s\n' "$pid"
        return 0
      fi
    done < <(/usr/bin/pgrep -x "$APP_EXECUTABLE_NAME" 2>/dev/null || true)
    sleep 0.25
  done
  echo "Agentic Secrets did not stay running after launch." >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    PID="$(wait_for_app_pid)"
    verify_app_window "$PID"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
