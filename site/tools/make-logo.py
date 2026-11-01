#!/usr/bin/env python3
"""Draws the ZMRIG mark, once, in every format the repository needs.

The mark is a **Z**, and it is drawn rather than typed: one outline, one tone,
no gradients, no shadow, no second element. Three strokes - bar, diagonal, bar -
at a weight that stays the same as the letter turns, with the diagonal cut
thinner than the bars because a diagonal at equal weight always reads heavier.
The two corners that sit on the diagonal's axis are chamfered, so the terminals
answer the direction of the stroke instead of being squared off against it.

Two properties make it survive being an icon rather than a poster:

* the outline is symmetric under a 180 degree rotation, so the mark cannot look
  crooked inside a circle, a square tile or a browser tab;
* every coordinate is a whole or half grid unit on a 32 unit grid, so the 16, 32
  and 48 pixel versions land on pixels instead of on grey fringes.

Why a letter: the miner is ZMRIG and the miner is written in Zig. A bold zigzag
is the shape both names already share, and a mark that is unmistakably a letter
needs no caption in a favicon. Anything built out of a ring, a core or a pair of
memory layers was tried first and read as a generic chip logo at 16 px, which is
where a logo spends its life.

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
# One closed outline, clockwise from the chamfered top-left corner. Read it as
# three strokes:
#
#   top bar      (8,4)  -> (28,4)  -> (28,11)         7 units thick
#   diagonal     28,11  -> (20.5,21) -> (28,21)       the thin stroke
#   bottom bar   (4,21) -> (4,28)  -> (28,28)         7 units thick
#
# with the bottom-right and top-left corners chamfered by 4 units. The outline
# is exactly symmetric under (x, y) -> (32 - x, 32 - y).
Z = [
    (8.0, 4.0),
    (28.0, 4.0),
    (28.0, 11.0),
    (20.5, 21.0),
    (28.0, 21.0),
    (28.0, 24.0),
    (24.0, 28.0),
    (4.0, 28.0),
    (4.0, 21.0),
    (11.5, 11.0),
    (4.0, 11.0),
    (4.0, 8.0),
]

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
    ZMRIG. Ziggurat, Zig: one bold Z, bar / diagonal / bar, one tone.
    The two chamfered corners follow the diagonal's axis, the outline is
    symmetric under a 180 degree rotation, and every coordinate is on the 32
    unit grid so the 16, 32 and 48 pixel versions stay sharp.
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
