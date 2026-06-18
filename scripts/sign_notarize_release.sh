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

ZIP_PATH="$ROOT/build/AgenticSecrets.zip"
SUBMISSION_ZIP="$ROOT/build/AgenticSecrets.notary-submission.zip"
rm -f "$ZIP_PATH" "$SUBMISSION_ZIP"
ditto --norsrc -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

ditto --norsrc -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
xcrun stapler validate "$VERIFY_DIR/$(basename "$APP_PATH")"
spctl --assess --type execute --verbose "$VERIFY_DIR/$(basename "$APP_PATH")"

echo "$ZIP_PATH"
