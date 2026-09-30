"""Generate painterly, hand-painted style textures for OpenRail assets.

Run with:  blender -b --factory-startup --python tools/make_textures.py
Outputs PNGs into source/textures/. Every texture tiles seamlessly except
the single-use ones (window, door, clock, terrain).
Image "up" (v) always corresponds to world up for wall textures.
"""
import math
import os

import bpy
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "source", "textures")
os.makedirs(OUT, exist_ok=True)
N = 512


def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


def vnoise(n, cells, rng):
    g = rng.random((cells, cells))
    t = np.arange(n) * cells / n
    i0 = np.floor(t).astype(int)
    f = t - i0
    f = f * f * (3 - 2 * f)
    i1 = (i0 + 1) % cells
    a = g[i0][:, i0] * (1 - f)[None, :] + g[i0][:, i1] * f[None, :]
    b = g[i1][:, i0] * (1 - f)[None, :] + g[i1][:, i1] * f[None, :]
    return a * (1 - f)[:, None] + b * f[:, None]


def fbm(n, rng, base=4, octaves=4):
    s = np.zeros((n, n))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        s += amp * vnoise(n, base * 2 ** o, rng)
        tot += amp
        amp *= 0.5
    s /= tot
    return (s - s.min()) / (s.max() - s.min() + 1e-9)


def ramp(t, cols):
    cols = [hexc(c) if isinstance(c, str) else c for c in cols]
    stops = np.linspace(0, 1, len(cols))
    out = np.zeros(t.shape + (3,))
    for ch in range(3):
        out[..., ch] = np.interp(t, stops, [c[ch] for c in cols])
    return out


def ramp1(t, cols):
    return ramp(np.array([t]), cols)[0]


def stroke(img, cx, cy, L, W, ang, col, alpha, rng, bristle=True):
    n = img.shape[0]
    R = int(max(L, W) / 2) + 2
    r = np.arange(-R, R + 1)
    X, Y = np.meshgrid(r, r)
    c, s = math.cos(ang), math.sin(ang)
    u = X * c + Y * s
    v = -X * s + Y * c
    m = np.clip(1 - (2 * u / L) ** 4, 0, 1) * np.clip(1 - (2 * v / W) ** 2, 0, 1)
    if bristle:
        m *= 0.72 + 0.28 * np.sin(v * (7.0 / max(W, 1)) * math.pi + rng.random() * 6.28)
    # dry-brush tail: stroke gets thinner towards its end
    m *= np.clip(0.55 + 0.9 * (0.5 - u / L), 0, 1)
    m = np.clip(m * 1.8, 0, 1) * alpha
    iy = (int(cy) + r) % n
    ix = (int(cx) + r) % n
    idx = np.ix_(iy, ix)
    sub = img[idx]
    img[idx] = sub * (1 - m[..., None]) + np.asarray(col)[None, None, :] * m[..., None]


def jitter(col, rng, amt=0.03):
    return np.clip(col + rng.normal(0, amt, 3), 0, 1)


def painted(rng, cols, strokes=2500, L=(18, 60), W=(5, 14), ang=0.0, ang_j=0.25,
            base=2, alpha=(0.25, 0.6), n=N, t_spread=0.15):
    t = 0.2 + 0.6 * fbm(n, rng, base=base, octaves=3)  # calm, low-contrast underpainting
    img = ramp(t, cols)
    for _ in range(strokes):
        x, y = rng.random() * n, rng.random() * n
        tv = np.clip(t[int(y) % n, int(x) % n] + rng.normal(0, t_spread), 0, 1)
        col = jitter(ramp1(tv, cols), rng)
        stroke(img, x, y, rng.uniform(*L), rng.uniform(*W),
               ang + rng.normal(0, ang_j), col, rng.uniform(*alpha), rng)
    return img


def hline(img, y, x0, x1, w, col, alpha, rng, wobble=1.5):
    n = img.shape[0]
    x = x0
    while x < x1:
        seg = rng.uniform(20, 40)
        stroke(img, x + seg / 2, y + rng.normal(0, wobble), seg * 1.3, w, rng.normal(0, 0.02),
               jitter(col, rng, 0.02), alpha, rng, bristle=False)
        x += seg


def vline(img, x, y0, y1, w, col, alpha, rng, wobble=1.5):
    y = y0
    while y < y1:
        seg = rng.uniform(20, 40)
        stroke(img, x + rng.normal(0, wobble), y + seg / 2, seg * 1.3, w, math.pi / 2 + rng.normal(0, 0.02),
               jitter(col, rng, 0.02), alpha, rng, bristle=False)
        y += seg


