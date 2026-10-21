#!/usr/bin/env python3
"""collate.py out.png cols img1 [img2 ...]: a contact sheet of captures at full resolution, never scaled: rows of
`cols` with an 8 px gap and the file name above each, in a lossless PNG."""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

out, cols, paths = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
gap, label = 8, 36
try:
    font = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 26)
except Exception:
    font = ImageFont.load_default()
tiles = [(p, Image.open(p).convert('RGBA')) for p in paths]
rows = [tiles[i:i + cols] for i in range(0, len(tiles), cols)]
heights = [max(im.height for _, im in r) + label for r in rows]
width = max(sum(im.width for _, im in r) + gap * (len(r) - 1) for r in rows)
sheet = Image.new('RGBA', (width, sum(heights) + gap * (len(rows) - 1)), (255, 255, 255, 255))
draw = ImageDraw.Draw(sheet)
y = 0
for row, h in zip(rows, heights):
    x = 0
    for p, im in row:
        draw.text((x + 4, y + 4), os.path.basename(p), fill=(0, 0, 0, 255), font=font)
        sheet.paste(im, (x, y + label))
        x += im.width + gap
    y += h + gap
sheet.save(out, 'PNG', compress_level=1)
print(out, sheet.size)
