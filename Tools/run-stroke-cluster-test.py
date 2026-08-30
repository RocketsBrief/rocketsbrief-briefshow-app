#!/usr/bin/env python3
"""Runs Tools/test-stroke-clusters.swift against the REAL clustering functions.

Pulls briefShowStrokeBox and briefShowStrokeClusters out of Develop.swift by
text, adds the one type they need (BrushStroke), and concatenates the lot with
the test before handing it to `swift -`.

Same point as run-layer-reorder-test.py: the test cannot drift from the code.
If either function is renamed, moved or changed, this extracts the new body or
fails loudly with "not found" — it cannot quietly keep testing a stale copy.
"""
import pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")


def extract(signature):
    start = src.find(signature)
    if start == -1:
        sys.exit(f"{signature!r} not found in Develop.swift — was it renamed or moved?")
    depth, i = 0, src.index("{", start)
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    sys.exit(f"unbalanced braces after {signature!r}")


pieces = [
    extract("func briefShowEraseDabs("),
    extract("func briefShowStrokeBox("),
    extract("func briefShowStrokeClusters("),
    extract("struct BriefShowRemovalJob {"),
    extract("func briefShowRemovalJobs("),
]

# BrushStroke's real declaration, so the test cannot be passing against a
# different shape of stroke than the app uses.
stroke_start = src.index("struct BrushStroke: Codable, Equatable, Identifiable {")
stroke = src[stroke_start:src.index("\n}\n", stroke_start) + 3]

test = (root / "Tools" / "test-stroke-clusters.swift").read_text(encoding="utf-8")
bundle = ("import Foundation\nimport CoreGraphics\n\n"
          + stroke + "\n" + "\n\n".join(pieces) + "\n\n"
          + test.replace("import Foundation\n", "", 1))

print(f"extracted {len(pieces)} declarations "
      f"({sum(p.count(chr(10)) + 1 for p in pieces)} lines) from Develop.swift")
r = subprocess.run(["swift", "-"], input=bundle, text=True)
sys.exit(r.returncode)
