# macOS Icon Audit And Packaging Notes

## Key Findings

- OpenAI image edit masks are not Apple app icon masks. In the OpenAI Images API, a mask is a same-sized PNG where fully transparent pixels indicate the edit area. That is useful for inpainting, not for choosing a macOS icon enclosure.
- Native macOS app icons should not rely on the system to round a square source in the same way iOS does. Apple forum guidance quotes the macOS exception: Mac Catalyst gets rounded treatment automatically, but native macOS icons need to be created in the correct shape.
- Apple Design Resources are the source of truth for official templates. WWDC25 confirms the icon system still uses a `1024` pixel canvas and rounded-rectangle template work for Mac.
- The practical template geometry used in this project is:
  - Canvas: `1024x1024`
  - Enclosure: `824x824`
  - Gutter: `100px`
  - Radius argument: `185.4px`
  - Center the enclosure exactly.
- The Apple-style corner is continuous, not a plain circular-corner rectangle. A basic rounded rectangle can be close, but a continuous cubic path better matches the intended shape.

## Useful Source URLs

- Apple Design Resources: `https://developer.apple.com/design/resources/`
- Apple Icon Composer: `https://developer.apple.com/icon-composer/`
- WWDC25 "Say hello to the new look of app icons": `https://developer.apple.com/videos/play/wwdc2025/220/`
- Apple Developer Forums, macOS icon specs discussion: `https://developer.apple.com/forums/thread/670578`
- OpenAI Images edit API reference: `https://developers.openai.com/api/reference/python/resources/images/methods/edit/`
- PaintCode continuous rounded rectangle constants: `https://www.paintcodeapp.com/news/code-for-ios-7-rounded-rectangles`

## Geometry Scaling

For a square source of size `N`:

```text
scale = N / 1024
gutter = 100 * scale
side = 824 * scale
radius = 185.4 * scale
box = (gutter, gutter, gutter + side, gutter + side)
```

For a `1254x1254` source:

```text
scale = 1.224609375
gutter = 122.4609375
side = 1009.078125
radius = 227.043
box = (122.4609375, 122.4609375, 1131.5390625, 1131.5390625)
```

## Audit Checklist

1. Inspect the raw candidate:

```bash
sips -g pixelWidth -g pixelHeight path/to/icon.png
file path/to/icon.png
```

2. Generate masked source and previews:

```bash
python3 .agents/skills/package-macos-app-icons/scripts/apply_macos_icon_mask.py \
  --source path/to/icon.png \
  --output /tmp/icon-masked.png \
  --preview-dir /tmp/icon-preview
```

3. Visually inspect:

- `/tmp/icon-preview/light.png`
- `/tmp/icon-preview/dark.png`
- `/tmp/icon-preview/checker.png`

Look for:

- gray/white rectangular backdrop outside the icon;
- dirty semi-transparent edge pixels;
- clipped outer bevels;
- baked shadows that remain inside the enclosure;
- illegible details at small sizes.

4. Replace the source PNG only after visual inspection passes.

## Packaging Checklist

For the Agentic Secrets SwiftPM app:

```bash
./scripts/package_release.sh
./script/build_and_run.sh --verify
./scripts/install_local.sh --load
```

Compare icon hashes:

```bash
for p in \
  build/AgenticSecrets.icns \
  dist/AgenticSecrets.icns \
  "$HOME/Library/Application Support/AgenticSecrets/LocalInstall/Applications/AgenticSecrets.app/Contents/Resources/AgenticSecrets.icns"
do
  shasum -a 256 "$p"
done
```

Extract and inspect final `.icns`:

```bash
rm -rf /tmp/AgenticSecrets.iconset
iconutil -c iconset \
  "$HOME/Library/Application Support/AgenticSecrets/LocalInstall/Applications/AgenticSecrets.app/Contents/Resources/AgenticSecrets.icns" \
  -o /tmp/AgenticSecrets.iconset
```

Then inspect `/tmp/AgenticSecrets.iconset/icon_512x512@2x.png` on a checkerboard background.

## Runtime Install Checklist

1. Check running processes:

```bash
pgrep -fl AgenticSecrets || true
```

2. If the GUI is running from `dist`, stop only that GUI process and launch the installed copy:

```bash
open "$HOME/Library/Application Support/AgenticSecrets/LocalInstall/Applications/AgenticSecrets.app"
```

3. If the installed `.icns` hash is correct but Finder/Dock still shows the old icon, suspect macOS icon cache or a pinned Dock entry. Verify the file first; only then consider clearing the Dock/Finder view state or re-adding the Dock item.

## Validation Commands

Run the project gates that fit the change:

```bash
swift build
swift run agentic-secrets-contract-tests
./scripts/validate_release_artifact.sh build/AgenticSecrets.app
git diff --check
```
