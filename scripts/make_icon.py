#!/usr/bin/env python3
"""Generates Stack's app icon (AppIcon.icns + PNGs) and the DMG background.

Pure numpy/Pillow, signed-distance-field rendering for crisp anti-aliased edges.
Run: python3 scripts/make_icon.py
"""
import os
import numpy as np
from PIL import Image, ImageFilter, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
S = 1024


def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])


# ---------------------------------------------------------------- canvas utils
class Canvas:
    def __init__(self, size=S):
        self.rgb = np.zeros((size, size, 3))
        self.a = np.zeros((size, size))
        self.size = size

    def paint(self, alpha, color):
        """Composite `color` (rgb tuple or HxWx3 array) with coverage `alpha` over the canvas."""
        alpha = np.clip(alpha, 0, 1)
        col = color if isinstance(color, np.ndarray) and color.ndim == 3 else np.broadcast_to(color, self.rgb.shape)
        out_a = alpha + self.a * (1 - alpha)
        safe = np.where(out_a > 1e-6, out_a, 1)
        self.rgb = (col * alpha[..., None] + self.rgb * (self.a * (1 - alpha))[..., None]) / safe[..., None]
        self.a = out_a

    def image(self):
        arr = np.dstack([self.rgb, self.a])
        return Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


yy, xx = np.mgrid[0:S, 0:S].astype(float) + 0.5


def cov(d):
    """Signed distance (px) -> anti-aliased coverage."""
    return np.clip(0.5 - d, 0, 1)


def sd_squircle(cx, cy, half, r=186.0, n=2.6):
    """Rounded square with smooth ("continuous") corners: superellipse-blended corner arcs."""
    qx = np.abs(xx - cx) - (half - r)
    qy = np.abs(yy - cy) - (half - r)
    ox, oy = np.maximum(qx, 0) / r, np.maximum(qy, 0) / r
    outside = (ox ** n + oy ** n) ** (1 / n) * r
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - r


def sd_rhombus(cx, cy, bx, by, r=0.0):
    """Rounded rhombus (iq). bx/by are half extents of the *final* shape."""
    bx, by = bx - r * 1.2, by - r * 0.7
    px = np.abs(xx - cx)
    py = np.abs(yy - cy)
    b = np.array([bx, by])
    ndot = (b[0] - 2 * px) * b[0] - (b[1] - 2 * py) * b[1]
    h = np.clip(ndot / (b @ b), -1, 1)
    qx = px - 0.5 * bx * (1 - h)
    qy = py - 0.5 * by * (1 + h)
    d = np.sqrt(qx * qx + qy * qy) * np.sign(px * by + py * bx - bx * by)
    return d - r


def blur(alpha, radius):
    img = Image.fromarray((np.clip(alpha, 0, 1) * 255).astype(np.uint8), "L")
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), dtype=float) / 255


def lin_grad(c1, c2, x0, y0, x1, y1):
    dx, dy = x1 - x0, y1 - y0
    t = ((xx - x0) * dx + (yy - y0) * dy) / (dx * dx + dy * dy)
    t = np.clip(t, 0, 1)[..., None]
    return hexc(c1) * (1 - t) + hexc(c2) * t


# ---------------------------------------------------------------- icon
def slab(cv, cx, cy, w, h, t, r, top_a, top_b, left, right, shadow=0.45, tiles=None):
    # soft shadow under the slab
    sh = cov(sd_rhombus(cx, cy + t + 22, w * 1.02, h * 1.02, r))
    cv.paint(blur(sh, 18) * shadow, hexc("#0B0820"))
    # extruded body (Minkowski sum with a vertical segment)
    body = np.full((S, S), 1e9)
    for k in np.linspace(0, t, int(t) + 1):
        body = np.minimum(body, sd_rhombus(cx, cy + k, w, h, r))
    side_col = np.where((xx < cx)[..., None], hexc(left), hexc(right))
    cv.paint(cov(body), side_col)
    # thin lighter edge between the two side faces
    edge = np.clip(1 - np.abs(xx - cx) / 1.2, 0, 1) * cov(body) * (yy > cy)
    cv.paint(edge * 0.35, hexc("#FFFFFF"))
    # top face
    top = sd_rhombus(cx, cy, w, h, r)
    cv.paint(cov(top), lin_grad(top_a, top_b, cx, cy - h, cx, cy + h))
    # rim light on the top face
    rim = cov(top) * np.clip(1 - np.abs(top + 3) / 2.5, 0, 1) * (yy < cy)
    cv.paint(rim * 0.55, hexc("#FFFFFF"))
    if tiles:
        L = np.array([cx - w, cy])
        A = np.array([w, -h])
        B = np.array([w, h])
        k = 0
        for i in range(2):
            for j in range(2):
                c = L + (i + 0.5) / 2 * A + (j + 0.5) / 2 * B
                ta, tb = tiles[k]
                k += 1
                tw, th = w / 2 * 0.70, h / 2 * 0.70
                depth = 9
                tb_body = np.full((S, S), 1e9)
                for kk in np.linspace(0, depth, depth + 1):
                    tb_body = np.minimum(tb_body, sd_rhombus(c[0], c[1] + kk - depth, tw, th, 11))
                cv.paint(cov(tb_body), hexc(tb))
                tt = sd_rhombus(c[0], c[1] - depth, tw, th, 11)
                cv.paint(cov(tt), lin_grad(ta, tb, c[0], c[1] - depth - th, c[0], c[1] - depth + th))
                gl = cov(tt) * np.clip(1 - np.abs(tt + 2.5) / 2, 0, 1) * (yy < c[1] - depth)
                cv.paint(gl * 0.6, hexc("#FFFFFF"))


