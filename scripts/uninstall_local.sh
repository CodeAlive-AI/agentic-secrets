#!/usr/bin/env sh
set -eu

. "$(cd "$(dirname "$0")/.." && pwd)/version.env"

PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
PURGE_LOCAL_STATE=0
KEEP_SECRETS=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --keep-secrets)
      KEEP_SECRETS=1
      shift
      ;;
    --purge-local-state)
      PURGE_LOCAL_STATE=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

APP_DEST="$PREFIX/Applications/$APP_NAME.app"
BIN_DIR="$PREFIX/bin"
STATE_DIR="$PREFIX/var/agentic-secrets"
RUN_DIR="$PREFIX/run/agentic-secrets"
SOCKET_DIR="/tmp/agentic-secrets-$(id -u)"
LAUNCH_DIR="$PREFIX/Library/LaunchAgents"
CORE_PLIST="$LAUNCH_DIR/com.agenticsecrets.broker.plist"

if [ -f "$CORE_PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$CORE_PLIST" >/dev/null 2>&1 || true
fi

for executable in agentic-secrets AgenticSecrets agentic-secrets-shim agentic-secrets-brokerd agentic-secrets-api-sessiond agentic-secrets-bitwarden-providerd agentic-secrets-mcpd; do
  rm -f "$BIN_DIR/$executable"
done

rm -f "$CORE_PLIST"
rm -rf "$RUN_DIR"
rm -rf "$SOCKET_DIR"
rm -rf "$APP_DEST"

if [ "$PURGE_LOCAL_STATE" -eq 1 ]; then
  rm -rf "$STATE_DIR"
fi

if [ "$PURGE_LOCAL_STATE" -eq 1 ]; then
  echo "Local Agentic Secrets state purged."
elif [ "$KEEP_SECRETS" -eq 1 ]; then
  echo "Local secret records retained. Use --purge-local-state only when you intentionally want to remove local Agentic Secrets state."
fi

find "$PREFIX" -type d -empty -delete 2>/dev/null || true
printf '%s\n' "$PREFIX"
