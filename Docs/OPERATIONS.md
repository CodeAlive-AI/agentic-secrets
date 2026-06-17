# AgenticFortress Operations

## Verification

The full no-Developer-ID production acceptance set is defined in `Docs/ACCEPTANCE_CRITERIA.md`.
For operator-facing installation steps and common local macOS pitfalls, see `Docs/INSTALLATION.md`.

Run the standard contract gate:

```sh
./scripts/ci.sh
```

Run the macOS Tahoe package/signing gate:

```sh
./scripts/tahoe_compatibility_check.sh
```

Check release readiness split by distribution track:

```sh
swift run agentic-fortress release-gates
swift run agentic-fortress ipc-conformance
./scripts/check_secret_authority.sh
```

`canRunLocal` is the production gate for the default self-build track. `canDistributeBinary` is only for optional future Developer ID releases.

## Local Install, Update, and Uninstall

Install from the current checkout:

```sh
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall"
```

Update by running the install command again from the desired commit. The script rebuilds, ad-hoc signs, validates, copies the app bundle, refreshes command symlinks, and rewrites the install manifest.

Smoke-test installed IPC:

```sh
PREFIX="$HOME/Library/Application Support/AgenticFortress/LocalInstall"
SOCKET="/tmp/agentic-fortress-core-smoke.sock"
"$PREFIX/Applications/AgenticFortress.app/Contents/MacOS/agentic-fortressd-core" serve-once \
  --socket "$SOCKET" \
  --manifest "$PREFIX/var/agentic-fortress/install-manifest.json" &
"$PREFIX/bin/agentic-fortress-shim" --ipc-health \
  --socket "$SOCKET" \
  --manifest "$PREFIX/var/agentic-fortress/install-manifest.json"
```

Uninstall without deleting local state or local secret records:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --keep-secrets
```

Uninstall and remove local AgenticFortress state:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --purge-local-state
```

Local secret record deletion is intentionally not implicit. Use `--purge-local-state` only as an explicit operator action, not as a side effect of package removal.

## Local Secret Prompt Verification

Non-interactive contract check:

```sh
./scripts/interactive_keychain_prompt_check.sh
```

Interactive prompt-producing check:

```sh
AGENTIC_FORTRESS_INTERACTIVE=1 ./scripts/interactive_keychain_prompt_check.sh
```

Interactive cancellation check:

```sh
AGENTIC_FORTRESS_INTERACTIVE=1 AGENTIC_FORTRESS_EXPECT_CANCEL=1 ./scripts/interactive_keychain_prompt_check.sh
```

For the cancellation check, press Deny or Cancel in the macOS prompt. The command passes only when core reports `userCanceled` and no secret is resolved.

The interactive path first packages the app and then runs the packaged `agentic-fortressd-core` binary. This matters on macOS Tahoe because restricted Keychain entitlements are not valid for ad-hoc self-build binaries. The default self-build path uses an owner-only local encrypted secret store gated by LocalAuthentication, without shared Keychain access.

The script creates a temporary device-local encrypted secret record, reads it through the decision-bound LocalAuthentication reason, and deletes it. It never prints the generated secret value.

The prompt-producing path runs in `agentic-fortressd-core`; CLI and helper targets are guarded by `scripts/check_secret_authority.sh` from directly using production secret resolution.

## CLI App Registration

Register a CLI app with one secret-backed environment variable:

```sh
PREFIX="$HOME/Library/Application Support/AgenticFortress/LocalInstall"
pbpaste | "$PREFIX/bin/agentic-fortress" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-stdin
```

The secret value is read by `agentic-fortressd-core` from stdin. The front-end CLI process does not parse or persist the value, and the value must not be passed as `HCLOUD_TOKEN=value` in argv.

For an interactive hidden prompt:

```sh
"$PREFIX/bin/agentic-fortress" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-prompt
```

For multiple environment variables, pass a JSON object over stdin:

```sh
printf '%s\n' '{"HCLOUD_TOKEN":"<redacted>"}' | "$PREFIX/bin/agentic-fortress" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secrets-json-stdin
```

Unregister the CLI app and delete its local secret records:

```sh
"$PREFIX/bin/agentic-fortress" cli unregister hcloud --delete-secrets
```

Registration stores non-secret metadata in `var/agentic-fortress/cli-registry.json` and encrypted secret records under `var/agentic-fortress/secrets/`. Registry files are owner-only and must not contain plaintext token material.

## Adapter Management

List built-in adapter metadata:

```sh
swift run agentic-fortress adapter list
```

Install a verified payload into a registry document:

```sh
swift run agentic-fortress adapter install-payload payload.json state/adapters.json
```

Revoke an adapter:

```sh
swift run agentic-fortress adapter revoke com.example.adapter state/adapters.json
```

External adapter packs must be signed and verified before they are accepted by production policy. Adapter id, version, and hash are part of remembered lease scope.

## Policy Recovery

Rollback mismatch puts policy into locked mode. Allowed operator actions:

- export diagnostic summary
- reset local policy
- import recovery bundle
- rebind providers

Blocked actions:

- secret delivery
- remembered approvals
- provider leases
- MCP bridge sessions

Accepting an old policy database never preserves remembered approvals.

## BWS Rotation

Rotation order:

1. create new BWS token
2. store new token through the core-owned local secret store under the configured BWS alias
3. test exact approved secret access
4. switch binding
5. invalidate provider leases
6. revoke old token
7. write redacted audit event

Production BWS profiles require per-fetch approval by default.

## Proxy Profiles

Proxy profiles must define:

- upstream origin
- allowed path prefixes
- allowed methods
- secret alias
- token TTL

Request and response bodies are not logged by default.

## MCP Profiles

MCP bridge profiles must define:

- pinned upstream origin
- allowed path prefixes
- Authorization header behavior
- cross-origin redirect policy

The bridge propagates `MCP-Session-Id` when supplied by the upstream server. Tool filtering is only a guardrail; upstream authorization scope remains the real security boundary.

## Diagnostics

Run these checks before accepting a local production release:

```sh
./scripts/ci.sh
./scripts/tahoe_compatibility_check.sh
./scripts/check_secret_authority.sh
./scripts/check_entitlements_diff.sh build/AgenticFortress.app
swift run agentic-fortress release-gates
swift run agentic-fortress ipc-conformance
swift run agentic-fortress mcp-conformance
./scripts/create_release_evidence.sh
```

Diagnostics must not include raw provider tokens, Keychain values, or full Authorization headers. Use `agentic-fortress redact` for ad-hoc log review.

## Release

Local package validation:

```sh
./scripts/package_release.sh
./scripts/validate_release_artifact.sh build/AgenticFortress.app
./scripts/check_entitlements_diff.sh build/AgenticFortress.app
./scripts/create_release_evidence.sh
```

The default supported distribution path is source checkout plus local ad-hoc signing. Developer ID signing and notarization are optional future maintainer steps for downloadable binaries.

Optional distribution signing and notarization:

```sh
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARYTOOL_PROFILE="agentic-fortress-notary" \
./scripts/sign_notarize_release.sh
```

Credentials must be stored in the macOS keychain via `xcrun notarytool store-credentials`. Do not put signing or notarization secrets in repository files.

See `Docs/FUTURE_DEVELOPER_ID.md` for the optional Developer ID roadmap.
