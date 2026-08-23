#!/usr/bin/env python3
"""Draw Meter's icon: one budget, divided three ways.

Two variants, because the platforms want opposite things — see `ios()`:
    python3 Tools/icon.py           macOS asset catalog
    python3 Tools/icon.py --ios     iOS asset catalog + Now Playing artwork

The whole idea of the program in one picture — the same total width split into
different segments on each row, which is exactly what the director does to a
measure over time. Run from the project root:  python3 Tools/icon.py
"""
import json
import os
from PIL import Image, ImageDraw

SIZE = 1024
# Transparent background, deliberately.
#
# Recent macOS composites an app icon that ships as a legacy icns onto a plate of
# its own — light in the light theme, dark in the dark one — and there is no way
# to opt out of it from an asset catalog. Drawing our own background therefore
# gets you a square (or a second, smaller rounded rectangle) sitting on the
# system's plate, which looks like a mistake. So the art is the three rows and
# nothing else: the plate becomes the card, and the icon reads correctly in both
# themes.
INSET = 168

# The rows are drawn dark so the colored blocks have contrast whichever plate
# the system puts behind them.
PANEL = (18, 19, 22, 235)

# The lane hues from DrumVoice, low to bright.
LANES = [
    (232, 96, 62), (247, 168, 62), (238, 205, 78), (140, 200, 130),
    (110, 205, 190), (120, 175, 235), (150, 140, 230), (205, 150, 235),
]

# Three allocations of the same budget: the segments only push each other around.
ROWS = [
    [5, 3, 1, 2, 1, 6, 3, 1],
    [2, 2, 1, 1, 3, 8, 3, 2],
    [8, 4, 2, 1, 1, 3, 1, 2],
]


def draw(size: int) -> Image.Image:
    scale = size / SIZE
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(image)

    inner = INSET * scale
    width = size - 2 * inner
    rows = len(ROWS)
    gap = 52 * scale
    bar = (size - 2 * inner - gap * (rows - 1)) / rows

    for r, row in enumerate(ROWS):
        y = inner + r * (bar + gap)
        d.rounded_rectangle([inner, y, inner + width, y + bar],
                            radius=12 * scale, fill=PANEL)
        total = sum(row)
        x = inner
        for i, units in enumerate(row):
            w = width * units / total
            color = LANES[i % len(LANES)]
            # The busiest lanes read brightest, so the row has a shape to it.
            alpha = int(150 + 105 * min(1.0, units / 6))
            pad = 3 * scale
            d.rounded_rectangle([x + pad, y + pad, x + w - pad, y + bar - pad],
                                radius=9 * scale, fill=color + (alpha,))
            x += w
    return image


def ios() -> None:
    """The iOS variant: full bleed and fully opaque.

    iOS masks its own corners and rejects any alpha channel outright
    (ITMS-90717), so the transparent macOS artwork cannot be reused — the
    background that is a liability on the Mac is a requirement here.
    """
    art = draw(SIZE)
    flat = Image.new("RGB", (SIZE, SIZE), (14, 15, 17))
    flat.paste(art, (0, 0), art)

    icon = "Sources/iOS/Assets.xcassets/AppIcon.appiconset"
    art_set = "Sources/iOS/Assets.xcassets/NowPlayingArt.imageset"
    for path in (icon, art_set):
        os.makedirs(path, exist_ok=True)
        flat.save(os.path.join(path, "icon_1024.png"))

    with open("Sources/iOS/Assets.xcassets/Contents.json", "w") as f:
        json.dump({"info": {"version": 1, "author": "meter"}}, f, indent=2)
    with open(os.path.join(icon, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "icon_1024.png", "idiom": "universal",
                               "platform": "ios", "size": "1024x1024"}],
                   "info": {"version": 1, "author": "meter"}}, f, indent=2)
    with open(os.path.join(art_set, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "icon_1024.png", "idiom": "universal", "scale": "1x"},
                              {"idiom": "universal", "scale": "2x"},
                              {"idiom": "universal", "scale": "3x"}],
                   "info": {"version": 1, "author": "meter"}}, f, indent=2)
    print("wrote the iOS icon and Now Playing artwork")


def main() -> None:
    out = "Assets.xcassets/AppIcon.appiconset"
    os.makedirs(out, exist_ok=True)
    images = []
    # macOS wants 16/32/128/256/512 at 1x and 2x.
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            draw(px).save(os.path.join(out, name))
            images.append({"idiom": "mac", "size": f"{pt}x{pt}",
                           "scale": f"{scale}x", "filename": name})
    with open(os.path.join(out, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "meter"}}, f, indent=2)
    print(f"wrote {len(images)} icon images to {out}")


if __name__ == "__main__":
    import sys
    if "--ios" in sys.argv:
        ios()
    else:
        main()
