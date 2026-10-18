#!/usr/bin/env python3
"""collate.py out.png cols img1 [img2 ...]: a contact sheet of captures at full resolution, never scaled.
Each tile keeps every pixel; tiles are laid out in rows of `cols` with an 8 px gap and the file name above
each. Lossless PNG, no compression of the image data beyond PNG's own (optimize off)."""
import sys, os
from PIL import Image, ImageDraw, ImageFont
out, cols, paths = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
ims = [Image.open(p).convert('RGBA') for p in paths]
gap, label = 8, 36
try: font = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 26)
except Exception: font = ImageFont.load_default()
rows = [ims[i:i + cols] for i in range(0, len(ims), cols)]
names = [paths[i:i + cols] for i in range(0, len(paths), cols)]
widths = [max(sum(im.width for im in r) + gap * (len(r) - 1), 0) for r in rows]
heights = [max(im.height for im in r) + label for r in rows]
sheet = Image.new('RGBA', (max(widths), sum(heights) + gap * (len(rows) - 1)), (255, 255, 255, 255))
d = ImageDraw.Draw(sheet); y = 0
for r, n, h in zip(rows, names, heights):
    x = 0
    for im, p in zip(r, n):
        d.text((x + 4, y + 4), os.path.basename(p), fill=(0, 0, 0, 255), font=font)
        sheet.paste(im, (x, y + label)); x += im.width + gap
    y += h + gap
sheet.save(out, 'PNG', compress_level=1)
print(out, sheet.size)
