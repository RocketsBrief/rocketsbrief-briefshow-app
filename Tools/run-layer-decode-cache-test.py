#!/usr/bin/env python3
"""Runs Tools/test-layer-decode-cache.swift against the REAL decode cache.

Pulls decodedLayerCache, decodedLayerImage(_:) and dataFingerprint(_:) out of
Develop.swift by text and concatenates them with the test.

The test declares its own two-field `ImageLayer`. That is not a copy of app
code being tested: decodedLayerImage reads exactly `.id` and `.imageData` and
nothing else, and if it ever reads a third field this file stops compiling —
which is the failure you want, rather than a silent pass.
"""
import pathlib, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")


def extract(marker, opener, closer, what, rename):
    start = src.find(marker)
    if start == -1:
        sys.exit(f"{what} not found in Develop.swift — was it renamed or moved?")
    open_at = src.index(opener, start)
    depth, i = 0, open_at
    while i < len(src):
        if src[i] == opener:
            depth += 1
        elif src[i] == closer:
            depth -= 1
            if depth == 0:
                break
        i += 1
    else:
        sys.exit(f"could not find the end of {what} — unbalanced {opener}{closer}?")
    return src[start:i + 1].replace(marker.strip(), rename, 1)


pieces = [
    extract("    private static let decodedLayerCache: NSCache<NSString, CIImage> = {",
            "{", "}", "decodedLayerCache",
            "let decodedLayerCache: NSCache<NSString, CIImage> = {"),
    extract("    private static func decodedLayerImage(_ layer: ImageLayer) -> CIImage? {",
            "{", "}", "decodedLayerImage(_:)",
            "func decodedLayerImage(_ layer: ImageLayer) -> CIImage? {"),
    extract("    private static func dataFingerprint(_ data: Data) -> UInt64 {",
            "{", "}", "dataFingerprint(_:)",
            "func dataFingerprint(_ data: Data) -> UInt64 {"),
]

# The cache initialiser closure ends in "}()", which the brace walk stops one
# character short of.
if not pieces[0].rstrip().endswith("()"):
    pieces[0] = pieces[0] + "()"

extracted = "\n\n".join(pieces)

test = (root / "Tools" / "test-layer-decode-cache.swift").read_text(encoding="utf-8")
anchor = "// ---- the real declarations, pasted in by the extractor at run time ---------"
if anchor not in test:
    sys.exit("marker line missing from test-layer-decode-cache.swift")
combined = test.replace(anchor, anchor + "\n" + extracted, 1)

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(combined)
    path = f.name

print("extracted decodedLayerCache, decodedLayerImage and dataFingerprint from Develop.swift")
sys.exit(subprocess.call(["swift", path]))
