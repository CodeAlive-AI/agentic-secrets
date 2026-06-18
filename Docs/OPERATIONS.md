# Agentic Secrets Operations

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
swift run agentic-secrets release-gates
swift run agentic-secrets ipc-conformance
./scripts/check_secret_authority.sh
```

`canRunLocal` is the production gate for the default self-build track. `canDistributeBinary` is only for optional future Developer ID releases.

## Local Install, Update, and Uninstall

Install from the current checkout:

```sh
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
```

Update by running the install command again from the desired commit. The script rebuilds, ad-hoc signs, validates, copies the app bundle, refreshes command symlinks, rewrites the install manifest, waits for broker IPC health when loading the LaunchAgent, and opens the installed app when using the default user-local prefix. Use `--no-open` for scripted updates.

Smoke-test installed IPC:

```sh
PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
SOCKET="/tmp/agentic-secrets-core-smoke.sock"
"$PREFIX/Applications/AgenticSecrets.app/Contents/MacOS/agentic-secrets-brokerd" serve-once \
  --socket "$SOCKET" \
  --manifest "$PREFIX/var/agentic-secrets/install-manifest.json" &
"$PREFIX/bin/agentic-secrets-shim" --ipc-health \
  --socket "$SOCKET" \
  --manifest "$PREFIX/var/agentic-secrets/install-manifest.json"
```

The native app can remove the local install from **Diagnostics → Removal → Remove Local Install**. The confirmation dialog removes managed shell PATH entries by default and deletes local Agentic Secrets state only when **Delete local Agentic Secrets state** is explicitly selected.

Uninstall from the command line without deleting local state or local secret records:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticSecrets/LocalInstall" --keep-secrets
```

Uninstall and remove local Agentic Secrets state:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticSecrets/LocalInstall" --purge-local-state
```

Uninstall removes the per-user LaunchAgent, helper links, command shims under the local install prefix, runtime files, the socket directory, the installed app bundle, and Agentic Secrets-managed PATH blocks from known shell startup files. With state purge selected, it also removes local state files and known Agentic Secrets Keychain integrity sidecars for that state directory. Local secret record deletion is intentionally not implicit. Use `--purge-local-state` only as an explicit operator action, not as a side effect of package removal.

## Local Secret Prompt Verification

Non-interactive contract check:

```sh
./scripts/interactive_keychain_prompt_check.sh
```

Interactive prompt-producing check:

```sh
AGENTIC_SECRETS_INTERACTIVE=1 ./scripts/interactive_keychain_prompt_check.sh
```

Interactive cancellation check:

```sh
AGENTIC_SECRETS_INTERACTIVE=1 AGENTIC_SECRETS_EXPECT_CANCEL=1 ./scripts/interactive_keychain_prompt_check.sh
```

For the cancellation check, press Deny or Cancel in the macOS prompt. The command passes only when core reports `userCanceled` and no secret is resolved.

The interactive path first packages the app and then runs the packaged `agentic-secrets-brokerd` binary. This matters on macOS Tahoe because restricted Keychain entitlements are not valid for ad-hoc self-build binaries. The default self-build path uses an owner-only local encrypted secret store gated by LocalAuthentication, without shared Keychain access.

The script creates a temporary device-local encrypted secret record, reads it through the decision-bound LocalAuthentication reason, and deletes it. It never prints the generated secret value.

LocalAuthentication may surface as Touch ID, Apple Watch, or the local account password. Treat all of these as valid local user-presence prompts unless the test is specifically verifying cancellation.

The prompt-producing path runs in `agentic-secrets-brokerd`; CLI and helper targets are guarded by `scripts/check_secret_authority.sh` from directly using production secret resolution.

## CLI App Registration

Register a CLI app with one secret-backed environment variable:

```sh
PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
"$PREFIX/bin/agentic-secrets" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-prompt
```

The secret value is read by `agentic-secrets-brokerd` through a hidden prompt. The front-end CLI process does not parse or persist the value, and the value must not be passed as `HCLOUD_TOKEN=value` in argv.

For clipboard or automation use, pipe the value explicitly:

```sh
pbpaste | "$PREFIX/bin/agentic-secrets" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-stdin
```

For multiple environment variables, pass a JSON object over stdin:

```sh
printf '%s\n' '{"HCLOUD_TOKEN":"<redacted>"}' | "$PREFIX/bin/agentic-secrets" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secrets-json-stdin
```

Run the registered CLI with target arguments after `--`:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud -- server list
```

