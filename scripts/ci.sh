#!/usr/bin/env sh
set -eu

swift build -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift run agentic-fortress-contract-tests
