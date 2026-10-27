# labels: testing, needs-review
"""Generate the G1 reference image (docs/G1_PLAN.md).

ARKit image detection needs rich, non-repeating, high-contrast texture. The crosshair
marks the exact image centre = the ARKit image-anchor centre = the touch target.

Outputs:
  Sightline/Sightline/g1_marker.png  - bundled in the app as the ARReferenceImage
  docs/assets/g1_marker_print.pdf    - US Letter page, marker 10 cm wide at 100% scale

Usage (from sightline/): python3 tools/make_g1_marker.py
"""

import random
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
DPI = 300
MARKER_CM = 10
SIDE = round(MARKER_CM / 2.54 * DPI)  # 1181 px
SEED = 2026


def marker() -> Image.Image:
    rng = random.Random(SEED)
    img = Image.new("L", (SIDE, SIDE), 255)
    draw = ImageDraw.Draw(img)
    for _ in range(260):
        x, y = rng.randrange(SIDE), rng.randrange(SIDE)
        r = rng.randrange(12, 110)
        shade = rng.choice([0, 0, 40, 90, 160, 210])
        kind = rng.random()
        if kind < 0.4:
            draw.ellipse((x - r, y - r, x + r, y + r), fill=shade)
        elif kind < 0.8:
            w, h = r, rng.randrange(12, 110)
            draw.rectangle((x - w, y - h, x + w, y + h), fill=shade)
        else:
            pts = [(x + rng.randrange(-r, r), y + rng.randrange(-r, r)) for _ in range(3)]
            draw.polygon(pts, fill=shade)

    # Crosshair on a white disc so the centre is easy to find by touch and by eye.
    c = SIDE / 2
    draw.ellipse((c - 70, c - 70, c + 70, c + 70), fill=255, outline=0, width=6)
    draw.line((c - 60, c, c + 60, c), fill=0, width=6)
    draw.line((c, c - 60, c, c + 60), fill=0, width=6)
    draw.rectangle((0, 0, SIDE - 1, SIDE - 1), outline=0, width=8)
    return img


def print_page(img: Image.Image) -> Image.Image:
    page = Image.new("L", (int(8.5 * DPI), int(11 * DPI)), 255)
    page.paste(img, ((page.width - SIDE) // 2, (page.height - SIDE) // 2))
    draw = ImageDraw.Draw(page)
    draw.text((150, 150), "Sightline G1 marker. Print at 100% / Actual size (no fit to page).", fill=0)
    draw.text((150, 200), "Measure the black border width with a ruler; it should be 100 mm.", fill=0)
    draw.text((150, 250), "Enter the measured width in the app. Touch target = crosshair centre.", fill=0)
    return page


def main() -> None:
    img = marker()
    png = ROOT / "Sightline" / "Sightline" / "g1_marker.png"
    pdf = ROOT / "docs" / "assets" / "g1_marker_print.pdf"
    pdf.parent.mkdir(parents=True, exist_ok=True)
    img.resize((600, 600)).save(png)  # ARKit only needs a modest resolution
    print_page(img).save(pdf, resolution=DPI)
    print(f"wrote {png}\nwrote {pdf}")


if __name__ == "__main__":
    main()
