#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FORBIDDEN='SecItemCopyMatching|KeychainSecretStore|\.resolve\(alias:'
HELPER_DIRS='Sources/CLI Sources/Shim Sources/Proxyd Sources/Bwsd Sources/Mcpd'

if rg "$FORBIDDEN" $HELPER_DIRS >/tmp/agentic-fortress-secret-authority-scan.txt; then
  cat /tmp/agentic-fortress-secret-authority-scan.txt >&2
  echo "Secret authority violation: helper or CLI source references production secret resolution." >&2
  exit 1
fi

rg "SecItemCopyMatching" Sources/Core/SecretStore.swift >/dev/null
rg "KeychainSecretStore" Sources/CoreDaemon Sources/Core/SecretStore.swift Sources/ContractTests >/dev/null

echo "Secret authority gate passed"
