#!/usr/bin/env python3
"""Draws FamChat's mark (a gable-roofed speech bubble with a lit window) as SVGs and renders PNGs.

Run from app/:  python3 tool/brand/make_brand.py
Needs rsvg-convert (librsvg). Then regenerate the platform files:
  dart run flutter_launcher_icons
  dart run flutter_native_splash:create
The in-app BrandMark (lib/widgets/brand_mark.dart) paints the same geometry; keep them in step.
"""
import pathlib
import subprocess

OUT = pathlib.Path("assets/brand")

DUSK = "#2E2550"
HOUSE = "#F6F1FF"
WINDOW = "#FFC75A"

# 1024-unit artboard. The house outline is stroked in its own color with round joins, which
# softens every corner by the stroke's half width (28 units).
HOUSE_PATH = (
    "M512 212 L780 432 L780 740 Q780 780 740 780 L470 780 L318 884 L352 780 "
    "L284 780 Q244 780 244 740 L244 432 Z"
)
GLYPH_CENTER_Y = 548  # middle of the glyph's bounding box, tail included


def glyph(scale: float, cx: float = 512, cy: float = 512) -> str:
    return f"""
  <g transform="translate({cx} {cy}) scale({scale}) translate(-512 -{GLYPH_CENTER_Y})">
    <path d="{HOUSE_PATH}" fill="{HOUSE}" stroke="{HOUSE}" stroke-width="56" stroke-linejoin="round"/>
    <rect x="398" y="462" width="228" height="200" rx="24" fill="{WINDOW}"/>
    <path d="M512 462 V662 M398 562 H626" stroke="{DUSK}" stroke-width="20"/>
  </g>"""


def svg(body: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}\n</svg>\n'


VARIANTS = {
    # Full-bleed square: iOS, Android legacy, Windows, web (also safe as a maskable icon).
    "famchat-icon": svg(f'\n  <rect width="1024" height="1024" fill="{DUSK}"/>' + glyph(0.84)),
    # macOS: the rounded tile with the system's margin.
    "famchat-icon-macos": svg(
        f'\n  <rect x="100" y="100" width="824" height="824" rx="186" fill="{DUSK}"/>' + glyph(0.64)
    ),
    # Android adaptive foreground: glyph inside the 66 % safe zone, transparent around it.
    "famchat-foreground": svg(glyph(0.56)),
    # Splash: the glyph alone; Android 12 masks it to a circle, so it stays well inside.
    "famchat-glyph": svg(glyph(0.62)),
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, content in VARIANTS.items():
        src = OUT / f"{name}.svg"
        src.write_text(content)
        subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", "-o", str(OUT / f"{name}.png"), str(src)], check=True)
        print("wrote", src, "and .png")


if __name__ == "__main__":
    main()
