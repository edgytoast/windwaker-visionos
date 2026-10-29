#!/usr/bin/env python3
# Draws Wind Waker VR's app icon layers (original art, needs Pillow), which make-app-icon.py packages:
#   visionos/scripts/draw-app-icon-layers.py <dir>
#   visionos/scripts/make-app-icon.py visionos/App/Assets.xcassets \
#       --back <dir>/Back.png --middle <dir>/Middle.png --front <dir>/Front.png
# A toon sky over an open sea (Back), a sun and curling clouds (Middle), and a small sailboat on a
# breaking wave (Front), in flat colours with dark outlines like Twilight Princess VR's icon. Drawn
# from scratch: no logos, box art, screenshots or anything from the game.
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 1024
BIG = 2  # supersampling for the outlined shapes
INK = (16, 22, 48, 255)
ORANGE = (232, 112, 52, 255)  # Trevorbilt's orange, on the sail


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def gradient(img, y0, y1, stops):
    px = img.load()
    for y in range(int(y0), int(y1)):
        t = min(1.0, max(0.0, (y - y0) / max(1, (y1 - y0 - 1))))
        for i in range(len(stops) - 1):
            if stops[i][0] <= t <= stops[i + 1][0]:
                u = (t - stops[i][0]) / max(1e-6, stops[i + 1][0] - stops[i][0])
                c = lerp(stops[i][1], stops[i + 1][1], u)
                break
        for x in range(S):
            px[x, y] = c


def canvas():
    return Image.new("RGBA", (S * BIG, S * BIG), (0, 0, 0, 0))


def down(img):
    return img.resize((S, S), Image.LANCZOS)


def P(x, y):
    return (x * BIG, y * BIG)


