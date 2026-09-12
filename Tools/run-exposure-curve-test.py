#!/usr/bin/env python3
"""Exposure: the curve's promises, and what it does to a real photograph.

    python3 Tools/run-exposure-curve-test.py [photo.NEF]

Reported 12.09: *„jel lightroomov expose radi drugacije nego nas? nekako bude
bas lepo, a ovde malo pomerim — sve se zapali!"* — and it did: a flat 2^EV gain
pushed a tenth of the frame into flat white over one stop.

Two halves.

The properties half compiles `ExposureCurve` out of the app's own sources and
runs Tools/test-exposure-curve.swift over it: EV 0 is the identity, the ends
are protected, nothing can be pushed through white, middle grey still carries
the whole stop, the curve is monotonic in both the tone and the slider, and the
lookup table the app renders through really is that curve.

The photograph half needs a RAW (or any photo) as an argument and prints the
clipping table. It is the one that answers the complaint, and it has a control
built in: the midtone column. A curve that stops the burning by simply
darkening the picture would show up there, and would not be a fix.
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

    binary = lrcal.build(work, main="test-exposure-curve.swift")
    failed = subprocess.call([str(binary)])

    if photo:
        if not pathlib.Path(photo).exists():
            sys.exit(f"missing: {photo}")
        print()
        highlights = lrcal.build(work, main="test-exposure-highlights.swift")
        subprocess.call([str(highlights), photo])
    else:
        print("\n(no photo given — the clipping table needs one, "
              "e.g. any .NEF on the machine)")

    sys.exit(failed)
