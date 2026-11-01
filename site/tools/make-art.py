#!/usr/bin/env python3
"""Renders the documentation screenshots from the built HTML.

There is no browser in this repository's CI, so the social/OG previews cannot be
produced with a headless Chrome. They are drawn instead: the real numbers, the
real palette from `src/css/custom.css`, the same monospace stack. A screenshot
that is generated is honest as long as it says what it is — so it is drawn from
the data the site itself renders, and `site/tests/og.test.mjs` checks that every
number on it still appears in `src/lib/pools.mjs` or `DEFAULT` report settings.

    python3 site/tools/make-art.py

Requires Pillow (`pip install --user pillow`). The output is committed, because
GitHub Pages serves it and a missing og:image is a worse failure than a static
one.
"""

import json
import os
import re
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SITE = Path(__file__).resolve().parent.parent
OUT = SITE / "static" / "img"

INK = (28, 27, 26)
INK_DIM = (85, 80, 74)
PAPER = (251, 250, 248)
RULE = (227, 222, 215)
ACCENT = (194, 65, 12)
OK = (21, 115, 71)

# DejaVu Sans Mono has no Vietnamese diacritics beyond Latin-1: "quyết" and
# "đều" render as boxes. Monospace is therefore used only for ASCII (host names,
# numbers, the wordmark), and every Vietnamese sentence is set in DejaVu Sans,
# which covers Latin Extended Additional.
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
MONO_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
SANS_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def font(path, size):
    return ImageFont.truetype(path, size)


def pools():
    """Reads the pool table out of the module the site renders from."""
    text = (SITE / "src" / "lib" / "pools.mjs").read_text()
    rows = []
    for block in re.findall(r"\{\s*id: \"([^\"]+)\"[\s\S]*?\n  \}", text):
        rows.append(block)
    entries = []
    for block in re.finditer(
        r"id: \"([^\"]+)\",\s*\n\s*name: \"([^\"]+)\",\s*\n\s*host: \"([^\"]+)\","
        r"[\s\S]*?fee: ([0-9.]+),\s*\n\s*min: ([0-9.]+),",
        text,
    ):
        entries.append(
            {
                "id": block.group(1),
                "name": block.group(2),
                "host": block.group(3),
                "fee": float(block.group(4)),
                "min": float(block.group(5)),
            }
        )
    return entries


def fit_title(text, width, draw, start=54, floor=34):
    """Shrinks the heading until it fits on one line; never truncates it."""
    size = start
    while size > floor:
        fnt = font(SANS_BOLD, size)
        if draw.textlength(text, font=fnt) <= width:
            return text, fnt
        size -= 2
    return text, font(SANS_BOLD, floor)


def clamp(text, width, fnt, draw):
    if draw.textlength(text, font=fnt) <= width:
        return text
    while text and draw.textlength(text + "…", font=fnt) > width:
        text = text[:-1]
    return text + "…"


def draw_mark(d, x, y, size, colour):
    """Pastes the ZMRIG mark into a card.

    The geometry lives in `make-logo.py`, which is also what writes the SVGs and
    the favicons; drawing it again here would be a second source of truth that
    drifts the first time the mark changes.
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location("make_logo", Path(__file__).resolve().parent / "make-logo.py")
    make_logo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(make_logo)

    mark = make_logo.png(size, ink=colour if len(colour) == 4 else (*colour, 255))
    d._image.paste(mark, (int(x), int(y)), mark)


def social_card(path, title, subtitle, rows, footer, locale_label, vietnamese=False):
    W, H = 1200, 630
    img = Image.new("RGB", (W, H), PAPER)
    d = ImageDraw.Draw(img)

    d.rectangle([0, 0, W, 6], fill=ACCENT)

    # wordmark: the same mark the site uses (cache core inside the dataset ring)
    draw_mark(d, 64, 56, 52, INK)
    d.text((132, 68), "ZMRIG", font=font(SANS_BOLD, 30), fill=INK)
    tag = font(MONO, 17)
    d.text((132, 100), locale_label, font=font(SANS if vietnamese else MONO, 17), fill=INK_DIM)

    heading, heading_font = fit_title(title, W - 128, d)
    d.text((64, 160), heading, font=heading_font, fill=INK)
    subtitle_font = font(SANS if vietnamese else MONO, 23)
    d.text((64, 232), clamp(subtitle, W - 128, subtitle_font, d), font=subtitle_font, fill=INK_DIM)

    # the pool table, which is the one table the site is built around
    top = 300
    col = [64, 290, 410, 600]
    head = font(SANS_BOLD if vietnamese else MONO_BOLD, 18)
    body = font(MONO, 18)
    body_text = font(SANS, 18)
    labels = (
        ["pool", "phí", "trả tối thiểu", "endpoint"]
        if vietnamese
        else ["pool", "fee", "min payout", "endpoint"]
    )
    for x, label in zip(col, labels):
        d.text((x, top), label, font=head, fill=INK_DIM)
    d.line([64, top + 30, W - 64, top + 30], fill=RULE, width=2)

    y = top + 44
    for row in rows[:4]:
        fee = f"{row['fee']:g} %"
        if vietnamese:
            fee = fee.replace(".", ",")
        minimum = f"{row['min']:g} XMR"
        if vietnamese:
            minimum = minimum.replace(".", ",")
        name_font = body_text if vietnamese else body
        d.text((col[0], y), clamp(row["name"], 220, name_font, d), font=name_font, fill=INK)
        d.text((col[1], y), fee, font=body, fill=ACCENT if row["fee"] == 0 else INK)
        d.text((col[2], y), minimum, font=body, fill=INK)
        d.text((col[3], y), clamp(row["host"], W - 64 - col[3], body, d), font=body, fill=INK)
        y += 38

    d.line([64, H - 116, W - 64, H - 116], fill=RULE, width=2)
    footer_font = font(SANS if vietnamese else MONO, 20)
    d.text((64, H - 96), clamp(footer, W - 128, footer_font, d), font=footer_font, fill=INK_DIM)
    d.text((64, H - 62), "nggkhaiz.github.io/ZMRIG", font=font(MONO, 19), fill=ACCENT)

    img.save(path, optimize=True)
    print(f"wrote {path.relative_to(SITE.parent)} {img.size[0]}x{img.size[1]}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    table = pools()
    if len(table) < 6:
        raise SystemExit(f"only {len(table)} pools parsed from src/lib/pools.mjs")

    social_card(
        OUT / "og-en.png",
        "A RandomX miner that takes no cut",
        "one command, every decision measured, 0 % developer fee",
        table,
        "Install  ·  Pools  ·  Profitability calculator  ·  Benchmarks",
        "Documentation · English",
    )
    social_card(
        OUT / "og-vi.png",
        "Miner RandomX không lấy phần trăm nào",
        "một lệnh, mọi quyết định đều được đo, phí developer 0 %",
        table,
        "Cài đặt · Pool · Máy tính lợi nhuận · Hiệu năng",
        "Tài liệu · Tiếng Việt",
        vietnamese=True,
    )


if __name__ == "__main__":
    main()
