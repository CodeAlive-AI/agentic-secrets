# Agentic Secrets Installation

This is the supported production path for the no-Developer-ID release track: clone the source, build locally, package with ad-hoc signing, and install into a user-owned prefix.

Agentic Secrets does not require an Apple Developer Program account for this path. It also does not require weakening macOS security settings or removing quarantine attributes as a normal step.

## Requirements

- macOS Tahoe 26.x or newer for the production compatibility gate.
- Xcode Command Line Tools or Xcode with macOS 26 SDK or newer.
- SwiftPM available through `swift`.
- Standard macOS command-line tools: `codesign`, `xcrun`, `launchctl`, `ditto`, `shasum`, and `plutil`.
- A source checkout. A downloadable unsigned `.app` is not the supported default distribution format.

Check the local toolchain:

```sh
sw_vers -productVersion
xcrun --sdk macosx --show-sdk-version
swift --version
```

## Build And Verify

From the repository root:

```sh
swift build
./scripts/ci.sh
./scripts/tahoe_compatibility_check.sh
```

`./scripts/ci.sh` is the standard contract gate. `./scripts/tahoe_compatibility_check.sh` additionally proves the local package/signing path on Tahoe with the current SDK.

## Package

```sh
./scripts/package_release.sh
```

The package is written to `build/AgenticSecrets.app`. By default it is ad-hoc signed with hardened runtime and the approved self-build entitlement baseline.

Validate the packaged app explicitly:

```sh
./scripts/validate_release_artifact.sh "build/AgenticSecrets.app"
./scripts/check_entitlements_diff.sh "build/AgenticSecrets.app"
codesign --verify --strict --deep --verbose=4 "build/AgenticSecrets.app"
```

## Install

For a native guided install, open `build/AgenticSecrets.app`, go to **Diagnostics**, review the daemon install plan, and choose **Install Local Daemon**. The app shows the app copy, helper links, state directory, run directory, install manifest, LaunchAgent, and socket path before writing files. It does not read or move local secret material.

If you launched the app from `build/`, open the installed copy after installation so authenticated IPC uses the installed bundle path recorded in the manifest.

The default prefix is `~/Library/Application Support/AgenticSecrets/LocalInstall`, so the common install command is short:

```sh
./scripts/install_local.sh --load --configure-shell
```

This recommended command installs the app at `~/Applications/AgenticSecrets.app`, keeps runtime files under the local install prefix, loads the LaunchAgent, waits for the broker daemon IPC health check, opens the installed app copy, and appends guarded PATH blocks to your user shell startup files so future shell sessions can run `agentic-secrets` directly. For zsh, the installer updates `.zshenv` for non-interactive tool runners, `.zprofile` for login shells, and `.zshrc` for interactive shells. Open a new terminal after installation, or source the relevant startup file in the current one.

For automation or CI where shell startup files must not be touched and the UI should not open, omit `--configure-shell` and pass `--no-open`:

```sh
./scripts/install_local.sh --load --no-open
```

The installer rebuilds, packages, validates, copies the app bundle, creates command symlinks, writes a LaunchAgent plist, and writes an install manifest at:

```text
$PREFIX/var/agentic-secrets/install-manifest.json
```

The manifest records helper paths, owner user IDs, permissions, versions, SHA-256 hashes, and cdhash values. Runtime IPC authorization uses that manifest instead of a Developer ID Team ID.

To add the installed commands to your current shell:

```sh
export PATH="$HOME/Library/Application Support/AgenticSecrets/LocalInstall/bin:$PATH"
```

To make the command available in future zsh sessions, add the same directory to your user shell startup files. Non-interactive tool runners read `.zshenv`; login shells read `.zprofile`; interactive terminal shells read `.zshrc`:

```sh
for file in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc"; do
  cat >> "$file" <<EOF

# Agentic Secrets PATH
agentic_secrets_path_dir="$HOME/Library/Application Support/AgenticSecrets/LocalInstall/bin"
export PATH="\$agentic_secrets_path_dir:\$PATH"
EOF
done
```

