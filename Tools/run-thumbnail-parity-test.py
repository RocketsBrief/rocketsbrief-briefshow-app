#!/usr/bin/env python3
"""Measures whether a filmstrip/grid thumbnail shows what the big canvas shows.

    python3 Tools/run-thumbnail-parity-test.py <photo> [preset.xmp] [size]

Compiles the app's own sources, so both paths are the shipping ones. Fails when
the two disagree by more than a couple of levels — the difference the client
reported on 05.09 was plain to the eye in the strip under the picture.
"""
import importlib.util, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

if len(sys.argv) < 2:
    sys.exit(__doc__)
photo = sys.argv[1]
preset = sys.argv[2] if len(sys.argv) > 2 else "-"
size = sys.argv[3] if len(sys.argv) > 3 else "384"

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    binary = lrcal.build(work, main="test-thumbnail-parity.swift")
    sys.exit(subprocess.call([str(binary), photo, preset, size]))
