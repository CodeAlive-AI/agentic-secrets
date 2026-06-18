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
USER_APPLICATIONS_DIR="$HOME/Applications"
USER_APP_LINK="$USER_APPLICATIONS_DIR/$APP_NAME.app"
BIN_DIR="$PREFIX/bin"
SHIM_DIR="$PREFIX/shims"
STATE_DIR="$PREFIX/var/agentic-secrets"
RUN_DIR="$PREFIX/run/agentic-secrets"
SOCKET_DIR="/tmp/agentic-secrets-$(id -u)"
LAUNCH_DIR="$PREFIX/Library/LaunchAgents"
CORE_PLIST="$LAUNCH_DIR/com.agenticsecrets.broker.plist"

if [ -f "$CORE_PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$CORE_PLIST" >/dev/null 2>&1 || true
fi

remove_managed_user_app_link() {
  [ -L "$USER_APP_LINK" ] || return 0
  link_target="$(readlink "$USER_APP_LINK" 2>/dev/null || printf '')"
  if [ "$link_target" = "$APP_DEST" ]; then
    rm -f "$USER_APP_LINK"
  fi
}

remove_managed_user_app_link

for executable in agentic-secrets AgenticSecrets agentic-secrets-shim agentic-secrets-brokerd agentic-secrets-api-sessiond agentic-secrets-bitwarden-providerd agentic-secrets-mcpd; do
  rm -f "$BIN_DIR/$executable"
done

rm -f "$CORE_PLIST"
rm -rf "$SHIM_DIR"
rm -rf "$RUN_DIR"
rm -rf "$SOCKET_DIR"
rm -rf "$APP_DEST"

if [ "$PURGE_LOCAL_STATE" -eq 1 ]; then
  state_parent="$(dirname "$STATE_DIR")"
  state_name="$(basename "$STATE_DIR")"
  if [ -d "$state_parent" ]; then
    state_path="$(cd "$state_parent" && printf '%s/%s\n' "$(pwd -P)" "$state_name")"
  else
    state_path="$STATE_DIR"
  fi
  state_account="local-state:$(printf '%s' "$state_path" | shasum -a 256 | awk '{print substr($1, 1, 24)}')"
  security delete-generic-password -s "com.agenticsecrets.cli-registry-integrity" -a "$state_account" >/dev/null 2>&1 || true
  security delete-generic-password -s "com.agenticsecrets.cli-persistent-allow" -a "$state_account" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
fi

if [ "$PURGE_LOCAL_STATE" -eq 1 ]; then
  echo "Local Agentic Secrets state purged."
elif [ "$KEEP_SECRETS" -eq 1 ]; then
  echo "Local secret records retained. Use --purge-local-state only when you intentionally want to remove local Agentic Secrets state."
fi

clean_shell_config() {
  target="$1"
  [ -f "$target" ] || return 0
  mode="$(stat -f '%Lp' "$target" 2>/dev/null || printf '')"
  tmp="${target}.agentic-secrets-clean.$$"
  awk -v bin_dir="$BIN_DIR" -v shim_dir="$SHIM_DIR" '
    function is_marker(line) {
      return line == "# Agentic Secrets PATH" || line == "# AgenticSecrets CLI shims"
    }
    function block_has_managed_path(count, i) {
      for (i = 1; i <= count; i++) {
        if (index(block[i], bin_dir) || index(block[i], shim_dir)) {
          return 1
        }
      }
      return 0
    }
    {
      if (is_marker($0)) {
        count = 1
        block[count] = $0
        while ((getline next_line) > 0) {
          count++
          block[count] = next_line
          if (next_line == "esac") {
            break
          }
        }
        if (count >= 3 && block[2] == "case \":$PATH:\" in" && block[count] == "esac" && block_has_managed_path(count)) {
          next
        }
        for (i = 1; i <= count; i++) {
          print block[i]
        }
        next
      }
      print
    }
  ' "$target" >"$tmp"
  mv "$tmp" "$target"
  [ -z "$mode" ] || chmod "$mode" "$target" 2>/dev/null || true
}

clean_shell_config "$HOME/.zshrc"
clean_shell_config "$HOME/.bashrc"
clean_shell_config "$HOME/.profile"

find "$PREFIX" -type d -empty -delete 2>/dev/null || true
printf '%s\n' "$PREFIX"
