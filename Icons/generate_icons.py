#!/usr/bin/env python3
"""
Mirror of CP_GenerateIcons.lua — produces the same 90×30 PNGs without
requiring REAPER. Useful for one-off generation directly from the dev box.

Outputs PNGs alongside this script. Three horizontal states per icon
(normal / hover / active), 30×30 each.
"""

import math
import os
from PIL import Image, ImageDraw

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
W, H, CELL = 90, 30, 30


# ---------------------------------------------------------------------------
# Anti-aliased line/circle helpers (PIL's draw is fine; we just centralise
# the alpha=0 background and white-with-modulated-alpha foreground)
# ---------------------------------------------------------------------------
def alpha(a):
    return int(round(max(0.0, min(1.0, a)) * 255))


def fill_circle(draw, cx, cy, radius, a):
    if radius <= 0:
        return
    bbox = (cx - radius, cy - radius, cx + radius, cy + radius)
    draw.ellipse(bbox, fill=(255, 255, 255, alpha(a)))


def ring(draw, cx, cy, radius, ring_w, a):
    fill_circle(draw, cx, cy, radius + ring_w * 0.5, a)
    # punch the inner hole back to transparent
    inner = radius - ring_w * 0.5
    if inner > 0:
        bbox = (cx - inner, cy - inner, cx + inner, cy + inner)
        draw.ellipse(bbox, fill=(0, 0, 0, 0))


def thick_line(draw, x1, y1, x2, y2, a, line_w):
    # PIL line width is per-stroke, antialiased on Pillow >=9 by default
    draw.line((x1, y1, x2, y2), fill=(255, 255, 255, alpha(a)),
              width=max(1, int(round(line_w))))


def diagonal_line(draw, x1, y1, x2, y2, a, thickness):
    draw.line((x1, y1, x2, y2), fill=(255, 255, 255, alpha(a)),
              width=max(1, int(round(thickness))))


def rect_outline(draw, x, y, w, h, a, line_w):
    draw.rectangle((x, y, x + w - 1, y + h - 1),
                   outline=(255, 255, 255, alpha(a)),
                   width=max(1, int(round(line_w))))


def rect_filled(draw, x, y, w, h, a):
    draw.rectangle((x, y, x + w - 1, y + h - 1),
                   fill=(255, 255, 255, alpha(a)))


# ---------------------------------------------------------------------------
# Icon designs (each takes the cell-local draw + ox + state params)
# ---------------------------------------------------------------------------
FXC_NODES = [(7, 9, 1.8), (23, 8, 1.8), (15, 14, 2.2), (9, 22, 1.8), (22, 22, 1.8)]
FXC_LINES = [(0, 2), (2, 1), (2, 3), (2, 4), (3, 4)]


def draw_fxconstellation(draw, ox, line_a, line_w, ring_w, fill):
    for ai, bi in FXC_LINES:
        ax, ay, _ = FXC_NODES[ai]
        bx, by, _ = FXC_NODES[bi]
        thick_line(draw, ax + ox, ay, bx + ox, by, line_a, line_w)
    for nx, ny, nr in FXC_NODES:
        if fill:
            fill_circle(draw, nx + ox, ny, nr + 0.2, 1.0)
        else:
            ring(draw, nx + ox, ny, nr, ring_w, 1.0)


INSP_LINES = [(5, 22, 9), (5, 20, 15), (5, 17, 21)]
LENS = (19, 18, 5.5)
HANDLE = (23, 22, 27, 26)


def draw_inspector(draw, ox, line_a, line_w, ring_w, fill):
    for x1, x2, y in INSP_LINES:
        thick_line(draw, x1 + ox, y, x2 + ox, y, line_a, line_w)
    cx, cy, lr = LENS
    if fill:
        fill_circle(draw, cx + ox, cy, lr, 1.0)
        # punch
        inner = lr - 2.2
        draw.ellipse((cx + ox - inner, cy - inner, cx + ox + inner, cy + inner),
                     fill=(0, 0, 0, 0))
    else:
        ring(draw, cx + ox, cy, lr, ring_w, 1.0)
    hx1, hy1, hx2, hy2 = HANDLE
    thickness = 2.4 if fill else ring_w
    diagonal_line(draw, hx1 + ox, hy1, hx2 + ox, hy2, 1.0, thickness)


