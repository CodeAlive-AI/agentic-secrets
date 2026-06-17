# #1 — Actor-isolation SIGTRAP at the GCD / NIO / C boundary

The single hardest bug class in this stack, and the one the community ecosystem most
actively mis-teaches.

## Symptom

- Crash-loop: the app dies seconds after launch, launchd respawns it, repeat.
- The `.ips` report (`~/Library/Logs/DiagnosticReports/<App>-*.ips`) shows
  `EXC_BREAKPOINT (SIGTRAP)` with a backtrace containing one of:
  - `_dispatch_assert_queue_fail`
  - `swift_task_checkIsolated` / `_swift_task_isCurrentExecutor`
  - `swift_task_reportUnexpectedExecutor`
- The build was **green** and unit tests **passed**. They always do — this is a runtime
  scheduling fault, not a type error.

Confirm fast:
```bash
ls -t ~/Library/Logs/DiagnosticReports/*.ips | head -1 | xargs grep -l -E 'dispatch_assert_queue|checkIsolated|isCurrentExecutor'
```

## Root cause (the boundary principle) [ours]

A closure written **inside a `@MainActor` type** is *inferred* `@MainActor`-isolated. When
you hand that closure to something that invokes it **off the main thread**, Swift's
injected main-actor assertion fires and traps:

- `DispatchSourceTimer.setEventHandler { … }` (fires on its `DispatchQueue`)
- `DispatchQueue.global().async { … }`
- SwiftNIO callbacks: `addCloseListener(named:)`, channel handlers, `EventLoopFuture`
  callbacks (fire on an `EventLoop` thread)
- C / Core Foundation callbacks (IOKit, CG, `CFRunLoop`), and `NSObject`
  notification handlers posted from a background thread

The compiler proves race-freedom *inside Swift*; the instant the closure crosses into
GCD/NIO/C the static proof ends but the runtime assertion does not. **That gap is the
crash.** This is why "Swift 6 makes data races compile errors" is dangerous framing here —
the race lives exactly where the compiler can't see.

> [mined — `charleswiltgen/axiom-ios-concurrency` › `swift-concurrency.md:44`]
> "A `@MainActor`-isolated Swift method can be called from C/ObjC/C++ on the wrong thread
> without a compile-time error — a data race at runtime."

## The fix: `@Sendable` on the boundary closure [ours + mined]

Mark the closure `@Sendable`. A `@Sendable` closure carries **no implied actor context**,
so the compiler injects **no main-actor assertion** — then hop back to the main actor
explicitly inside.

```swift
// DispatchSourceTimer heartbeat — @Sendable, hop back via Task { @MainActor }
timer.setEventHandler { @Sendable [weak self] in
    Task { @MainActor in await self?.tickHeartbeat() }
}

// SwiftNIO close-listener — @Sendable, no main-actor assumption
client.addCloseListener(named: closeListenerName) { @Sendable [weak self] _ in
    Task { await self?.handleUnexpectedClose() }
}
```

> [mined — `axiom › isolation-inheritance-diag.md:87`] "mark the closure `@Sendable`. A
> `@Sendable` closure has no implied actor context, so no runtime assertion is injected."

**Do not confuse `@Sendable` on a *closure* with `@unchecked Sendable` on a *type*:**

> [mined — `axiom › isolation-inheritance-diag.md:357`] "`@Sendable` on a closure breaks
> isolation inheritance [safely]. `@unchecked Sendable` on a type hides data races."

Capture **value copies, not `self`/`@MainActor` state**, inside the boundary closure
(copy a `Bool`/`String` into the capture list rather than reaching through `self`).

## The misuse trap: `MainActor.assumeIsolated` on an unverified executor [ours + mined]

`assumeIsolated` *asserts* "I am already on the main actor" and **crashes if not** — it is
not a way to *get* onto the main actor. Putting it inside a GCD block does not make the
block main-isolated; it just relocates the same crash.

