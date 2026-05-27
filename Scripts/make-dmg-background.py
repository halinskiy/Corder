#!/usr/bin/env python3
"""
Generate the DMG background for Corder.app installer at 1x AND 2x
resolution, then combine into a single HiDPI TIFF that Finder
renders sharply on both Retina and non-Retina displays.

Layout (logical 540×400 — the size the DMG window opens at):

    +-------------------------------------------------+
    |                                                 |
    |               Install Corder                    |   ← brand-tone title
    |        Drag Corder to the Applications folder   |   ← muted helper
    |                                                 |
    |               · · · · ↓ · · · ·                 |   ← dashed arc
    |       ┌──────┐                  ┌──────┐        |
    |       │      │                  │      │        |
    |       │ icon │                  │ apps │        |   ← drop slots
    |       │ slot │                  │ slot │        |
    |       └──────┘                  └──────┘        |
    |       Corder.app                Applications    |
    |                                                 |
    +-------------------------------------------------+

create-dmg places `Corder.app` at icon-grid (130, 200) and the
Applications alias at (410, 200). The dashed arc on the background
arches from over Corder.app down to over Applications, with a
small arrow head at the end — visual cue "drag this way".

Output:
    Resources/dmg-background.png       (540×400, 1x)
    Resources/dmg-background@2x.png    (1080×800, 2x)
    Resources/dmg-background.tiff      (HiDPI TIFF, combined)

The TIFF is what create-dmg references. Finder picks the right
representation based on the user's display scale.
"""

from PIL import Image, ImageDraw, ImageFont
import math
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RES = os.path.join(ROOT, "Resources")
OUT_1X   = os.path.join(RES, "dmg-background.png")
OUT_2X   = os.path.join(RES, "dmg-background@2x.png")
OUT_TIFF = os.path.join(RES, "dmg-background.tiff")

# Brand-accent (matches --accent in Web/src/styles.css)
ACCENT = (0x1F, 0x7A, 0x4F)
WHITE  = (255, 255, 255)
MUTED  = (140, 140, 140)
FG     = (28, 28, 30)

# Logical canvas — must match create-dmg --window-size.
W, H = 540, 400

# Logical icon centres — must match create-dmg --icon positions.
# create-dmg coords are the BASELINE of the icon; the visual centre
# of a 100 px icon is about 50 px above that.
LEFT_ICON_CX  = 130
RIGHT_ICON_CX = 410
ICON_CY       = 200    # visual centre


def load_font(scale: int, size: int) -> ImageFont.ImageFont:
    """Pick the first system font that opens — SF Pro / Helvetica /
    Inter / DejaVu — and load it at the given point size, scaled."""
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size * scale)
            except Exception:
                continue
    return ImageFont.load_default()


def draw_dashed_arc(draw: ImageDraw.ImageDraw,
                    cx: float, cy: float, rx: float, ry: float,
                    start_deg: float, end_deg: float,
                    colour: tuple, width: int,
                    dash_px: float, gap_px: float):
    """Draw a dashed elliptical arc by sampling many short line
    segments. PIL's `arc()` doesn't support dashed strokes, so we
    chunk the perimeter into dash + gap units."""
    total_deg = end_deg - start_deg
    # Approximate ellipse perimeter for the arc (Ramanujan).
    r_avg = (rx + ry) / 2
    perimeter = abs(math.radians(total_deg)) * r_avg
    unit = dash_px + gap_px
    n_units = max(1, int(perimeter / unit))
    deg_per_unit = total_deg / n_units
    dash_frac = dash_px / unit

    for i in range(n_units):
        a_start_deg = start_deg + i * deg_per_unit
        a_end_deg   = a_start_deg + deg_per_unit * dash_frac
        # Sample within the dash and connect short straight strokes.
        substeps = max(2, int(abs(deg_per_unit * dash_frac) / 2))
        pts = []
        for s in range(substeps + 1):
            t = s / substeps
            ang = math.radians(a_start_deg + (a_end_deg - a_start_deg) * t)
            x = cx + rx * math.cos(ang)
            y = cy + ry * math.sin(ang)
            pts.append((x, y))
        for a, b in zip(pts, pts[1:]):
            draw.line([a, b], fill=colour, width=width)


