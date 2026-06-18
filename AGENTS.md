# AgenticFortress Agent Notes

This file is for coding agents and maintainers working in this repository. Keep user-facing onboarding short in `README.md`; put implementation, verification, and release workflow details here or in `Docs/`.

`AGENTS.md` is the source of truth for agent instructions. `CLAUDE.md` should remain a symlink to this file, not a separate copy.

Current release metadata: `0.1.0 alpha`. This is a pre-stable product; breaking changes to local install state, registry format, CLI UX, and trust policy are acceptable when they improve security or clarity.

## Product Boundary

AgenticFortress is a macOS lower-leakage secret delivery system for developer machines.

It does not make execution safe. It makes delivery of secrets explicit, narrow, approved, bounded, auditable, and lower-leakage than `.env`, shell environment, MCP configs, or plaintext provider tokens.

The default distribution model is open-source self-build with local ad-hoc signing. Downloadable Developer ID-signed and notarized binaries are optional future maintainer work, not a requirement for contributors or local use.

## Native macOS UI And UX

When working on the native macOS UI, agents must actively think about good UX, not only whether the Swift code compiles. Follow current Apple Human Interface Guidelines and keep the app boring, clear, auditable, and native.

Required Apple references for UI work:

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
- [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
- [Apple Design Resources](https://developer.apple.com/design/resources/)

UI changes must preserve native macOS expectations:

- Keep sidebar navigation stable, scannable, and selection-driven.
- Keep toolbar actions contextual to the current page.
- Keep menu bar commands and MenuBarExtra actions synchronized with the same app state and disabled states as visible UI controls.
- Keep one clear best next action in each empty, error, repair, and onboarding state.
- Use sheets for focused tasks that can complete before returning to the parent window; split complex security workflows into short steps.
- Prefer inline, non-blocking feedback for routine success/error states; reserve alerts for blocking, destructive, or system-level failures.
- Add explicit accessibility labels/help for icon-heavy controls, external links, toolbar items, and security-sensitive actions.
- After UI changes, inspect every page in the running app, not only `swift build`.

## Implemented Delivery Contracts

- Signed shim model through one `agentic-fortress-shim` binary and symlink-style invocation.
- CLI env delivery with signed/versioned dynamic command adapter packs and deterministic decision manifests.
- Local API proxy profiles with per-session localhost capability tokens.
- BWS provider split where runtime fetch is one approved secret per invocation.
- Remote MCP bridge contracts with pinned upstream profile and session propagation.
- Rollback detection that locks policy use and clears remembered leases.
- Structured audit with redaction gates.
- Release gate checklist backed by executable contract tests.

Adapter packs are dynamic but not trust-by-configuration. External packs must verify under a trusted P-256 signing key, publisher allowlist, CLI allowlist, schema version, expiry, rule validation, and rollback checks before registration. Lease scope includes adapter identity, version, and hash.

Runtime policy is configurable through `AgenticFortressConfig`; the default JSON lives at `config/default.agentic-fortress.json`. Configuration covers adapter trust, delivery defaults, proxy profiles, MCP profiles, and macOS compatibility gates.

## Build And Verify

Run the standard gates before presenting a production-ready change:

```sh
swift build
swift run agentic-fortress-contract-tests
./script/ui_smoke.sh
./script/build_and_run.sh --verify
./scripts/ci.sh
./scripts/tahoe_compatibility_check.sh
./scripts/check_secret_authority.sh
```

Use `git diff --check` before finalizing edits.

## Package And Install

Package manually:

```sh
./scripts/package_release.sh
./scripts/validate_release_artifact.sh build/AgenticFortress.app
./scripts/check_entitlements_diff.sh build/AgenticFortress.app
codesign --verify --strict --deep --verbose=4 build/AgenticFortress.app
```

Recommended local install:

```sh
./scripts/install_local.sh --load --configure-shell
```

Native guided install:

```sh
./scripts/package_release.sh
open build/AgenticFortress.app
```

Then use **Diagnostics → Install Local Daemon** or **Diagnostics → Repair Local Daemon**. The app shows the app copy, helper symlinks, state directory, run directory, install manifest, LaunchAgent, and socket path before writing files. It does not read or move local secret material. If the app was launched from `build/`, open the installed copy after installation so authenticated IPC matches the installed bundle path in the manifest.

Uninstall while keeping local secret state:

```sh
./scripts/uninstall_local.sh --prefix "$HOME/Library/Application Support/AgenticFortress/LocalInstall" --keep-secrets
```

The local installer writes an install manifest with helper paths, owners, permissions, versions, SHA-256 hashes, and cdhash values. Runtime IPC authorization uses that manifest instead of requiring a Developer ID Team ID.

The core daemon serves the local control plane over a Unix domain socket. Helpers authenticate to core with the install manifest and do not read local secret material directly.

On macOS Tahoe, the self-build track avoids restricted entitlements so ad-hoc signed binaries can execute normally. The core daemon stores local secret material in an owner-only encrypted file store gated by LocalAuthentication; no shared Keychain access group is required for the self-build track. Registered CLI trust metadata is protected by a device-local macOS Keychain integrity key so hand-edited registry files fail closed before any secret is resolved.

CLI runs may reuse scoped authorization grants after successful LocalAuthentication. The default mode is `always`; `remember-24h`, `short`, and `once` are available per run. Persistent grants are signed with a device-local macOS Keychain key and scoped to CLI name, target identity, workspace hash, config context, untrusted origin hint, provenance confidence, delivery mode, and secret alias. Short grants additionally include action class, command digest, and risk. Command policy is re-evaluated before every secret delivery, and destructive commands require fresh approval. Grants must never contain secret values.

## Release Evidence

```sh
swift run agentic-fortress release-gates
swift run agentic-fortress ipc-conformance
./scripts/check_secret_authority.sh
./scripts/check_entitlements_diff.sh build/AgenticFortress.app
./scripts/create_release_evidence.sh
```

`release-gates` reports `canRunLocal` separately from optional `canDistributeBinary`.

Optional future maintainer distribution signing and notarization:

```sh
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARYTOOL_PROFILE="agentic-fortress-notary" \
./scripts/sign_notarize_release.sh
```

The notarization script requires credentials to be stored in the macOS keychain via `xcrun notarytool store-credentials`; it never reads or prints credential values.

## Secret Handling

Never read, print, summarize, or search for real secret values in `.env`, shell rc files, keychains, cloud credential files, SSH keys, or vaults.

Do not run broad secret-discovery commands. For smoke tests, use synthetic placeholder values only, pass them through stdin, and avoid logging token-shaped strings.

Do not put provider tokens into shell startup files. Shell configuration may contain PATH only.

## Primary Docs

- `Docs/INSTALLATION.md`
- `Docs/OPERATIONS.md`
- `Docs/ACCEPTANCE_CRITERIA.md`
- `Docs/THREAT_MODEL.md`
- `Docs/IMPLEMENTATION_MAP.md`
- `Docs/IMPLEMENTATION_PLAN.md`
- `Docs/FUTURE_DEVELOPER_ID.md`
- `Docs/THIRD_PARTY_NOTICES.md`
