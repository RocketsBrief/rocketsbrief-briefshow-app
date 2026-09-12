#!/usr/bin/env python3
"""Measures whether a slider on a LAYER does what the same slider on the PHOTO does.

    python3 Tools/run-layer-edit-parity-test.py <photo.NEF> [size] [only=contrast]

The client's report, 12.09: *„kada se podele layeri na background i people e taj
edit nije uopste isti kao main edit jedne slike … kada kliknem na layer people
ili backround isti slidebar edit treba da bude da da je iste rezultate"*.

Compiles the app's own sources, so both sides are the shipping pipeline: the
photo through `PhotoEditRenderer.render`, the layer through
`applyLocalToneColorDetail`. The layer is a full-frame derived layer with a
white matte, so the two differ ONLY in which code path applied the number.
"""
import importlib.util, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

if len(sys.argv) < 2:
    sys.exit(__doc__)

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    binary = lrcal.build(work, main="test-layer-edit-parity.swift")
    sys.exit(subprocess.call([str(binary), *sys.argv[1:]]))
