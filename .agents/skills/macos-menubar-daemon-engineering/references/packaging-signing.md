# #4 — SwiftPM → .app bundle, stable signing, notarization

The app won't launch on double-click, Gatekeeper blocks it, or — the active daily pain —
**every ad-hoc rebuild re-triggers Keychain "Allow access" prompts** because the cdhash
changed. SwiftPM produces a bare executable; turning it into a distributable, trusted
`.app` is all on you.

**Source of truth:** the `dimillian/macos-spm-app-packaging` skill is **installed
alongside this one** and ships runnable templates (`package_app.sh`,
`setup_dev_signing.sh`, `sign-and-notarize.sh`). Use those scripts directly; this file is
the **map** of what they do, the gotchas that bite SwiftPM bundlers specifically, and the
two enhancements we add. All recipe content is **[mined — dimillian]** unless tagged
**[ours]**.

## The cdhash → Keychain connection (why this matters beyond packaging) [ours]

Ad-hoc signing (`codesign --sign -`) computes a **new cdhash every build**. The Keychain
ACL on your secret item is keyed to the *previous* binary's cdhash, so each rebuild is an
"untrusted new binary" → a modal **"Allow access"** prompt. For an `LSUIElement` app that
prompt is invisible and **freezes startup** (see #5). A **stable signing identity** gives a
**stable cdhash** → the Keychain keeps trusting the binary across rebuilds → the prompt
class disappears. So fixing #4 is the cleanest way to kill a #5 trigger.

## Stable dev identity [mined — `setup_dev_signing.sh`] + [ours enhancement]

The skill creates a stable self-signed code-signing certificate and imports it for
`codesign`:

```bash
# [mined] create a stable self-signed codeSigning cert and import for codesign
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -keyout dev.key -out dev.crt -subj "/CN=<AppName> Development" \
  -addext "extendedKeyUsage=codeSigning"
# (cert is wrapped into a .p12 and) imported:
security import dev.p12 -k login.keychain-db -T /usr/bin/codesign
export APP_IDENTITY='<AppName> Development'    # then sign with --sign "$APP_IDENTITY"
```

> [ours — required for true non-interactivity] the skill's import does **not** set a
> partition list, so the first `codesign` may still prompt. Add:
> ```bash
> security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" login.keychain-db
> ```
> After this, `codesign` runs without any prompt — the point of the whole exercise.

## Bundle assembly gotchas specific to SwiftPM [mined — `package_app.sh`]

- **Universal binary:** build per-arch, then `lipo -create`; assert the result with a
  `verify_binary_arches()` guard so a half-built binary fails the bundle, not the user.
- **Bundle tree:** `Contents/{MacOS,Resources,Frameworks}`.
- **Framework rpath fix** (if any dep ships as a `.framework`/dylib rather than static):
  ```bash
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/<exe>"
  ```
- **Harvest SwiftPM resource bundles** — the `*_<Target>.bundle` SwiftPM emits next to the
  binary is easy to forget:
  ```bash
  SWIFTPM_BUNDLES=("${BUILD_DIR}/"*.bundle); cp -R "${SWIFTPM_BUNDLES[@]}" "$APP/Contents/Resources/"
  ```
- **Code-sealing hygiene — strip xattrs/AppleDouble BEFORE signing** (prevents the
  baffling "resource fork / Finder information … not permitted" codesign failure):
  ```bash
  chmod -R u+w "$APP"
  xattr -cr "$APP"
  find "$APP" -name '._*' -delete
  ```
- **Sign frameworks inner-first**, then the outer bundle (order people get wrong).

## Info.plist for a menu-bar app [mined]

Generated as an inline heredoc (no plist file to maintain). Menu-bar mode is a flag:

```bash
[ "$MENU_BAR_APP" = 1 ] && echo '<key>LSUIElement</key><true/>'   # menu-bar-only, no Dock icon
```

Keys it sets: `CFBundleName/DisplayName/Identifier/Executable`, `CFBundlePackageType=APPL`,
`CFBundleShortVersionString`/`CFBundleVersion`, `LSMinimumSystemVersion`,
`CFBundleIconFile`, and — a cheap provenance trick worth copying — **`BuildTimestamp` +
`GitCommit`** (`git rev-parse --short HEAD`) baked into the plist so you can answer "which
build is this menu-bar app actually running?" during triage.

## Signing decision [mined]

```
SIGNING_MODE == adhoc  ||  -z APP_IDENTITY   →   codesign --sign "-"               # dev fallback
else                                          →   codesign --force --timestamp \
                                                   --options runtime --sign "$APP_IDENTITY"  # Developer ID
```

Prefer the stable identity even for local dev (kills the #5 prompt). Reserve `--sign "-"`
for throwaway runs.

## Notarization [mined — `sign-and-notarize.sh`]

```
codesign --options runtime …                                    # hardened runtime (required)
ditto --norsrc -c -k --keepParent "$APP" "$APP.zip"
xcrun notarytool submit "$APP.zip" --wait \                      # App Store Connect API key:
  --key "$APP_STORE_CONNECT_API_KEY_P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID"
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP" && xcrun stapler validate "$APP"     # live gates
```

Battle-tested failure table [mined]:

| notarytool says | fix |
|---|---|
| "The executable does not have the hardened runtime enabled" | add `--options runtime` |
| "...has already been uploaded" | bump `CFBundleVersion` / `BUILD_NUMBER` |
| `stapler validate` fails right after submit | wait ~60s, re-staple |

## Verify (these are #7 live gates, not build output)

```bash
codesign -dv --verbose=4 "$APP"          # identity + cdhash actually applied?
spctl --assess --type execute -vv "$APP" # Gatekeeper verdict
xcrun stapler validate "$APP"            # ticket stapled?
```

launchd / LaunchAgent for "run at login + respawn on crash" lives in
`keychain-launchd-power.md` (it is **[ours]** — the dimillian skill stops at the signed
`.app` and Sparkle auto-update; it has **no** launchd content).

## Checklist

- [ ] Stable signing identity created + partition-list set (no codesign prompts).
- [ ] `xattr -cr` + `._*` strip **before** signing.
- [ ] SwiftPM resource bundles harvested into `Contents/Resources`.
- [ ] `LSUIElement` set for menu-bar mode; `BuildTimestamp`/`GitCommit` baked in.
- [ ] Frameworks signed inner-first; hardened runtime on for Developer ID.
- [ ] `codesign -dv` / `spctl` / `stapler validate` all green on the **built bundle**.
