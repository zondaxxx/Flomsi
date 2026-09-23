#!/usr/bin/env python3
"""The Flomsi app icon for every platform: an "fl" ligature on the app's dark background.
The f is IBM Plex's own f; the l is a bar the width of the stem, drawn in the accent, which
is also the editor's text cursor. As in Plex's fi, the f's crossbar runs into the bar.
Needs Pillow.

    python3 scripts/make_icons.py
"""
from PIL import Image, ImageDraw, ImageFilter
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
SITE = os.path.join(ROOT, "site")
BG = (22, 24, 29, 255)        # #16181D, the app's dark background
FG = (215, 218, 224, 255)     # #D7DAE0
BLUE = (116, 173, 232, 255)   # #74ADE8
S = 4  # supersampling

# The mark in px on a 1024 icon; everything but the curve handle sits on a 4 px grid.
# H f height, s stem and bar width, h hook and crossbar height, R shoulder radius, k handle
# length / R (0.552 is a circle, Plex is squarer), e crossbar overhang left of the stem, ext
# hook reach right of the stem, g gap from hook to bar, xh crossbar top above the baseline.
P = dict(H=560, s=96, h=80, R=108, k=0.64, e=48, ext=80, g=64, xh=396)
MARK_W = P["e"] + P["s"] + P["ext"] + P["g"] + P["s"]   # 384
MARK_H = P["H"]                                          # 560


def _bezier(p0, p1, p2, p3, steps=48):
    return [
        (
            (1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0] + t ** 3 * p3[0],
            (1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1] + t ** 3 * p3[1],
        )
        for t in (i / steps for i in range(1, steps + 1))
    ]


def shapes(ox, oy, scale, notch=None):
    """The f as a polygon and the bar as a rectangle, with the mark's top-left at (ox, oy) and
    `scale` px per icon px. With `notch`, the crossbar stops that far short of the bar (the
    one-colour mark: fully joined, its silhouette reads as an H)."""
    s, e, R, k = P["s"], P["e"], P["R"], P["k"]
    T, B = 0, P["H"]
    a = e
    t = a + s + P["ext"]
    bx = t + P["g"]
    cbT = B - P["xh"]
    cbB = cbT + P["h"]
    xr = bx - notch if notch is not None else bx + s / 2
    pts = [(a, B), (a, cbB), (a - e, cbB), (a - e, cbT), (a, cbT), (a, T + R)]
    pts += _bezier((a, T + R), (a, T + R - k * R), (a + R - k * R, T), (a + R, T))
    pts += [(t, T), (t, T + P["h"]), (a + s, T + P["h"]), (a + s, cbT), (xr, cbT), (xr, cbB), (a + s, cbB), (a + s, B)]
    f = [(ox + x * scale, oy + y * scale) for x, y in pts]
    bar = (ox + bx * scale, oy + T * scale, ox + (bx + s) * scale, oy + B * scale)
    return f, bar


def draw_mark(img, cx, cy, height, fg=FG, accent=BLUE, notch=None):
    """The mark `height` px tall, its box centred at (cx, cy) and nudged a little left: the bar
    carries more weight than the f's open right side."""
    scale = height / MARK_H
    ox = cx - MARK_W * scale / 2 - 8 * scale
    oy = cy - MARK_H * scale / 2
    f, bar = shapes(ox, oy, scale, notch)
    d = ImageDraw.Draw(img)
    d.polygon(f, fill=fg)
    d.rectangle(bar, fill=accent)


def full_bleed(size):
    """iOS and the start screen: the whole square, no transparency (the system rounds it)."""
    W = size * S
    img = Image.new("RGBA", (W, W), BG)
    draw_mark(img, W / 2, W / 2, W * MARK_H / 1024)
    return img.resize((size, size), Image.LANCZOS).convert("RGB")


