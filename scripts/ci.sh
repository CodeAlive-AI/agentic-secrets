#!/usr/bin/env sh
set -eu

swift build
swift run agentic-fortress-contract-tests

