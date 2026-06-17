#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/version.env"

IDENTITY_NAME="${IDENTITY_NAME:-$APP_NAME Development}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  printf '%s\n' "$IDENTITY_NAME"
  printf 'Development signing identity already exists.\n'
  exit 0
fi

openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -keyout "$WORK_DIR/dev.key" \
  -out "$WORK_DIR/dev.crt" \
  -subj "/CN=$IDENTITY_NAME" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$WORK_DIR/dev.key" \
  -in "$WORK_DIR/dev.crt" \
  -out "$WORK_DIR/dev.p12" \
  -passout pass: >/dev/null 2>&1

security import "$WORK_DIR/dev.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign >/dev/null

if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
else
  cat >&2 <<NEXT
Imported $IDENTITY_NAME.
For fully non-interactive signing, rerun with KEYCHAIN_PASSWORD set in your shell session
or run security set-key-partition-list for this keychain manually. Do not store the password in this repo.
NEXT
fi

printf '%s\n' "$IDENTITY_NAME"
