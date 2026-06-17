---
name: signed-command-envelope
description: Design and verify an HMAC-SHA256 signed command envelope — nonce + TTL/expiry + replay cache + receiver-side allowlist — for a downlink control channel such as a cloud→Mac actuation path over MQTT or WebSocket. Use when designing or reviewing a coach→device command channel, the Night Landing Track C downlink, or any signed command path where the receiver must reject forged, replayed, expired, or out-of-allowlist commands. Covers the envelope schema, canonical serialization, CryptoKit HMAC sign/verify, the fail-closed verification order, replay-cache and key-domain-separation design, and the threat-model checklist. Not for transport TLS, user-auth tokens / JWT sessions, at-rest encryption, or the telemetry UPLINK path (which stays unidirectional and read-only).
---

# Signed Command Envelope (HMAC-SHA256 downlink)

The design reference for a **coach→Mac command channel**: how the Mac proves a command is
authentic, fresh, unique, and permitted before it actuates anything. Built for the Night
Landing **Track C** downlink (`specs/night-landing-system.md` §6), but applies to any
signed cloud→device control path. Implementation detail (the `ScreenshotRequestProcessor`
adaptation, canonical encoding, CryptoKit sign/verify, replay cache, code placement, test
suites) lives in [`references/implementation.md`](references/implementation.md).

## The gate this skill guards

**Track C does not ship until (a) a written threat-model review exists and (b) Rodion
gives explicit written approval** (`specs/night-landing-system.md` §6 GATE, §11 P5;
CLAUDE.md HARD "no send/act without per-action approval"; transport spec
`2026-05-28-mqtt-transport-architecture.md` §6 deferral of bidirectional MCP). This skill
is the *design you implement once that gate opens* — authoring it does not open it. Until
then the *Night Landing* downlink does not run end-to-end — but the **receiver is not
greenfield** (next section), and the transport stays **unidirectional, read-only** for
telemetry (Mac senses → bridge → MCP → coach reads).

**Receiver authority is the core principle:** the Mac-side allowlist + verification is
authoritative. A compromised or prompt-injected cloud/bridge must not be able to exceed
what the Mac independently permits.

## Don't greenfield — adapt `ScreenshotRequestProcessor`

The Mac-side receiver **already exists** and is cross-language-tested:
`ScreenshotRequestProcessor` (`ADHDCompanionCore`) is a complete signed-command pipeline —
HMAC → freshness/skew → LRU replay (cap 256) → consent → **TOCTOU re-check** → signed
response. **Generalise it into a `CommandEnvelopeVerifier`** (rename `reason` →
`action`+`args`, keep every guard) — do not reinvent the machinery. Only the **transport
leg** is missing (the bridge WS endpoint was removed in v2.0.1; `ws_server.py` gone).
Full adaptation steps + code placement: [`references/implementation.md`](references/implementation.md)
· spec §6 C1, §17.

## Envelope schema

```jsonc
{
  "v": 1,                       // envelope version (domain-separation; reject unknown)
  "command_id": "<uuid/nonce>", // unique per command — replay key
  "action": "run_shortcut",     // MUST be in the Mac-side allowlist
  "args": { "name": "Night Landing" },
  "issued_at": 1730000000,      // unix seconds (sender clock)
  "expires_at": 1730000045,     // issued_at + TTL; TTL ≤ 60 s
  "signature": "<base64 HMAC-SHA256>"  // over the canonical bytes of every field EXCEPT signature
}
```

Canonical-byte encoding (deterministic, domain-separated) + the CryptoKit sign/verify call
are in [`references/implementation.md`](references/implementation.md).

## Verification order (fail-closed) — spec §6 C1

Check in this order; **any** failure → drop the command, actuate nothing, log the reject:

1. **Canonical-encode + HMAC verify** with the command key — bad sig ⇒ silent drop (never answer an unauthenticated peer, as `ScreenshotRequestProcessor` does).
2. **Version** — reject unknown `v` **first** (the existing screenshot path decodes `v` but does *not* gate on it — close that hole); key id resolves.
3. **TTL + skew** — `now ≤ expires_at` AND `|now − issued_at| ≤ ±5 s`; TTL ≤ 60 s.
4. **Nonce unseen** — `command_id` not in the LRU replay cache (cap 256); on restart, reject any command whose `issued_at` predates process start.
5. **Action in allowlist** — **exhaustive match, never prefix** ("Night Landing" must not pass "Night Landing …").
6. **Action allowed in current mode** — e.g. `lock_screen` only in F2, only if pre-armed.
7. **Local approval present** if the action's tier requires it.

