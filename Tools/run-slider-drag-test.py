#!/usr/bin/env python3
"""Runs Tools/test-slider-drag.swift against the REAL EditSliderDrag.

Pulls the whole `enum EditSliderDrag` out of Develop.swift by text. It is a
plain value type with no SwiftUI in it — that is why the drag maths was moved
out of the two slider views in the first place: a gesture cannot be scripted
against this window (osascript already failed on it once, see the notes), but
the arithmetic underneath the gesture can, and that is where the bug was.
"""
import pathlib, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")

marker = "enum EditSliderDrag {"
start = src.find(marker)
if start == -1:
    sys.exit("EditSliderDrag not found in Develop.swift — was it renamed or moved?")

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
    sys.exit("could not find the end of EditSliderDrag — unbalanced braces?")

extracted = src[start:i + 1]

# ⚠️ The Swift file hard-codes the Exposure range it measures. If the app's own
# range moves and this does not, the test goes on passing while measuring a
# slider that no longer exists — the "ruler that measures nothing" this project
# has already been bitten by four times. So check them against each other.
import re as _re
_slider = _re.search(r'editSlider\("Exposure", value: \$settings\.exposure, range: (-?[\d.]+)\.\.\.(-?[\d.]+)', src)
if not _slider:
    sys.exit("could not find the Exposure slider's range in Develop.swift")

test = (root / "Tools" / "test-slider-drag.swift").read_text(encoding="utf-8")
_test_range = _re.search(r"let range = (-?[\d.]+)\.\.\.(-?[\d.]+)", test)
if not _test_range:
    sys.exit("could not find the range this test measures in test-slider-drag.swift")

if (float(_slider.group(1)), float(_slider.group(2))) != (float(_test_range.group(1)), float(_test_range.group(2))):
    sys.exit(
        f"the app's Exposure slider is {_slider.group(1)}...{_slider.group(2)} but this test "
        f"measures {_test_range.group(1)}...{_test_range.group(2)} — fix test-slider-drag.swift"
    )
anchor = "// ---- the real type, pasted in by the extractor at run time ----------------"
if anchor not in test:
    sys.exit("marker line missing from test-slider-drag.swift")
combined = test.replace(anchor, anchor + "\n" + extracted, 1)

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(combined)
    path = f.name

print(f"extracted EditSliderDrag ({extracted.count(chr(10))} lines) from Develop.swift")
sys.exit(subprocess.call(["swift", path]))
