#!/usr/bin/env python3
import sys
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
x0, y0, x1, y1 = map(int, sys.argv[3:7]); zoom = int(sys.argv[7]) if len(sys.argv) > 7 else 1
im = Image.open(src).crop((x0, y0, x1, y1))
if zoom > 1: im = im.resize((im.width * zoom, im.height * zoom), Image.NEAREST)
im.save(out, 'PNG', compress_level=1); print(out, im.size)
