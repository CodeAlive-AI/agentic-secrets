#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="com.agenticfortress.interactive-smoke"
ALIAS="agentic-fortress.interactive-smoke"

echo "This check creates a temporary device-local Keychain item, reads it through LocalAuthentication, and deletes it."
echo "The secret value is generated locally and is never printed."
echo "Canceling the macOS prompt should make this command fail closed."

if [ "${AGENTIC_FORTRESS_INTERACTIVE:-0}" != "1" ]; then
  echo "Set AGENTIC_FORTRESS_INTERACTIVE=1 to run the prompt-producing check."
  echo "Set AGENTIC_FORTRESS_EXPECT_CANCEL=1 with interactive mode, then press Cancel, to verify fail-closed cancellation."
  echo "Non-interactive static contract check:"
  swift run --package-path "$ROOT" agentic-fortress-contract-tests
  exit 0
fi

if [ "${AGENTIC_FORTRESS_EXPECT_CANCEL:-0}" = "1" ]; then
  set +e
  OUTPUT="$(swift run --package-path "$ROOT" agentic-fortressd-core -- keychain-smoke --service "$SERVICE" --alias "$ALIAS" 2>&1)"
  STATUS=$?
  set -e
  printf '%s\n' "$OUTPUT"
  if [ "$STATUS" -eq 0 ]; then
    echo "Expected prompt cancellation, but secret resolution succeeded." >&2
    exit 1
  fi
  printf '%s\n' "$OUTPUT" | grep -q "userCanceled"
  echo "Interactive cancellation denied secret resolution as expected."
  exit 0
fi

swift run --package-path "$ROOT" agentic-fortressd-core -- keychain-smoke --service "$SERVICE" --alias "$ALIAS"
