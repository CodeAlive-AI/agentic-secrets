#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p "$ROOT/build/release-evidence"
COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(git rev-parse --short HEAD)"
OUT="$ROOT/build/release-evidence/agentic-fortress-$SHORT_COMMIT.md"

append_cmd() {
  title="$1"
  shift
  printf '\n## %s\n\n```sh\n%s\n```\n\n```text\n' "$title" "$*" >>"$OUT"
  "$@" >>"$OUT" 2>&1
  printf '```\n' >>"$OUT"
}

cat >"$OUT" <<EOF
# AgenticFortress Release Evidence

- Product: AgenticFortress
- Release track: source self-build with local ad-hoc signing
- Commit: $COMMIT
- Generated at UTC: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- Residual risks:
  - Developer ID signing, notarization, stapling, and downloadable Gatekeeper-friendly binaries are not part of this release track.
  - Same-user malware, root compromise, kernel compromise, malicious target CLIs, and upstream provider compromise remain documented limits.

EOF

append_cmd "Git Status" git status --short
append_cmd "macOS Version" sw_vers
append_cmd "macOS SDK Version" xcrun --sdk macosx --show-sdk-version
append_cmd "Swift Version" swift --version
append_cmd "CI" ./scripts/ci.sh
append_cmd "Secret Authority Gate" ./scripts/check_secret_authority.sh
append_cmd "Release Gates" swift run agentic-fortress release-gates
append_cmd "Package" ./scripts/package_release.sh
append_cmd "Package Validation" ./scripts/validate_release_artifact.sh build/AgenticFortress.app
append_cmd "IPC Conformance" swift run agentic-fortress ipc-conformance
append_cmd "MCP Conformance" swift run agentic-fortress mcp-conformance

printf '%s\n' "$OUT"
