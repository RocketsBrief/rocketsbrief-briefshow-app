#!/usr/bin/env python3
"""Dodge & Burn builds up with every pass (18.09). No photograph needed.

    python3 Tools/run-dodge-burn-test.py
"""
import importlib.util, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

with tempfile.TemporaryDirectory() as tmp:
    binary = lrcal.build(pathlib.Path(tmp), main="test-dodge-burn-stacking.swift")
    sys.exit(subprocess.call([str(binary)]))