The installer prints these next steps after every install. It opens the installed app by default for the standard user-local prefix; pass `--no-open` to suppress that, or `--open` to force opening when installing to an explicit custom prefix. It only edits shell startup files when `--configure-shell` is passed, and it appends without reading existing shell rc contents. It does not write to `/etc/paths.d`; this keeps the self-build installer user-local, reviewable, and reversible.

Do not put raw provider secrets into shell rc files. Configure secret aliases through reviewed product tooling, not through environment variables.

## Start The Secret Broker Daemon

Install without `--load` only writes the LaunchAgent plist. To load it immediately:

```sh
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticSecrets/LocalInstall" --load
```

Inspect launchd state:

```sh
launchctl print "gui/$(id -u)/com.agenticsecrets.broker"
```

Runtime logs are under:

```text
$PREFIX/run/agentic-secrets/core.stdout.log
$PREFIX/run/agentic-secrets/core.stderr.log
```

## Smoke Test Installed IPC

```sh
PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
SOCKET="/tmp/agentic-secrets-core-smoke.sock"
"$HOME/Applications/AgenticSecrets.app/Contents/MacOS/agentic-secrets-brokerd" serve-once \
  --socket "$SOCKET" \
  --manifest "$PREFIX/var/agentic-secrets/install-manifest.json" \
  --state-dir "$PREFIX/var/agentic-secrets" &
"$PREFIX/bin/agentic-secrets-shim" --ipc-health \
  --socket "$SOCKET" \
  --manifest "$PREFIX/var/agentic-secrets/install-manifest.json"
```

## Verify LocalAuthentication Secret Prompt

Non-interactive contract check:

```sh
./scripts/interactive_keychain_prompt_check.sh
```

Interactive success path:

```sh
AGENTIC_SECRETS_INTERACTIVE=1 ./scripts/interactive_keychain_prompt_check.sh
```

Interactive cancellation path:

```sh
AGENTIC_SECRETS_INTERACTIVE=1 AGENTIC_SECRETS_EXPECT_CANCEL=1 ./scripts/interactive_keychain_prompt_check.sh
```

For cancellation, press Deny or Cancel in the macOS prompt. The command passes only when core reports `userCanceled` and no secret is resolved.

LocalAuthentication is the macOS security mechanism. The visible prompt may offer Touch ID, Apple Watch, or the local account password depending on hardware, session state, policy, and current macOS behavior. Agentic Secrets requires successful local user presence; it does not guarantee that the UI will be Touch ID-only.

The script name is kept for compatibility with older acceptance scripts, but the default self-build runtime path uses an owner-only encrypted local file store gated by LocalAuthentication. It does not require shared Keychain access groups.

## Register hcloud Without cli.toml

Do not use `hcloud context create` for the Agentic Secrets flow. That official hcloud mode stores the token in `~/.config/hcloud/cli.toml`.

Instead, register `hcloud` through Agentic Secrets and enter the token at the hidden prompt:

```sh
PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
"$PREFIX/bin/agentic-secrets" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-prompt
```

The token is read by the broker-owned registration command and stored in the local encrypted secret store. Do not pass token values as command-line arguments.

For clipboard or automation use, pipe the value explicitly:

```sh
pbpaste | "$PREFIX/bin/agentic-secrets" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-stdin
```

Run `hcloud` through Agentic Secrets with arguments after `--`:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud -- server list
```

Agentic Secrets prints its own diagnostics to stderr, requests local authentication before reading the secret, scrubs inherited secret-like environment variables, injects `HCLOUD_TOKEN` only into the child process, and leaves the target CLI stdout/stderr intact. Use `--quiet` before `--` when wrapping scripts:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud --quiet -- server list
```

After a successful prompt, Agentic Secrets writes a local authorization grant so repeated matching runs do not prompt every time. The default CLI authorization mode is `always`, which does not expire. `remember-24h`, `short`, and `once` are available per run. Grants store no secret value. Persistent grants are HMAC-signed with a device-local macOS Keychain key and bound to CLI name, target identity, workspace hash, config context, untrusted origin hint, provenance confidence, delivery mode, and secret alias. Short grants additionally bind action class, command digest, and risk. Each command is still policy-checked before secret delivery, and destructive commands require fresh approval.