def dot(img, x, y, rad, col, alpha, rng):
    stroke(img, x, y, rad * 2, rad * 2, 0, col, alpha, rng, bristle=False)


def rect(img, x0, y0, x1, y1, col, rng, amt=0.06):
    """Fill a rectangle with a slightly mottled flat colour (no wrapping)."""
    x0, y0, x1, y1 = (int(max(0, v)) for v in (x0, y0, x1, y1))
    h, w = img[y0:y1, x0:x1].shape[:2]
    if h <= 0 or w <= 0:
        return
    m = fbm(64, rng, base=4)[:h % 64 or 64, :w % 64 or 64]
    m = np.resize(m, (h, w))[..., None] - 0.5
    img[y0:y1, x0:x1] = np.clip(np.asarray(col)[None, None, :] * (1 + m * amt * 4), 0, 1)


def save(name, img):
    n = img.shape[0]
    im = bpy.data.images.new(name, n, n, alpha=False)
    rgba = np.ones((n, n, 4), dtype=np.float32)
    rgba[..., :3] = np.clip(img, 0, 1)
    im.pixels.foreach_set(rgba.ravel())
    im.filepath_raw = os.path.join(OUT, name + ".png")
    im.file_format = "PNG"
    im.save()
    print("saved", name)


# ---------------------------------------------------------------- materials

def metal_paint(seed, cols, panel=256, rivets=True, line_col="#10181c", hi_col=None):
    rng = np.random.default_rng(seed)
    img = painted(rng, cols, strokes=1100, L=(70, 180), W=(16, 34), ang=0.0, ang_j=0.06)
    hi = hexc(hi_col or cols[-1])
    dark = hexc(line_col)
    for x in range(0, N, panel):
        vline(img, x, 0, N, 3.5, dark, 0.85, rng)
        vline(img, x + 4, 0, N, 2.0, hi, 0.5, rng)
        if rivets:
            for y in range(12, N, 32):
                for ox in (-10, 14):
                    dot(img, x + ox + 1, y - 1, 3.2, dark, 0.7, rng)
                    dot(img, x + ox, y, 2.6, jitter(hi, rng), 0.9, rng)
    # worn edges / scratches in the lightest paint colour
    for _ in range(20):
        stroke(img, rng.random() * N, rng.random() * N, rng.uniform(6, 22), rng.uniform(1.5, 3),
               rng.normal(0, 0.4), jitter(hexc(cols[-1]), rng), 0.45, rng, bristle=False)
    return img


def plain_metal(seed, cols, highlight=None, dabs=40):
    rng = np.random.default_rng(seed)
    img = painted(rng, cols, strokes=1400, L=(50, 130), W=(14, 30), ang=0.0, ang_j=0.35)
    if highlight:
        h = hexc(highlight)
        for _ in range(dabs):
            stroke(img, rng.random() * N, rng.random() * N, rng.uniform(10, 30), rng.uniform(3, 6),
                   rng.normal(0, 0.3), jitter(h, rng), 0.8, rng)
    return img


def planks(seed, cols, plank=64, gap="#16080c", grain_dir=math.pi / 2):
    rng = np.random.default_rng(seed)
    t = fbm(N, rng, base=3)
    img = ramp(t, cols)
    for x0 in range(0, N, plank):
        shift = rng.normal(0, 0.12)
        for _ in range(150):
            x = x0 + rng.uniform(4, plank - 4)
            y = rng.random() * N
            tv = np.clip(t[int(y) % N, int(x) % N] + shift + rng.normal(0, 0.2), 0, 1)
            stroke(img, x, y, rng.uniform(100, 240), rng.uniform(4, 9), grain_dir + rng.normal(0, 0.03),
                   jitter(ramp1(tv, cols), rng), rng.uniform(0.3, 0.6), rng)
        # knots
        for _ in range(rng.integers(0, 3)):
            x, y = x0 + rng.uniform(15, plank - 15), rng.random() * N
            dot(img, x, y, rng.uniform(4, 7), hexc(cols[0]), 0.8, rng)
    g = hexc(gap)
    for x0 in range(0, N, plank):
        vline(img, x0, 0, N, 4, g, 0.9, rng)
        vline(img, x0 + 4, 0, N, 2, hexc(cols[-1]), 0.45, rng)
    return img


