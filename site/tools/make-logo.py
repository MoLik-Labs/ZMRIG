#!/usr/bin/env python3
"""Draws the ZMRIG mark, once, in every format the repository needs.

The mark is a **Z sitting on a wave**: three strokes - bar, diagonal, bar - with
the bottom edge of the lower bar rising and falling like a water line. One
outline, one tone, no gradients, no shadow, no second element.

Why a Z with water under it:

* the miner is ZMRIG and the miner is written in Zig; a bold zigzag is the shape
  both names already share, and a letter needs no caption in a favicon;
* the pool, the proxy and the site are the sea this rig swims in, so the base of
  the letter is water rather than a straight rule - the one decoration the mark
  allows itself, and it is part of the letter, not a bubble next to it;
* the top bar, the diagonal and both verticals stay straight and on the grid, so
  the mark still reads as a Z at 16 px, where a wave drawn *inside* the stroke
  (a curved diagonal, a split stem, a ring) turns to mush.

Two properties make it survive being an icon rather than a poster:

* the straight parts use whole and half grid units on a 32 unit grid, so the 16,
  32 and 48 pixel versions land on pixels instead of on grey fringes;
* the wave is sampled, not a second shape: a curve rendered as a separate path
  leaves a hairline seam against the bar it is supposed to be part of.

    python3 site/tools/make-logo.py

Writes, into `site/static/img/`:

    logo.svg          black, for light pages
    logo-dark.svg     white, for dark pages
    favicon.svg       follows the browser's colour scheme
    favicon-32.png    white tile, black mark
    favicon-192.png
    apple-touch-icon.png

Requires Pillow for the PNGs (`pip install --user pillow`). Everything is
committed: GitHub Pages serves these files, and an icon that has to be built on
the fly is an icon that goes missing.
"""

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "static" / "img"

# --- geometry, on a 32 unit grid -------------------------------------------
#
# Read it as three strokes plus a water line:
#
#   top bar      (4,4)   -> (28,4)  -> (28,11)        7 units thick
#   diagonal     (28,11) -> (11,20.6)                 the letter's slant
#   bottom bar   (4,20.6) -> (4,26.8) -> (28,26.8)    6 units thick
#   water line   the bottom edge, y = 26.8 + 1.9 sin(2 pi x / 24)
#
# The wave is sampled at a fixed step instead of being a second path: two shapes
# that share an edge leave a hairline seam once an SVG renderer anti-aliases
# them separately, and the seam shows at exactly the sizes this is used at.

WAVE_BASE = 26.8
WAVE_AMPLITUDE = 1.9
WAVE_PERIODS = 1.0
WAVE_STEPS = 180


def _wave(x_from=28.0, x_to=4.0):
    """The water line, right to left: crest under the diagonal, trough on the left."""
    import math

    points = []
    width = x_from - x_to
    for i in range(1, WAVE_STEPS):
        x = x_from - width * i / WAVE_STEPS
        y = WAVE_BASE + WAVE_AMPLITUDE * math.sin(2 * math.pi * WAVE_PERIODS * (x_from - x) / width)
        points.append((round(x, 2), round(y, 2)))

    return points


Z = (
    [(4.0, 4.0), (28.0, 4.0), (28.0, 11.0), (11.0, 20.6), (28.0, 20.6), (28.0, WAVE_BASE)]
    + _wave()
    + [(4.0, WAVE_BASE), (4.0, 20.6), (21.0, 11.0), (4.0, 11.0)]
)

# A single polygon rather than three: adjacent shapes with a shared edge leave a
# hairline seam once an SVG renderer anti-aliases each one separately, and the
# seam is visible at exactly the sizes this is used at.
SHAPES = [Z]


def _fmt(value):
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return text if text else "0"


def _points(polygon):
    return " ".join(f"{_fmt(x)},{_fmt(y)}" for x, y in polygon)


def svg_document(colour, note=""):
    body = "".join(f'\n  <polygon fill="{colour}" points="{_points(p)}"/>' for p in SHAPES)

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32" role="img" aria-label="ZMRIG">
  <title>ZMRIG</title>{note}{body}
</svg>
"""


NOTE = """
  <!--
    ZMRIG. One bold Z on a water line: bar / diagonal / bar, one tone, no
    gradient, no second shape. The straight parts are on the 32 unit grid so the
    16, 32 and 48 pixel versions stay sharp; the bottom edge is a sampled wave,
    part of the same outline, so it cannot leave a seam.
    Regenerate with site/tools/make-logo.py - do not hand-edit.
  -->"""


def png(size, tile=None, ink=(0, 0, 0, 255), pad=0.12):
    """Rasterises the mark. `tile` paints a rounded background of that colour.

    Supersampled 16x: the diagonal's edge is the only curve-free line that can
    still alias badly, and it is the one thing a favicon is judged on.
    """
    ss = 16
    s = size * ss

    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    if tile is not None:
        ImageDraw.Draw(img).rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.19, fill=tile)

    inner = s * (1 - 2 * pad) if tile is not None else s
    off = (s - inner) / 2
    unit = inner / 32

    mask = Image.new("L", (s, s), 0)
    draw = ImageDraw.Draw(mask)
    for polygon in SHAPES:
        draw.polygon([(off + x * unit, off + y * unit) for x, y in polygon], fill=255)

    img.paste(Image.new("RGBA", (s, s), ink), (0, 0), mask)
    return img.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    (OUT / "logo.svg").write_text(svg_document("#000000", NOTE))
    (OUT / "logo-dark.svg").write_text(svg_document("#ffffff", NOTE))

    # A tab bar can be light or dark and the mark has one tone, so the favicon
    # carries the opposite tone instead of assuming a background.
    favicon = svg_document("#000000").replace(
        "<title>ZMRIG</title>",
        "<title>ZMRIG</title>\n  <style>\n"
        "    polygon { fill: #000000; }\n"
        "    @media (prefers-color-scheme: dark) { polygon { fill: #ffffff; } }\n"
        "  </style>",
    )
    (OUT / "favicon.svg").write_text(favicon)

    white = (255, 255, 255, 255)
    for name, size in (
        ("favicon-32.png", 32),
        ("favicon-192.png", 192),
        ("apple-touch-icon.png", 180),
    ):
        png(size, tile=white).save(OUT / name, optimize=True)
        print(f"wrote {name} {size}x{size}")

    for name in ("logo.svg", "logo-dark.svg", "favicon.svg"):
        print(f"wrote {name}")


if __name__ == "__main__":
    main()
