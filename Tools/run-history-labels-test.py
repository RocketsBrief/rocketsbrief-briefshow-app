#!/usr/bin/env python3
"""Dehaze through renderers other than the app's — the Intel report of 23.09.

    python3 Tools/run-dehaze-renderers-test.py <photo> [size] [dehaze] [out-dir]
"""
import importlib.util, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

if False:
    sys.exit(__doc__)

with tempfile.TemporaryDirectory() as tmp:
    binary = lrcal.build(pathlib.Path(tmp), main="test-history-labels.swift")
    sys.exit(subprocess.call([str(binary), *sys.argv[1:]]))
