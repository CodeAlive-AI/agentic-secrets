# #3 — SwiftNIO / MQTTNIO reconnect ladder, backstop, and wake hook

Telemetry stops after the Mac sleeps or the broker blips, and **never resumes** until the
app is restarted. The publish gap grows monotonically (often == process uptime). Build was
green; the transport just quietly died and nothing reconnected it.

Core asymmetry [ours]: **the server reconnects, the client usually doesn't.** A Python
bridge with `loop_forever(retry_first_connection=True)` is resilient by default;
`MQTTNIO`/`SwiftNIO` is **not** — `MQTTClient` has no auto-reconnect, only a close hook.
All of the recovery machinery below is **[ours]**; the ecosystem's closest analog
(`dpearson/ios-networking`, URLSession-shaped) validates the *shape* and contributes two
polish nuggets, flagged inline.

## What MQTTNIO gives you, and what it doesn't

- The same `MQTTClient` instance **is reusable** after a drop — call `connect()` again.
- Use `cleanSession: false` so QoS-1 sessions resume.
- The only drop signal is `client.addCloseListener(named:)`. Install it **once** (idempotent)
  and route to your unexpected-close handler.

```swift
func installCloseListenerIfNeeded() {
    client.addCloseListener(named: closeListenerName) { @Sendable [weak self] _ in   // @Sendable: see #1
        Task { await self?.handleUnexpectedClose() }
    }
}
```

## The ladder: full-jitter exponential backoff

Keep the delay function **pure, `nonisolated`, and unit-testable** — it is the one piece
you can actually test without a broker.

```swift
/// Full-jitter backoff (AWS "Exponential Backoff and Jitter"): random in [0, capped 2^n].
/// Pure + `nonisolated` so a TestRunner suite can assert the bounds without a broker.
public nonisolated static func reconnectDelaySeconds(
    attempt: Int, base: Double, cap: Double
) -> Double {
    let ceiling = min(cap, base * pow(2.0, Double(max(0, attempt))))
    return Double.random(in: 0 ... max(0, ceiling))     // full jitter — not exp ± jitter
}
```

State that drives it: `reconnectAttempt`, `reconnectTask`, `intentionalDisconnect`,
`sessionEverEstablished`. Reset `reconnectAttempt = 0` on a successful connect.

**Gate intentional vs unintentional disconnects** — an explicit `disconnect()` must NOT
trigger the ladder:

```swift
func handleUnexpectedClose() async {
    guard !intentionalDisconnect else { return }
    connected = false
    scheduleReconnect()
}
```

> [mined — `dpearson/ios-networking › background-websocket.md`] confirms the same design in
> a `URLSessionWebSocketTask` actor: full-jitter, `reconnectAttempts = 0 // Reset on
> successful connection`, an `isIntentionalDisconnect` gate, and a `maxReconnectAttempts`
> ceiling. Useful nugget: it uses **two jitter fractions deliberately** — `capped * 0.25`
> at the connection level vs `capped * 0.1` for per-request retry. Invariant worth
> asserting in the NIO path too: **`CancellationError` is never retryable.**

Also recover inside `publish()` itself — a publish throw is a drop signal:

```swift
do { try await client.publish(...) }
catch { connected = false; scheduleReconnect(); throw PublishError.publishFailed }
```

## The ladder alone is not enough — add a hard-reconnect backstop [ours]

This is the non-obvious lesson. After real sleep/wake cycles the *ladder itself* can wedge
(the underlying `MQTTClient`/channel is half-dead but never emits a clean close). The fix
is a **backstop one level up** (in the coordinator that drives heartbeats): after N
consecutive failed heartbeats, **throw the publisher away and build a fresh one**.

```swift
// Coordinator
private var consecutiveSendFailures = 0
private let hardReconnectThreshold = 3
private var isHardReconnecting = false

func noteSendFailureAndMaybeRecreate() async {
    consecutiveSendFailures += 1
    guard consecutiveSendFailures >= hardReconnectThreshold, !isHardReconnecting else { return }
    isHardReconnecting = true
    await publisher?.disconnect()          // must finish() its stream — see below
    publisher = MQTTPublisher(configuration: cfg)
    try? await publisher?.connect()        // fresh client, fresh channel, fresh ELG
    isHardReconnecting = false
}
// reset consecutiveSendFailures = 0 on .connected / .publishAcked
```

