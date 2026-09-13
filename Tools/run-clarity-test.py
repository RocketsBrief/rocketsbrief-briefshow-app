#!/usr/bin/env python3
"""Clarity: local contrast that knows where an edge is.

    python3 Tools/run-clarity-test.py [photo.NEF ...]

The client's specification of 13.09 asks for four things: separate the picture
with an EDGE-PRESERVING filter rather than a Gaussian, weight the work by a
midtone mask on perceptual lightness (nothing below L 0.15 or above L 0.85),
boost the MID frequencies, and on the negative side soften those while leaving
the sharp edges alone.

⚠️ TWO MEASUREMENTS DECIDED THE DESIGN, both taken before anything was written.

1. The shipping path was `CIUnsharpMask` — the same arithmetic with a Gaussian
   base. On a synthetic step edge, the brightest pixel beside the edge overshot
   the level it should settle at by **41.81 levels**, against 3.97 for the
   untouched source. That white rim is the halo the spec names, and it is what a
   Gaussian base IS.

2. `CIGuidedFilter` — the filter the spec asks for by name, and the one Apple
   ships for exactly this — **does nothing on macOS 26**. Self-guided or with a
   separate guide, at radii 1…40 and epsilons 0.0001…0.1, it returns the input
   unchanged: texture RMS 14.37 in, 14.37 out, where `CIGaussianBlur` returns
   0.08. Do not spend another afternoon on it.

What works is `CIEdgePreserveUpsampleFilter`, a joint bilateral upsample: the
picture as its own guide, a downscaled copy as the small image. Same synthetic
edge — texture 10.74 → 0.03 while the step's rise stays 0 px wide, where a
Gaussian of the same strength smears it across 15 px.

Two halves.

The properties half runs Tools/test-clarity-local-contrast.swift on synthetic
plates, because a spatial control cannot be proved on a ramp: 0 is the identity,
the halo is a fraction of the old path's, the texture goes up, the highlights and
the shadows barely move while the midtones do, the negative half softens the
texture but keeps the step's own rise where the old path smeared it, the strength
cannot invert the texture, the slider is monotonic, and the mask table is the
mask. It also reads Develop.swift for the 🔴 MUST and prints what a render costs
at preview and export size.

The photograph half needs a RAW and measures LOCAL CONTRAST — the RMS of each
pixel against the average of the 5×5 around it — inside three bands, with the old
path computed alongside.
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

photos = sys.argv[1:]
missing = [p for p in photos if not pathlib.Path(p).exists()]
if missing:
    sys.exit("missing: " + ", ".join(missing))

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)

    binary = lrcal.build(work, main="test-clarity-local-contrast.swift")
    failed = subprocess.call([str(binary), str(ROOT / "BriefShow" / "Develop.swift")])

    if photos:
        ramp = lrcal.build(work, main="test-clarity-photo.swift")
        for photo in photos:
            print()
            failed |= subprocess.call([str(ramp), photo])
    else:
        print("\n(no photo given — the band ramp needs one, e.g. any .NEF on the machine)")

    sys.exit(failed)
