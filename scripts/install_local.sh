#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/version.env"

PREFIX="$HOME/Library/Application Support/AgenticFortress/LocalInstall"
LOAD_LAUNCHD=0
CONFIGURE_SHELL=0
SHELL_CONFIG=""
PREFIX_EXPLICIT=0

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
"$ROOT/scripts/package_release.sh" >/tmp/agentic-fortress-install-package-path.txt
APP_SOURCE="$(tail -n 1 /tmp/agentic-fortress-install-package-path.txt)"

APP_DEST="$PREFIX/Applications/$APP_NAME.app"
BIN_DIR="$PREFIX/bin"
STATE_DIR="$PREFIX/var/agentic-fortress"
RUN_DIR="$PREFIX/run/agentic-fortress"
LAUNCH_DIR="$PREFIX/Library/LaunchAgents"
MANIFEST_PATH="$STATE_DIR/install-manifest.json"

rm -rf "$APP_DEST"
mkdir -p "$(dirname "$APP_DEST")" "$BIN_DIR" "$STATE_DIR" "$RUN_DIR" "$LAUNCH_DIR"
ditto "$APP_SOURCE" "$APP_DEST"

for executable in AgenticFortress agentic-fortress agentic-fortress-shim agentic-fortressd-core agentic-fortress-proxyd agentic-fortress-bwsd agentic-fortress-mcpd; do
  ln -sf "$APP_DEST/Contents/MacOS/$executable" "$BIN_DIR/$executable"
done

CORE_PLIST="$LAUNCH_DIR/com.agenticfortress.core.plist"
cat >"$CORE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.agenticfortress.core</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DEST/Contents/MacOS/agentic-fortressd-core</string>
    <string>serve</string>
    <string>--socket</string>
    <string>$RUN_DIR/core.sock</string>
    <string>--manifest</string>
    <string>$MANIFEST_PATH</string>
  </array>
  <key>RunAtLoad</key>
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
    printf '  "productName": "AgenticFortress",\n'
    printf '  "appVersion": "%s",\n' "$MARKETING_VERSION"
    printf '  "releaseChannel": "%s",\n' "$RELEASE_CHANNEL"
    printf '  "prefix": "%s",\n' "$(printf '%s' "$PREFIX" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '  "installedAt": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '  "helpers": [\n'
    first=1
    for helper in AgenticFortress agentic-fortress-shim agentic-fortressd-core agentic-fortress-proxyd agentic-fortress-bwsd agentic-fortress-mcpd; do
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
    printf '\n# AgenticFortress PATH\n'
    printf 'case ":$PATH:" in\n'
    printf '  *":%s:"*) ;;\n' "$BIN_DIR"
    printf '  *) export PATH="%s:$PATH" ;;\n' "$BIN_DIR"
    printf 'esac\n'
  } >>"$target"
  printf 'Configured shell PATH in %s\n' "$target"
}

if [ "$CONFIGURE_SHELL" -eq 1 ]; then
  configure_shell_path
fi

if [ "$LOAD_LAUNCHD" -eq 1 ]; then
  launchctl bootout "gui/$(id -u)" "$CORE_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$CORE_PLIST"
fi

printf '%s\n' "$PREFIX"
printf '\nInstalled AgenticFortress commands under:\n  %s\n' "$BIN_DIR"
if command -v agentic-fortress >/dev/null 2>&1; then
  printf 'agentic-fortress is already available on PATH: %s\n' "$(command -v agentic-fortress)"
else
  printf '\nagentic-fortress is not on PATH in this shell yet.\n'
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
