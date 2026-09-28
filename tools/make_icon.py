"""Draws the NXTPTT app icon: a cyan glass talk orb in a Tron ring over a light grid.

    python3 tools/make_icon.py

Writes the 1024 px icon into the iOS and watchOS asset catalogs. Needs Pillow.
The icon is opaque (App Store icons must have no alpha).
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 2  # supersample for smooth edges
N = S * SS
ROOT = Path(__file__).resolve().parent.parent
OUT = [
    ROOT / "App/iOS/Support/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    ROOT / "App/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
]

CYAN = (0, 229, 255)
ICE = (111, 246, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(stops):
    img = Image.new("RGB", (1, N))
    px = img.load()
    for y in range(N):
        t = y / (N - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                px[0, y] = lerp(c0, c1, (t - p0) / (p1 - p0))
                break
    return img.resize((N, N))


def radial(size, center, radius, color, alpha_max):
    """An RGBA layer with a soft radial glow."""
    layer = Image.new("RGBA", (size, size), color + (0,))
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    steps = 64
    for i in range(steps, 0, -1):
        r = radius * i / steps
        a = int(alpha_max * (1 - i / steps) ** 1.6)
        d.ellipse([center[0] - r, center[1] - r, center[0] + r, center[1] + r], fill=a)
    layer.putalpha(mask)
    return layer


def main():
    img = vertical_gradient([(0, (1, 16, 34)), (0.45, (2, 34, 58)), (0.7, (1, 24, 44)), (1, (0, 8, 18))]).convert("RGBA")

    # Aurora.
    img.alpha_composite(radial(N, (N * 0.2, N * 0.1), N * 0.8, (0, 190, 255), 110))
    img.alpha_composite(radial(N, (N * 0.9, N * 0.2), N * 0.6, (0, 255, 214), 55))

    # Perspective grid below the horizon.
    horizon = N * 0.64
    grid = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    g = ImageDraw.Draw(grid)
    floor = N - horizon
    for i in range(1, 13):
        z = i / 12
        y = horizon + floor * z ** 2.2
        g.line([(0, y), (N, y)], fill=CYAN + (int(40 + 150 * z),), width=3 * SS)
    cx = N / 2
    spread = N * 2.6
    for i in range(0, 14):
        x = cx - spread / 2 + spread * i / 13
        g.line([(cx, horizon), (x, N)], fill=CYAN + (120,), width=3 * SS)
    img.alpha_composite(grid)

    # Horizon glow.
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rectangle([0, horizon - 10 * SS, N, horizon + 10 * SS], fill=CYAN + (200,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(18 * SS)))
    ImageDraw.Draw(img).rectangle([0, horizon - 2 * SS, N, horizon + 2 * SS], fill=(220, 255, 255, 255))

    c = (N / 2, N * 0.47)
    orb_r = N * 0.25
    ring_r = N * 0.355

    # Halo behind the orb.
    img.alpha_composite(radial(N, c, ring_r * 1.25, CYAN, 170))

    # Identity-disc ring: dashed arcs with a glow.
    ring = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    box = [c[0] - ring_r, c[1] - ring_r, c[0] + ring_r, c[1] + ring_r]
    for start, length in [(-80, 110), (45, 30), (90, 80), (185, 20), (220, 95)]:
        rd.arc(box, start, start + length, fill=CYAN + (255,), width=14 * SS)
    tick_r = ring_r * 0.86
    for k in range(48):
        a = math.radians(k * 7.5)
        p0 = (c[0] + math.cos(a) * tick_r, c[1] + math.sin(a) * tick_r)
        p1 = (c[0] + math.cos(a) * (tick_r - 10 * SS), c[1] + math.sin(a) * (tick_r - 10 * SS))
        rd.line([p0, p1], fill=ICE + (150,), width=2 * SS)
    img.alpha_composite(ring.filter(ImageFilter.GaussianBlur(10 * SS)))
    img.alpha_composite(ring)

    # The glass orb: radial body, darker bottom, glossy top highlight.
    orb = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    od = ImageDraw.Draw(orb)
    colors = [(223, 254, 255), (110, 232, 255), (16, 179, 230), (7, 92, 138), (2, 34, 58)]
    hl = (c[0], c[1] - orb_r * 0.4)
    steps = 160
    for i in range(steps, 0, -1):
        t = i / steps
        seg = min(len(colors) - 2, int(t * (len(colors) - 1)))
        local = t * (len(colors) - 1) - seg
        col = lerp(colors[seg], colors[seg + 1], local)
        r = orb_r * 1.24 * t
        # Clip each disc to the orb circle by drawing it inside a mask afterwards.
        od.ellipse([hl[0] - r, hl[1] - r, hl[0] + r, hl[1] + r], fill=col + (255,))
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).ellipse([c[0] - orb_r, c[1] - orb_r, c[0] + orb_r, c[1] + orb_r], fill=255)
    orb.putalpha(mask)

    shade = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for i in range(100):
        y = c[1] + orb_r * i / 100
        sd.line([(0, y), (N, y)], fill=(0, 20, 48, int(120 * i / 100)))
    shade.putalpha(_mul(shade.getchannel("A"), mask))
    orb.alpha_composite(shade)

    gloss = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gw, gh = orb_r * 1.4, orb_r * 0.78
    top = c[1] - orb_r * 0.93
    for i in range(100):
        y = top + gh * i / 100
        gd.line([(0, y), (N, y)], fill=(255, 255, 255, int(235 - 200 * i / 100)))
    gmask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(gmask).ellipse([c[0] - gw / 2, top, c[0] + gw / 2, top + gh], fill=255)
    gloss.putalpha(_mul(gloss.getchannel("A"), gmask))
    orb.alpha_composite(gloss)

    # Rim.
    ImageDraw.Draw(orb).ellipse([c[0] - orb_r, c[1] - orb_r, c[0] + orb_r, c[1] + orb_r],
                                outline=(200, 250, 255, 230), width=5 * SS)

    # Drop shadow, then the orb.
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([c[0] - orb_r, c[1] - orb_r + 30 * SS, c[0] + orb_r, c[1] + orb_r + 30 * SS],
                                   fill=(0, 0, 0, 150))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28 * SS)))
    img.alpha_composite(orb)

    # Mic glyph in deep ink, drawn from primitives.
    ink = (2, 34, 56, 255)
    md = ImageDraw.Draw(img)
    mc = (c[0], c[1] + orb_r * 0.12)
    w, h = orb_r * 0.26, orb_r * 0.5
    md.rounded_rectangle([mc[0] - w / 2, mc[1] - h / 2 - orb_r * 0.12, mc[0] + w / 2, mc[1] + h / 2 - orb_r * 0.12],
                         radius=w / 2, fill=ink)
    cup_r = orb_r * 0.24
    cup_c = (mc[0], mc[1] - orb_r * 0.02)
    md.arc([cup_c[0] - cup_r, cup_c[1] - cup_r, cup_c[0] + cup_r, cup_c[1] + cup_r], 0, 180, fill=ink, width=9 * SS)
    md.line([(mc[0], cup_c[1] + cup_r), (mc[0], cup_c[1] + cup_r + orb_r * 0.12)], fill=ink, width=9 * SS)
    md.line([(mc[0] - orb_r * 0.12, cup_c[1] + cup_r + orb_r * 0.12), (mc[0] + orb_r * 0.12, cup_c[1] + cup_r + orb_r * 0.12)],
            fill=ink, width=9 * SS)

    final = img.convert("RGB").resize((S, S), Image.LANCZOS)
    for path in OUT:
        path.parent.mkdir(parents=True, exist_ok=True)
        final.save(path, "PNG", optimize=True)
        print("wrote", path.relative_to(ROOT))


def _mul(a, b):
    from PIL import ImageChops
    return ImageChops.multiply(a, b)


if __name__ == "__main__":
    main()
