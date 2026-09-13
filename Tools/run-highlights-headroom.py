#!/usr/bin/env python3
"""What Highlights has to work with — measured before any of it is written.

    python3 Tools/run-highlights-headroom.py <photo.NEF>

See Tools/test-highlights-headroom.swift for what the columns mean and why the
answer decides where the Highlights curve can live.
"""
import importlib.util, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

photos = sys.argv[1:]
if not photos:
    sys.exit(__doc__)
missing = [p for p in photos if not pathlib.Path(p).exists()]
if missing:
    sys.exit("missing: " + ", ".join(missing))

# Built once, run per photograph: the build is the slow part and the question is
# about a FOLDER of pictures, not one of them — the scale factor the cube is
# given has to clear the whole set.
with tempfile.TemporaryDirectory() as tmp:
    binary = lrcal.build(pathlib.Path(tmp), main="test-highlights-headroom.swift")
    failed = 0
    for photo in photos:
        failed |= subprocess.call([str(binary), photo])
        print()
    sys.exit(failed)
