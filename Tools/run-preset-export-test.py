#!/usr/bin/env python3
"""Round-trips presets through LightroomPresetExport and back through the import.

    python3 Tools/run-preset-export-test.py [an existing .xmp]

Compiles the app's own sources — the same builder the calibration harness uses,
with a different top level — so what is exercised is the shipping exporter, not
a copy of it. Give it a real .xmp and it round-trips that too.
"""
import importlib.util, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    binary = lrcal.build(work, main="test-preset-roundtrip.swift")
    sys.exit(subprocess.call([str(binary), *sys.argv[1:]]))
