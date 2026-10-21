#!/usr/bin/env python3
# crops.py <out.png> <scale> (<label> <capture.png> <x> <width>)…: the toolbar strip of each 2x capture from x for
# width points, enlarged and stacked with its label; and, between each pair in turn, how many pixels differ and by
# how much at most.
import sys
from PIL import Image, ImageChops, ImageDraw

out, scale, rest = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
rows = []
for i in range(0, len(rest), 4):
    label, path, x, w = rest[i], rest[i + 1], float(rest[i + 2]), float(rest[i + 3])
    im = Image.open(path).convert('RGB')
    rows.append((label, im.crop((int(x * 2), 0, int((x + w) * 2), 104))))
for (la, a), (lb, b) in zip(rows[::2], rows[1::2]):
    if a.size == b.size:
        hist = ImageChops.difference(a, b).convert('L').histogram()
        most = max(i for i, n in enumerate(hist) if n)
        print(f"{la} | {lb}: {sum(hist[9:])} px differ by more than 8, most {most} of 255, of {a.width * a.height}")
sheet = Image.new('RGB', (max(r.width for _, r in rows) * scale + 260, sum(r.height * scale + 4 for _, r in rows)),
                  (128, 128, 128))
draw = ImageDraw.Draw(sheet)
y = 0
for label, crop in rows:
    big = crop.resize((crop.width * scale, crop.height * scale), Image.NEAREST)
    draw.text((8, y + big.height // 2), label, fill=(255, 255, 255))
    sheet.paste(big, (260, y))
    y += big.height + 4
sheet.save(out)
print(out, sheet.size)
