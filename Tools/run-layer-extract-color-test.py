#!/usr/bin/env python3
"""Runs Tools/test-layer-extract-color.swift against the REAL extraction path.

Pulls three things out of Develop.swift by text — the app's colour space, the
context every cut-out is rendered through, and pngData(for:pixelRect:) — and
concatenates them with the test before handing the result to `swift -`.

The context line is the whole point of the test, so it is extracted rather than
retyped: if someone gives it different options, or takes the options away
again, this measures what is actually in the file.
"""
import pathlib, re, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")

pieces = []

# 1. The app's colour space, as the app declares it.
m = re.search(r"^private let briefEditsSRGBColorSpace = .*$", src, re.M)
if not m:
    sys.exit("briefEditsSRGBColorSpace not found in Develop.swift — was it renamed?")
pieces.append(m.group(0).replace("private let", "let", 1))

# 2. The context cut-outs are rendered through. Spans to the closing bracket
#    when it carries options, or to end of line when it does not.
start = src.find("    private static let sharedExtractionContext = ")
if start == -1:
    sys.exit("sharedExtractionContext not found in Develop.swift — was it renamed or moved?")
open_paren = src.index("(", start)
depth, i = 0, open_paren
while i < len(src):
    if src[i] == "(":
        depth += 1
    elif src[i] == ")":
        depth -= 1
        if depth == 0:
            break
    i += 1
else:
    sys.exit("could not find the end of the sharedExtractionContext declaration")
pieces.append(src[start:i + 1].replace("    private static let", "let", 1))

# 3. pngData, which is what every extraction actually calls.
marker = "    private static func pngData(for image: CIImage, pixelRect: CGRect) -> Data? {"
start = src.find(marker)
if start == -1:
    sys.exit("pngData(for:pixelRect:) not found in Develop.swift — was it renamed or moved?")
open_brace = src.index("{", start)
depth, i = 0, open_brace
while i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
else:
    sys.exit("could not find the end of pngData — unbalanced braces?")
pieces.append(src[start:i + 1].replace("    private static func pngData", "func pngData", 1))

extracted = "\n\n".join(pieces)

test = (root / "Tools" / "test-layer-extract-color.swift").read_text(encoding="utf-8")
anchor = "// ---- the real declarations, pasted in by the extractor at run time ---------"
if anchor not in test:
    sys.exit("marker line missing from test-layer-extract-color.swift")
combined = test.replace(anchor, anchor + "\n" + extracted, 1)

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(combined)
    path = f.name

print("extracted briefEditsSRGBColorSpace, sharedExtractionContext and pngData from Develop.swift")
sys.exit(subprocess.call(["swift", path]))
