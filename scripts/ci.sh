#!/usr/bin/env sh
set -eu

swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift run agentic-fortress-contract-tests
swift run agentic-fortress release-gates | grep -q '"canRunLocal" : true'
swift run agentic-fortress ipc-conformance | grep -q '"compatibilityStatus" : "compatible"'
swift run agentic-fortress mcp-conformance | grep -q '"no-body-logging"'
