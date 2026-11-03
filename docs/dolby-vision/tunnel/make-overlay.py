#!/usr/bin/python3 -I
# Writes a 1920x1080 premultiplied BGRA test overlay shaped like a player's
# controls: a dark panel along the bottom, a seek bar with a thumb, a white
# box at the top left and swatches in white, Plezy's orange, red, green and
# blue. Usage: make-overlay.py out.bgra
import sys

W, H = 1920, 1080
buf = bytearray(W * H * 4)


def fill(x0, y0, x1, y1, rgb, alpha=255):
    r, g, b = (c * alpha // 255 for c in rgb)
    px = bytes((b, g, r, alpha)) * (x1 - x0)
    for y in range(y0, y1):
        o = (y * W + x0) * 4
        buf[o:o + len(px)] = px


# Bottom panel, fading in from transparent to 70 percent black.
for y in range(760, H):
    a = min(180, (y - 760) * 180 // 120)
    fill(0, y, W, y + 1, (0, 0, 0), a)
fill(120, 960, 1800, 968, (128, 128, 128))
fill(120, 960, 900, 968, (229, 160, 13))
for dy in range(-16, 17):
    dx = int((256 - dy * dy) ** 0.5)
    fill(900 - dx, 964 + dy, 900 + dx, 965 + dy, (255, 255, 255))
fill(120, 1000, 300, 1030, (255, 255, 255))
fill(1620, 1000, 1800, 1030, (255, 255, 255))
fill(80, 60, 680, 160, (255, 255, 255))
swatches = [(255, 255, 255), (229, 160, 13), (255, 0, 0), (0, 255, 0), (0, 0, 255)]
for i, rgb in enumerate(swatches):
    fill(1180 + i * 120, 60, 1280 + i * 120, 160, rgb)

with open(sys.argv[1], "wb") as f:
    f.write(buf)
