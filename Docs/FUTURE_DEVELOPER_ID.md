# Future Developer ID Distribution

AgenticFortress defaults to an open-source self-build distribution model:

- users clone the repository;
- users build locally with SwiftPM;
- local packaging uses ad-hoc signing;
- no Apple Developer Program membership is required;
- Keychain secret material is owned only by `agentic-fortressd-core`;
- helpers communicate with core through local IPC and do not need shared Keychain access groups.

Developer ID signing and notarization are optional future distribution improvements for maintainers who want frictionless downloadable binaries.

## What Developer ID Adds

- Gatekeeper-friendly downloaded `.app` and `.pkg` artifacts.
- A stable public publisher identity for binary releases.
- Notarization tickets for externally distributed macOS software.
- Cleaner user onboarding for non-developer users who do not want to build from source.
- Stronger code-signing requirements based on Team ID and bundle identity instead of local build hashes only.

## What Must Change

### Release Packaging

- Produce a notarizable archive from `build/AgenticFortress.app`.
- Sign every executable, XPC service, login item, and bundle with `Developer ID Application`.
- Preserve hardened runtime across the full bundle.
- Staple notarization tickets to released artifacts.
- Add a release CI job that fails if notarization, stapling, or Gatekeeper assessment fails.

### Bundle Layout

- Move XPC services to `Contents/XPCServices`.
- Move login items or launch agents to their standard bundle locations.
- Keep CLI shims and user-facing command tools in stable install paths.
- Ensure every embedded executable has its own Info.plist, identifier, version, and entitlements.

### XPC Trust Model

- Add production designated requirements for each helper.
- Validate Team ID, bundle identifier, minimum version, hardened runtime, and debug-signing status.
- Keep local self-build mode available with pinned hash/cdhash validation when Developer ID is absent.

### Keychain Model

- Keep the default invariant: only `agentic-fortressd-core` reads Keychain secret material.
- Do not introduce shared Keychain access groups unless a future multi-app design truly requires it.
- If access groups are introduced, make them optional and Developer ID-only.
- Add interactive end-to-end tests for LocalAuthentication prompts against the signed bundle identity.

### Release Gates

- Split release readiness into two explicit tracks:
  - `canRunLocal`: self-build/ad-hoc signed local install is valid.
  - `canDistributeBinary`: Developer ID signing, notarization, stapling, and Gatekeeper assessment are valid.
- Keep binary distribution blocked when Developer ID credentials are unavailable.

## Required External State

These are intentionally not repository secrets:

- Apple Developer Program membership.
- Developer ID Application certificate in the local login keychain or CI signing environment.
- Notary credentials stored via `xcrun notarytool store-credentials`.
- CI secret store entries for signing only if maintainers choose automated binary releases.

## Non-Goals

- Requiring every contributor to have an Apple Developer account.
- Requiring Developer ID for source builds.
- Teaching users to disable Gatekeeper.
- Sharing raw Keychain secret access with helpers.
- Making notarization a prerequisite for development or contract tests.

## Suggested Implementation Order

1. Finish self-build install and local ad-hoc signing.
2. Implement production XPC bundle layout while preserving self-build mode.
3. Add local Gatekeeper-style validation where possible.
4. Add optional Developer ID variables to release scripts.
5. Add notarization and stapling only for maintainer binary releases.
6. Publish notarized artifacts as a convenience channel, not as the only supported install path.
