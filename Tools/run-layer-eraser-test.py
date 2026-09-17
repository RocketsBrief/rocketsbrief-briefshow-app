#!/usr/bin/env python3
"""Layer Eraser (17.09): hard edge, soft edge, opacity and a rotated layer.

    python3 Tools/run-layer-eraser-test.py

Compiles BriefShow/LayerEraser.swift with Tools/test-layer-eraser.swift and
runs it on synthetic pieces — no photograph needed.
"""
import os, subprocess, sys, tempfile
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
work = tempfile.mkdtemp()
out = os.path.join(work, "layer-eraser-test")
# Copied in as main.swift: only a file of that name may hold top-level code.
main = os.path.join(work, "main.swift")
with open(os.path.join(root, "Tools", "test-layer-eraser.swift")) as src, open(main, "w") as dst:
    dst.write(src.read())
build = subprocess.run(["swiftc", "-O", os.path.join(root, "BriefShow", "LayerEraser.swift"), main, "-o", out])
if build.returncode != 0:
    sys.exit(build.returncode)
sys.exit(subprocess.run([out]).returncode)
