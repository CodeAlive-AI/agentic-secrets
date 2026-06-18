# Future EndpointSecurity Provenance Track

AgenticFortress does not require EndpointSecurity for the default local self-build release track. EndpointSecurity is a possible future provenance enhancement for maintainers who want stronger process-origin evidence than terminal environment hints or best-effort process-tree inspection can provide.

The default product boundary remains unchanged: AgenticFortress is a lower-leakage secret delivery system, not a general endpoint monitoring agent.

## What EndpointSecurity Adds

- Kernel-delivered process execution events with stable process identity data.
- `audit_token`, `parent_audit_token`, and `responsible_audit_token` for correlating a CLI invocation with the process that launched or is responsible for it.
- Code-signing metadata for observed processes, including cdhash, signing identifier, team identifier, validation category, executable path, TTY, and start time.
- Better provenance for prompts, audit events, and unlock-grant scoping when a terminal, editor, automation tool, or agent launches a registered CLI.
- A path to distinguish the terminal host from the responsible app when macOS reports one.

## Why It Is Not The Default

EndpointSecurity conflicts with the current default release model:

- The self-build track intentionally uses local ad-hoc signing and avoids restricted entitlements.
- EndpointSecurity clients require `com.apple.developer.endpoint-security.client`, which is a restricted Apple entitlement and cannot be made available to every source-build user by adding it to the repository entitlements file.
- EndpointSecurity clients must be approved by the user through TCC as Full Disk Access.
- EndpointSecurity clients must run with elevated privileges; `es_new_client` can fail with `ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED`.
- Shipping an EndpointSecurity client changes AgenticFortress from a user-local secret-delivery tool into a privileged endpoint-observation component with a larger privacy and reliability surface.

## Required External State

These are intentionally not repository secrets:

- Apple Developer Program membership.
- Apple approval for the EndpointSecurity entitlement.
- Developer ID signing material for the EndpointSecurity component.
- User approval in System Settings for Full Disk Access, or MDM/PPPC configuration in managed environments.
- A privileged installation path, likely a root LaunchDaemon or system-extension style layout.

## Proposed Architecture

EndpointSecurity should be isolated in a separate component:

- `agentic-fortress-esd` observes process provenance only.
- It never reads, stores, receives, or resolves secret values.
- It runs as a privileged observer with the EndpointSecurity entitlement.
- It subscribes to the minimum process events needed to correlate registered CLI executions.
- It mutes or ignores AgenticFortress-owned helper activity to avoid feedback loops.
- It writes short-lived provenance assertions to core over authenticated local IPC.
- Core treats those assertions as confidence evidence for prompts, audit, and grant scoping, not as a standalone permission to deliver secrets.

Suggested assertion fields:

- observed process audit token digest;
- observed process executable path, cdhash, signing identifier, team identifier, and start time;
- parent process audit token digest and identity summary;
- responsible process audit token digest and identity summary when available;
- TTY identifier when present;
- registered CLI name and resolved target path when correlation is possible;
- assertion creation time and expiry;
- esd signing identity and assertion signature or MAC.

## Trust Model

- Core must authenticate `agentic-fortress-esd` as a separate trusted peer.
- The assertion must be bound to a specific invocation, not just to a CLI name.
- Assertions must expire quickly and must be replay-protected.
- If EndpointSecurity is unavailable, core must fail back to the non-EndpointSecurity policy instead of weakening delivery rules.
- EndpointSecurity provenance may reduce prompt frequency, but it must not bypass fresh approval for destructive or policy-changing operations.

## Privacy And Reliability Constraints

- Do not log raw command arguments unless they already pass AgenticFortress command redaction rules.
- Do not log unrelated process activity.
- Do not subscribe to broad AUTH events unless the product explicitly needs enforcement; prefer NOTIFY-style provenance collection.
- Keep event handling non-blocking and minimal.
- Treat dropped events, delayed assertions, TCC denial, or entitlement denial as reduced confidence, not as a fatal product failure.

## Required Product Changes

### Packaging

- Add a separate EndpointSecurity build target and install layout.
- Add dedicated entitlements for the EndpointSecurity component only.
- Keep default `packaging/AgenticFortress.entitlements` restricted-entitlement-free.
- Add Developer ID-only or enterprise-only package validation for `agentic-fortress-esd`.
- Document Full Disk Access setup and failure states.

### IPC

- Add a typed provenance assertion message.
- Authenticate `agentic-fortress-esd` independently from app, CLI, and shim helpers.
- Bind assertions to invocation handles or process audit-token digests.
- Reject stale, replayed, malformed, or cross-invocation assertions.

### Policy

- Add a provenance confidence level to decision manifests:
  - `none`;
  - `environmentHint`;
  - `processTree`;
  - `socketPeer`;
  - `xpcPeer`;
  - `endpointSecurity`.
- Allow policy to require higher provenance confidence for specific secrets, environments, or command classes.
- Keep destructive commands fresh-auth by default; unknown non-destructive commands may reuse authorization only under the same scoped policy gates as other non-destructive commands.

### UI And Operations

- Show EndpointSecurity availability as optional hardening, not as required setup.
- Show whether Full Disk Access is missing, the entitlement is unavailable, or the daemon is not running.
- Provide a one-click path to the Full Disk Access settings pane when possible.
- Explain that EndpointSecurity observes local process provenance and does not read secrets.

## Release Gates

Add a separate optional report section:

- `canRunLocal`: unchanged self-build/ad-hoc path.
- `canDistributeBinary`: Developer ID and notarization path.
- `canUseEndpointSecurity`: entitlement, signing, privilege, TCC, daemon health, and assertion conformance are valid.

EndpointSecurity failure must not make `canRunLocal` false.

## Non-Goals

- Requiring EndpointSecurity for normal local development.
- Requiring Full Disk Access for users who only want the self-build secret-delivery track.
- Using EndpointSecurity as a generic EDR product.
- Letting EndpointSecurity authorize secret delivery by itself.
- Logging complete system process activity.

## Suggested Implementation Order

1. Implement verified invocation context without EndpointSecurity first: action-bound unlock scopes, socket peer validation, and XPC peer requirements where available.
2. Add a provenance confidence field to decision manifests and audit events.
3. Design the `agentic-fortress-esd` assertion schema and replay protection.
4. Prototype EndpointSecurity in a disabled-by-default target.
5. Add Developer ID and entitlement-specific packaging checks.
6. Add Full Disk Access diagnostics and user-facing setup guidance.
7. Enable EndpointSecurity only as an optional hardening track after self-build and Developer ID tracks remain green.
