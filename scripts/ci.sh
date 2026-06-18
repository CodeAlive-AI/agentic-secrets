#!/usr/bin/env sh
set -eu

PACKAGE_LOG="$(mktemp)"
ACCESS_GROUP_SCAN="$(mktemp)"
trap 'rm -f "$PACKAGE_LOG" "$ACCESS_GROUP_SCAN"' EXIT

swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift run agentic-secrets-contract-tests
./script/ui_smoke.sh
./scripts/check_secret_authority.sh
swift run agentic-secrets release-gates | grep -q '"canRunLocal" : true'
swift run agentic-secrets ipc-conformance | grep -q '"compatibilityStatus" : "compatible"'
swift run agentic-secrets mcp-conformance | grep -q '"no-body-logging"'
./scripts/package_release.sh >"$PACKAGE_LOG"
./scripts/validate_release_artifact.sh "build/AgenticSecrets.app"
./scripts/check_entitlements_diff.sh "build/AgenticSecrets.app"
if rg "kSecAttrAccessGroup|keychain-access-groups|com.apple.security.application-groups" Sources packaging Docs README.md --glob '!ACCEPTANCE_CRITERIA.md' >"$ACCESS_GROUP_SCAN"; then
  cat "$ACCESS_GROUP_SCAN" >&2
  exit 1
fi
rg "Spoofing|Tampering|Repudiation|Information Disclosure|Denial of Service|Elevation of Privilege" Docs/THREAT_MODEL.md >/dev/null
