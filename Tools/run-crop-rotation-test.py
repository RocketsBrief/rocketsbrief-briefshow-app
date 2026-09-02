#!/usr/bin/env python3
"""Runs Tools/test-crop-rotation.swift against the REAL crop-frame geometry.

Pulls EditCropRect, CropHandle and the four crop-rotation functions out of
Develop.swift by text, wraps the two instance methods in a small struct that
supplies the one thing they read from the view (`currentImagePixelRatio`), and
concatenates the lot with the test before handing it to `swift -`.

Same extraction discipline as run-layer-reorder-test.py and
run-editsettings-decode-test.py: the test can never drift from the code. If a
function is renamed, moved or changed, this either extracts the new body or
fails loudly with "not found" — it cannot quietly keep testing a stale copy.

⚠️ It also cannot see anything declared in an EXTENSION, only declarations
found by brace balance from the headers listed below. That limitation has
already bitten once: EditCropRect's decoder was written in an extension, and
run-editsettings-decode-test.py reported all 25 stored crops as lost because it
was compiling the synthesized decoder instead. Keep what matters in the body.
"""
import pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")


def extract(header: str) -> str:
    """The whole declaration, bounded by brace balance from its opening brace."""
    start = src.find(header)
    if start == -1:
        sys.exit(f"not found in Develop.swift — was it renamed or moved?\n  {header}")
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


TYPES = [
    "struct EditCropRect: Codable, Equatable {",
    "enum CropHandle:",
]

# The two static helpers are pure; the two instance methods read only
# `currentImagePixelRatio`, which the wrapper below supplies.
FUNCTIONS = [
    "    private static func cropFramePoint(",
    "    private static func cropFrameTranslation(",
    "    private func constrainedToImage(",
    "    private func anchoredAfterResize(",
]

types = "\n\n".join(extract(h) for h in TYPES)
functions = "\n\n".join(extract(h) for h in FUNCTIONS)

# `private` would put these out of reach of the test file; the bodies are
# otherwise untouched.
functions = functions.replace("    private static func ", "    static func ")
functions = functions.replace("    private func ", "    func ")

wrapper = (
    "struct CropGeometry {\n"
    "    // The one thing these two methods read from the view.\n"
    "    var imagePixelRatio: Double? = nil\n"
    "    var currentImagePixelRatio: Double? { imagePixelRatio }\n\n"
    + functions +
    "\n}\n"
)

test = (root / "Tools" / "test-crop-rotation.swift").read_text(encoding="utf-8")
bundle = ("import Foundation\nimport CoreGraphics\n\n" + types + "\n\n" + wrapper + "\n\n"
          + test.replace("import Foundation\n", "", 1))

print(f"extracted {len(TYPES)} types and {len(FUNCTIONS)} functions from Develop.swift, compiling…")
r = subprocess.run(["swift", "-"], input=bundle, text=True)
sys.exit(r.returncode)
