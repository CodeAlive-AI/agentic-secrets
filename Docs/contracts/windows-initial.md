# Windows Initial Contracts

These contracts back the Windows support plan and the ADRs in `Docs/adr/`.

## Environment Delivery

- Delivery plans are one-use.
- Delivery plans expire and expired plans fail before environment construction
  or launch.
- Delivery plans must use the environment sink while that is the only
  implemented sink.
- Every secret binding must have an explicit value in the broker-issued plan.
- The target executable identity is rehashed immediately before launch.
- The runner builds an explicit Unicode environment block.
- Ambient variables are copied only from the minimal allowlist.
- Secret-shaped ambient names are scrubbed.
- Injected secret names collide case-insensitively and fail before launch.
- Audit records include aliases, environment names, digests, policy epoch, and
  action class, not raw secret values.

Test evidence: `platform/windows/tests/env_delivery_contracts.rs`.

## IPC Authorization

- Requests include protocol version, request id, nonce, timestamp, operation,
  and typed payload.
- Unsupported protocol versions fail closed.
- Stale or replayed nonces fail closed.
- Caller user SID and expected runner executable digest must match.
- Pipe ACLs exclude broad principals such as Everyone and Anonymous.
- Runner production flow can request a plan through a broker pipe. The
  synthetic in-process broker is gated behind an explicit demo flag.

Test evidence: `platform/windows/tests/named_pipe_auth_contracts.rs`.

## Store Integrity

- Secret records are protected by a `SecretProtector`; Windows uses DPAPI
  current-user protection.
- Store files carry an HMAC integrity envelope.
- Store files are paired with a signed rollback anchor tracking the highest
  observed epoch and current store digest.
- Tampering fails before secret resolution.
- Rollback epochs fail before store write.
- Replaying an older valid store envelope fails before secret resolution.

Test evidence: `platform/windows/tests/dpapi_store_contracts.rs`.