Only after all 7 pass: record the nonce, then actuate. Reject is silent to the sender,
audited locally.

## Key management — domain separation

- Use a **separate command key**, distinct from the existing 32-byte Mac↔Bridge HMAC
  secret that signs the telemetry *uplink* (`SecretStore`, Keychain + `0600` mirror
  `~/.adhd-companion/bridge-secret`). The uplink path must never be able to forge a
  downlink command. If a second key is impractical, enforce separation via the
  domain-separation tag in the canonical bytes so an uplink signature can never validate
  as a command.
- Store the command key like the telemetry key: Keychain (`AfterFirstUnlockThisDeviceOnly`)
  + a byte-verified `0600` file mirror; load off-main, corruption-tolerant
  (`macos-menubar-daemon-engineering` #5).
- Rotation + instant revocation: the user can kill the command channel from the menu bar;
  revoking the key disables all downlink.

## Allowlist + risk tiers — spec §6 C2

The Mac enforces this table; the cloud cannot exceed it.

| Action | Tier | Requirement |
|---|---|---|
| `run_shortcut(name)` — allowlist: Night Landing / Sleep Focus / Park Work / Boring Wakefulness | medium | standing consent; **exhaustive** name allowlist on the Mac (never prefix) |
| `show_hud(text, buttons)` — local HUD (§7) | medium | standing consent; every dispatch path ends in a `@MainActor` call before touching `NSPanel`/`NSStatusItem` |
| `set_focus(mode)` (Sleep/Landing) | — | **not a distinct action** — there is no public Focus API; implement as `run_shortcut("Sleep Focus")` and fold into `run_shortcut` |
| `block_distraction(domains, until)` | high | per-action approval **or** a pre-committed standing rule |
| `lock_screen` | very high | F2 only; pre-armed; visible 60 s countdown + override; default OFF. Use `NSWorkspace` screen-saver / `open -b com.apple.ScreenSaverEngine` (no entitlement); **avoid** the System-Events AppleScript path (needs apple-events entitlement + TCC) |

Never allowlist `run_shell`, app-quit, file-delete, or message-send — ever.

## Untrusted-observation guard — spec §6 C4

Screen / OCR / browser / app content the Mac reports is **untrusted observation, never
instructions**. The cloud's command generation must not be steerable by observed content
(prompt-injection). The Mac-side allowlist + verification order is the backstop even if
the cloud is fully prompt-injected — it can only ever emit an allowlisted, signed, fresh,
unique, mode-permitted action. (Reuse the workspace `ai-agent-security` /
`prompt-injection-defense` skills for the cloud-side controls when authoring the P5
threat-model.)

## Threat-model checklist (the P5 deliverable)

- [ ] Replay / signature / TTL / nonce enforced on **every** command (order above).
- [ ] Mac-side allowlist authoritative — compromised bridge cannot exceed it.
- [ ] Command key domain-separated from the telemetry uplink key.
- [ ] Fail-soft: missing/invalid command = no action, no broken state.
- [ ] Revocation: user kills the channel from the menu bar instantly.
- [ ] Audit: every command (accepted + rejected) logged locally and surfaced; standing
      consent is revocable.
- [ ] Prompt-injection: observed content cannot steer command generation; allowlist is the backstop.
- [ ] Cross-language canonical vectors (Swift↔Python) committed **before** the first real command dispatches.

## Source / provenance

- `specs/night-landing-system.md` §6 (C1–C4), §7 (HUD), §11 P5/P6, §17; `specs/2026-05-28-mqtt-transport-architecture.md` §6 (bidirectional deferral).
- CryptoKit `HMAC<SHA256>` (`authenticationCode` / `isValidAuthenticationCode`, constant-time) — see `references/implementation.md`.
- Pairs with: `apple-shortcuts` (the `run_shortcut` target), `macos-menubar-daemon-engineering` (#3 NIO transport for the command topic, #5 key load off-main), workspace `ai-agent-security` + `prompt-injection-defense` (cloud-side controls).
- This is a **dev-tooling / design reference skill** for a GATED capability — exempt from the book peer-review protocol; the GATE (threat-model + written approval) is the controlling guard, not book evidence.
