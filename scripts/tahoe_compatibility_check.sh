#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="$(printf '%s' "$OS_VERSION" | cut -d. -f1)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="$(printf '%s' "$SDK_VERSION" | cut -d. -f1)"

if [ "$OS_MAJOR" -lt 26 ]; then
  echo "Expected macOS Tahoe 26.x or newer for this compatibility gate; got $OS_VERSION" >&2
  exit 1
fi

if [ "$SDK_MAJOR" -lt 26 ]; then
  echo "Expected macOS 26 SDK or newer; got $SDK_VERSION" >&2
  exit 1
fi

swift build
swift run agentic-secrets-contract-tests
swift run agentic-secrets check-macos "$SDK_MAJOR"
./scripts/package_release.sh >/tmp/agentic-secrets-package-path.txt
APP_PATH="$(cat /tmp/agentic-secrets-package-path.txt | tail -n 1)"
codesign --verify --strict --deep --verbose=4 "$APP_PATH"
./scripts/validate_release_artifact.sh "$APP_PATH"
codesign -dvvv --entitlements :- "$APP_PATH" >/tmp/agentic-secrets-entitlements.plist 2>/tmp/agentic-secrets-codesign.txt
grep -q "flags=.*runtime" /tmp/agentic-secrets-codesign.txt

echo "Tahoe compatibility gate passed for OS $OS_VERSION with SDK $SDK_VERSION"