Indirect validation: the overnight log showed 6.5h sleep cycles surviving once the
backstop shipped — the ladder-only build had not.

## Reconnect on wake — collapse the backoff [ours]

Observe **both** `NSWorkspace.didWakeNotification` and an IOKit power callback (belt and
braces), and on wake call `forceReconnect()` which **collapses the backoff to zero** so you
don't wait out a 60s ladder delay after the lid opens:

```swift
func forceReconnect() {                     // called from the wake observers
    reconnectTask?.cancel()
    reconnectAttempt = 0                     // collapse backoff
    scheduleReconnect(immediate: true)
}
```

See `keychain-launchd-power.md` for the wake-observer wiring and the power-assertion
options.

## AsyncStream lifecycle — finish, and cancel the source [ours + mined]

If you bridge the transport to an `AsyncStream`, **always `continuation.finish()` on
disconnect** — otherwise recreating the publisher on a hard-reconnect **leaks the NIO
`EventLoopGroup`** (a real bug, "M1", we hit).

```swift
func disconnect() async {
    intentionalDisconnect = true
    try? await client.disconnect()
    continuation.finish()                   // ← without this, ELG leaks on recreate
}
```

> [mined — `avdlee/swift-concurrency › async-sequences.md`] always `finish()`; set
> `onTermination` to cancel the backing source (e.g. cancel a `DispatchSource`); single
> consumer only; `bufferingNewest(1)` for "latest value only" telemetry.

Deferred root-cause note [ours]: `MQTTClient(eventLoopGroupProvider: .createNew)` is
deprecated and gives each publisher its own ELG — migrating to
`.shared(MultiThreadedEventLoopGroup.singleton)` both fixes the deprecation and removes the
per-publisher ELG that makes the M1 leak possible.

## Bounded shutdown [ours]

`disconnect()` can hang if the broker is unreachable. Bound it so quit/logout never stalls:

```swift
await withTaskGroup(of: Void.self) { group in
    group.addTask { await publisher?.disconnect() }
    group.addTask { try? await Task.sleep(for: .seconds(1.2)) }   // deadline
    await group.next()                                            // first to finish wins
    group.cancelAll()
}
// outer hard stop: a 1.5s semaphore timeout around the whole teardown
```

⚠️ cross-check #1: any `try? await Task.sleep` in these loops **swallows
`CancellationError`** — make sure the loop also checks `Task.isCancelled`, or the backoff
keeps running after `stop()`.

## Testing the ladder without a broker [mined — affaan/swift-protocol-di-testing]

Inject a transport behind a protocol with **configurable error properties** so tests can
script connect/publish failures deterministically:

```swift
protocol Transport: Sendable { func connect() async throws; func publish(_ d: Data) async throws }
final class MockTransport: Transport, @unchecked Sendable {
    var scriptedConnectOutcomes: [Result<Void, Error>] = []   // drive the ladder
    // pop the next outcome on each call; assert backoff/attempt/backstop behaviour
}
```

> [mined] "Design mocks with configurable error properties for testing failure paths …
> mock only boundaries, not internal types."

## Checklist

- [ ] Close listener installed once, `@Sendable`, gated on `intentionalDisconnect`.
- [ ] Full-jitter backoff, pure/testable, `attempt` reset on connect.
- [ ] `publish()` failure also schedules reconnect.
- [ ] Hard-reconnect backstop recreates the client after N failed heartbeats.
- [ ] `forceReconnect()` wired to **both** NSWorkspace and IOKit wake.
- [ ] `continuation.finish()` on every disconnect path (no ELG leak on recreate).
- [ ] Bounded shutdown; no `try?`-swallowed cancellation in the loops.
- [ ] **Live-verified across a real sleep/wake**: event log shows
      `disconnect → (hard_reconnect →) connected` and publishing resumes.
