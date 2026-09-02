#!/usr/bin/env python3
"""Runs Tools/test-effect-extraction.swift with BOTH versions of six effects.

The OLD ones come out of `git show HEAD:BriefShow/Develop.swift` — the inline
`if settings.texture != 0 { … }` blocks as they stood inside `render` before
they were pulled into functions. The NEW ones come off disk.

Neither is retyped, so this cannot quietly compare a copy against itself. If
the extraction moved so much as one pixel, the test says so.

⚠️ This test is meaningful only while HEAD still holds the pre-extraction code.
Once the extraction is committed, `git show HEAD` returns the NEW code and both
sides become the same thing — a test that passes for the wrong reason. Point
BASE_REV at the last commit before the extraction (or delete this harness) at
that point; the runner prints which revision it used so the output always says
what was actually compared.
"""
import pathlib, subprocess, sys, tempfile

# ⚠️ PINNED, and it had to be. While the extraction was uncommitted, HEAD was
# the pre-extraction code and this compared old against new. The moment it is
# committed, HEAD becomes the NEW code and both sides of the comparison are the
# same thing — a test that passes for the wrong reason. a096884 is the last
# commit before the six effects were pulled out of `render`.
BASE_REV = "a096884"

root = pathlib.Path(__file__).resolve().parent.parent
new_src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")
old_src = subprocess.run(["git", "show", f"{BASE_REV}:BriefShow/Develop.swift"],
                         cwd=root, capture_output=True, text=True, check=True).stdout


def block(src, head, where_end, what):
    """The `if settings.X … { … }` statement, brace-matched, from `src`."""
    lines = src.split("\n")
    hits = [i for i, l in enumerate(lines) if l.strip() == head and i < where_end]
    if len(hits) != 1:
        sys.exit(f"expected exactly one {what} block before line {where_end}, found {len(hits)}")
    start = hits[0]
    depth, i = 0, start
    while i < len(lines):
        depth += lines[i].count("{") - lines[i].count("}")
        i += 1
        if depth == 0:
            break
    else:
        sys.exit(f"could not find the end of the {what} block")
    return "\n".join(lines[start:i])


def decl(src, marker, what, rename):
    start = src.find(marker)
    if start == -1:
        sys.exit(f"{what} not found — was it renamed or moved?")
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
        sys.exit(f"could not find the end of {what}")
    return src[start:i + 1].replace(marker.strip(), rename, 1)


olds = [
    ("if settings.sharpness > 0 {", "oldSharpen"),
    ("if settings.texture != 0 {", "oldTexture"),
    ("if settings.clarity != 0 {", "oldClarity"),
    ("if settings.dehaze != 0 {", "oldDehaze"),
    ("if settings.softGlow > 0 {", "oldSoftGlow"),
    ("if settings.vignette != 0 {", "oldVignette"),
]

pieces = ["""
/// Exactly the fields the six old blocks read off `settings`, so their code can
/// be pasted in with no edits at all.
struct OldSettings {
    var sharpness = 0.0
    var sharpenRadius = 1.0
    var texture = 0.0
    var clarity = 0.0
    var dehaze = 0.0
    var softGlow = 0.0
    var vignette = 0.0
    var vignetteMidpoint = 0.5
    var vignetteFeather = 0.5
    var vignetteRoundness = 0.0
}
"""]

for head, name in olds:
    body = block(old_src, head, 2400, name)
    pieces.append(f"func {name}(_ settings: OldSettings, to image: CIImage) -> CIImage {{\n"
                  f"    var output = image\n{body}\n    return output\n}}")

# The constant the sharpen block reads, and the new functions themselves.
for line in old_src.split("\n"):
    if line.startswith("private let briefEditsDefaultSharpenRadius"):
        pieces.append(line.replace("private let", "let", 1))
        break
else:
    sys.exit("briefEditsDefaultSharpenRadius not found")

new_funcs = []
for marker, rename in [
    ("    private static func applySharpen(_ sharpness: Double, radius: Double, to image: CIImage) -> CIImage {",
     "static func applySharpen(_ sharpness: Double, radius: Double, to image: CIImage) -> CIImage {"),
    ("    private static func applyTexture(_ texture: Double, to image: CIImage) -> CIImage {",
     "static func applyTexture(_ texture: Double, to image: CIImage) -> CIImage {"),
    ("    private static func applyClarity(_ clarity: Double, to image: CIImage) -> CIImage {",
     "static func applyClarity(_ clarity: Double, to image: CIImage) -> CIImage {"),
    ("    private static func applyDehaze(_ dehaze: Double, to image: CIImage) -> CIImage {",
     "static func applyDehaze(_ dehaze: Double, to image: CIImage) -> CIImage {"),
    ("    private static func applySoftGlow(_ softGlow: Double, to image: CIImage) -> CIImage {",
     "static func applySoftGlow(_ softGlow: Double, to image: CIImage) -> CIImage {"),
    ("    private static func applyVignette(_ vignette: Double, midpoint: Double, feather: Double, roundness: Double, to image: CIImage) -> CIImage {",
     "static func applyVignette(_ vignette: Double, midpoint: Double, feather: Double, roundness: Double, to image: CIImage) -> CIImage {"),
]:
    new_funcs.append("    " + decl(new_src, marker, marker.strip()[:40], rename))

pieces.append("enum PhotoEditRenderer {\n" + "\n\n".join(new_funcs) + "\n}")

test = (root / "Tools" / "test-effect-extraction.swift").read_text(encoding="utf-8")
anchor = "// ---- both implementations, pasted in by the extractor at run time ----------"
if anchor not in test:
    sys.exit("marker line missing from test-effect-extraction.swift")
combined = test.replace(anchor, anchor + "\n" + "\n\n".join(pieces), 1)

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(combined)
    path = f.name

rev = subprocess.run(["git", "rev-parse", "--short", BASE_REV], cwd=root,
                     capture_output=True, text=True, check=True).stdout.strip()
print(f"old code from {BASE_REV} ({rev}), new code from the working tree")
sys.exit(subprocess.call(["swift", path]))