```swift
// ❌ WRONG — this was a real regression. The GCD block runs off-main;
//    assumeIsolated then traps exactly like the bug it was meant to fix.
DispatchQueue.main.async { MainActor.assumeIsolated { self.delegate?.handle(event) } }

// ✅ RIGHT — a Task hop is verified; no assumption, no trap.
Task { @MainActor [weak self] in
    guard let self else { return }
    self.delegate?.handle(event)
}
```

> [mined — `avdlee/swift-concurrency › actors.md`] "Use [`assumeIsolated`] sparingly —
> assumes you're on main thread, crashes if not … Avoid `assumeIsolated`; prefer explicit
> isolation."

**Defensive converse** [mined — axiom]: at a *C/ObjC→Swift* boundary you do not control
(a C library that may call you on any thread), `assumeIsolated` (or `dispatchPrecondition(condition: .onQueue(.main))`)
is the *correct* tool — you *want* a loud crash on the wrong thread rather than a silent
race. Use it to **assert** a guarantee you can't express in types, not to fake one.

## `Task.detached` silently severs trace context [mined — axiom]

> [mined — `axiom › isolation-inheritance-diag.md:211`] "`Task.detached` … drops
> everything the originating task carried: no priority inheritance and no task-local
> values, which silently severs trace IDs, logging metadata… Crashes vanish; observability
> quietly does too."

Prefer `Task { @concurrent in … }` (Swift 6.2+) or a plain `Task {}` that inherits
context. Reserve `Task.detached` for genuinely context-free work and know you are losing
`@TaskLocal` correlation (relevant if your event log relies on task-local trace IDs).

## `try?` around `await` swallows `CancellationError` [mined — avdlee] → see #3

> [mined — `avdlee/swift-concurrency › memory-management.md`] "`try?` can swallow
> `CancellationError`, causing the loop to continue running after cancellation. Always
> check `Task.isCancelled` explicitly."

A `try? await Task.sleep(...)` inside a backoff/heartbeat loop will **not** stop when the
owning `Task` is cancelled (e.g. during `stop()` or a hard-reconnect recreate) — you get a
zombie loop. Either propagate (`try await`) or check `Task.isCancelled` after the sleep.
This is the same class as #3's reconnect ladder; see `nio-reconnect.md`.

## Escape hatch for protocol-witness isolation mismatch [mined — axiom]

When an AppKit/delegate protocol conformance crosses into the main actor:

> [mined — `axiom › isolation-inheritance-diag.md:274`] "Isolated conformance:
> `extension T: @MainActor P` (SE-0470) … the requirement is satisfied without
> `nonisolated` or a trap."

Cleaner than `assumeIsolated` inside every witness when an `@Observable`/delegate type
conforms to an AppKit protocol whose methods are called on the main thread.

## Checklist before declaring a concurrency fix done

- [ ] Every closure handed to GCD/NIO/C/notification is `@Sendable` **or** provably runs
      on the main thread.
- [ ] No `assumeIsolated` inside a `DispatchQueue.*.async` / off-main block.
- [ ] No `try? await` in a loop that must stop on cancellation (#3 cross-check).
- [ ] No `Task.detached` that silently drops trace/log context.
- [ ] **Verified on the running binary:** relaunch, watch the event log + crash-report dir
      for ≥1 full heartbeat/reconnect cycle. A clean `swift build` is not evidence.
- [ ] Triage aid [mined — axiom]: `.ips` with `_swift_task_isCurrentExecutor` ⇒ this class.

## Why the ecosystem doesn't cover this

`avdlee/swift-concurrency`, `dimillian/swift-concurrency-expert`, `dpearson`,
`affaan/swift-concurrency-6-2`, `jamesrochabrun` all teach actor/Sendable *theory* and
steer **away** from the GCD/NIO/C interop surface ("never use `DispatchQueue`"). None name
the runtime trap. Only `charleswiltgen/axiom-ios-concurrency` does — mined above. The rest
is **[ours]**.
