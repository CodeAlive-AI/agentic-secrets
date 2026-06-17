---
name: macos-menubar-daemon-engineering
description: Engineer, debug, package, and harden native macOS menu-bar / background-daemon apps built with Swift 6, SwiftUI MenuBarExtra, and SwiftPM (no Xcode project), running as an LSUIElement agent. Focuses on the runtime-only bug classes that a green `swift build` and passing unit tests do NOT catch — actor-isolation SIGTRAP at GCD/NIO/C callback boundaries, MenuBarExtra observation staleness, SwiftNIO/MQTT reconnect ladders, SwiftPM-to-.app bundling with stable code signing and notarization, launchd LaunchAgents, Keychain main-thread ACL freezes, IOKit power assertions, and live diagnosis with sample/.ips/Console. Use when building, debugging, signing, packaging, or hardening a macOS menu-bar app or headless agent, or when a Swift macOS app builds clean but misbehaves only at runtime. Not for general iOS development, Xcode-project (xcodebuild) builds, pure Swift-language or SwiftUI-layout questions, or app-side business logic — use a general Swift/SwiftUI skill for those.
---

# macOS Menu-Bar Daemon Engineering

Hard-won runtime engineering for native macOS menu-bar and background-daemon apps:
**Swift 6 · SwiftUI `MenuBarExtra` · SwiftPM-built (no `.xcodeproj`) · `LSUIElement`**.

## The one rule this skill exists to enforce

**A green `swift build` and passing unit tests prove almost nothing for this class of app.**
Every bug class below survives compilation and the test suite and surfaces only on the
running system — as a crash-loop, an invisible freeze, a stale menu, or telemetry that
silently stops. After any change to concurrency, observation, networking, signing, or
startup, **verify on the running binary** — `events.log` / your own event log, `sample <pid>`,
`.ips` crash reports, `Console.app`, `pmset -g assertions`, `codesign -dv` — not in the
build log. During this project's development, five separate "fixed" claims were overturned
by live verification; that is the norm, not the exception, for these seven classes.

This is **not** a general Swift/SwiftUI guide. The community ecosystem covers Swift-6
concurrency theory, the SwiftUI observation model, SPM packaging, and Instruments
profiling well (see Provenance). This skill covers the **AppKit-systems-integration layer
the ecosystem is blind to**, where these seven runtime bug classes actually live.

## Bug-class router

| # | Symptom on the running system | Root layer | Reference |
|---|---|---|---|
| 1 | Crash-loop; `EXC_BREAKPOINT`/SIGTRAP; `_dispatch_assert_queue_fail` or `swift_task_checkIsolated` in the `.ips` | A closure inferred `@MainActor` handed to GCD/SwiftNIO/a C callback, fired off-main | `references/concurrency-sigtrap.md` |
| 2 | Menu bar shows stale text ("Starting up…") forever; UI never reflects live state | `MenuBarExtra` `.menu` style, or observation dependency never established | `references/menubar-observation.md` |
| 3 | Telemetry stops after sleep / a broker blip and never resumes | SwiftNIO/MQTTNIO has no auto-reconnect; needs a ladder + hard-reconnect backstop + wake hook | `references/nio-reconnect.md` |
| 4 | App won't launch on double-click; Gatekeeper blocks it; re-sign/Keychain prompts every rebuild | SwiftPM→.app bundle + ad-hoc signing cdhash churn + notarization | `references/packaging-signing.md` |
| 5 / 6 | Invisible launch freeze; or the app blocks system sleep / dies on wake | Keychain main-thread ACL prompt; launchd lifecycle; IOKit power assertion | `references/keychain-launchd-power.md` |
| 7 | "It's hung / silent, but the build was green" — need to see what a live process is doing | `sample`/`.ips`/`vmmap`+`atos`/Console for a headless `LSUIElement` process | `references/live-debug.md` |

## Cross-cutting principles

