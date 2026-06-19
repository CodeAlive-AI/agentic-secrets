#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/version.env"

DEFAULT_PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
PREFIX="$DEFAULT_PREFIX"
LOAD_LAUNCHD=0
CONFIGURE_SHELL=0
SHELL_CONFIG=""
PREFIX_EXPLICIT=0
OPEN_APP=1
OPEN_EXPLICIT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      PREFIX_EXPLICIT=1
      shift 2
      ;;
    --load)
      LOAD_LAUNCHD=1
      shift
      ;;
    --open)
      OPEN_APP=1
      OPEN_EXPLICIT=1
      shift
      ;;
    --no-open)
      OPEN_APP=0
      OPEN_EXPLICIT=1
      shift
      ;;
    --configure-shell)
      CONFIGURE_SHELL=1
      shift
      ;;
    --shell-config)
      SHELL_CONFIG="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

APP_SOURCE="$ROOT/build/$APP_NAME.app"
"$ROOT/scripts/package_release.sh" >/tmp/agentic-secrets-install-package-path.txt
APP_SOURCE="$(tail -n 1 /tmp/agentic-secrets-install-package-path.txt)"

if [ "$PREFIX" = "$DEFAULT_PREFIX" ]; then
  APP_DEST="$HOME/Applications/$APP_NAME.app"
else
  APP_DEST="$PREFIX/Applications/$APP_NAME.app"
fi
LEGACY_APP_DEST="$PREFIX/Applications/$APP_NAME.app"
BIN_DIR="$PREFIX/bin"
STATE_DIR="$PREFIX/var/agentic-secrets"
RUN_DIR="$PREFIX/run/agentic-secrets"
SOCKET_DIR="/tmp/agentic-secrets-$(id -u)"
SOCKET_PATH="$SOCKET_DIR/core.sock"
LAUNCH_DIR="$PREFIX/Library/LaunchAgents"
MANIFEST_PATH="$STATE_DIR/install-manifest.json"
BROKER_LABEL="com.agenticsecrets.broker"
CORE_PLIST="$LAUNCH_DIR/$BROKER_LABEL.plist"

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
    return 0
  fi
  printf 'Refusing to replace non-Agentic Secrets app at:\n  %s\n' "$path" >&2
  exit 73
}

running_ui_pids() {
  /usr/bin/pgrep -x "$APP_EXECUTABLE_NAME" 2>/dev/null || true
}

wait_for_ui_exit() {
  attempt=1
  while [ "$attempt" -le 25 ]; do
    if [ -z "$(running_ui_pids)" ]; then
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  return 1
}

terminate_running_ui() {
  pids="$(running_ui_pids)"
  [ -n "$pids" ] || return 1

  printf 'Stopping running Agentic Secrets app before replacing it...\n'
  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  if wait_for_ui_exit; then
    return 0
  fi

  pids="$(running_ui_pids)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    /bin/kill -TERM $pids >/dev/null 2>&1 || true
  fi
  if wait_for_ui_exit; then
    return 0
  fi

  pids="$(running_ui_pids)"
  if [ -n "$pids" ]; then
    printf 'Agentic Secrets app did not exit cleanly; forcing shutdown.\n'
    # shellcheck disable=SC2086
    /bin/kill -KILL $pids >/dev/null 2>&1 || true
  fi
  wait_for_ui_exit || true
  return 0
}

broker_is_loaded() {
  launchctl print "gui/$(id -u)/$BROKER_LABEL" >/dev/null 2>&1
}

bootout_existing_broker() {
  if [ -f "$CORE_PLIST" ]; then
    launchctl bootout "gui/$(id -u)" "$CORE_PLIST" >/dev/null 2>&1 || true
  else
    launchctl bootout "gui/$(id -u)/$BROKER_LABEL" >/dev/null 2>&1 || true
  fi
}

UI_WAS_RUNNING=0
if terminate_running_ui; then
  UI_WAS_RUNNING=1
fi

