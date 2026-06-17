# #5 / #6 — Keychain ACL freeze · launchd LaunchAgent · IOKit power

Three daemon-runtime concerns the community ecosystem does not cover at all. All **[ours]**.

---

## #5 — Keychain `SecItemCopyMatching` main-thread ACL freeze

### Symptom
The app launches and **freezes invisibly** — no Dock icon (it's `LSUIElement`), no window,
the menu stays on "Starting up…", **zero telemetry**, and the publish gap == process
uptime. No crash, no log line past startup.

### Diagnosis (this is the technique that found it) [ours] → see live-debug.md
```bash
sample <pid> 3        # while it's frozen
```
The main thread is 100% blocked in:
```
attemptStartup() → SecretStore.loadWithSource() → loadFromKeychain()
  → SecItemCopyMatching → mach_msg   (blocked on a modal SecurityAgent prompt)
```

### Root cause
`SecItemCopyMatching` **blocks synchronously** on a modal "Allow access" prompt when the
calling binary's cdhash is not on the Keychain item's ACL. After an **ad-hoc rebuild the
cdhash changes every time** (see #4), so every launch re-prompts. For a foreground app you
*see* the prompt; for an `LSUIElement` agent the prompt has nowhere to show → the main
thread hangs forever.

### Fix: prefer a byte-verified file mirror; Keychain only as fallback
Keep a `0600` mirror of the secret and read **that** first (a plain, fast, non-blocking
file read), falling back to the Keychain only if the mirror is absent:

```swift
public static func loadWithSource() throws -> (secret: Data, source: Source) {
    if let url = AppPaths.secretOverridePath { /* env override (dev) */ … }
    // file mirror — non-blocking, no ACL prompt
    let mirror = AppPaths.secretMirrorPath           // ~/.<app>/bridge-secret, chmod 600
    if let data = try? Data(contentsOf: mirror), data.count == 32 {
        return (data, .fileMirror)
    }
    return (try loadFromKeychain(), .keychain)       // fallback only
}
```

- Verify the mirror **byte-for-byte** against the Keychain value when you write it
  (`sha256`), so the mirror is never a stale/divergent secret.
- Store the Keychain item `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Treat ACL/`errSecInteractionNotAllowed`/`errSecAuthFailed` as **transient** and
  self-heal with a bounded retry (e.g. 30s interval, ~20 attempts) rather than crashing —
  the secret exists, it's momentarily unreadable (e.g. before first unlock).

### ⚠️ Known residual / open follow-up [ours]
**Scaffolded ≠ wired — verify the fix is actually in the executed load path.** In this
codebase the mirror was *documented* (`AppPaths.secretMirrorPath`), *scaffolded* (`pair.py`
writes `bridge-secret`; a `Source.fileMirror` enum case exists), and believed "fixed" — but
an audit found `SecretStore.loadWithSource()` checks only the env override and then falls
straight through to `loadFromKeychain()`; **it never reads the mirror.** So the synchronous
main-thread `SecItemCopyMatching` is still the *default* path, re-arming the freeze after
every ad-hoc rebuild (new cdhash → ACL distrust). This is itself the lesson of #7: a fix
that exists in comments and enum cases but **not in the executed code** is invisible to a
green build — only reading the real `loadWithSource()` body (or a `sample` of the frozen
process) reveals it. Open fixes, in order: **(1)** wire the mirror read in
(32-byte/0600-verified, *before* the Keychain fall-through — copy the env-override read as
the template); **(2)** move the secret load **off the main thread** so even a mirror-absent
corrupt-Keychain case shows "Starting up…" instead of wedging the run loop; **(3)** upstream,
a **stable signing identity** (#4) keeps the cdhash constant so the ACL never distrusts the
binary. The file-side cousin is **any** synchronous disk read in a type/actor `init` on the
main thread at launch — same freeze, same fix.

---

## launchd LaunchAgent — run at login, respawn on crash [ours]

The dimillian packaging skill stops at a signed `.app`; keeping a menu-bar agent *alive* is
launchd's job. Use a **LaunchAgent** (per-user GUI session), not a LaunchDaemon.

`~/Library/LaunchAgents/ai.codealive.adhdcompanion.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key>            <string>ai.codealive.adhdcompanion</string>
  <key>ProgramArguments</key> <array>
    <string>/Applications/ADHDCompanion.app/Contents/MacOS/ADHDCompanion</string>
  </array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <dict><key>Crashed</key><true/></dict>  <!-- respawn on crash, NOT on intentional quit -->
  <key>ThrottleInterval</key> <integer>10</integer>                  <!-- min seconds between respawns -->
  <key>ProcessType</key>      <string>Interactive</string>
</dict></plist>
```
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.codealive.adhdcompanion.plist
launchctl print gui/$(id -u)/ai.codealive.adhdcompanion   # status, last exit, respawn count
```

- `KeepAlive.Crashed = true` respawns **only** on abnormal exit — a clean user "Quit" stays
  quit. `ThrottleInterval` stops a crash-loop from hammering respawn.
- **Trap [ours]:** launchd faithfully restarting a process that SIGTRAPs (#1) every
  `ThrottleInterval` **is** the "crash-loop" symptom. If a menu-bar app "keeps starting and
  dying," check the `.ips` for the #1 signature before blaming launchd — launchd is doing
  its job; the binary is crashing.
- A tiny external watchdog (`launchctl print` + "no publish since boot" check) is a cheap
  belt-and-braces over KeepAlive.

---

## #6 — IOKit power: stay lively without blocking sleep, and survive wake

### The `beginActivity` options trap
You want the app **lively enough that its timers fire**, but you must **not** prevent the
Mac from sleeping (a telemetry agent that blocks sleep is a battery/heat bug and a support
ticket).

```swift
// ✅ correct — keep the app scheduled, allow the system to idle-sleep normally
powerActivity = ProcessInfo.processInfo.beginActivity(
    options: .userInitiatedAllowingIdleSystemSleep,   // ← the only correct option here
    reason: "telemetry heartbeat")

// ❌ .userInitiated           → bundles .idleSystemSleepDisabled (blocks sleep)
// ❌ .idleSystemSleepDisabled → blocks sleep outright
```
Verify on the running system:
```bash
pmset -g assertions          # your app must NOT appear under PreventUserIdleSystemSleep
```

### Sleep/wake observers (belt and braces) — drive `forceReconnect()`
Register **both** an NSWorkspace observer and an IOKit power callback; on wake, collapse the
reconnect backoff (see #3):
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
) { [weak self] _ in Task { @MainActor in await self?.publisher?.forceReconnect() } }

// plus IORegisterForSystemPower → on kIOMessageSystemHasPoweredOn, same forceReconnect()
```
The IOKit callback is a **C callback** → it is a #1 boundary: it must be `@Sendable`/
isolation-correct (hop to the main actor via `Task { @MainActor }`, don't `assumeIsolated`
on the IOKit thread). See `concurrency-sigtrap.md`.

### Heartbeat / periodic timers
Use `DispatchSourceTimer` with **`@Sendable`** event handlers (a 5s heartbeat, a 24h
reconnect/TLS-flush). The `@Sendable` is mandatory — these fire off the main thread (#1).
Log resident memory (`task_info` → `rss_mb`) on the heartbeat to catch leaks on the running
binary, not in Instruments.

## Checklist
- [ ] Secret read prefers a byte-verified `0600` mirror; Keychain is fallback only.
- [ ] Keychain errors treated as transient + bounded self-heal retry; no crash.
- [ ] (Follow-up) Keychain fallback moved off the main thread for the mirror-absent path.
- [ ] LaunchAgent: `RunAtLoad` + `KeepAlive.Crashed` + `ThrottleInterval`; `.ips` checked
      before blaming respawns on launchd.
- [ ] `beginActivity(.userInitiatedAllowingIdleSystemSleep)`; `pmset -g assertions` clean.
- [ ] Wake observers (NSWorkspace **and** IOKit) → `forceReconnect()`; IOKit C callback is
      `@Sendable`.
