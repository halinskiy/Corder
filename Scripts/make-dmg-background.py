#!/usr/bin/env python3
"""
DMG installer background for Corder — wraps the Swift CoreText
renderer (`make-dmg-background.swift`) so we can produce a HiDPI
multi-rep TIFF that Finder picks the right scale from.

Why Swift+CoreText (not SVG+rsvg-convert): Finder draws the
"Corder" / "Applications" captions under the icons with CoreText.
FreeType (which rsvg-convert uses) paints the same glyphs at the
same size with subtly different antialiasing — the text on the
background always read softer than the captions under it. Driving
the same CoreText path that Finder uses gives pixel-identical AA.

This wrapper only runs the Swift binary + tiffutil; all geometry
lives in `make-dmg-background.swift`.
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RES = os.path.join(ROOT, "Resources")
SWIFT_SRC = os.path.join(os.path.dirname(__file__), "make-dmg-background.swift")
OUT_1X   = os.path.join(RES, "dmg-background.png")
OUT_2X   = os.path.join(RES, "dmg-background@2x.png")
OUT_TIFF = os.path.join(RES, "dmg-background.tiff")


def build_hidpi_tiff(png_1x: str, png_2x: str, out_tiff: str) -> None:
    if not shutil.which("tiffutil"):
        raise RuntimeError("tiffutil not found — required for HiDPI DMG background")
    subprocess.run(
        ["tiffutil", "-cathidpicheck", png_1x, png_2x, "-out", out_tiff],
        check=True,
    )


def main() -> int:
    os.makedirs(RES, exist_ok=True)
    if not shutil.which("swift"):
        raise RuntimeError("swift not found — install Xcode command-line tools")
    subprocess.run(
        ["swift", SWIFT_SRC, OUT_1X, OUT_2X],
        check=True,
    )
    build_hidpi_tiff(OUT_1X, OUT_2X, OUT_TIFF)
    print(f"✔ wrote {OUT_TIFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