Use `--quiet` before `--` for scripts that do not want AgenticSecrets diagnostic lines on stderr:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud --quiet -- server list
```

Unregister the CLI app and delete its local secret records:

```sh
"$PREFIX/bin/agentic-secrets" cli unregister hcloud --delete-secrets
```

Registration stores non-secret metadata in `var/agentic-secrets/cli-registry.json` and encrypted secret records under `var/agentic-secrets/secrets/`. Registry files are owner-only and must not contain plaintext token material. The registry is also paired with `var/agentic-secrets/cli-registry.integrity.json`; that sidecar is signed with an HMAC-SHA256 key stored in the user's macOS Keychain using `WhenUnlockedThisDeviceOnly` accessibility. If the registry or sidecar is edited outside Agentic Secrets, `cli run` fails before local authentication and before any secret-store read.

During `cli run`, the front-end CLI still does not resolve the secret; `agentic-secrets-brokerd` resolves it after local authentication, scrubs inherited secret-like environment variables, and injects the registered environment variables only into the child process.

After a successful local authentication prompt, Secret Broker writes an HMAC-signed CLI authorization grant under Agentic Secrets state. The default mode is `always`, which does not expire. `remember-24h` expires after 24 hours, `short` uses the 300 second default TTL with a 900 second maximum, and `once` disables reuse. Grants contain no secret material. Persistent grants are signed with a device-local macOS Keychain key and scoped to CLI name, target identity, workspace hash, config context, untrusted origin hint, provenance confidence, delivery mode, and secret alias. Short grants additionally bind action class, command digest, and risk. Matching runs reuse the grant and skip the LocalAuthentication prompt; non-matching runs prompt again. Each command is still policy-checked before secret delivery, and destructive commands require fresh approval.

The LocalAuthentication prompt shows the parent app display name when available. Environment-derived names are display context only; they do not make the origin trusted.

Per-run authorization mode:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud --authorization-mode remember-24h -- server list
"$PREFIX/bin/agentic-secrets" cli run hcloud --authorization-mode short --delivery-grant-ttl-seconds 60 -- server list
"$PREFIX/bin/agentic-secrets" cli run hcloud --authorization-mode once -- server list
```