def shadowed(layer, strength=0.4, blur=14, offset=(0, 10)):
    shadow = Image.new("RGBA", (S, S), (8, 16, 48, 0))
    shadow.putalpha(layer.getchannel("A").point(lambda a: int(a * strength)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(shadow, offset, shadow)
    return Image.alpha_composite(out, layer)


horizon = S * 0.60

# Back: the sky, bright at the horizon, and the sea with flat wave crests.
back = Image.new("RGB", (S, S))
gradient(back, 0, horizon, [(0.0, (22, 70, 178)), (0.6, (58, 136, 230)), (1.0, (150, 214, 250))])
gradient(back, horizon, S, [(0.0, (34, 120, 214)), (0.25, (20, 86, 188)), (1.0, (10, 48, 132))])
crests = canvas()
cd = ImageDraw.Draw(crests)
rng = random.Random(11)
for _ in range(26):
    y = rng.uniform(horizon + 18, S * 0.97)
    depth = (y - horizon) / (S - horizon)
    x = rng.uniform(40, S - 40)
    w = 26 + 90 * depth
    h = 6 + 16 * depth
    cd.arc([P(x - w, y - h), P(x + w, y + h)], 200, 340, fill=(236, 248, 255, 230), width=int((3 + 7 * depth) * BIG))
cd.line([P(0, horizon), P(S, horizon)], fill=(220, 244, 255, 200), width=4 * BIG)
back = Image.alpha_composite(back.convert("RGBA"), down(crests)).convert("RGB")

# Middle: a toon sun with rings, and puffy clouds whose ends curl.
middle = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sun_glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(sun_glow)
sx, sy, sr = S * 0.70, S * 0.27, S * 0.105
for k in range(24, 0, -1):
    rr = sr * (1 + k * 0.06)
    gd.ellipse([sx - rr, sy - rr, sx + rr, sy + rr], fill=(255, 246, 200, int(4 + 2.4 * (24 - k))))
middle = Image.alpha_composite(middle, sun_glow.filter(ImageFilter.GaussianBlur(16)))
sun = canvas()
sd = ImageDraw.Draw(sun)
sd.ellipse([P(sx - sr * 1.32, sy - sr * 1.32), P(sx + sr * 1.32, sy + sr * 1.32)], outline=(255, 250, 220, 150),
           width=7 * BIG)
sd.ellipse([P(sx - sr, sy - sr), P(sx + sr, sy + sr)], fill=(255, 238, 150, 255), outline=(244, 176, 70, 255),
           width=6 * BIG)
sd.ellipse([P(sx - sr * 0.62, sy - sr * 0.62), P(sx + sr * 0.62, sy + sr * 0.62)], fill=(255, 250, 214, 255))
middle = Image.alpha_composite(middle, down(sun))


def curl(draw, cx, cy, r, turns, start, color, width):
    """A spiral that winds in: the curl at a cloud's end."""
    pts = []
    steps = int(60 * turns)
    for i in range(steps + 1):
        t = i / steps
        a = start + t * turns * 2 * math.pi
        rr = r * (1 - 0.82 * t)
        pts.append(P(cx + rr * math.cos(a), cy + rr * math.sin(a)))
    draw.line(pts, fill=color, width=width, joint="curve")


def cloud(layer, cx, cy, scale, flip=False):
    c = canvas()
    d = ImageDraw.Draw(c)
    puffs = [(-1.25, 0.18, 0.42), (-0.62, -0.18, 0.58), (0.12, -0.32, 0.70), (0.82, -0.08, 0.56), (1.3, 0.2, 0.38)]
    sign = -1 if flip else 1
    body = []
    for dx, dy, r in puffs:
        x, y, rr = cx + sign * dx * scale, cy + dy * scale, r * scale
        body.append((x, y, rr))
    base_y = cy + 0.34 * scale
    # Outline pass, then the fill, then the shading along the bottom.
    for x, y, rr in body:
        d.ellipse([P(x - rr - 7, y - rr - 7), P(x + rr + 7, y + rr + 7)], fill=INK)
    d.rounded_rectangle([P(cx - 1.55 * scale - 7, cy - 0.05 * scale), P(cx + 1.55 * scale + 7, base_y + 7)],
                        radius=int(0.3 * scale * BIG), fill=INK)
    for x, y, rr in body:
        d.ellipse([P(x - rr, y - rr), P(x + rr, y + rr)], fill=(255, 255, 255, 255))
    d.rounded_rectangle([P(cx - 1.55 * scale, cy - 0.05 * scale), P(cx + 1.55 * scale, base_y)],
                        radius=int(0.3 * scale * BIG), fill=(255, 255, 255, 255))
    d.rounded_rectangle([P(cx - 1.48 * scale, base_y - 0.16 * scale), P(cx + 1.48 * scale, base_y - 0.02 * scale)],
                        radius=int(0.08 * scale * BIG), fill=(196, 222, 248, 255))
    # The curls: one at the leading end, one tucked in the top puff.
    lead_x = cx + sign * 1.18 * scale
    curl(d, lead_x, cy + 0.12 * scale, 0.26 * scale, 1.3, math.pi if not flip else 0, (150, 190, 232, 255), 6 * BIG)
    curl(d, cx + sign * 0.15 * scale, cy - 0.34 * scale, 0.3 * scale, 1.2, math.pi * 0.9, (176, 206, 240, 255), 5 * BIG)
    return Image.alpha_composite(layer, down(c))


middle = cloud(middle, S * 0.30, S * 0.22, S * 0.105)
middle = cloud(middle, S * 0.80, S * 0.47, S * 0.075, flip=True)

# Front: a small sailboat on a breaking wave, heeled over in the wind.
F = canvas()
fd = ImageDraw.Draw(F)
bx, by = S * 0.50, S * 0.70  # the hull's waterline centre
# The sail: a full, curved triangle in orange with a light band.
mast_top, mast_x = S * 0.24, bx - S * 0.02
sail = [P(mast_x + 10, mast_top + 14)]
for i in range(1, 21):
    t = i / 20
    y = mast_top + 14 + (by - S * 0.075 - mast_top - 14) * t
    bulge = math.sin(t * math.pi) * S * 0.07
    x = mast_x + 10 + S * 0.215 * t + bulge
    sail.append(P(x, y))
sail.append(P(mast_x + 10, by - S * 0.075))
fd.polygon(sail, fill=ORANGE, outline=INK, width=9 * BIG)
band = [P(mast_x + 12, mast_top + S * 0.25)]
for i in range(0, 11):
    t = 0.5 + i * 0.03
    y = mast_top + 14 + (by - S * 0.075 - mast_top - 14) * t
    x = mast_x + 10 + S * 0.215 * t + math.sin(t * math.pi) * S * 0.07
    band.append(P(x - 10, y))
band.append(P(mast_x + 12, mast_top + S * 0.25 + S * 0.10))
fd.polygon(band, fill=(255, 196, 120, 255))
fd.line(sail + [sail[0]], fill=INK, width=9 * BIG, joint="curve")
# The mast and a small pennant.
fd.rounded_rectangle([P(mast_x - 7, mast_top - S * 0.05), P(mast_x + 7, by - S * 0.04)], radius=6 * BIG,
                     fill=(120, 74, 44, 255), outline=INK, width=6 * BIG)
fd.polygon([P(mast_x + 6, mast_top - S * 0.05), P(mast_x + S * 0.09, mast_top - S * 0.03),
            P(mast_x + 6, mast_top - S * 0.005)], fill=(255, 250, 236, 255), outline=INK, width=5 * BIG)
# The hull: a rounded wooden boat with a raised bow.
hull = [P(bx - S * 0.21, by - S * 0.06), P(bx + S * 0.17, by - S * 0.06), P(bx + S * 0.25, by - S * 0.115),
        P(bx + S * 0.215, by - S * 0.01), P(bx + S * 0.12, by + S * 0.05), P(bx - S * 0.15, by + S * 0.05),
        P(bx - S * 0.22, by - S * 0.01)]
fd.polygon(hull, fill=(150, 92, 52, 255), outline=INK, width=9 * BIG)
fd.line([P(bx - S * 0.205, by - S * 0.02), P(bx + S * 0.2, by - S * 0.02)], fill=(108, 64, 36, 255), width=6 * BIG)
fd.line([P(bx - S * 0.21, by - S * 0.06), P(bx + S * 0.17, by - S * 0.06), P(bx + S * 0.25, by - S * 0.115)],
        fill=(196, 132, 78, 255), width=7 * BIG)
# The wave it rides: a white crest curling over at the left.
wave = canvas()
wd = ImageDraw.Draw(wave)
wy = by + S * 0.02
body = [P(S * 0.0, S * 1.0), P(S * 0.0, wy + S * 0.03)]
for i in range(0, 41):
    x = S * 0.06 + (S * 0.94 - S * 0.06) * i / 40
    y = wy + S * 0.03 * math.sin(i / 40 * math.pi * 2.2 + 0.4)
    body.append(P(x, y))
body += [P(S * 1.0, wy + S * 0.03), P(S * 1.0, S * 1.0)]
wd.polygon(body, fill=(38, 132, 222, 255), outline=INK, width=8 * BIG)
crest = []
for i in range(0, 41):
    x = S * 0.06 + (S * 0.94 - S * 0.06) * i / 40
    y = wy + S * 0.03 * math.sin(i / 40 * math.pi * 2.2 + 0.4)
    crest.append(P(x, y))
wd.line(crest, fill=(244, 252, 255, 255), width=16 * BIG, joint="curve")
curl(wd, S * 0.20, wy - S * 0.035, S * 0.07, 1.25, math.pi * 0.15, (244, 252, 255, 255), 14 * BIG)
curl(wd, S * 0.20, wy - S * 0.035, S * 0.07, 1.25, math.pi * 0.15, INK, 4 * BIG)
for i in range(5):
    x = S * (0.30 + i * 0.13)
    y = wy + S * (0.10 + 0.05 * (i % 2))
    wd.arc([P(x - 34, y - 10), P(x + 34, y + 10)], 200, 340, fill=(200, 232, 255, 255), width=6 * BIG)
F = down(F).rotate(8, resample=Image.BICUBIC, center=(bx, by))
front = shadowed(F, 0.45, 14, (0, 12))
front = Image.alpha_composite(front, down(wave))
# Keep the front layer inside the circle visionOS shows (the wave's ends are clipped by it).
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).ellipse([S * 0.02, S * 0.02, S * 0.98, S * 0.98], fill=255)
front.putalpha(Image.composite(front.getchannel("A"), Image.new("L", (S, S), 0), mask))

out = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out, exist_ok=True)
back.save(os.path.join(out, "Back.png"))
middle.save(os.path.join(out, "Middle.png"))
front.save(os.path.join(out, "Front.png"))
comp = Image.alpha_composite(Image.alpha_composite(back.convert("RGBA"), middle), front)
circle = Image.new("L", (S, S), 0)
ImageDraw.Draw(circle).ellipse([0, 0, S, S], fill=255)
bg = Image.new("RGBA", (S, S), (40, 40, 40, 255))
bg.paste(comp, (0, 0), circle)
bg.resize((512, 512), Image.LANCZOS).save(os.path.join(out, "preview.png"))
print(os.path.join(out, "preview.png"))
