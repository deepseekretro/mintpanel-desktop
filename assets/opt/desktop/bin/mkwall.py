#!/usr/bin/env python3
"""Debian-13-flavoured wallpaper: teal diagonal gradient + red Debian swirl. Pure stdlib."""
import math, sys
w, h = 1920, 1080
c0, c1 = (21, 48, 62), (46, 112, 145)
buf = bytearray(w * h * 3)
for y in range(h):
    ty = 0.65 * (y / (h - 1))
    base = y * w * 3
    for x in range(w):
        t = 0.35 * (x / (w - 1)) + ty
        i = base + x * 3
        buf[i]     = int(c0[0] + (c1[0] - c0[0]) * t)
        buf[i + 1] = int(c0[1] + (c1[1] - c0[1]) * t)
        buf[i + 2] = int(c0[2] + (c1[2] - c0[2]) * t)

# red Debian swirl (archimedean spiral, anti-aliased by distance field)
cx, cy = 660, 545
R_in, R_out, turns, half = 34, 330, 2.15, 15.0
red = (215, 10, 83)
lo, hi = cy - R_out - 40, cy + R_out + 40
for y in range(lo, hi):
    if not (0 <= y < h):
        continue
    base = y * w * 3
    for x in range(cx - R_out - 40, cx + R_out + 40):
        if not (0 <= x < w):
            continue
        dx, dy = x - cx, y - cy
        r = math.hypot(dx, dy)
        if r < R_in - 40 or r > R_out + 40:
            continue
        f = (r - R_in) / (R_out - R_in)
        if f < 0:
            f = 0.0
        a = 2 * math.pi * turns * f
        th = math.atan2(dy, dx)
        d = (th - a + math.pi) % (2 * math.pi) - math.pi
        dist = abs(r * math.sin(d))
        if dist > half:
            continue
        k = 1.0 - dist / half
        k = k * k * (3 - 2 * k)
        j = base + x * 3
        buf[j]     = int(buf[j]     + (red[0] - buf[j])     * k)
        buf[j + 1] = int(buf[j + 1] + (red[1] - buf[j + 1]) * k)
        buf[j + 2] = int(buf[j + 2] + (red[2] - buf[j + 2]) * k)

out = sys.argv[1] if len(sys.argv) > 1 else '/tmp/trixie.ppm'
with open(out, 'wb') as f:
    f.write(b'P6\n%d %d\n255\n' % (w, h))
    f.write(bytes(buf))
print('wrote', out)
