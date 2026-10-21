# shotdiff.py <dir a> <dir b>: for each PNG in both, the count of pixels that differ by more than 2 in any channel
# and the box that holds them; for each JSON or text file in both, whether it is the same.
import os
import sys
from PIL import Image, ImageChops

a, b = sys.argv[1], sys.argv[2]
names = [n for n in sorted(os.listdir(a)) if os.path.exists(os.path.join(b, n))]
for n in names:
    if not n.endswith('.png'):
        continue
    x = Image.open(os.path.join(a, n)).convert('RGB')
    y = Image.open(os.path.join(b, n)).convert('RGB')
    if x.size != y.size:
        print(f"{n}: sizes {x.size} {y.size}")
        continue
    d = ImageChops.difference(x, y).point(lambda v: 255 if v > 2 else 0).convert('L')
    box = d.getbbox()
    count = sum(d.histogram()[1:])
    print(f"{n}: {count} px {box}")
for n in names:
    if n.endswith(('.json', '.txt')):
        same = open(os.path.join(a, n)).read() == open(os.path.join(b, n)).read()
        print(f"{n}: {'same' if same else 'DIFFERS'}")
