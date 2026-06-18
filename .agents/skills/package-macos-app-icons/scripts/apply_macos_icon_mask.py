#!/usr/bin/env python3
"""Apply the standard macOS app icon enclosure mask to a square PNG."""

from __future__ import annotations

import argparse
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover - depends on host environment
    raise SystemExit("This script requires Pillow. Use the bundled Codex Python runtime if needed.") from exc


CANVAS = 1024.0
GUTTER = 100.0
SIDE = 824.0
RADIUS = 185.4


def cubic(p0, p1, p2, p3, steps=36):
    for i in range(1, steps + 1):
        t = i / steps
        mt = 1.0 - t
        yield (
            mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0],
            mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1],
        )


def continuous_mask(size: int) -> Image.Image:
    scale = size / CANVAS
    x = y = GUTTER * scale
    width = height = SIDE * scale
    radius = RADIUS * scale
    limited_radius = min(radius, min(width, height) / 2 / 1.52866483)

    def tl(a, b):
        return (x + a * limited_radius, y + b * limited_radius)

    def tr(a, b):
        return (x + width - a * limited_radius, y + b * limited_radius)

    def br(a, b):
        return (x + width - a * limited_radius, y + height - b * limited_radius)

    def bl(a, b):
        return (x + a * limited_radius, y + height - b * limited_radius)

    points = [tl(1.52866483, 0.0)]

    def line(point):
        points.append(point)

    def curve(c1, c2, point):
        points.extend(cubic(points[-1], c1, c2, point))

    line(tr(1.52866471, 0.0))
    curve(tr(1.08849323, 0.0), tr(0.86840689, 0.0), tr(0.66993427, 0.06549600))
    line(tr(0.63149399, 0.07491100))
    curve(tr(0.37282392, 0.16905899), tr(0.16906013, 0.37282401), tr(0.07491176, 0.63149399))
    curve(tr(0.0, 0.86840701), tr(0.0, 1.08849299), tr(0.0, 1.52866483))
    line(br(0.0, 1.52866471))
    curve(br(0.0, 1.08849323), br(0.0, 0.86840689), br(0.06549569, 0.66993493))
    line(br(0.07491111, 0.63149399))
    curve(br(0.16905883, 0.37282392), br(0.37282392, 0.16905883), br(0.63149399, 0.07491111))
    curve(br(0.86840689, 0.0), br(1.08849323, 0.0), br(1.52866471, 0.0))
    line(bl(1.52866483, 0.0))
    curve(bl(1.08849299, 0.0), bl(0.86840701, 0.0), bl(0.66993397, 0.06549569))
    line(bl(0.63149399, 0.07491111))
    curve(bl(0.37282401, 0.16905883), bl(0.16906001, 0.37282392), bl(0.07491100, 0.63149399))
    curve(bl(0.0, 0.86840689), bl(0.0, 1.08849323), bl(0.0, 1.52866471))
    line(tl(0.0, 1.52866483))
    curve(tl(0.0, 1.08849299), tl(0.0, 0.86840701), tl(0.06549600, 0.66993397))
    line(tl(0.07491100, 0.63149399))
    curve(tl(0.16906001, 0.37282401), tl(0.37282401, 0.16906001), tl(0.63149399, 0.07491100))
    curve(tl(0.86840701, 0.0), tl(1.08849299, 0.0), tl(1.52866483, 0.0))

    supersample = 4
    mask = Image.new("L", (size * supersample, size * supersample), 0)
    scaled = [(round(px * supersample), round(py * supersample)) for px, py in points]
    ImageDraw.Draw(mask).polygon(scaled, fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def center_square(image: Image.Image) -> Image.Image:
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def checkerboard(size: int, tile: int = 32) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    draw = ImageDraw.Draw(canvas)
    for y in range(0, size, tile):
        for x in range(0, size, tile):
            if (x // tile + y // tile) % 2:
                draw.rectangle([x, y, x + tile - 1, y + tile - 1], fill=(205, 205, 205, 255))
    return canvas


def write_previews(image: Image.Image, preview_dir: Path) -> None:
    preview_dir.mkdir(parents=True, exist_ok=True)
    backgrounds = {
        "light.png": Image.new("RGBA", image.size, (246, 246, 246, 255)),
        "dark.png": Image.new("RGBA", image.size, (42, 42, 42, 255)),
        "checker.png": checkerboard(image.size[0]),
    }
    for name, canvas in backgrounds.items():
        canvas.alpha_composite(image)
        canvas.save(preview_dir / name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--preview-dir", type=Path)
    args = parser.parse_args()

    source = center_square(Image.open(args.source).convert("RGBA"))
    mask = continuous_mask(source.size[0])
    result = source.copy()
    result.putalpha(mask)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result.save(args.output)

    if args.preview_dir:
        write_previews(result, args.preview_dir)

    scale = source.size[0] / CANVAS
    print(f"source={source.size[0]}x{source.size[1]}")
    print(f"scale={scale:.9f}")
    print(f"gutter={GUTTER * scale:.3f} side={SIDE * scale:.3f} radius={RADIUS * scale:.3f}")


if __name__ == "__main__":
    main()
