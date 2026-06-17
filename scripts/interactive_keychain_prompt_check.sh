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
  echo "Non-interactive static contract check:"
  swift run --package-path "$ROOT" agentic-fortress-contract-tests
  exit 0
fi

swift run --package-path "$ROOT" agentic-fortressd-core -- keychain-smoke --service "$SERVICE" --alias "$ALIAS"
