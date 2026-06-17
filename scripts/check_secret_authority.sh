#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FORBIDDEN='SecItemCopyMatching|KeychainSecretStore|LocalEncryptedSecretStore|\.resolve\(alias:'
HELPER_DIRS='Sources/CLI Sources/Shim Sources/Proxyd Sources/Bwsd Sources/Mcpd'
SCAN_RESULT="$(mktemp)"
trap 'rm -f "$SCAN_RESULT"' EXIT

if rg "$FORBIDDEN" $HELPER_DIRS >"$SCAN_RESULT"; then
  cat "$SCAN_RESULT" >&2
  echo "Secret authority violation: helper or CLI source references production secret resolution." >&2
  exit 1
fi

rg "SecItemCopyMatching" Sources/Core/SecretStore.swift >/dev/null
rg "KeychainSecretStore" Sources/CoreDaemon Sources/Core/SecretStore.swift Sources/ContractTests >/dev/null
rg "LocalEncryptedSecretStore" Sources/CoreDaemon Sources/Core/SecretStore.swift Sources/ContractTests >/dev/null

echo "Secret authority gate passed"