def make_icon():
    cv = Canvas()
    C, HALF = 512, 412

    # drop shadow of the whole tile
    base = sd_squircle(C, C + 14, HALF)
    cv.paint(blur(cov(base), 22) * 0.38, hexc("#000000"))

    sq = sd_squircle(C, C, HALF)
    m = cov(sq)
    bg = lin_grad("#2A2466", "#120F2E", C - 300, 100, C + 300, 924)
    cv.paint(m, bg)
    # glow behind the stack
    d = np.sqrt((xx - C) ** 2 + (yy - 560) ** 2)
    glow = np.clip(1 - d / 420, 0, 1) ** 1.8
    cv.paint(m * glow * 0.85, hexc("#7C4DFF"))
    glow2 = np.clip(1 - np.sqrt((xx - 700) ** 2 + (yy - 780) ** 2) / 380, 0, 1) ** 2
    cv.paint(m * glow2 * 0.42, hexc("#FF4FA3"))
    # top sheen
    sheen = np.clip(1 - (yy - 100) / 420, 0, 1) ** 2
    cv.paint(m * sheen * 0.10, hexc("#FFFFFF"))

    w, h, t, r = 262, 262 * 0.58, 34, 30
    slab(cv, C, 590, w, h, t, r, "#FF9ACB", "#F0569E", "#E0408A", "#B82C6E", shadow=0.55)
    slab(cv, C, 494, w, h, t, r, "#C9B8FF", "#9E7BFF", "#8458F5", "#6737DB", shadow=0.5)
    slab(cv, C, 398, w, h, t, r, "#FFFFFF", "#E9E4FF", "#D3CBFA", "#B7ACF0", shadow=0.45,
         tiles=[("#FFC24D", "#FF8A00"), ("#5CE68A", "#1FB85A"), ("#5FB3FF", "#0A6CFF"), ("#FF7A93", "#FF2D55")])

    # subtle inner border
    border = m * np.clip(1 - np.abs(sq + 1.5) / 1.5, 0, 1)
    cv.paint(border * 0.16, hexc("#FFFFFF"))
    return cv.image()


def save_icns(img, path):
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    img.save(path, format="ICNS", append_images=[img.resize((s, s), Image.LANCZOS) for s in sizes])


# ---------------------------------------------------------------- DMG background
def make_dmg_background(scale):
    W, H = 640 * scale, 400 * scale
    y, x = np.mgrid[0:H, 0:W].astype(float)
    top, bot = hexc("#F6F4FF"), hexc("#E9E5FB")
    t = (y / H)[..., None]
    rgb = top * (1 - t) + bot * t
    # soft colored blobs
    for (bx, by, rad, col, a) in [(0.18, 0.1, 0.55, "#C9B8FF", 0.35), (0.9, 0.95, 0.6, "#FFB3D6", 0.3)]:
        d = np.sqrt((x - bx * W) ** 2 + (y - by * H) ** 2) / (rad * W)
        k = (np.clip(1 - d, 0, 1) ** 2 * a)[..., None]
        rgb = rgb * (1 - k) + hexc(col) * k
    img = Image.fromarray((rgb * 255).astype(np.uint8), "RGB")
    dr = ImageDraw.Draw(img)
    # arrow between the two icons (icons centered at x=170 and x=470, y=190)
    ay = 190 * scale
    x0, x1 = 250 * scale, 390 * scale
    col = (124, 92, 255)
    for i, xx_ in enumerate(range(x0, x1 - 14 * scale, 14 * scale)):
        dr.rounded_rectangle([xx_, ay - 3 * scale, xx_ + 7 * scale, ay + 3 * scale], radius=3 * scale, fill=col)
    dr.polygon([(x1 - 16 * scale, ay - 13 * scale), (x1 + 2 * scale, ay), (x1 - 16 * scale, ay + 13 * scale)], fill=col)
    font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    bold_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    f1 = ImageFont.truetype(bold_path, 17 * scale)
    f2 = ImageFont.truetype(font_path, 12 * scale)
    t1 = "Drag Stack to Applications"
    t2 = "Glisse Stack dans le dossier Applications"
    for text, font, yy_, c in [(t1, f1, 318, (40, 32, 90)), (t2, f2, 344, (110, 100, 150))]:
        wdt = dr.textlength(text, font=font)
        dr.text(((W - wdt) / 2, yy_ * scale), text, font=font, fill=c)
    return img


if __name__ == "__main__":
    icon = make_icon()
    os.makedirs(RES, exist_ok=True)
    icon.save(os.path.join(RES, "AppIcon-1024.png"))
    save_icns(icon, os.path.join(RES, "AppIcon.icns"))
    os.makedirs(os.path.join(RES, "dmg"), exist_ok=True)
    make_dmg_background(1).save(os.path.join(RES, "dmg", "background.png"))
    make_dmg_background(2).save(os.path.join(RES, "dmg", "background@2x.png"))
    print("ok")