Legacy TTL override still selects short authorization mode:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud --delivery-grant-ttl-seconds 0 -- server list
```

Agentic Secrets does not require per-CLI shims in the default self-build flow. Installed Agentic Secrets executables are symlinked under `$PREFIX/bin`, while registered apps are stored as metadata in `cli-registry.json`. When a CLI is auto-discovered from `PATH`, the registry keeps the stable invocation path such as `/opt/homebrew/bin/hcloud`, plus the target binary identity captured at registration time. Each `cli run` resolves the current target, validates it against the captured macOS designated requirement when available, and otherwise falls back to SHA-256 identity pinning. Homebrew CLI upgrades therefore fail closed until the CLI target trust is refreshed after you verify the new binary. Because this changes trusted identity metadata, it requires LocalAuthentication:

```sh
"$PREFIX/bin/agentic-secrets" cli trust-refresh hcloud
```

`trust-refresh` updates only target identity metadata and re-seals the registry integrity sidecar; it does not read, rewrite, or ask for the token again. If local authentication is canceled or the target changes between the authentication prompt and the registry write, the command fails closed and leaves the previous trust metadata intact. A manually registered versioned path such as `/opt/homebrew/Cellar/hcloud/1.65.0/bin/hcloud` is also pinned and must be trust-refreshed or registered again after the version is removed.

Optional shim mode is available when users want `hcloud ...` to route through Agentic Secrets directly:

```sh
agentic-secrets cli shim install hcloud --configure-shell
```

This creates `$PREFIX/shims/hcloud` as a symlink to the installed `agentic-secrets-shim` binary and prepends the shim directory to future shell sessions. It does not edit or replace `/opt/homebrew/bin/hcloud`.

Normal shimmed commands route to `agentic-secrets cli run hcloud -- ...`. Global help/version commands pass through to the registered target without secret resolution or injection:

```sh
hcloud --help
hcloud server --help
hcloud version
```

The pass-through environment is still scrubbed of inherited secret-like variables.

Pass-through help/version reads only non-secret registry metadata and avoids the registry Keychain integrity key. Secret-bearing commands still verify registry integrity inside core before resolving local secret material.

If `hcloud server list` works through `agentic-secrets cli run hcloud -- ...`
but fails inside Codex App with `no active context or token`, verify that Codex
resolves `hcloud` to the Agentic Secrets shim:

```sh
command -v hcloud
agentic-secrets cli shim install hcloud --force
```

Do not fix this by adding `HCLOUD_TOKEN` to `~/.codex/.env`; keep provider
tokens out of Codex process environment and route through Agentic Secrets.

## Adapter Management

List built-in adapter metadata:

```sh
swift run agentic-secrets adapter list
```

Install a verified payload into a registry document:

```sh
swift run agentic-secrets adapter install-payload payload.json state/policyPacks.json
```

Revoke an adapter:

```sh
swift run agentic-secrets command policy pack revoke com.example.adapter state/policyPacks.json
```

External command policy packs must be signed and verified before they are accepted by production policy. Adapter id, version, and hash are part of remembered lease scope.

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

## Bitwarden Provider Rotation

Rotation order:

1. create new Bitwarden token
2. store new token through the broker-owned local secret store under the configured Bitwarden alias
3. test exact approved secret access
4. switch binding
5. invalidate provider leases
6. revoke old token
7. write redacted audit event

Production Bitwarden provider profiles require per-fetch approval by default.

## API Session Profiles

API session profiles must define:

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

The native app is the preferred recovery path for ordinary users:

- Open **Diagnostics**.
- Review the **Daemon** section.
- Use **Install Local Daemon** when the local self-build daemon has not been installed.
- Use **Repair Local Daemon** when helper links, the install manifest, or the LaunchAgent need to be refreshed.
- Use **Restart Daemon** when the LaunchAgent exists but IPC is unavailable.

The UI shows the app copy, helper directory, state directory, run directory, install manifest, LaunchAgent, and socket before changing files. It does not read or move local secret material. If the app was launched from a temporary build location, open the installed copy after installation so IPC authorization matches the install manifest.

Run these checks before accepting a local production release:

```sh
./scripts/ci.sh
./scripts/tahoe_compatibility_check.sh
./scripts/check_secret_authority.sh
./scripts/check_entitlements_diff.sh "build/AgenticSecrets.app"
swift run agentic-secrets release-gates
swift run agentic-secrets ipc-conformance
swift run agentic-secrets mcp-conformance
./scripts/create_release_evidence.sh
```

Diagnostics must not include raw provider tokens, Keychain values, or full Authorization headers. Use `agentic-secrets redact` for ad-hoc log review.

## Release

Local package validation:

```sh
./scripts/package_release.sh
./scripts/validate_release_artifact.sh "build/AgenticSecrets.app"
./scripts/check_entitlements_diff.sh "build/AgenticSecrets.app"
./scripts/create_release_evidence.sh
```

The default supported distribution path is source checkout plus local ad-hoc signing. Developer ID signing and notarization are optional future maintainer steps for downloadable binaries.

Optional distribution signing and notarization:

```sh
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARYTOOL_PROFILE="agentic-secrets-notary" \
./scripts/sign_notarize_release.sh
```

Credentials must be stored in the macOS keychain via `xcrun notarytool store-credentials`. Do not put signing or notarization secrets in repository files.

See `Docs/FUTURE_DEVELOPER_ID.md` for the optional Developer ID roadmap.
