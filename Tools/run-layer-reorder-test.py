#!/usr/bin/env python3
"""Runs Tools/test-layer-reorder.swift against the REAL reorder function.

Pulls LayerDropDelegate.reorder(_:moving:onto:) out of Develop.swift by text,
wraps it in a bare enum (the real struct conforms to DropDelegate, which would
drag SwiftUI and a whole view hierarchy in here), and concatenates it with the
test before handing the result to `swift -`.

The point is that the test can never drift from the code: if the function is
renamed, moved or changed, this either extracts the new body or fails loudly
with "not found" — it cannot quietly keep testing a stale copy.
"""
import pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")

start = src.find("    @discardableResult\n    static func reorder<T: Identifiable>")
if start == -1:
    sys.exit("reorder(_:moving:onto:) not found in Develop.swift — was it renamed or moved?")

# Bounded by brace balance from the function's opening "{".
open_brace = src.index("{", src.index("static func reorder", start))
depth, i = 0, open_brace
while i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
fn = src[start:i + 1]

test = (root / "Tools" / "test-layer-reorder.swift").read_text(encoding="utf-8")
bundle = "import Foundation\n\nenum LayerDropDelegate {\n" + fn + "\n}\n\n" + \
         test.replace("import Foundation\n", "", 1)

print(f"extracted reorder(): {fn.count(chr(10)) + 1} lines from Develop.swift")
r = subprocess.run(["swift", "-"], input=bundle, text=True)
sys.exit(r.returncode)