Choose authorization mode for one run:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud --authorization-mode remember-24h -- server list
"$PREFIX/bin/agentic-secrets" cli run hcloud --authorization-mode short --delivery-grant-ttl-seconds 60 -- server list
"$PREFIX/bin/agentic-secrets" cli run hcloud --authorization-mode once -- server list
```

Legacy TTL override still selects short authorization mode:

```sh
"$PREFIX/bin/agentic-secrets" cli run hcloud --delivery-grant-ttl-seconds 0 -- server list
```

Changing target identity, workspace, config context, origin hint, provenance confidence, delivery mode, or secret alias produces a different persistent authorization scope and requires a fresh local authentication prompt. For short grants, changing action class, command shape, or risk also requires a fresh prompt.

### Optional hcloud Shim

If you want the normal `hcloud ...` command to route through Agentic Secrets, install an opt-in shim after registration:

```sh
agentic-secrets cli shim install hcloud --configure-shell
```

Open a new terminal or restart the tool runner so the shell picks up the shim PATH block, then verify command resolution. If Codex, Claude Code, or another agent app was already running during registration, restart that agent app before using `hcloud` from it.

```sh
command -v hcloud
hcloud version
```

Expected: `command -v hcloud` points under `~/Library/Application Support/AgenticSecrets/LocalInstall/shims/hcloud`.

The shim does not replace or modify the Homebrew binary. It is a symlink to the installed `agentic-secrets-shim` binary. The registered target remains the stable native CLI path, such as `/opt/homebrew/bin/hcloud`.

Normal commands are routed through the same broker-owned secret delivery path:

```sh
hcloud server list
```

Global help/version commands pass through to the registered target without resolving or injecting secrets:

```sh
hcloud --help
hcloud server --help
hcloud version
```

The pass-through environment is scrubbed of inherited secret-like variables. This keeps basic inspection commands usable while avoiding token delivery for help/version output.

Pass-through help/version reads only non-secret registry metadata and intentionally avoids the registry Keychain integrity key so it does not prompt for local authentication just to show help or version output. Commands that can receive secrets still verify registry integrity in core before any secret-store read.

### Codex App hcloud Use

Codex App may not inherit the same shell startup environment as Terminal. Avoid
putting provider tokens such as `HCLOUD_TOKEN` into `~/.codex/.env`; that would
move secret delivery back into Codex process environment. Instead, keep the token
registered in AgenticSecrets and install the per-CLI shim:

```sh
"$PREFIX/bin/agentic-secrets" cli shim install hcloud --force
```

Then verify from inside Codex App or a Codex-spawned command:

```sh
command -v hcloud
hcloud server list
```

Expected: `command -v hcloud` resolves to
`~/Library/Application Support/AgenticSecrets/LocalInstall/shims/hcloud`, and
normal commands route through Agentic Secrets secret delivery.

Remove only the shim:

```sh
agentic-secrets cli shim uninstall hcloud
```

Registration metadata and secret records remain intact until you run `agentic-secrets cli unregister hcloud --delete-secrets`.

The default explicit flow does not require a separate `hcloud` shim symlink. The registration stores metadata in Agentic Secrets state and keeps the stable invocation path discovered from `PATH`, such as `/opt/homebrew/bin/hcloud`, plus the target binary identity captured at registration time. The registry JSON is paired with `cli-registry.integrity.json`, an HMAC-SHA256 integrity sidecar whose key is stored in the user's macOS Keychain with `WhenUnlockedThisDeviceOnly` accessibility. Hand-editing either file fails closed before Agentic Secrets asks for local authentication or resolves any secret.

Each run validates the current target against the captured macOS designated requirement when available and otherwise falls back to SHA-256 identity pinning. Homebrew upgrades therefore fail closed until you verify the new binary and refresh target trust through Agentic Secrets; this does not require entering the token again, but it does require local authentication because it changes trusted CLI identity metadata:

```sh
"$PREFIX/bin/agentic-secrets" cli trust-refresh hcloud
```

If the LocalAuthentication prompt is canceled or the target changes between the prompt and the registry write, the trust refresh fails closed and the existing registration remains unchanged. A manually registered versioned Cellar path is also pinned and must be trust-refreshed or registered again after that version is removed.

To remove the registration and its local secret record:

```sh
"$PREFIX/bin/agentic-secrets" cli unregister hcloud --delete-secrets
```

## Update

Update by checking out the desired commit and running install again:

```sh
git pull --ff-only
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticSecrets/LocalInstall" --load
```

The installer replaces the app bundle, refreshes command symlinks, validates the package, and rewrites the install manifest.

## Uninstall

Open the installed app, go to **Diagnostics → Removal**, and choose **Remove Local Install** for the guided native uninstall. The dialog removes managed shell PATH entries by default. Select **Delete local Agentic Secrets state** only when you intentionally want to remove local Agentic Secrets state and local secret records.

Remove runtime surface from the command line while retaining local Agentic Secrets state:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticSecrets/LocalInstall" --keep-secrets
```

