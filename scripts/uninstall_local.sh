#!/usr/bin/env sh
set -eu

. "$(cd "$(dirname "$0")/.." && pwd)/version.env"

DEFAULT_PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
PREFIX="$DEFAULT_PREFIX"
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

if [ "$PREFIX" = "$DEFAULT_PREFIX" ]; then
  APP_DEST="$HOME/Applications/$APP_NAME.app"
else
  APP_DEST="$PREFIX/Applications/$APP_NAME.app"
fi
LEGACY_APP_DEST="$PREFIX/Applications/$APP_NAME.app"
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

bundle_id_at() {
  [ -d "$1" ] || return 1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || return 1
}

remove_managed_app_bundle() {
  path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ -L "$path" ]; then
    link_target="$(readlink "$path" 2>/dev/null || printf '')"
    if [ "$link_target" = "$LEGACY_APP_DEST" ] || [ "$link_target" = "$APP_DEST" ]; then
      rm -f "$path"
      return 0
    fi
  fi
  if [ "$(bundle_id_at "$path" || printf '')" = "$BUNDLE_ID" ]; then
    rm -rf "$path"
  fi
}

remove_managed_app_bundle "$APP_DEST"
remove_managed_app_bundle "$LEGACY_APP_DEST"

for executable in agentic-secrets AgenticSecrets agentic-secrets-shim agentic-secrets-brokerd agentic-secrets-api-sessiond agentic-secrets-bitwarden-providerd agentic-secrets-mcpd; do
  rm -f "$BIN_DIR/$executable"
done

normalize_link_destination() {
  link_path="$1"
  destination="$2"
  case "$destination" in
    /*)
      printf '%s\n' "$destination"
      ;;
    *)
      link_dir="$(dirname "$link_path")"
      destination_dir="$(dirname "$destination")"
      destination_base="$(basename "$destination")"
      if cd "$link_dir/$destination_dir" 2>/dev/null; then
        printf '%s/%s\n' "$(pwd -P)" "$destination_base"
      else
        printf '%s/%s\n' "$link_dir" "$destination"
      fi
      ;;
  esac
}

remove_managed_shims() {
  [ -d "$SHIM_DIR" ] || return 0
  expected_bin="$BIN_DIR/agentic-secrets-shim"
  expected_app="$APP_DEST/Contents/MacOS/agentic-secrets-shim"
  for shim in "$SHIM_DIR"/* "$SHIM_DIR"/.[!.]* "$SHIM_DIR"/..?*; do
    [ -e "$shim" ] || [ -L "$shim" ] || continue
    [ -L "$shim" ] || continue
    target="$(readlink "$shim" 2>/dev/null || printf '')"
    [ -n "$target" ] || continue
    normalized="$(normalize_link_destination "$shim" "$target")"
    if [ "$normalized" = "$expected_bin" ] || [ "$normalized" = "$expected_app" ]; then
      rm -f "$shim"
    fi
  done
  rmdir "$SHIM_DIR" 2>/dev/null || true
}

rm -f "$CORE_PLIST"
remove_managed_shims
rm -rf "$RUN_DIR"
rm -rf "$SOCKET_DIR"

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
          if (next_line == "esac" || next_line ~ /^[[:space:]]*export PATH=/) {
            break
          }
        }
        case_index = 2
        if (block[2] ~ /^[[:space:]]*agentic_secrets_path_dir=/) {
          case_index = 3
        }
        if (count >= case_index && block[case_index] ~ /^[[:space:]]*export PATH=/ && block_has_managed_path(count)) {
          next
        }
        if (count >= case_index + 2 && block[case_index] == "case \":$PATH:\" in" && block[count] == "esac" && block_has_managed_path(count)) {
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

clean_shell_config "$HOME/.zshenv"
clean_shell_config "$HOME/.zprofile"
clean_shell_config "$HOME/.zshrc"
clean_shell_config "$HOME/.bash_profile"
clean_shell_config "$HOME/.bashrc"
clean_shell_config "$HOME/.profile"

find "$PREFIX" -type d -empty -delete 2>/dev/null || true
printf '%s\n' "$PREFIX"
