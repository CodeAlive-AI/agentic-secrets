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
LINK_USER_APPLICATIONS=1

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
    --link-user-applications)
      LINK_USER_APPLICATIONS=1
      shift
      ;;
    --no-link-user-applications)
      LINK_USER_APPLICATIONS=0
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

APP_DEST="$PREFIX/Applications/$APP_NAME.app"
USER_APPLICATIONS_DIR="$HOME/Applications"
USER_APP_LINK="$USER_APPLICATIONS_DIR/$APP_NAME.app"
BIN_DIR="$PREFIX/bin"
STATE_DIR="$PREFIX/var/agentic-secrets"
RUN_DIR="$PREFIX/run/agentic-secrets"
SOCKET_DIR="/tmp/agentic-secrets-$(id -u)"
SOCKET_PATH="$SOCKET_DIR/core.sock"
LAUNCH_DIR="$PREFIX/Library/LaunchAgents"
MANIFEST_PATH="$STATE_DIR/install-manifest.json"

rm -rf "$APP_DEST"
mkdir -p "$(dirname "$APP_DEST")" "$BIN_DIR" "$STATE_DIR" "$RUN_DIR" "$SOCKET_DIR" "$LAUNCH_DIR"
chmod 700 "$SOCKET_DIR"
ditto "$APP_SOURCE" "$APP_DEST"

remove_managed_user_app_link() {
  [ -L "$USER_APP_LINK" ] || return 0
  link_target="$(readlink "$USER_APP_LINK" 2>/dev/null || printf '')"
  if [ "$link_target" = "$APP_DEST" ]; then
    rm -f "$USER_APP_LINK"
  fi
}

link_user_applications() {
  [ "$LINK_USER_APPLICATIONS" -eq 1 ] || return 0
  mkdir -p "$USER_APPLICATIONS_DIR"
  remove_managed_user_app_link
  if [ -e "$USER_APP_LINK" ] || [ -L "$USER_APP_LINK" ]; then
    printf 'Skipped Applications shortcut because a file already exists:\n  %s\n' "$USER_APP_LINK"
    return 0
  fi
  ln -s "$APP_DEST" "$USER_APP_LINK"
}

link_user_applications

for executable in AgenticSecrets agentic-secrets agentic-secrets-shim agentic-secrets-brokerd agentic-secrets-api-sessiond agentic-secrets-bitwarden-providerd agentic-secrets-mcpd; do
  ln -sf "$APP_DEST/Contents/MacOS/$executable" "$BIN_DIR/$executable"
done

CORE_PLIST="$LAUNCH_DIR/com.agenticsecrets.broker.plist"
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

default_shell_config() {
  case "$(basename "${SHELL:-zsh}")" in
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    bash)
      printf '%s\n' "$HOME/.bashrc"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

configure_shell_path() {
  target="${SHELL_CONFIG:-$(default_shell_config)}"
  mkdir -p "$(dirname "$target")"
  touch "$target"
  {
    printf '\n# Agentic Secrets PATH\n'
    printf 'case ":$PATH:" in\n'
    printf '  *":%s:"*) ;;\n' "$BIN_DIR"
    printf '  *) export PATH="%s:$PATH" ;;\n' "$BIN_DIR"
    printf 'esac\n'
  } >>"$target"
  printf 'Configured shell PATH in %s\n' "$target"
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
if [ "$LOAD_LAUNCHD" -eq 1 ]; then
  launchctl bootout "gui/$(id -u)" "$CORE_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$CORE_PLIST"
  printf 'Waiting for broker daemon...\n'
  if wait_for_daemon_health; then
    DAEMON_READY=1
    printf 'Broker daemon is reachable.\n'
  else
    printf 'Broker daemon did not become reachable before the installer timeout.\n'
  fi
fi

if [ "$PREFIX" != "$DEFAULT_PREFIX" ] && [ "$OPEN_EXPLICIT" -eq 0 ]; then
  OPEN_APP=0
fi

printf '%s\n' "$PREFIX"
if [ "$LINK_USER_APPLICATIONS" -eq 1 ] && [ -L "$USER_APP_LINK" ]; then
  printf '\nApplications shortcut:\n  %s\n' "$USER_APP_LINK"
fi
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

if [ "$OPEN_APP" -eq 1 ] && [ "$LOAD_LAUNCHD" -eq 1 ] && [ "$DAEMON_READY" -eq 0 ]; then
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