Remove runtime surface and local Agentic Secrets state:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticSecrets/LocalInstall" --purge-local-state
```

Uninstall bootouts the LaunchAgent if present, removes command symlinks, removes command shims, removes runtime files and the socket directory, removes the installed app bundle, and removes Agentic Secrets-managed PATH blocks from known shell startup files. When local state purge is selected, it also removes known Agentic Secrets Keychain integrity sidecars for that state directory. Local secret records are retained unless local state purge is explicitly requested.

## Common Pitfalls

### `tahoe_compatibility_check.sh` Fails On OS Or SDK Version

The production compatibility gate requires macOS 26.x and macOS 26 SDK or newer. Install or select a current Xcode/Command Line Tools, then rerun:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcrun --sdk macosx --show-sdk-version
```

### Quoted Prefix Paths

The default prefix contains spaces. Always quote `$PREFIX` and the default path. Unquoted commands will fail or create partial paths under `Application`.

### LocalAuthentication Prompt Does Not Appear

Make sure interactive mode is set:

```sh
AGENTIC_SECRETS_INTERACTIVE=1 ./scripts/interactive_keychain_prompt_check.sh
```

The default non-interactive run executes contract tests and intentionally does not produce a prompt.

### Prompt Cancellation Is Treated As Failure Outside The Cancellation Test

That is expected. Production secret resolution fails closed when the user cancels, denies, or the system cancels the LocalAuthentication prompt.

### Ad-Hoc Signing And Developer ID

The self-build track intentionally uses ad-hoc signing. `release-gates` should report `canRunLocal: true` and `canDistributeBinary: false` unless optional Developer ID signing and notarization are configured.

Do not add restricted entitlements such as shared Keychain access groups to the default self-build package. On Tahoe, restricted entitlements can make ad-hoc signed binaries fail before runtime.

### Gatekeeper And Quarantine

The supported path is source checkout plus local build. Do not make quarantine-removal commands or weakened macOS security settings part of the normal install flow. If a user downloads an archive instead of cloning, prefer a fresh source checkout and local build.

### LaunchAgent Is Installed But Not Running

Install with `--load`, or bootstrap the generated plist manually:

```sh
PREFIX="$HOME/Library/Application Support/AgenticSecrets/LocalInstall"
launchctl bootstrap "gui/$(id -u)" "$PREFIX/Library/LaunchAgents/com.agenticsecrets.broker.plist"
launchctl print "gui/$(id -u)/com.agenticsecrets.broker"
```

If it is already loaded, unload and load again:

```sh
launchctl bootout "gui/$(id -u)" "$PREFIX/Library/LaunchAgents/com.agenticsecrets.broker.plist"
launchctl bootstrap "gui/$(id -u)" "$PREFIX/Library/LaunchAgents/com.agenticsecrets.broker.plist"
```

### IPC Health Fails After Rebuild

Run install again from the current commit. IPC authorization binds helpers to the installed manifest, including binary hash and cdhash, so using a newly built helper against an old manifest is expected to fail.

### Permission Or Manifest Validation Fails

Use a user-owned prefix. Avoid installing under system locations such as `/Applications` or `/usr/local` for the no-Developer-ID track. The self-build validator expects helper files and parent directories to match the manifest ownership and permission model.

### No Downloadable Binary Claim

This release track is production-ready for source self-build. It is not a notarized downloadable binary release. Optional Developer ID work is tracked in `Docs/FUTURE_DEVELOPER_ID.md`.
