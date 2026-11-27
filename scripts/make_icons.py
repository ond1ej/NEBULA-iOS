#!/usr/bin/env python3
"""Render NEBULA's app icon (iOS + macOS asset catalogs) with Pillow — no external assets.

A deep violet → indigo field with a soft nebula glow and a four-point star. iOS gets a full-bleed square (the system
applies the mask); macOS gets the Big Sur style rounded square with a margin and a subtle shadow.

Run from the repository root (needs Pillow, for example in a virtual environment): python3 scripts/make_icons.py
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]  # the repository root (this file is scripts/make_icons.py)
S = 1024


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def field(size: int, dark: bool = False) -> Image.Image:
    top, bottom = ((24, 16, 52), (8, 6, 20)) if dark else ((116, 78, 255), (40, 22, 120))
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = min(1.0, (x * 0.35 + y * 0.9) / (size * 1.1))
            px[x, y] = lerp(top, bottom, t)
    return img


def glow(size: int, cx: float, cy: float, r: float, color, alpha: int) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*color, alpha))
    return layer.filter(ImageFilter.GaussianBlur(r * 0.45))


def star(size: int, cx: float, cy: float, r: float, color=(255, 255, 255, 255)) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    pts = []
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.2
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    d.polygon(pts, fill=color)
    return layer


def artwork(size: int = S, dark: bool = False) -> Image.Image:
    img = field(size, dark).convert("RGBA")
    for cx, cy, r, col, a in ((0.62, 0.38, 0.36, (190, 140, 255), 150), (0.36, 0.64, 0.30, (90, 120, 255), 120),
                              (0.5, 0.5, 0.18, (255, 210, 255), 110)):
        img = Image.alpha_composite(img, glow(size, cx * size, cy * size, r * size, col, a))
    halo = star(size, size * 0.5, size * 0.5, size * 0.36, (255, 255, 255, 140)).filter(ImageFilter.GaussianBlur(size * 0.03))
    img = Image.alpha_composite(img, halo)
    img = Image.alpha_composite(img, star(size, size * 0.5, size * 0.5, size * 0.33))
    img = Image.alpha_composite(img, star(size, size * 0.73, size * 0.27, size * 0.075, (255, 255, 255, 230)))
    img = Image.alpha_composite(img, star(size, size * 0.28, size * 0.74, size * 0.05, (255, 255, 255, 190)))
    return img


def squircle_mask(size: int, inset: float, radius: float) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return m


def mac_icon(base: Image.Image) -> Image.Image:
    size = base.size[0]
    inset = size * 0.098  # 824 px artwork on a 1024 canvas (macOS grid)
    mask = squircle_mask(size, inset, size * 0.185)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(ImageChops.multiply(mask, Image.new("L", (size, size), 90)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.02))
    out = Image.alpha_composite(out, ImageChops.offset(shadow, 0, int(size * 0.012)))
    art = base.copy()
    art.putalpha(mask)
    return Image.alpha_composite(out, art)


def main() -> int:
    ios = ROOT / "iOS/Assets.xcassets/AppIcon.appiconset"
    mac = ROOT / "macOS/Assets.xcassets/AppIcon.appiconset"
    for d in (ios, mac):
        d.mkdir(parents=True, exist_ok=True)
        (d.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
    light = artwork()
    light.convert("RGB").save(ios / "icon-1024.png")
    artwork(dark=True).convert("RGB").save(ios / "icon-1024-dark.png")
    tinted = light.convert("L").convert("RGB")
    tinted.save(ios / "icon-1024-tinted.png")
    (ios / "Contents.json").write_text(json.dumps({"images": [
        {"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "icon-1024-dark.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "icon-1024-tinted.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}, indent=2))
    big = mac_icon(light)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            big.resize((px, px), Image.LANCZOS).save(mac / name)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    (mac / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                                                  indent=2))
    # accent colour asset for both apps
    for base in (ROOT / "iOS/Assets.xcassets", ROOT / "macOS/Assets.xcassets"):
        ac = base / "AccentColor.colorset"
        ac.mkdir(exist_ok=True)
        (ac / "Contents.json").write_text(json.dumps({"colors": [
            {"color": {"color-space": "srgb", "components": {"red": "0x6D", "green": "0x4A", "blue": "0xFF", "alpha": "1.000"}},
             "idiom": "universal"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "color": {"color-space": "srgb", "components": {"red": "0x9B", "green": "0x87", "blue": "0xFF", "alpha": "1.000"}},
             "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2))
    print("icons written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
