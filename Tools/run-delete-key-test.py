#!/usr/bin/env python3
"""Runs Tools/test-delete-key.swift against the REAL DeleteKeyAction.

Pulls `enum DeleteKeyAction` out of Develop.swift by text, the same way
run-slider-drag-test.py pulls EditSliderDrag: the decision is a pure function
precisely so it can be run rather than reasoned about. The key monitor around
it cannot be scripted on this machine — there is no accessibility permission —
but this is where the bug was.
"""
import pathlib, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")

marker = "enum DeleteKeyAction: Equatable {"
start = src.find(marker)
if start == -1:
    sys.exit("DeleteKeyAction not found in Develop.swift — was it renamed or moved?")

depth, i = 0, src.index("{", start)
while i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
else:
    sys.exit("could not find the end of DeleteKeyAction — unbalanced braces?")

extracted = src[start:i + 1]

test = (root / "Tools" / "test-delete-key.swift").read_text(encoding="utf-8")
anchor = "// ---- the real type, pasted in by the extractor at run time ----------------"
if anchor not in test:
    sys.exit("marker line missing from test-delete-key.swift")

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(test.replace(anchor, anchor + "\n" + extracted, 1))
    path = f.name

print(f"extracted DeleteKeyAction ({extracted.count(chr(10))} lines) from Develop.swift")
sys.exit(subprocess.call(["swift", path]))
