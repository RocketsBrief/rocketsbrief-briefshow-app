#!/usr/bin/env python3
"""How dense a repaired patch's fine texture is, against the photo around it.

This is the measurement behind KORAK 109. The client's report was about
TEXTURE DENSITY, not content — "the sand is blurrier, not like the beach",
"the grass is thinner than the grass around it" — and that can be measured
instead of argued about.

The score is the mean absolute Laplacian of luma (how much the image changes
from pixel to pixel: grains of sand, blades of grass) inside the given
rectangle, divided by the same thing in a ring of untouched photograph just
outside it. 1.00 means the patch is as busy as the photo it sits in; 0.33,
which is what the shipping pipeline scored on the client's own beach frame
before KORAK 109, means it is three times smoother.

  measure-texture-density.py <png> <x> <y> <w> <h>     # pixels, top-left origin

Use it on the PNGs Tools/run-inpaint-sweep.py writes. The rectangle is the
hole; when it is not known, find it by differencing two sweep variants — they
are identical everywhere except inside the repair.

⚠️ THE NUMBER IS NOT THE ANSWER, AND KORAK 109 HAS THE SCARS TO PROVE IT.
Three times during that step the score went UP while the photograph got worse:

  0.77  full-strength SD — bought entirely by an invented rock on the beach
  1.48  per-row donor matching — a hard regular comb across the patch
  0.82  a single flat donor patch — sand ripples laid across the sea

Wrong texture is still texture, and this metric cannot tell it from right
texture. Look at the PNG. The ratio is for deciding whether a change is worth
looking at, and for catching a regression later; it never settles anything on
its own.
"""
import sys
import numpy as np
from PIL import Image

if len(sys.argv) != 6:
    sys.exit(__doc__)

path, x, y, w, h = sys.argv[1], *[int(v) for v in sys.argv[2:6]]
a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
img = 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]

energy = np.zeros_like(img)
centre = img[1:-1, 1:-1]
energy[1:-1, 1:-1] = np.abs(4 * centre - img[:-2, 1:-1] - img[2:, 1:-1]
                            - img[1:-1, :-2] - img[1:-1, 2:])

hole = np.zeros(img.shape, dtype=bool)
hole[y:y + h, x:x + w] = True

# Held off the feathered edge on both sides, so the score is the patch itself
# and the photograph itself, not the ramp between them.
core = hole.copy()
core[y:y + 10, :] = core[y + h - 10:y + h, :] = False
core[:, x:x + 10] = core[:, x + w - 10:x + w] = False

pad = 40
ring = np.zeros(img.shape, dtype=bool)
ring[max(0, y - pad):y + h + pad, max(0, x - pad):x + w + pad] = True
ring &= ~hole

if core.sum() < 100 or ring.sum() < 100:
    sys.exit(f"rectangle too small or too near the edge: "
             f"{core.sum()} patch px, {ring.sum()} surround px")

inside, outside = energy[core].mean(), energy[ring].mean()
print(f"{path.split('/')[-1]:<26} patch {inside:.5f}  surround {outside:.5f}  "
      f"ratio {inside / outside:.2f}   ({core.sum():,} / {ring.sum():,} px)")
