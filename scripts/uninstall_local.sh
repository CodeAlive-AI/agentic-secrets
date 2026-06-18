#!/usr/bin/env sh
set -eu

. "$(cd "$(dirname "$0")/.." && pwd)/version.env"

PREFIX="$HOME/Library/Application Support/AgenticFortress/LocalInstall"
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
STATE_DIR="$PREFIX/var/agentic-fortress"
RUN_DIR="$PREFIX/run/agentic-fortress"
SOCKET_DIR="/tmp/agentic-fortress-$(id -u)"
LAUNCH_DIR="$PREFIX/Library/LaunchAgents"
CORE_PLIST="$LAUNCH_DIR/com.agenticfortress.core.plist"

if [ -f "$CORE_PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$CORE_PLIST" >/dev/null 2>&1 || true
fi

for executable in agentic-fortress AgenticFortress agentic-fortress-shim agentic-fortressd-core agentic-fortress-proxyd agentic-fortress-bwsd agentic-fortress-mcpd; do
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
  echo "Local AgenticFortress state purged."
elif [ "$KEEP_SECRETS" -eq 1 ]; then
  echo "Local secret records retained. Use --purge-local-state only when you intentionally want to remove local AgenticFortress state."
fi

find "$PREFIX" -type d -empty -delete 2>/dev/null || true
printf '%s\n' "$PREFIX"