def tile(size, margin, radius_frac, shadow):
    """macOS, Windows and older Android: a dark rounded square inset by `margin` (fraction of
    size) on a transparent canvas."""
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    m = int(W * margin)
    bw = W - 2 * m
    r = int(bw * radius_frac)
    if shadow:
        sh = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        off = int(bw * 0.012)
        ImageDraw.Draw(sh).rounded_rectangle((m, m + off * 2, W - m, W - m + off * 2), r, fill=(0, 0, 0, 110))
        img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(bw * 0.02)))
    ImageDraw.Draw(img).rounded_rectangle(
        (m, m, W - m, W - m), r, fill=BG, outline=(44, 49, 58, 255), width=max(1, int(bw * 0.006))
    )
    draw_mark(img, W / 2, W / 2, bw * MARK_H / 1024)
    return img.resize((size, size), Image.LANCZOS)


def adaptive_layer(size, mono):
    """Android 8+: the mark alone on the 108 dp canvas, well inside the 66 dp safe circle.
    The monochrome layer (themed icons, Android 13+) is the one-colour mark in white."""
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    h = W * 0.37
    if mono:
        white = (255, 255, 255, 255)
        draw_mark(img, W / 2, W / 2, h, fg=white, accent=white, notch=24)
    else:
        draw_mark(img, W / 2, W / 2, h)
    return img.resize((size, size), Image.LANCZOS)


def main():
    mac = tile(1024, 0.0977, 0.225, True)
    for n in [16, 32, 64, 128, 256, 512, 1024]:
        mac.resize((n, n), Image.LANCZOS).save(
            f"{APP}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{n}.png")
    ios = full_bleed(1024)
    for name, n in [("20x20@1x", 20), ("20x20@2x", 40), ("20x20@3x", 60), ("29x29@1x", 29),
                    ("29x29@2x", 58), ("29x29@3x", 87), ("40x40@1x", 40), ("40x40@2x", 80),
                    ("40x40@3x", 120), ("60x60@2x", 120), ("60x60@3x", 180), ("76x76@1x", 76),
                    ("76x76@2x", 152), ("83.5x83.5@2x", 167), ("1024x1024@1x", 1024)]:
        ios.resize((n, n), Image.LANCZOS).save(
            f"{APP}/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-{name}.png")
    square = tile(1024, 0.06, 0.22, False)
    for d, n in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
        square.resize((n, n), Image.LANCZOS).save(
            f"{APP}/android/app/src/main/res/mipmap-{d}/ic_launcher.png")
    for d, n in [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]:
        adaptive_layer(n, False).save(f"{APP}/android/app/src/main/res/mipmap-{d}/ic_launcher_foreground.png")
        adaptive_layer(n, True).save(f"{APP}/android/app/src/main/res/mipmap-{d}/ic_launcher_monochrome.png")
    os.makedirs(f"{APP}/android/app/src/main/res/mipmap-anydpi-v26", exist_ok=True)
    with open(f"{APP}/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml", "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
            '</adaptive-icon>\n'
        )
    with open(f"{APP}/android/app/src/main/res/values/ic_launcher_background.xml", "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources>\n'
            '    <color name="ic_launcher_background">#16181D</color>\n'
            '</resources>\n'
        )
    # The mark on the start screen (56 pt at 1x, 2x and 3x); the screen rounds its corners.
    for folder, n in [("", 56), ("2.0x/", 112), ("3.0x/", 168)]:
        os.makedirs(f"{APP}/assets/brand/{folder}", exist_ok=True)
        ios.resize((n, n), Image.LANCZOS).save(f"{APP}/assets/brand/{folder}flomsi_mark.png")
    square.save(f"{APP}/windows/runner/resources/app_icon.ico",
                sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    # The website: the home-screen icon and the tab icon for browsers without SVG favicons.
    if os.path.isdir(SITE):
        ios.resize((180, 180), Image.LANCZOS).save(f"{SITE}/apple-touch-icon.png")
        tile(256, 0.0, 0.22, False).save(f"{SITE}/favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])


if __name__ == "__main__":
    main()
