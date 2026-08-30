#!/usr/bin/env python3
"""Runs Tools/test-double-click.swift against the REAL briefShowIsDoubleClick.

Pulls the function out of ContentView.swift by text and concatenates it with the
test before handing the result to `swift -`. Same rule as the other two
runners here: the test compiles what ships, so it cannot drift.
"""
import pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "ContentView.swift").read_text(encoding="utf-8")

signature = "func briefShowIsDoubleClick("
start = src.find(signature)
if start == -1:
    sys.exit(f"{signature!r} not found in ContentView.swift — was it renamed or moved?")

depth, i = 0, src.index("{", src.index(") -> Bool", start))
while i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
fn = src[start:i + 1]

test = (root / "Tools" / "test-double-click.swift").read_text(encoding="utf-8")
bundle = "import Foundation\n\n" + fn + "\n\n" + test.replace("import Foundation\n", "", 1)

print(f"extracted briefShowIsDoubleClick(): {fn.count(chr(10)) + 1} lines from ContentView.swift")
r = subprocess.run(["swift", "-"], input=bundle, text=True)
sys.exit(r.returncode)
