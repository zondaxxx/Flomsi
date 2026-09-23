#!/usr/bin/env python3
"""The Flomsi app icon for every platform: a dark rounded square (the app's background),
an "f" in IBM Plex Mono and a blue block cursor, as in an editor. Needs Pillow.

    python3 scripts/make_icons.py
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
FONT = os.path.join(APP, "assets/fonts/IBMPlexMono-SemiBold.ttf")
BG = (22, 24, 29, 255)        # #16181D, the app's dark background
EDGE = (44, 49, 58, 255)      # hairline
FG = (215, 218, 224, 255)     # #D7DAE0
BLUE = (116, 173, 232, 255)   # #74ADE8
S = 4  # supersampling

def artwork(size, margin, radius_frac, shadow):
    """The icon on a transparent canvas of `size`: a dark rounded square inset by `margin`
    (fraction of size), an `f` and a block cursor."""
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    m = int(W * margin)
    body = (m, m, W - m, W - m)
    bw = W - 2 * m
    r = int(bw * radius_frac)
    if shadow:
        sh = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        d = ImageDraw.Draw(sh)
        off = int(bw * 0.012)
        d.rounded_rectangle((m, m + off * 2, W - m, W - m + off * 2), r, fill=(0, 0, 0, 110))
        sh = sh.filter(ImageFilter.GaussianBlur(bw * 0.02))
        img = Image.alpha_composite(img, sh)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(body, r, fill=BG, outline=EDGE, width=max(1, int(bw * 0.006)))
    glyph(img, body)
    return img.resize((size, size), Image.LANCZOS)

def glyph(img, body):
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = body
    bw = x1 - x0
    font = ImageFont.truetype(FONT, int(bw * 0.62))
    l, t, r_, b = font.getbbox("f")
    gw, gh = r_ - l, b - t
    cursor_w = int(bw * 0.17)
    gap = int(bw * 0.035)
    total = gw + gap + cursor_w
    gx = x0 + (bw - total) // 2 - l
    gy = y0 + (bw - gh) // 2 - t
    d.text((gx, gy), "f", font=font, fill=FG)
    # The block cursor: from the x-height to the baseline, like an editor's.
    base = gy + b
    xl, xt, xr, xb = font.getbbox("x")
    top = gy + xt
    cx = gx + r_ + gap
    d.rectangle((cx, top, cx + cursor_w, base), fill=BLUE)

def full_bleed(size):
    """iOS: the whole square, no transparency (the system rounds it)."""
    W = size * S
    img = Image.new("RGBA", (W, W), BG)
    glyph(img, (int(W * 0.06), int(W * 0.06), W - int(W * 0.06), W - int(W * 0.06)))
    return img.resize((size, size), Image.LANCZOS).convert("RGB")


def main():
    mac = artwork(1024, 0.0977, 0.225, True)
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
    square = artwork(1024, 0.06, 0.22, False)
    for d, n in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
        square.resize((n, n), Image.LANCZOS).save(
            f"{APP}/android/app/src/main/res/mipmap-{d}/ic_launcher.png")
    # Android 8+: an adaptive icon, the glyph on its own layer over the background colour,
    # inside the 72 dp safe zone of the 108 dp canvas.
    for d, n in [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]:
        W = n * S
        layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        inset = int(W * 0.19)
        glyph(layer, (inset, inset, W - inset, W - inset))
        layer.resize((n, n), Image.LANCZOS).save(
            f"{APP}/android/app/src/main/res/mipmap-{d}/ic_launcher_foreground.png")
    os.makedirs(f"{APP}/android/app/src/main/res/mipmap-anydpi-v26", exist_ok=True)
    with open(f"{APP}/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml", "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '</adaptive-icon>\n'
        )
    with open(f"{APP}/android/app/src/main/res/values/ic_launcher_background.xml", "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources>\n'
            '    <color name="ic_launcher_background">#16181D</color>\n'
            '</resources>\n'
        )
    # The mark on the start screen: 56 pt at 1x, 2x and 3x.
    mark = artwork(1024, 0.0, 0.22, False)
    for folder, n in [("", 56), ("2.0x/", 112), ("3.0x/", 168)]:
        os.makedirs(f"{APP}/assets/brand/{folder}", exist_ok=True)
        mark.resize((n, n), Image.LANCZOS).save(f"{APP}/assets/brand/{folder}flomsi_mark.png")
    square.save(f"{APP}/windows/runner/resources/app_icon.ico",
                sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])


if __name__ == "__main__":
    main()
