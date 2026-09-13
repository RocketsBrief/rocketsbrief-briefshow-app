#!/usr/bin/env python3
"""Highlights: the curve's promises, and whether blown areas really come back.

    python3 Tools/run-highlights-curve-test.py [photo.NEF]

The client's specification of 13.09 asks for four things: act only above middle
grey, no hard edge where the work starts, reconstruct a channel that is past
white from the ones that are not, and take a little colour out of the very
brightest tones at the extreme.

⚠️ WHAT DECIDED THE DESIGN, and it is measured rather than argued —
Tools/run-highlights-headroom.py: between 0.04% and 30.6% of the client's frames
sit ABOVE white when Highlights gets them, and neither CIToneCurve nor a colour
cube can see up there (both clamp at 1.0, probed directly). So Highlights left
the shared five-knot tone curve and became a pass of its own, with the picture
scaled by 1/headroom in front of the table so that range is in reach.

Two halves.

The properties half runs Tools/test-highlights-curve.swift over the real type:
0 is the identity, NOTHING below L 0.50 moves at any setting, the slider goes
the right way, five tones between white and 1.074 stay five tones, there is no
crease at the knee, hue never turns, a channel past white comes back as colour
rather than as a grey patch, chroma drops at the extreme top and only there, and
the lookup table is that curve in its own scaled axes. It also reads
Develop.swift and checks Highlights has ONE implementation and is no longer a
row of the shared tone curve — the MUST, without needing a photograph.

The photograph half needs a RAW and prints what happens to the blown region. Its
control is the SPREAD column: a blown area that merely gets darker is not
recovered, it is dimmed. Recovery means the pixels that were one flat value stop
being one flat value.
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

photo = sys.argv[1] if len(sys.argv) > 1 else None

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)

    binary = lrcal.build(work, main="test-highlights-curve.swift")
    failed = subprocess.call([str(binary), str(ROOT / "BriefShow" / "Develop.swift")])

    if photo:
        if not pathlib.Path(photo).exists():
            sys.exit(f"missing: {photo}")
        print()
        ramp = lrcal.build(work, main="test-highlights-photo.swift")
        failed |= subprocess.call([str(ramp), photo])
    else:
        print("\n(no photo given — the recovery ramp needs one, "
              "e.g. any .NEF on the machine)")

    sys.exit(failed)
