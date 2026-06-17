#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${CODESIGN_IDENTITY+x}" ] || [ "$CODESIGN_IDENTITY" = "" ]; then
  echo "CODESIGN_IDENTITY is required for distribution signing." >&2
  exit 2
fi

if [ -z "${NOTARYTOOL_PROFILE+x}" ] || [ "$NOTARYTOOL_PROFILE" = "" ]; then
  echo "NOTARYTOOL_PROFILE is required. Store credentials with xcrun notarytool store-credentials; do not put secrets in this repo." >&2
  exit 2
fi

APP_PATH="$(CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$ROOT/scripts/package_release.sh" | tail -n 1)"
"$ROOT/scripts/validate_release_artifact.sh" "$APP_PATH"

ZIP_PATH="$ROOT/build/AgenticFortress.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "$ZIP_PATH"

