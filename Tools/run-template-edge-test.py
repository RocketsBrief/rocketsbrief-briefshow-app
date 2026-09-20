#!/usr/bin/env python3
"""No pass may leave the photograph's edge translucent.

    python3 Tools/run-template-edge-test.py

Built against the real pipeline through the calibration harness, so it drives
PhotoEditRenderer.render itself rather than a copy of it.

⚠️ WHY IT EXISTS. A photograph laid into a print template sits on white paper,
so any pass that hands back a soft, partly transparent border becomes a white
feather along the edge of the print — reported by the client on 20.09 as
"zastu su krajeve slike blei?". It was Dehaze: the transmission map's
edge-preserving upsample had nothing to read within about two patch radii of
the frame and returned alpha 74 at the outermost row, opaque only past row 64
of a 3000x2000 frame. On a photograph filling the window that is invisible,
which is why nothing caught it for as long as it existed.

The negative control is in the notes: with the clamp removed from the
transmission map, "dehaze: the edge is opaque" fails and nothing else does.
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

with tempfile.TemporaryDirectory() as tmp:
    binary = lrcal.build(pathlib.Path(tmp), main="test-template-edge.swift")
    sys.exit(subprocess.call([str(binary)]))