def bricks(seed, cols, mortar=("#5e5048", "#8c7a66", "#b3a08a"), bw=64, bh=24):
    rng = np.random.default_rng(seed)
    img = painted(rng, list(mortar), strokes=600, L=(10, 30), W=(4, 8), ang_j=1.0)
    rows = N // bh
    for r in range(rows):
        off = (bw // 2) * (r % 2)
        for c in range(N // bw):
            tv = rng.random()
            base = jitter(ramp1(tv, cols), rng, 0.04)
            x0, y0 = c * bw + off + 3, r * bh + 3
            rect(img, x0, y0, x0 + bw - 6, y0 + bh - 5, base, rng)
            for _ in range(10):
                stroke(img, x0 + rng.uniform(6, bw - 12), y0 + rng.uniform(4, bh - 10), rng.uniform(16, 34),
                       rng.uniform(6, 10), rng.normal(0, 0.1),
                       jitter(ramp1(np.clip(tv + rng.normal(0, 0.18), 0, 1), cols), rng), 0.85, rng)
            # top highlight and bottom shadow of the brick
            hline(img, y0 + bh - 7, x0 + 2, x0 + bw - 10, 2.2, hexc(cols[-1]), 0.45, rng, 0.5)
            hline(img, y0 + 1, x0 + 2, x0 + bw - 10, 2.5, hexc(cols[0]), 0.5, rng, 0.5)
    return img


def tiles(seed, cols, tw=64, th=40):
    rng = np.random.default_rng(seed)
    img = painted(rng, cols, strokes=900, L=(40, 100), W=(10, 20), ang=0.0, ang_j=0.2)
    rows = N // th
    dark, light = hexc(cols[0]) * 0.7, hexc(cols[-1])
    for r in range(rows):
        y = r * th
        hline(img, y + 2, 0, N, 5, dark, 0.8, rng, 0.8)  # shadow under the tile above
        hline(img, y + 7, 0, N, 2, light, 0.35, rng, 0.8)
        off = (tw // 2) * (r % 2)
        for c in range(N // tw + 1):
            x = c * tw + off
            vline(img, x, y + 3, y + th - 2, 2.5, dark, 0.6, rng, 0.6)
    return img


def paving(seed, cols, slab=128):
    rng = np.random.default_rng(seed)
    img = painted(rng, cols, strokes=1000, L=(30, 80), W=(12, 24), ang_j=1.2)
    dark = hexc(cols[0]) * 0.75
    for i in range(0, N, slab):
        hline(img, i, 0, N, 3.5, dark, 0.8, rng)
        vline(img, i + (slab // 2 if (i // slab) % 2 else 0), 0, N, 3.5, dark, 0.0, rng)
    for r in range(N // slab):
        off = slab // 2 * (r % 2)
        for c in range(N // slab + 1):
            vline(img, c * slab + off, r * slab + 2, (r + 1) * slab - 2, 3.5, dark, 0.8, rng)
    # cracks
    for _ in range(12):
        x, y = rng.random() * N, rng.random() * N
        a = rng.random() * 6.28
        for _ in range(5):
            stroke(img, x, y, 14, 1.8, a, dark, 0.7, rng, bristle=False)
            x += 6 * math.cos(a)
            y += 6 * math.sin(a)
            a += rng.normal(0, 0.6)
    return img


def dabs(seed, cols, n=2200, size=(14, 34), warm="#e8d879", warm_n=150):
    rng = np.random.default_rng(seed)
    t = fbm(N, rng, base=4)
    img = ramp(t * 0.8, cols)
    for _ in range(n):
        x, y = rng.random() * N, rng.random() * N
        tv = np.clip(t[int(y) % N, int(x) % N] + rng.normal(0, 0.25), 0, 1)
        s = rng.uniform(*size)
        stroke(img, x, y, s * rng.uniform(1.0, 1.6), s, rng.random() * 3.14, jitter(ramp1(tv, cols), rng),
               rng.uniform(0.5, 0.9), rng)
    w = hexc(warm)
    for _ in range(warm_n):
        s = rng.uniform(4, 10)
        stroke(img, rng.random() * N, rng.random() * N, s * 1.4, s, rng.random() * 3.14, jitter(w, rng), 0.6, rng)
    return img


def window(seed):
    rng = np.random.default_rng(seed)
    n = N
    yy, xx = np.mgrid[0:n, 0:n] / n
    glass = ramp(np.clip(yy * 0.8 + 0.1 * fbm(n, rng, 3), 0, 1), ["#12222c", "#23485a", "#4a8294"])
    img = glass
    # warm interior glow at the bottom
    glow = np.clip(1 - yy * 2.2, 0, 1)[..., None] * 0.35
    img = img * (1 - glow) + hexc("#e0a14a") * glow
    # diagonal reflection streaks
    for k, (off, w) in enumerate([(0.25, 40), (0.45, 16)]):
        for _ in range(60):
            p = rng.random()
            x = (off + p * 0.6) * n
            y = (1 - p) * n * 0.9 + rng.normal(0, 8)
            stroke(img, x, y, rng.uniform(30, 60), w * rng.uniform(0.6, 1.0), -0.9, hexc("#cfe8e6"), 0.12, rng)
    frame = ["#1b2e2c", "#2f5a52", "#5e9a86"]
    fw = 34
    def band(x0, y0, x1, y1, horizontal):
        rect(img, x0, y0, x1, y1, hexc(frame[1]), rng)
        for _ in range(int((x1 - x0) * (y1 - y0) / 400) + 4):
            x, y = rng.uniform(x0 + 6, x1 - 6), rng.uniform(y0 + 6, y1 - 6)
            L = rng.uniform(20, 50)
            stroke(img, x, y, L, min(y1 - y0, x1 - x0, 14) * 0.7,
                   0 if horizontal else math.pi / 2, jitter(ramp1(rng.uniform(0.2, 1), frame), rng), 0.6, rng)
    band(0, 0, n, fw, True)
    band(0, n - fw, n, n, True)
    band(0, 0, fw, n, False)
    band(n - fw, 0, n, n, False)
    band(n / 2 - 10, 0, n / 2 + 10, n, False)
    band(0, n * 0.6 - 10, n, n * 0.6 + 10, True)
    return img


def door(seed):
    rng = np.random.default_rng(seed)
    img = planks(seed, ["#2a160e", "#5a3420", "#94603a"], plank=85, gap="#140a06")
    # small window at the top
    win = window(seed + 1)
    y0, y1, x0, x1 = int(N * 0.68), int(N * 0.9), int(N * 0.22), int(N * 0.78)
    sub = win[::max(1, N // (y1 - y0))][: y1 - y0, ::max(1, N // (x1 - x0))][:, : x1 - x0]
    img[y0:y0 + sub.shape[0], x0:x0 + sub.shape[1]] = sub
    frame = hexc("#2f5a52")
    for y in (y0, y0 + sub.shape[0]):
        hline(img, y, x0 - 6, x0 + sub.shape[1] + 6, 12, frame, 0.95, rng, 0.5)
    for x in (x0, x0 + sub.shape[1]):
        vline(img, x, y0 - 6, y0 + sub.shape[0] + 6, 12, frame, 0.95, rng, 0.5)
    # brass handle
    dot(img, N * 0.8, N * 0.45, 10, hexc("#6b4a1e"), 1, rng)
    dot(img, N * 0.8 - 2, N * 0.45 + 2, 7, hexc("#f2d27a"), 1, rng)
    # frame around the door
    fr = ["#1b2e2c", "#2f5a52", "#5e9a86"]
    for x in (8, N - 8):
        for y in range(0, N, 30):
            stroke(img, x, y + 15, 40, 18, math.pi / 2, jitter(ramp1(rng.random(), fr), rng), 0.95, rng)
    for y in range(0, N, 30):
        stroke(img, y + 15, N - 8, 40, 18, 0, jitter(ramp1(rng.random(), fr), rng), 0.95, rng)
    return img


def clock(seed):
    rng = np.random.default_rng(seed)
    n = N
    img = ramp(fbm(n, rng, 3) * 0.6 + 0.3, ["#b89a6a", "#eadcb8", "#fff6dc"])
    c = n / 2
    ink = hexc("#241a24")
    for i in range(12):
        a = i / 12 * 2 * math.pi
        L = 36 if i % 3 == 0 else 20
        r = c * 0.8
        stroke(img, c + r * math.sin(a), c + r * math.cos(a), L, 10 if i % 3 == 0 else 6,
               math.pi / 2 - a, ink, 0.95, rng, bristle=False)
    # hands: 10:10
    for a, L, W in ((-2 * math.pi / 12 * 2 + 0.0, c * 0.5, 14), (2 * math.pi / 12 * 2, c * 0.72, 9)):
        ang = math.pi / 2 - a
        stroke(img, c + math.cos(ang) * L / 2, c + math.sin(ang) * L / 2, L, W, ang, ink, 1, rng, bristle=False)
    dot(img, c, c, 14, hexc("#b8862f"), 1, rng)
    return img


def terrain(seed, n=1024):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:n, 0:n] / n
    t = fbm(n, rng, base=4, octaves=5)
    grass_cols = ["#203a26", "#3b6634", "#6f9a44", "#b7c660"]
    dirt_cols = ["#3e2a22", "#74503a", "#b08058", "#d8b284"]
    img = ramp(t, grass_cols)
    center = 0.5 + 0.14 * np.sin(yy * 2 * math.pi * 1.0 + 0.6) + 0.04 * np.sin(yy * 2 * math.pi * 3.0)
    d = np.abs(xx - center) + (fbm(n, rng, base=8) - 0.5) * 0.04
    path = np.clip((0.06 - d) / 0.02, 0, 1)
    img = img * (1 - path[..., None]) + ramp(t, dirt_cols) * path[..., None]
    for _ in range(26000):
        x, y = rng.random() * n, rng.random() * n
        p = path[int(y), int(x)]
        tv = np.clip(t[int(y), int(x)] + rng.normal(0, 0.22), 0, 1)
        if p > 0.5:
            col = jitter(ramp1(tv, dirt_cols), rng)
            stroke(img, x, y, rng.uniform(10, 28), rng.uniform(4, 9), rng.normal(math.pi / 2, 0.4), col,
                   rng.uniform(0.4, 0.8), rng)
        else:
            col = jitter(ramp1(tv, grass_cols), rng)
            stroke(img, x, y, rng.uniform(8, 22), rng.uniform(3, 7), rng.normal(math.pi / 2, 0.6), col,
                   rng.uniform(0.4, 0.85), rng)
    for _ in range(900):  # flower / light flecks
        x, y = rng.random() * n, rng.random() * n
        if path[int(y), int(x)] < 0.2:
            col = hexc(["#f0e08a", "#e6a0b4", "#fff4d0"][rng.integers(0, 3)])
            dot(img, x, y, rng.uniform(1.5, 3), col, 0.9, rng)
    return img


def make_all():
    T = {}
    T["loco_teal"] = metal_paint(1, ["#1f4a48", "#2c6964", "#3f8579", "#6fae98"], hi_col="#b8862f")
    T["stone_cream"] = bricks(21, ["#cdb58e", "#d8c29c", "#e2cfab", "#ebdbba"],
                              mortar=("#8a7a66", "#a8977e", "#c2b196"), bw=128, bh=64)
    T["metal_dark"] = plain_metal(2, ["#101117", "#23242e", "#3e4050", "#5c5f73"], highlight="#7a7f9a")
    T["brass"] = plain_metal(3, ["#4a3012", "#8e6424", "#c9973a", "#f2d27a"], highlight="#fff0b8", dabs=80)
    T["red_paint"] = plain_metal(4, ["#3a0c12", "#7e1f24", "#b8392e", "#e0704e"], highlight="#f0a070")
    T["wood_wagon"] = planks(5, ["#2e0f18", "#63202e", "#96403e", "#c46a52"])
    T["wood_brown"] = planks(6, ["#2a160e", "#5a3420", "#94603a", "#c48a58"], plank=96)
    T["roof_slate"] = tiles(7, ["#3a4966", "#40506e", "#475878", "#566a8c"])
    T["roof_verdigris"] = metal_paint(8, ["#2f6e66", "#357870", "#3c8277", "#4a9082"], panel=128,
                                       rivets=False, line_col="#0e2224")
    T["brick"] = bricks(9, ["#4a1a14", "#7e2e20", "#a8503a", "#d07a58"])
    T["plaster"] = painted(np.random.default_rng(10), ["#7a5a34", "#b48a52", "#dcb878", "#f4dca8"],
                           strokes=1200, L=(50, 140), W=(18, 40), ang_j=1.4, t_spread=0.12)
    T["stone_paving"] = paving(11, ["#3e3c46", "#67646e", "#96918c", "#c4bba8"])
    T["stone"] = painted(np.random.default_rng(12), ["#2e2c36", "#58566a", "#8c8894", "#c2baa8"],
                         strokes=1300, L=(30, 90), W=(14, 30), ang_j=1.4)
    T["bark"] = painted(np.random.default_rng(13), ["#1e1210", "#422a20", "#6e4a34", "#9c7250"],
                        strokes=1800, L=(90, 220), W=(6, 14), ang=math.pi / 2, ang_j=0.06)
    T["leaves"] = dabs(14, ["#3c763a", "#42803f", "#4a8a44", "#56964a"], warm_n=0)
    T["leaves_conifer"] = dabs(15, ["#0f2622", "#1f4a3c", "#3a7458", "#79a878"], size=(5, 12),
                               warm="#b8d890", warm_n=80)
    T["coal"] = plain_metal(16, ["#07070a", "#16161c", "#2c2c38", "#4a4a5c"], highlight="#6a6a86", dabs=120)
    T["window"] = window(17)
    T["door"] = door(18)
    T["clock_face"] = clock(19)
    for k, v in T.items():
        save(k, v)
    save("terrain_grass", terrain(20))


make_all()
