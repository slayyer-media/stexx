# Regenerates Stexx/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png from
# brand/v6c_glass_icon.png: drops the baked-in rounded corners and alpha so iOS can
# apply its own mask, and fills the corners with the surrounding background.
#
# Usage (from ios/): python3 scripts/make_app_icon.py ../brand/v6c_glass_icon.png \
#        Stexx/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
# Requires Pillow.
import sys
from PIL import Image, ImageFilter
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGBA')
a = im.getchannel('A').point(lambda v: 255 if v > 250 else 0)
er = a.filter(ImageFilter.MinFilter(31))  # drop ~15px rim highlight
W, H = im.size
px = im.load(); em = er.load()
bg = Image.new('RGB', im.size)
bp = bg.load()
last = (38, 39, 45)
rows = {}
for y in range(H):
    xs = [x for x in range(W) if em[x, y] == 255]
    if len(xs) > 40:
        x0, x1 = xs[0] + 6, xs[-1] - 6
        l = px[x0, y]; r = px[x1, y]
        last = tuple((l[i] + r[i]) // 2 for i in range(3))
    rows[y] = last
# rows above first opaque row: fill with first known
first = next(y for y in range(H) if any(em[x, y] == 255 for x in range(0, W, 4)))
for y in range(first): rows[y] = rows[first + 20]
for y in range(H):
    c = rows[y]
    for x in range(W): bp[x, y] = c
soft = er.filter(ImageFilter.GaussianBlur(4))
out = Image.composite(im.convert('RGB'), bg, soft)
# crop inside the original squircle so system mask hides old rounded edge
b = 37 + 14
out = out.crop((b, b, W - b, H - b)).resize((1024, 1024), Image.LANCZOS)
out.save(dst, 'PNG')
print('ok', out.mode, out.size)
