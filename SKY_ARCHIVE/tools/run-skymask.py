#!/usr/bin/env python3
"""Draws SkyMasker's mask in red over a real photograph.

    python3 Tools/run-skymask.py <photo> <output.png>

Pulls SubjectMasker, SkyMasker and skyMeasurementContext out of
BriefShow/DevelopInpaint.swift by brace balance and concatenates them with
Tools/skymask-driver.swift before handing the lot to `swift -`.

Same extraction discipline as run-layer-reorder-test.py and
run-crop-rotation-test.py: the harness cannot drift from the code. If a type is
renamed or moved this either extracts the new body or fails loudly.

⚠️ It replaces Tools/skymask.swift, which carried a HAND COPY of both maskers
while the notes claimed it extracted them. The copy was still identical, so
nothing had been mis-measured yet — but the next change to SkyMasker would have
been measured against the old code, and the result would have looked like a
measurement. That is exactly the trap KORAK 66 paid for three times over.
"""
import pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
source = root / "BriefShow" / "DevelopInpaint.swift"
src = source.read_text(encoding="utf-8")


def extract(header: str) -> str:
    start = src.find(header)
    if start == -1:
        sys.exit(f"not found in {source.name} — was it renamed or moved?\n  {header}")
    depth, i = 0, src.index("{", start)
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    sys.exit(f"unbalanced braces while extracting:\n  {header}")


def line(prefix: str) -> str:
    for candidate in src.splitlines():
        if candidate.startswith(prefix):
            return candidate
    sys.exit(f"not found in {source.name}: {prefix}")


if len(sys.argv) != 3:
    sys.exit(__doc__)

parts = [
    "import AppKit",
    "import CoreImage",
    "import CoreImage.CIFilterBuiltins",
    "import Vision",
    "",
    extract("enum SubjectMasker {"),
    extract("enum SkyMasker {"),
    # `private` at file scope is fine — everything ends up in one file.
    line("private let skyMeasurementContext"),
    (root / "Tools" / "skymask-driver.swift").read_text(encoding="utf-8"),
]
bundle = "\n\n".join(parts)

print(f"extracted SubjectMasker + SkyMasker from {source.name}, compiling…")
r = subprocess.run(["swift", "-", sys.argv[1], sys.argv[2]], input=bundle, text=True)
sys.exit(r.returncode)