BROKER_WAS_LOADED=0
if broker_is_loaded; then
  BROKER_WAS_LOADED=1
  printf 'Stopping running broker daemon before replacing it...\n'
  bootout_existing_broker
fi

remove_managed_app_bundle "$APP_DEST"
remove_managed_app_bundle "$LEGACY_APP_DEST"
mkdir -p "$(dirname "$APP_DEST")" "$BIN_DIR" "$STATE_DIR" "$RUN_DIR" "$SOCKET_DIR" "$LAUNCH_DIR"
chmod 700 "$SOCKET_DIR"
ditto "$APP_SOURCE" "$APP_DEST"

for executable in AgenticSecrets agentic-secrets agentic-secrets-shim agentic-secrets-brokerd agentic-secrets-api-sessiond agentic-secrets-bitwarden-providerd agentic-secrets-mcpd; do
  ln -sf "$APP_DEST/Contents/MacOS/$executable" "$BIN_DIR/$executable"
done

cat >"$CORE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.agenticsecrets.broker</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DEST/Contents/MacOS/agentic-secrets-brokerd</string>
    <string>serve</string>
    <string>--socket</string>
    <string>$SOCKET_PATH</string>
    <string>--manifest</string>
    <string>$MANIFEST_PATH</string>
    <string>--state-dir</string>
    <string>$STATE_DIR</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$RUN_DIR/core.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$RUN_DIR/core.stderr.log</string>
</dict>
</plist>
PLIST

write_manifest() {
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "productName": "Agentic Secrets",\n'
    printf '  "appVersion": "%s",\n' "$MARKETING_VERSION"
    printf '  "releaseChannel": "%s",\n' "$RELEASE_CHANNEL"
    printf '  "prefix": "%s",\n' "$(printf '%s' "$PREFIX" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '  "installedAt": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '  "helpers": [\n'
    first=1
    for helper in AgenticSecrets agentic-secrets-shim agentic-secrets-brokerd agentic-secrets-api-sessiond agentic-secrets-bitwarden-providerd agentic-secrets-mcpd; do
      path="$APP_DEST/Contents/MacOS/$helper"
      hash="$(shasum -a 256 "$path" | awk '{print $1}')"
      owner="$(stat -f '%u' "$path")"
      mode="$(stat -f '%Lp' "$path")"
      parent_mode="$(stat -f '%Lp' "$(dirname "$path")")"
      cdhash="$(codesign -dv --verbose=4 "$path" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
      if [ -n "$cdhash" ]; then
        cdhash_json="\"$cdhash\""
      else
        cdhash_json="null"
      fi
      if [ "$first" -eq 0 ]; then
        printf ',\n'
      fi
      first=0
      printf '    {\n'
      printf '      "helperName": "%s",\n' "$helper"
      printf '      "resolvedPath": "%s",\n' "$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      printf '      "ownerUserID": %s,\n' "$owner"
      printf '      "minimumVersion": "%s",\n' "$MARKETING_VERSION"
      printf '      "binarySHA256": "%s",\n' "$hash"
      printf '      "cdHash": %s,\n' "$cdhash_json"
      printf '      "fileMode": "%s",\n' "$mode"
      printf '      "parentMode": "%s",\n' "$parent_mode"
      printf '      "allowDebugSigned": false\n'
      printf '    }'
    done
    printf '\n  ]\n'
    printf '}\n'
  } >"$MANIFEST_PATH"
}

write_manifest
"$ROOT/scripts/validate_release_artifact.sh" "$APP_DEST" >/dev/null

default_shell_configs() {
  case "$(basename "${SHELL:-zsh}")" in
    zsh)
      printf '%s\n' "$HOME/.zshenv"
      printf '%s\n' "$HOME/.zprofile"
      printf '%s\n' "$HOME/.zshrc"
      ;;
    bash)
      printf '%s\n' "$HOME/.bash_profile"
      printf '%s\n' "$HOME/.bashrc"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