def draw_arrow_head(draw: ImageDraw.ImageDraw,
                    tip: tuple, dir_angle_rad: float,
                    colour: tuple, length: int, width: int):
    """Tiny chevron arrow head pointing along `dir_angle_rad`."""
    head_angle = math.radians(30)
    for side in (-1, +1):
        a = dir_angle_rad + math.pi - side * head_angle
        end = (tip[0] + length * math.cos(a),
               tip[1] + length * math.sin(a))
        draw.line([tip, end], fill=colour, width=width)


def render(scale: int) -> Image.Image:
    canvas_w = W * scale
    canvas_h = H * scale
    # Render at 2× internal supersample then downsample for a
    # cleaner edge on the dashed strokes + text.
    super_scale = 2
    img = Image.new("RGB", (canvas_w * super_scale, canvas_h * super_scale), WHITE)
    d = ImageDraw.Draw(img)

    s = scale * super_scale  # effective pixels per logical point

    # ─ Headline + helper text, centred near the top.
    title_font  = load_font(s, 22)
    helper_font = load_font(s, 12)

    title = "Install Corder"
    tw = d.textlength(title, font=title_font)
    d.text(((canvas_w * super_scale - tw) / 2, 50 * s),
           title, fill=FG, font=title_font)

    helper = "Drag Corder to your Applications folder"
    hw = d.textlength(helper, font=helper_font)
    d.text(((canvas_w * super_scale - hw) / 2, 84 * s),
           helper, fill=MUTED, font=helper_font)

    # ─ Dashed arc arching ABOVE the two icons.
    # Centre the ellipse between the icons, peaking above the
    # icon centres so the arc reads as "from this icon UP and
    # OVER to that icon".
    arc_cx = (LEFT_ICON_CX + RIGHT_ICON_CX) / 2 * s
    arc_cy = (ICON_CY + 4) * s                  # slightly below icon centre
    arc_rx = (RIGHT_ICON_CX - LEFT_ICON_CX) / 2 * s
    arc_ry = 56 * s                              # how tall the arch is

    draw_dashed_arc(d,
                    cx=arc_cx, cy=arc_cy,
                    rx=arc_rx, ry=arc_ry,
                    start_deg=180, end_deg=360,    # top half of ellipse
                    colour=ACCENT, width=max(2, int(2 * s)),
                    dash_px=8 * s, gap_px=6 * s)

    # Arrow head at the right end of the arc (angle 360° = (cx+rx, cy)).
    tip = (arc_cx + arc_rx, arc_cy)
    # Tangent at end of upper semicircle points DOWN-LEFT (the arc
    # is travelling left→right from 180 to 360, but the tangent at
    # 360° is straight down). We want the head to point along the
    # arc's direction at that point — straight down.
    draw_arrow_head(d, tip=tip,
                    dir_angle_rad=math.pi / 2,  # pointing down
                    colour=ACCENT,
                    length=int(11 * s), width=max(2, int(2 * s)))

    # Downsample from supersample → target.
    final = img.resize((canvas_w, canvas_h), Image.LANCZOS)
    return final


def build_hidpi_tiff(png_1x: str, png_2x: str, out_tiff: str) -> None:
    """Combine 1x + 2x PNG into a single HiDPI multi-rep TIFF using
    `tiffutil -cathidpicheck`. macOS Finder reads the right
    representation based on the user's display scale."""
    if not shutil.which("tiffutil"):
        raise RuntimeError("tiffutil not found — required for HiDPI DMG background")
    subprocess.run(
        ["tiffutil", "-cathidpicheck", png_1x, png_2x, "-out", out_tiff],
        check=True,
    )


def main() -> int:
    os.makedirs(RES, exist_ok=True)
    render(1).save(OUT_1X, "PNG")
    render(2).save(OUT_2X, "PNG")
    build_hidpi_tiff(OUT_1X, OUT_2X, OUT_TIFF)
    print(f"✔ wrote {OUT_1X}")
    print(f"✔ wrote {OUT_2X}")
    print(f"✔ wrote {OUT_TIFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
