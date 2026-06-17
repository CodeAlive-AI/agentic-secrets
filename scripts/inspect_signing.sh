#!/usr/bin/env sh
set -eu

ARTIFACT="${1:-build/AgenticFortress.app}"

ulimit -n 10240 2>/dev/null || true
/usr/bin/perl -e 'alarm 15; exec @ARGV' codesign --verify --strict --deep --verbose=4 "$ARTIFACT"
/usr/bin/perl -e 'alarm 15; exec @ARGV' codesign -dvvv --entitlements :- "$ARTIFACT"
/usr/bin/perl -e 'alarm 15; exec @ARGV' spctl --assess --type execute --verbose "$ARTIFACT" || true
