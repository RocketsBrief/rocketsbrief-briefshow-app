#!/usr/bin/env python3
"""Background Enhanced card: does its preview move with its numbers?

    python3 Tools/run-dehaze-renderers-test.py <photo>
"""
import importlib.util, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

if len(sys.argv) < 2:
    sys.exit(__doc__)

with tempfile.TemporaryDirectory() as tmp:
    binary = lrcal.build(pathlib.Path(tmp), main="test-background-enhanced-preview.swift")
    sys.exit(subprocess.call([str(binary), *sys.argv[1:]]))
