# AgenticFortress Installation

This is the supported production path for the no-Developer-ID release track: clone the source, build locally, package with ad-hoc signing, and install into a user-owned prefix.

AgenticFortress does not require an Apple Developer Program account for this path. It also does not require weakening macOS security settings or removing quarantine attributes as a normal step.

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

The package is written to `build/AgenticFortress.app`. By default it is ad-hoc signed with hardened runtime and the approved self-build entitlement baseline.

Validate the packaged app explicitly:

```sh
./scripts/validate_release_artifact.sh build/AgenticFortress.app
./scripts/check_entitlements_diff.sh build/AgenticFortress.app
codesign --verify --strict --deep --verbose=4 build/AgenticFortress.app
```

## Install

The default prefix is user-local and contains spaces, so keep the quotes:

```sh
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall"
```

The installer rebuilds, packages, validates, copies the app bundle, creates command symlinks, writes a LaunchAgent plist, and writes an install manifest at:

```text
$PREFIX/var/agentic-fortress/install-manifest.json
```

The manifest records helper paths, owner user IDs, permissions, versions, SHA-256 hashes, and cdhash values. Runtime IPC authorization uses that manifest instead of a Developer ID Team ID.

To add the installed commands to your current shell:

```sh
export PATH="$HOME/Library/Application Support/AgenticFortress/LocalInstall/bin:$PATH"
```

Do not put raw provider secrets into shell rc files. Configure secret aliases through reviewed product tooling, not through environment variables.

## Start The Core Daemon

Install without `--load` only writes the LaunchAgent plist. To load it immediately:

```sh
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --load
```

Inspect launchd state:

```sh
launchctl print "gui/$(id -u)/com.agenticfortress.core"
```

Runtime logs are under:

```text
$PREFIX/run/agentic-fortress/core.stdout.log
$PREFIX/run/agentic-fortress/core.stderr.log
```

## Smoke Test Installed IPC

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

## Verify LocalAuthentication Secret Prompt

Non-interactive contract check:

```sh
./scripts/interactive_keychain_prompt_check.sh
```

Interactive success path:

```sh
AGENTIC_FORTRESS_INTERACTIVE=1 ./scripts/interactive_keychain_prompt_check.sh
```

Interactive cancellation path:

```sh
AGENTIC_FORTRESS_INTERACTIVE=1 AGENTIC_FORTRESS_EXPECT_CANCEL=1 ./scripts/interactive_keychain_prompt_check.sh
```

For cancellation, press Deny or Cancel in the macOS prompt. The command passes only when core reports `userCanceled` and no secret is resolved.

The script name is kept for compatibility with older acceptance scripts, but the default self-build runtime path uses an owner-only encrypted local file store gated by LocalAuthentication. It does not require shared Keychain access groups.

## Register hcloud Without cli.toml

Do not use `hcloud context create` for the AgenticFortress flow. That official hcloud mode stores the token in `~/.config/hcloud/cli.toml`.

Instead, copy the Hetzner Cloud project token to the clipboard and register `hcloud` through AgenticFortress:

```sh
PREFIX="$HOME/Library/Application Support/AgenticFortress/LocalInstall"
pbpaste | "$PREFIX/bin/agentic-fortress" cli register hcloud \
  --env HCLOUD_TOKEN \
  --secret-stdin
```

The token is read by the core-owned registration command from stdin and stored in the local encrypted secret store. Do not pass token values as command-line arguments.

Run `hcloud` through AgenticFortress with arguments after `--`:

```sh
"$PREFIX/bin/agentic-fortress" cli run hcloud -- server list
```

AgenticFortress prints its own diagnostics to stderr, requests local authentication before reading the secret, scrubs inherited secret-like environment variables, injects `HCLOUD_TOKEN` only into the child process, and leaves the target CLI stdout/stderr intact. Use `--quiet` before `--` when wrapping scripts:

```sh
"$PREFIX/bin/agentic-fortress" cli run hcloud --quiet -- server list
```

The default flow does not create a separate `hcloud` shim symlink. The registration stores metadata in AgenticFortress state and keeps the stable invocation path discovered from `PATH`, such as `/opt/homebrew/bin/hcloud`, plus the target binary identity captured at registration time. Each run validates the current target against the captured macOS designated requirement when available and otherwise falls back to SHA-256 identity pinning. Homebrew upgrades therefore fail closed until you verify the new binary and refresh target trust; this does not require entering the token again:

```sh
"$PREFIX/bin/agentic-fortress" cli trust-refresh hcloud
```

A manually registered versioned Cellar path is also pinned and must be trust-refreshed or registered again after that version is removed.

To remove the registration and its local secret record:

```sh
"$PREFIX/bin/agentic-fortress" cli unregister hcloud --delete-secrets
```

## Update

Update by checking out the desired commit and running install again:

```sh
git pull --ff-only
./scripts/install_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --load
```

The installer replaces the app bundle, refreshes command symlinks, validates the package, and rewrites the install manifest.

## Uninstall

Remove runtime surface while retaining local AgenticFortress state:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --keep-secrets
```

Remove runtime surface and local AgenticFortress state:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --purge-local-state
```

Uninstall bootouts the LaunchAgent if present, removes command symlinks, removes runtime files, and removes the installed app bundle. Local secret records are retained unless local state purge is explicitly requested.

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
AGENTIC_FORTRESS_INTERACTIVE=1 ./scripts/interactive_keychain_prompt_check.sh
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
PREFIX="$HOME/Library/Application Support/AgenticFortress/LocalInstall"
launchctl bootstrap "gui/$(id -u)" "$PREFIX/Library/LaunchAgents/com.agenticfortress.core.plist"
launchctl print "gui/$(id -u)/com.agenticfortress.core"
```

If it is already loaded, unload and load again:

```sh
launchctl bootout "gui/$(id -u)" "$PREFIX/Library/LaunchAgents/com.agenticfortress.core.plist"
launchctl bootstrap "gui/$(id -u)" "$PREFIX/Library/LaunchAgents/com.agenticfortress.core.plist"
```

### IPC Health Fails After Rebuild

Run install again from the current commit. IPC authorization binds helpers to the installed manifest, including binary hash and cdhash, so using a newly built helper against an old manifest is expected to fail.

### Permission Or Manifest Validation Fails

Use a user-owned prefix. Avoid installing under system locations such as `/Applications` or `/usr/local` for the no-Developer-ID track. The self-build validator expects helper files and parent directories to match the manifest ownership and permission model.

### No Downloadable Binary Claim

This release track is production-ready for source self-build. It is not a notarized downloadable binary release. Optional Developer ID work is tracked in `Docs/FUTURE_DEVELOPER_ID.md`.
