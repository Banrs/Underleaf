import sys, os
from PIL import Image, ImageChops
a, b = sys.argv[1], sys.argv[2]
for n in sorted(os.listdir(a)):
    if not n.endswith('.png') or not os.path.exists(os.path.join(b, n)): continue
    x, y = Image.open(os.path.join(a, n)).convert('RGB'), Image.open(os.path.join(b, n)).convert('RGB')
    if x.size != y.size: print(f"{n}: sizes {x.size} {y.size}"); continue
    d = ImageChops.difference(x, y).point(lambda v: 255 if v > 2 else 0).convert('L')
    box = d.getbbox()
    count = sum(1 for v in d.getdata() if v) if box else 0
    print(f"{n}: {count} px {box}")
for n in sorted(os.listdir(a)):
    if n.endswith(('.json', '.txt')) and os.path.exists(os.path.join(b, n)):
        same = open(os.path.join(a, n)).read() == open(os.path.join(b, n)).read()
        print(f"{n}: {'same' if same else 'DIFFERS'}")