def draw_paintsynth(draw, ox, line_a, line_w, ring_w, fill):
    # Diagonal brush handle
    hx1, hy1, hx2, hy2 = 24, 6, 14, 16
    diagonal_line(draw, hx1 + ox, hy1, hx2 + ox, hy2,
                  line_a + 0.1, 2.4 if fill else ring_w)

    # Brush tip
    if fill:
        fill_circle(draw, 13 + ox, 17, 2.6, 1.0)
        fill_circle(draw, 11 + ox, 19, 1.4, 1.0)
    else:
        ring(draw, 13 + ox, 17, 2.6, ring_w, 1.0)

    # Sound wave
    wave_y = 24
    steps = 20
    x0, x1 = 4, 26
    pts = []
    for i in range(steps + 1):
        t = i / steps
        px = x0 + (x1 - x0) * t
        py = wave_y + math.sin(t * math.pi * 2.5) * 2.2
        pts.append((px, py))
    for i in range(len(pts) - 1):
        ax, ay = pts[i]
        bx, by = pts[i + 1]
        thick_line(draw, ax + ox, ay, bx + ox, by, line_a, line_w)


FRAME = (4, 6, 22, 16)


def draw_video_frame(draw, ox, line_a, line_w, ring_w, fill):
    fx, fy, fw, fh = FRAME
    if fill:
        rect_filled(draw, fx + ox, fy, fw, fh, line_a * 0.35)
    rect_outline(draw, fx + ox, fy, fw, fh, line_a, max(1, line_w))


def draw_videokit(draw, ox, line_a, line_w, ring_w, fill):
    draw_video_frame(draw, ox, line_a, line_w, ring_w, fill)
    fx, fy, fw, fh = FRAME
    cx = fx + fw / 2 + ox
    cy = fy + fh / 2
    size = 5
    # Build a play triangle as a polygon
    poly = [
        (cx - size * 0.6, cy - size),
        (cx - size * 0.6, cy + size),
        (cx + size * 0.9, cy),
    ]
    if fill:
        draw.polygon(poly, fill=(255, 255, 255, alpha(1.0)))
    else:
        draw.polygon(poly, outline=(255, 255, 255, alpha(line_a + 0.1)))
        # filled but lighter
        draw.polygon(poly, fill=(255, 255, 255, alpha(line_a * 0.6)))


def draw_videokit_inspector(draw, ox, line_a, line_w, ring_w, fill):
    draw_video_frame(draw, ox, line_a, line_w, ring_w, fill)
    cx, cy, lr = 19, 17, 4.2
    if fill:
        fill_circle(draw, cx + ox, cy, lr, 1.0)
        inner = lr - 1.8
        draw.ellipse((cx + ox - inner, cy - inner, cx + ox + inner, cy + inner),
                     fill=(0, 0, 0, 0))
    else:
        ring(draw, cx + ox, cy, lr, ring_w, 1.0)
    diagonal_line(draw, 22 + ox, 20, 26 + ox, 24, 1.0, 2.0 if fill else ring_w)


def draw_videokit_modules(draw, ox, line_a, line_w, ring_w, fill):
    draw_video_frame(draw, ox, line_a, line_w, ring_w, fill)
    bx = 16 + ox
    bw = 8
    bh = 3
    gap = 1
    for i in range(3):
        by = 9 + i * (bh + gap)
        if fill:
            rect_filled(draw, bx, by, bw, bh, 1.0)
        else:
            rect_outline(draw, bx, by, bw, bh, line_a + 0.1, max(1, line_w))


# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------
STATES = [
    dict(line_a=0.45, line_w=1.0, ring_w=1.2, fill=False),  # normal
    dict(line_a=0.65, line_w=1.4, ring_w=1.6, fill=False),  # hover
    dict(line_a=0.90, line_w=1.4, ring_w=1.6, fill=True),   # active
]

JOBS = [
    ("CP_FXConstellation.png",      draw_fxconstellation),
    ("CP_Inspector.png",            draw_inspector),
    ("CP_PaintSynth.png",           draw_paintsynth),
    ("CP_VideoKit.png",             draw_videokit),
    ("CP_VideoKit_Inspector.png",   draw_videokit_inspector),
    ("CP_VideoKit_Modules.png",     draw_videokit_modules),
]


def generate(name, draw_fn):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for i, st in enumerate(STATES):
        ox = i * CELL
        draw_fn(draw, ox, **st)
    path = os.path.join(OUT_DIR, name)
    img.save(path, "PNG")
    return path


if __name__ == "__main__":
    for name, fn in JOBS:
        out = generate(name, fn)
        print("OK  " + out)
