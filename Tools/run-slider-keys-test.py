#!/usr/bin/env python3
"""Which key moves the slider, which key moves the photo, and what a drag does.

    python3 Tools/run-slider-keys-test.py

Two halves, and the second one is honest about being a source read.

The first runs Tools/test-slider-keys.swift against the REAL SliderNudgeKey,
pulled out of Develop.swift by text the same way run-delete-key-test.py pulls
DeleteKeyAction: the decision is a pure function precisely so it can be run
rather than reasoned about.

⚠️ THE SECOND HALF CANNOT BE RUN AND DOES NOT CLAIM TO BE. "A mouse drag must
not change which slider the keys control" lives in a SwiftUI closure, and this
document already carries the rule that a ruler which measures nothing reports no
failure — so this says plainly that it is reading the source, and reads for the
absence that matters: neither track view may be handed an onEditingChanged that
arms a slider, because that was the second way in that got out of step with the
click.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
develop = root / "BriefShow" / "Develop.swift"
src = develop.read_text(encoding="utf-8")

marker = "enum SliderNudgeKey: Equatable {"
start = src.find(marker)
if start == -1:
    sys.exit("SliderNudgeKey not found in Develop.swift — was it renamed or moved?")

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
    sys.exit("could not find the end of SliderNudgeKey — unbalanced braces?")
extracted = src[start:i + 1]

test = (root / "Tools" / "test-slider-keys.swift").read_text(encoding="utf-8")
anchor = "// ---- the real type, pasted in by the extractor at run time ----------------"
if anchor not in test:
    sys.exit("marker line missing from test-slider-keys.swift")

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(test.replace(anchor, anchor + "\n" + extracted, 1))
    path = f.name

print(f"extracted SliderNudgeKey ({extracted.count(chr(10))} lines) from Develop.swift\n")
failed = subprocess.call(["swift", path]) != 0

print("\nread out of Develop.swift, not run — a SwiftUI closure cannot be called from here")

# The arrows must reach stepPhoto.
arrows = re.search(r"event\.keyCode == 123 \|\| event\.keyCode == 124,\s*"
                   r"[^\n]*\n\s*stepPhoto\(by: event\.keyCode == 124 \? 1 : -1\)", src)
print(f"  {'ok  ' if arrows else 'FAIL'} ← / → step the filmstrip")
if not arrows:
    failed = True

# ⚠️ and no track view may arm a slider from a drag.
for view in ("EditTrackSlider", "GradientTrackSlider"):
    call = re.search(view + r"\(value: value.*?\)(\s*\{)?", src, re.S)
    armed = bool(call and call.group(1))
    print(f"  {'FAIL' if armed else 'ok  '} {view} is built without an onEditingChanged that could arm it")
    if armed:
        failed = True

# and clicking the name still does arm it
clicks = "selectSlider(sliderKey, title: title)" in src
print(f"  {'ok  ' if clicks else 'FAIL'} clicking the slider's name still arms it")
if not clicks:
    failed = True

# the card must not still tell the client to press the arrows
stale = "Press ← to lower" in src or "with the ← / → keys" in src
print(f"  {'FAIL' if stale else 'ok  '} the selection card and the tooltip name the keys that actually work")
if stale:
    failed = True

print()
print("the keys do what the client asked for." if not failed else "something is out of step.")
sys.exit(1 if failed else 0)
