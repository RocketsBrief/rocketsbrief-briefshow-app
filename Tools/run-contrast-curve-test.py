#!/usr/bin/env python3
"""Contrast: the curve's promises, and what it does to a real photograph.

    python3 Tools/run-contrast-curve-test.py [photo.NEF]

The client's specification of 12.09 is exact — *„Klasično rastezanje RGB
vrednosti oko centra nije prihvatljivo"* — and names five things: a perceptual
space, a fixed pivot on middle grey, a smooth S, a soft rolloff at both ends,
and chroma held back so skin does not go orange. All five are testable.

Two halves.

The properties half compiles `ContrastCurve` out of the app's own sources and
runs Tools/test-contrast-curve.swift over it: Contrast 0 is the identity, middle
grey never moves, both endpoints are pinned, nothing leaves the box, the midtone
slope is the one figure inherited from the Lightroom-calibrated curve it
replaces, the ends are flatter than the middle, +c undoes −c exactly, the hue
angle never turns, chroma is damped but not flattened, and the lookup table the
app renders through really is that curve. It also reads Develop.swift and checks
that there is still only ONE implementation of Contrast — the MUST at the top of
BRIEFSHOW_DEVELOP_NOTES.md, checked without needing a photograph.

The photograph half needs a RAW (or any photo) as an argument and prints the
clipping/spread/chroma ramp. It has a control built in: the spread column. A
curve that protects the ends by simply not adding contrast would score
beautifully everywhere else and would not be a fix.
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

    binary = lrcal.build(work, main="test-contrast-curve.swift")
    failed = subprocess.call([str(binary), str(ROOT / "BriefShow" / "Develop.swift")])

    if photo:
        if not pathlib.Path(photo).exists():
            sys.exit(f"missing: {photo}")
        print()
        ramp = lrcal.build(work, main="test-contrast-photo.swift")
        failed |= subprocess.call([str(ramp), photo])
    else:
        print("\n(no photo given — the clipping/spread ramp needs one, "
              "e.g. any .NEF on the machine)")

    sys.exit(failed)
