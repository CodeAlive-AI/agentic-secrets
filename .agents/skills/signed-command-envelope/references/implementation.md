# Signed Command Envelope — implementation detail

Companion to `../SKILL.md`. The decision-critical contract (the gate, envelope schema,
verification order, allowlist, threat-model checklist) stays in `SKILL.md`; this file is
the *how*.

## Adapt `ScreenshotRequestProcessor` (don't greenfield)

The Mac-side receiver already exists and is cross-language-tested: **`ScreenshotRequestProcessor`**
(`ADHDCompanionCore`) is a complete inbound signed-command pipeline — HMAC-verify (bad sig ⇒
silent drop) → freshness (`expires_at`) + clock-skew → LRU replay guard (`recentRequestIds`,
cap 256) → consent (concurrent-popup guard) → **TOCTOU re-check after consent, before the
action** → signed response. Its `SignedScreenshotRequest` envelope (`v`, `type`, `request_id`,
`ts`, `expires_at`, `reason`, `sig`) is structurally the command envelope.

**Generalise it into a `CommandEnvelopeVerifier`** (rename `reason` → `action`+`args`, keep
every guard) — do **not** re-implement the consent/replay/TOCTOU machinery from scratch. Only
the **transport leg** is genuinely missing: the bridge-side WS endpoint was removed in v2.0.1
(`ws_server.py` gone), so the chosen transport (the reserved `MAC_BRIDGE_WS_PORT` 8766, or an
MQTT `adhd/rodion/cmd/<device_id>` QoS-1 topic) needs the bridge publisher rebuilt.
(`specs/night-landing-system.md` §6 C1, §17.)

## Canonical serialization (deterministic)

The signature covers a **canonical** byte encoding so sender and receiver agree
bit-for-bit. Pick one and pin it:

- Fixed field order (e.g. `v\ncommand_id\naction\nargs\nissued_at\nexpires_at`), each
  value serialized deterministically (sorted JSON keys for `args`, no insignificant
  whitespace), joined by a separator that cannot appear in a value.
- Prefix with a **domain-separation tag** (e.g. `"adhd-cmd-v1\n"`) so a signature can
  never be mistaken for any other HMAC in the system (see key management in SKILL.md).
- Exclude `signature` itself from the signed bytes.
- Commit **cross-language canonical vectors** (Swift `CanonicalEncoder` vs Python
  `json.dumps(sort_keys=True, separators=(',',':'))`) before any real command dispatches —
  a mismatch silently fails *every* command.

## Sign (sender) / verify (receiver) — CryptoKit

```swift
import CryptoKit

let key = SymmetricKey(data: commandKeyBytes)   // 32-byte command key (NOT the telemetry key)

// sender (bridge):
let sig = Data(HMAC<SHA256>.authenticationCode(for: canonicalBytes, using: key))

// receiver (Mac) — constant-time compare is INSIDE isValidAuthenticationCode:
let signatureOK = HMAC<SHA256>.isValidAuthenticationCode(
    receivedSignature,            // Data decoded from envelope.signature
    authenticating: canonicalBytes,
    using: key)
guard signatureOK else { return reject(.badSignature) }
```

Never hand-roll the compare (`==` on Data leaks timing). `isValidAuthenticationCode` is
constant-time.

## Replay-cache design

- Store `command_id` → `expires_at`; evict entries once `now > expires_at`. With TTL ≤ 60 s
  the cache is tiny.
- **Restart safety:** an in-memory cache loses nonces on relaunch. Either (a) reject any
  command whose `issued_at` predates process start, or (b) persist the small nonce ring.
  Prefer (a) — simplest and sufficient given short TTLs.
- Tolerate modest clock skew on `issued_at`; reject hard on `expires_at < now`.

## Where the code lives + required tests (§17.4–17.5)

Preserve the Core / Transport / App split (`Package.swift` keeps `ADHDCompanionCore` pure):
- **`CommandEnvelopeVerifier` + the action allowlist** → `ADHDCompanionCore` (beside `HMACSigner`/`CanonicalEncoder`).
- **MQTT/WS command subscriber** → `ADHDCompanionTransport` (confines MQTTNIO).
- **`runShortcut(_:)` adapter / HUD dispatch** → `ADHDCompanion` (App target).

Required `TestRunner` suites before any real command dispatches:
- **`CommandEnvelopeVerifierSuite`** — one case per rule (bad sig, unknown `v`, expired TTL, future `issued_at`, replayed nonce incl. restart-persistence, unknown action, action-not-in-allowlist, action-forbidden-in-mode, valid round-trip).
- **`CrossLanguageCommandVectorsSuite`** — Swift↔Python canonical-parity fixtures (≥2, incl. non-ASCII `args`).
- **`ShortcutInvocationAdapterSuite`** — allowlist exhaustive-not-prefix; rejects arbitrary args.