1. **The boundary is where isolation guarantees end.** The Swift 6 compiler proves
   data-race freedom *inside* Swift. The moment a closure crosses into GCD, SwiftNIO, a
   C callback, or an `NSObject` notification, the compiler's static proof stops — but the
   `@MainActor` *runtime assertion* it injected does **not**. That assertion firing
   off-main is the SIGTRAP. Mark such closures `@Sendable` (a `@Sendable` closure carries
   no implied actor context, so no assertion is injected) and capture value copies, not
   `self`. The community's "the compiler catches your races" framing is precisely the
   false confidence that ships this crash. (#1)
2. **Reading `@Published`/`@Observable` state does not, by itself, establish a SwiftUI
   dependency.** A dependency is established only when the read happens *through a tracked
   graph node* — a `@StateObject`/`@State`-owned model in a `.window`-style scene. State
   read off an `@NSApplicationDelegateAdaptor` object, or inside a `.menu`-style
   `MenuBarExtra` (whose `NSMenu` is built once and never re-rendered), is invisible to
   SwiftUI → permanently stale UI. (#2)
3. **Anything the daemon needs at launch must be non-blocking and corruption-tolerant.**
   A synchronous Keychain read, a `Data(contentsOf:)`, or a sync disk read in an
   actor/type `init` on the main thread is a latent *invisible* freeze for an
   `LSUIElement` app — no Dock icon, no window, the user just sees nothing. Prefer a
   byte-verified file mirror; reseed on corruption; never block the main thread on a
   modal prompt. (#5)
4. **External resilience is asymmetric — the client is the weak side.** Servers/bridges
   usually reconnect; the Mac client usually doesn't. Build the ladder (full-jitter
   exponential backoff), a hard-reconnect backstop (recreate the client after N failed
   heartbeats), and a `forceReconnect()` on wake. (#3)
5. **Stable identity beats ad-hoc.** Ad-hoc signing (`--sign -`) changes the cdhash on
   every rebuild, which re-triggers Keychain ACL prompts and Gatekeeper friction. A
   stable self-signed dev identity gives a stable cdhash → the Keychain keeps trusting the
   binary across rebuilds. (#4, and it removes the most common trigger of #5)

## First moves on any task

- **Building / packaging:** read `references/packaging-signing.md`; the installed
  `macos-spm-app-packaging` skill (dimillian) ships runnable bundler/notarizer templates —
  use those, don't re-derive them.
- **A crash-loop:** pull the newest `.ips` from `~/Library/Logs/DiagnosticReports/`, grep
  for `dispatch_assert` / `checkIsolated` / `EXC_BREAKPOINT` → `concurrency-sigtrap.md`.
- **A hang / freeze:** `sample <pid> 5` while it is stuck → `live-debug.md`.
- **Stale UI:** confirm the `MenuBarExtra` style and where the model is *owned* →
  `menubar-observation.md`.
- **Telemetry stopped:** check the event log for the last publish, then look for a
  reconnect ladder + wake hook → `nio-reconnect.md`.

## Provenance — why this skill is bespoke

A 25-skill deep review of the community Swift/macOS skill ecosystem (2026-06) found it
strong on four axes and blind on ours:

- **Covered well (use these directly):** SPM packaging + signing + notarization
  (`dimillian/macos-spm-app-packaging` — **installed alongside this skill**); Swift-6
  concurrency *theory* (`avdlee/swift-concurrency`); the SwiftUI observation model
  (`avdlee/swiftui-expert`); Instruments profiling (`avdlee/swiftui-expert` `xctrace`
  trace harness).
- **The only skill that names our #1 crash:** `charleswiltgen/axiom-ios-concurrency`
  (`isolation-inheritance-diag.md`).
- **Not covered by anyone (our net-new):** #2 MenuBarExtra observation staleness, #3
  NIO/MQTT reconnect ladder with backstop + wake, #4 launchd, #5 Keychain main-thread ACL
  freeze, #6 IOKit power, #7 `sample`/`.ips` for a headless daemon. Several concurrency
  skills actively mislead on #1 ("the compiler catches races", "never use GCD").

Each reference file tags content **[mined]** (extracted from a named community skill, with
attribution) vs **[ours]** (hard-won from production; not present in any reviewed skill).
