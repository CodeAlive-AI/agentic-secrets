#!/usr/bin/env sh
set -eu

swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift run agentic-fortress-contract-tests
./scripts/check_secret_authority.sh
swift run agentic-fortress release-gates | grep -q '"canRunLocal" : true'
swift run agentic-fortress ipc-conformance | grep -q '"compatibilityStatus" : "compatible"'
swift run agentic-fortress mcp-conformance | grep -q '"no-body-logging"'
rg "Spoofing|Tampering|Repudiation|Information Disclosure|Denial of Service|Elevation of Privilege" Docs/THREAT_MODEL.md >/dev/null
