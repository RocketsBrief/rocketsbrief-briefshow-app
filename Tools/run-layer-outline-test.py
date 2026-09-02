#!/usr/bin/env python3
"""Runs Tools/test-layer-outline.swift against the REAL overlay builder.

Pulls layerOutlineImage(for:) out of Develop.swift by text and rewrites the
four lines that tie it to a live view — the @State cache and the layer it is
handed — into a plain `layerOutlineImage(maskData:)`. The FILTER CHAIN, which
is the whole thing being measured, is carried across untouched.

Every substitution is asserted. If the function is renamed, moved, or its shape
changes, this fails loudly with what it could not find rather than quietly
testing a stale copy of the code.
"""
import pathlib, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")

marker = "    private func layerOutlineImage(for layer: ImageLayer) -> NSImage? {"
start = src.find(marker)
if start == -1:
    sys.exit("layerOutlineImage(for:) not found in Develop.swift — was it renamed or moved?")

# Bounded by brace balance from the function's opening "{".
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
    sys.exit("could not find the end of layerOutlineImage — unbalanced braces?")

body = src[start:i + 1]


def swap(text, old, new, what):
    if old not in text:
        sys.exit(f"could not find {what} in layerOutlineImage — the function changed shape:\n  {old!r}")
    return text.replace(old, new, 1)


# The signature: a live layer becomes the matte bytes themselves.
body = swap(body, marker,
            "func layerOutlineImage(maskData: Data) -> NSImage? {",
            "the signature")
# The cache is @State on a view and has nothing to do with the drawing.
body = swap(body,
            "        if let cached = layerOutlineCache[layer.id] {\n"
            "            return cached\n"
            "        }\n",
            "", "the cache read")
body = swap(body, "        layerOutlineCache[layer.id] = image\n", "", "the cache write")
body = swap(body,
            "guard let data = layer.maskData, let mask = CIImage(data: data) else {",
            "guard let mask = CIImage(data: maskData) else {",
            "the matte guard")
# Self. is a type reference inside the view; the test owns the context.
body = swap(body, "Self.overlayContext", "overlayContext", "the CIContext reference")

test = (root / "Tools" / "test-layer-outline.swift").read_text(encoding="utf-8")
anchor = "// ---- the real function, pasted in by the extractor at run time -------------"
if anchor not in test:
    sys.exit("marker line missing from test-layer-outline.swift")
combined = test.replace(anchor, anchor + "\n" + body, 1)

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(combined)
    path = f.name

print(f"extracted layerOutlineImage ({body.count(chr(10))} lines) from Develop.swift")
sys.exit(subprocess.call(["swift", path]))
