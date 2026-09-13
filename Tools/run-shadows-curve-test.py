#!/usr/bin/env python3
"""Shadows: the curve's promises, and what it does to a real photograph.

    python3 Tools/run-shadows-curve-test.py [photo.NEF ...]

The client's specification of 13.09 asks for four things: act only on the dark
band with the midtones weighted exactly zero, hold the black point so opening
the shadows does not wash the picture grey, lift non-linearly one way and
compress gently the other, and tune the saturation — put back what a lift washes
out, then hold it back again past +50 so a lifted shadow does not come up noisy.

⚠️ WHAT DECIDED THE DESIGN, measured on the shipping five-knot curve before any
of it was written. As one row of that curve, at Shadows +100:

    the black point   +7.6 levels      the spec says 0.0
    the midtone      +15.2 levels      the spec says 0.0
    level 16         +12.9 levels      the band the control is actually for

So two of the four clauses were not missing, they were broken the other way
round — the control's strongest effect sat at levels 64–80 and the one place it
must not move moved the most visibly. Shadows left the shared curve and became a
pass of its own, on OKLab lightness, with a Hermite window that is zero at black
and zero above middle grey.

Two halves.

The properties half runs Tools/test-shadows-curve.swift over the real type:
0 is the identity, NOTHING above L 0.50 moves at any setting, the black point is
anchored and the deepest twentieth moves under a level, the window peaks where
the spec puts it, the compression is gentler than the lift, the strength at the
peak is the OLD, Lightroom-scored one (computed from the old weights, not typed
in), the curve never flattens or inverts, there is no crease at either edge, the
hue does not turn, the saturation clause fires in both directions and is exactly
nothing below +50, the range above white walks through untouched, and the lookup
table is that curve — at its entries AND between them. It also reads
Develop.swift and checks Shadows has ONE implementation and is no longer a row
of the shared tone curve — the 🔴 MUST, without needing a photograph.

The photograph half needs a RAW and prints the ramp with the OLD curve computed
alongside the new one, so the two can be read side by side. Its two controls are
the MIDTONE column, which must not move at all, and the black point.

⚠️ It takes as many photographs as you give it and builds ONCE, because the
build is the slow part and the columns that matter are not the same on every
frame: a bright one has nothing below the peak to open, and only a frame with
black in it can say whether the anchor holds. Four of the fifteen RAWs on this
machine cover both.
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

    binary = lrcal.build(work, main="test-shadows-curve.swift")
    failed = subprocess.call([str(binary), str(ROOT / "BriefShow" / "Develop.swift")])

    if photos:
        ramp = lrcal.build(work, main="test-shadows-photo.swift")
        for photo in photos:
            print()
            failed |= subprocess.call([str(ramp), photo])
    else:
        print("\n(no photo given — the ramp needs one, e.g. any .NEF on the machine)")

    sys.exit(failed)