configured_shell_targets() {
  if [ -n "${SHELL_CONFIG:-}" ]; then
    printf '%s\n' "$SHELL_CONFIG"
  else
    default_shell_configs
  fi
}

shell_single_quote() {
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    printf 'Refusing to write shell PATH block for a path containing control characters.\n' >&2
    exit 64
  fi
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

configure_shell_path() {
  quoted_bin_dir="$(shell_single_quote "$BIN_DIR")"
  configured_shell_targets | while IFS= read -r target; do
    mkdir -p "$(dirname "$target")"
    touch "$target"
    {
      printf '\n# Agentic Secrets PATH\n'
      printf 'agentic_secrets_path_dir=%s\n' "$quoted_bin_dir"
      printf 'export PATH="$agentic_secrets_path_dir:$PATH"\n'
    } >>"$target"
    printf 'Configured shell PATH in %s\n' "$target"
  done
}

wait_for_daemon_health() {
  attempt=1
  while [ "$attempt" -le 30 ]; do
    if "$BIN_DIR/agentic-secrets-shim" --ipc-health --socket "$SOCKET_PATH" --manifest "$MANIFEST_PATH" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  return 1
}

if [ "$CONFIGURE_SHELL" -eq 1 ]; then
  configure_shell_path
fi

DAEMON_READY=0
DAEMON_START_REQUESTED=0
if [ "$LOAD_LAUNCHD" -eq 1 ] || [ "$BROKER_WAS_LOADED" -eq 1 ]; then
  DAEMON_START_REQUESTED=1
  bootout_existing_broker
  launchctl bootstrap "gui/$(id -u)" "$CORE_PLIST"
  printf 'Waiting for broker daemon...\n'
  if wait_for_daemon_health; then
    DAEMON_READY=1
    printf 'Broker daemon is reachable.\n'
  else
    printf 'Broker daemon did not become reachable before the installer timeout.\n'
  fi
fi

if [ "$PREFIX" != "$DEFAULT_PREFIX" ] && [ "$OPEN_EXPLICIT" -eq 0 ] && [ "$UI_WAS_RUNNING" -eq 0 ]; then
  OPEN_APP=0
fi
if [ "$UI_WAS_RUNNING" -eq 1 ] && [ "$OPEN_EXPLICIT" -eq 0 ]; then
  OPEN_APP=1
fi

printf '%s\n' "$PREFIX"
printf '\nInstalled Agentic Secrets app:\n  %s\n' "$APP_DEST"
printf '\nInstalled Agentic Secrets commands under:\n  %s\n' "$BIN_DIR"
if command -v agentic-secrets >/dev/null 2>&1; then
  printf 'agentic-secrets is already available on PATH: %s\n' "$(command -v agentic-secrets)"
else
  printf '\nagentic-secrets is not on PATH in this shell yet.\n'
  printf 'For the current shell, run:\n  export PATH="%s:$PATH"\n' "$BIN_DIR"
  cat <<NEXT_STEPS

For future shell sessions, rerun install with:
NEXT_STEPS
  if [ "$PREFIX_EXPLICIT" -eq 1 ]; then
    printf '  ./scripts/install_local.sh --prefix "%s" --load --configure-shell\n' "$PREFIX"
  else
    printf '  ./scripts/install_local.sh --load --configure-shell\n'
  fi
fi

if [ "$OPEN_APP" -eq 1 ] && [ "$DAEMON_START_REQUESTED" -eq 1 ] && [ "$DAEMON_READY" -eq 0 ]; then
  OPEN_APP=0
  printf '\nBroker daemon did not become reachable yet; leaving the app closed.\n'
  printf 'Check daemon status with:\n  launchctl print "gui/%s/com.agenticsecrets.broker"\n' "$(id -u)"
fi

if [ "$OPEN_APP" -eq 1 ]; then
  open "$APP_DEST"
  printf '\nOpened installed Agentic Secrets app:\n  %s\n' "$APP_DEST"
else
  printf '\nInstalled app is available at:\n  %s\n' "$APP_DEST"
fi
