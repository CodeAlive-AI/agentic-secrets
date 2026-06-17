# #7 — Live diagnosis of a headless LSUIElement daemon

The meta-skill behind all the others: **a green build proves nothing.** Bugs #1–#6 are
invisible to `swift build` and to unit tests; you find them by interrogating the **running
process**. No community skill covers host-process post-mortem for a headless daemon — they
cover iOS-simulator UI automation or CPU profiling. The hang/crash techniques here are
**[ours]**; CPU-profiling and re-render tooling are **[mined]** and flagged.

## Build your own black box first [ours]

Before any external tool, the app should keep an **append-only event log** (with rotation)
that records the startup chain and liveness. It is the authoritative record and the first
thing to read:

```
app_launch → coordinator_start → mqtt_connected → publish(seq=…) … mqtt_disconnect → reconnect → mqtt_connected
```
Log `rss_mb` (resident memory via `task_info`) on each heartbeat. The publish-gap and the
last event tell you *which stage* failed: no `coordinator_start` ⇒ startup freeze (#5);
`mqtt_disconnect` with no following `connected` ⇒ reconnect failure (#3); growing `rss_mb`
⇒ a leak (e.g. ELG, #3).

## Symptom → tool

### "It's hung / frozen" (no crash, just stopped)
```bash
pgrep -lf ADHDCompanion           # confirm a single instance + pid
sample <pid> 3                    # 3-second statistical backtrace of every thread
```
Read the **main thread**: if it's parked in `mach_msg` under `SecItemCopyMatching` →
Keychain ACL freeze (#5); under a `Data(contentsOf:)`/file read → blocking startup I/O;
under a lock/semaphore `.wait()` → a deadlock. This single command found the #5 freeze.

> [mined — `avdlee/swiftui-expert`] blocked-vs-CPU heuristic: a thread's
> `main_running_coverage_pct` **< 25% ⇒ blocked** (I/O, lock, sync XPC, `Task.sleep`,
> waiting on an actor); **≥ 75% ⇒ CPU-bound**.

### "It crashed / crash-loops"
```bash
ls -t ~/Library/Logs/DiagnosticReports/*.ips | head        # newest crash reports
grep -E 'EXC_BREAKPOINT|dispatch_assert|checkIsolated|isCurrentExecutor' <report>.ips
```
A SIGTRAP with `dispatch_assert_queue_fail`/`checkIsolated` ⇒ concurrency boundary (#1).
If the backtrace has **raw addresses** (unsymbolicated, e.g. a stripped release binary),
symbolicate against the *running* slide:

> [mined — `patrickserrano/native-app-profiling`] ASLR-aware offline symbolication:
> ```bash
> vmmap <pid> | grep '__TEXT'                      # runtime __TEXT load address (changes each launch)
> atos -o <App>.app/Contents/MacOS/<exe> -l <load-addr> <raw-addr>
> ```
> The `__TEXT` slide changes every launch — always read it from `vmmap`, never assume.

### "It's silent" (running, but no telemetry)
Tail your event log for the last publish; check uptime vs last-publish gap; confirm a
single instance (a second copy double-publishing or fighting for the port is its own bug).
A tiny watchdog ("no publish since `kern.boottime` + autostart loaded ⇒ alert") catches the
silent-death case the app itself can't report.

### "UI re-renders constantly / janky popover"
Find *why* a view re-renders, then *who* invalidates it:
```swift
let _ = Self._printChanges()   // [mined — dimillian/swiftui-performance-audit] debug-only; dumps what changed
```
> [mined — `avdlee/swiftui-expert` trace harness] `xctrace` record + `analyze_trace.py
> --fanin-for "<View>"` answers "who keeps invalidating this view?" and names invalidation
> storms (e.g. an `@AppStorage`/`UserDefaults` feedback loop). Long-View-Body thresholds:
> **orange > 500µs, red > 1000µs.** Supports host-Mac capture with a stop-file
> (`touch /tmp/stop-trace`).

> [mined — dimillian/swiftui-performance-audit] **triage order:** 1) broad
> invalidation / observation fan-out → 2) unstable identity / list churn → 3) main-thread
> render work → 4) image decode → 5) layout/animation. Guardrails: *"`@State` is not a
> cache"*; do **not** apply `.equatable()` as a blanket fix. (For the menu-bar app the
> usual culprit is #1 here — too-broad `@Published` reads; narrow the observed surface.)

### Headless CPU profile (no Instruments GUI) [mined — patrickserrano]
```bash
xcrun xctrace record --template 'Time Profiler' --attach <pid> --output run.trace
xcrun xctrace export --input run.trace --toc       # then XPath into the time-profile table
```

## The verification gate (run after EVERY fix to #1–#6)

1. `swift build` green — necessary, **not** sufficient.
2. Rebuild the `.app`, relaunch the real bundle (not `swift run` — signing/bundle/LSUIElement
   only exist in the bundle).
3. Watch the event log for ≥1 full cycle (startup chain + a heartbeat + ideally a
   reconnect). `tail -f` it.
4. `sample <pid>` once while idle — main thread should be parked in the run loop, not in I/O.
5. Check `~/Library/Logs/DiagnosticReports/` — **no new `.ips`** since relaunch.
6. For #4/#5: `codesign -dv` + `pmset -g assertions` + Keychain prompt did **not** appear.

Only after 2–6 is a fix "done." During this project, five "fixed" claims were overturned at
step 2–5; treat that as the expected hit rate, not bad luck.

## Checklist
- [ ] App keeps an append-only event log with the startup chain + `rss_mb`; read it first.
- [ ] Hang → `sample <pid>`; crash → `.ips` grep; silent → event log + watchdog.
- [ ] Raw addresses symbolicated via `vmmap __TEXT` + `atos -l`.
- [ ] Re-render storms found with `_printChanges()` / `xctrace --fanin-for`.
- [ ] Every #1–#6 fix passed the 6-step verification gate on the **running bundle**.
