---
name: package-macos-app-icons
description: Build, audit, replace, and install native macOS app icons from raster source artwork. Use when Codex needs to review an icon candidate against Apple macOS icon expectations, remove background halos with the standard macOS rounded-rectangle enclosure, preserve PNG alpha while resizing into .iconset/.icns files, update SwiftPM macOS app packaging scripts, compare installed/build/dist icon assets, or clear/restart local app icon installation state.
---

# Package macOS App Icons

## Workflow

1. Audit the candidate before installing it:
   - Check pixel dimensions, alpha channel, color mode, visible padding, edge cleanliness, and small-size legibility.
   - Inspect on light, dark, and checkerboard backgrounds. Do not trust only Finder/Dock rendering because icon caches can hide stale assets.
   - If the artwork came from an image model, assume outer gray/white backdrops and baked shadows may exist until visually checked.
   - Do not hand-draw replacement artwork in code unless the user explicitly asks. Programmatic work is for masking, alpha cleanup, resizing, packing, previewing, and verification.
   - Treat menu bar/status item icons as separate assets from the app icon. They usually need monochrome/template rendering and separate inspection.

2. Use Apple geometry for native macOS rounded enclosure work:
   - Reference canvas: `1024x1024`.
   - Standard enclosure: `824x824`, centered.
   - Gutter: `100px` on all sides.
   - Radius argument used by common template workflows: `185.4px`.
   - For non-1024 square sources, scale all values by `source_size / 1024`.
   - Prefer a continuous-corner path over a simple circular `rounded_rectangle`.

3. Apply the mask deterministically instead of hand-drawing it:

```bash
python3 .agents/skills/package-macos-app-icons/scripts/apply_macos_icon_mask.py \
  --source packaging/AgenticSecretsIconSource.png \
  --output /tmp/AgenticSecretsIconSource_masked.png \
  --preview-dir /tmp/agentic-icon-preview
```

4. Keep icon resizing alpha-safe:
   - The source PNG used for `.icns` generation should retain transparent pixels outside the enclosure.
   - Any resizer/packer must draw onto clear, not white, before writing PNG slots.
   - After generating `.icns`, extract the `icon_512x512@2x.png` slot and verify `alpha` has both `0` and `255` values.

5. Rebuild and install every app copy that can affect what the user sees:
   - Regenerate the project `.icns` source.
   - Rebuild packaged app bundles.
   - Reinstall the local app copy if the project uses a local installer.
   - Compare hashes across build, dist, and installed `.app` resources.
   - Restart the running GUI from the installed app path, not a stale `dist` copy.

## Project Notes

For Agentic Secrets, the relevant files are:

- `packaging/AgenticSecretsIconSource.png`
- `packaging/make_icon.swift`
- `scripts/package_release.sh`
- `script/build_and_run.sh`
- `scripts/install_local.sh`

The Swift icon resizer should preserve alpha. In practice this means its bitmap context should be cleared with `NSColor.clear`, not filled with `NSColor.white`, before drawing the source image.

## References

Read `references/macos-icon-audit.md` when you need the source rationale, Apple/OpenAI findings, exact geometry, verification commands, or cache/install checklist.
