#!/usr/bin/env python3
"""⌘ + wheel zooms, and Original shows the file on the card.

    python3 Tools/run-zoom-original-test.py

Two reports from the client's own run, 20.09:

    „Zoom - cmd and scroll on mous, beside cmd = and -"
    „also original button when clicked and hold to get back not one step
     history, instead need to get to the real reset show on the original image"

Two halves, and the split is the same one the rest of Tools follows.

1. COMPILED. Tools/test-scroll-wheel.swift is built against the REAL
   `briefShowScrollWheelAction`, pulled out of Develop.swift by text — the wheel
   cannot be posted on this machine (no accessibility permission), so the
   decision was moved OUT of the NSEvent closure precisely so it could be run.

2. READ FROM THE SOURCE — the Original hold, which is four state variables and
   two render paths and therefore cannot be a unit test:
     - the hold reaches for the card's own file,
     - both render paths — the fast one and the sharp one 0.45 s later — swap
       to it, because a hold that shows the original and then quietly stops is
       the bug with extra steps,
     - `loadBaseImage(at:)` has exactly ONE caller. Everything else must keep
       opening the baked copy; a second caller here silently un-flattens a path,
     - the second decode is only taken for a photo that HAS a baked copy (8 GB
       machine), and
     - it is dropped in `loadImages`, the one place every base-image swap goes
       through — a flatten and an unflatten included.

Negative controls, RUN rather than assumed (20.09):
  - the ⌘ branch made to defer to an armed tool (what "put it after the tool
    branch" amounts to): 3 checks fail, ⌘ zooms even with a sizeable tool armed
    among them;
  - one shared counter instead of two: 2 checks fail, and the measurement is
    the reason the second one exists — a single fraction of a trackpad flick
    resized the brush TWO sizes (resizeTool(steps: 2)) because the travel held
    for a zoom is longer than a whole brush rung. The first shared-counter
    check, written the other way round, passed under that fault and measured
    nothing.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"
TEST = ROOT / "Tools" / "test-scroll-wheel.swift"

src = SOURCE.read_text(encoding="utf-8")

failures = 0


def wiring(label: str, passed: bool, detail: str = "") -> None:
    global failures
    if passed:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{('   ' + detail) if detail else ''}")


def body(marker: str) -> str:
    """The body of a declaration, so a check reads the thing it names."""
    if marker not in src:
        return ""
    start = src.index(marker)
    depth, i = 0, src.index("{", start)
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    return ""


# ---------------------------------------------------------------- the decision

start = src.find("enum ScrollWheelAction: Equatable {")
if start == -1:
    sys.exit("ScrollWheelAction not found in Develop.swift — was it renamed or moved?")
end = src.find("struct DevelopView: View {", start)
if end == -1:
    sys.exit("could not find the end of the scroll-wheel block")
extracted = src[start:end]
if "func briefShowScrollWheelAction(" not in extracted:
    sys.exit("briefShowScrollWheelAction is no longer beside ScrollWheelAction — fix the extractor")

test = TEST.read_text(encoding="utf-8")
anchor = "// ---- the real decision, pasted in by the extractor at run time -------------"
if anchor not in test:
    sys.exit("marker line missing from test-scroll-wheel.swift")

print(f"\nextracted the wheel decision ({extracted.count(chr(10))} lines) from Develop.swift")
with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(test.replace(anchor, anchor + "\n" + extracted, 1))
    path = f.name

compiled = subprocess.call(["swift", path])

# ------------------------------------------------------------------- the hold

print("\nthe Original hold, read out of Develop.swift")

render = body("    private func renderNow() {")
refine = body("    private func refinedRenderNow() {")
loader = body("    private func loadOriginalBaseIfNeeded() {")
load_images = body("    private func loadImages(for url: URL) {")

wiring("the fast render takes the card's own file while held",
       "showOriginal ? (originalPreviewBaseImage ?? previewBaseImage)" in render)
wiring("so does the sharp one that lands 0.45 s later",
       "showOriginal ? (originalBaseImage ?? fullBaseImage)" in refine)
# The `onChange` body, comments and all: the decode has to be asked for on the
# way DOWN, not left to whatever happens to render next.
hold = src.split(".onChange(of: showOriginal)", 1)[-1].split("\n        }", 1)[0] if ".onChange(of: showOriginal)" in src else ""
wiring("the hold asks for the decode before it renders",
       "if isOn { loadOriginalBaseIfNeeded() }" in hold and "renderNow()" in hold)

wiring("the second decode opens the photo's OWN url, not the flattened source",
       "PhotoEditRenderer.loadBaseImage(at: url)" in loader
       and "PhotoEditRenderer.loadPreviewBaseImage(at: url" in loader)
wiring("and only for a photo that has a baked copy",
       "FlattenedImageStore.isFlattened(url)" in loader)
wiring("a second hold does not start the same decode twice",
       "originalBaseURL != url" in loader and "originalBaseURL = url" in loader)
wiring("a photo switched away from mid-decode drops the result",
       "guard url == selectedURL else" in loader)

# The one-caller rule. `loadBaseImage(at:)` and `loadPreviewBaseImage(at:)` are
# the only way in the app to get the UNFLATTENED picture, and every other path
# must keep seeing the bake — so their callers are counted, not assumed.
# Counted over the CODE of every Swift file in the app, with the comments taken
# out (they name these functions on purpose) and with the three places that are
# allowed to call them removed: the two wrappers, which is how the rest of the
# app gets the baked copy, and the hold. Anything left is a path that has
# quietly stopped seeing a flatten.
allowed = [body("    static func loadBaseImage(from photoURL: URL) -> PhotoBaseImage? {"),
           body("    static func loadPreviewBaseImage(from photoURL: URL, full: PhotoBaseImage, previewMax: CGFloat = 2600) -> PhotoBaseImage {"),
           body("    private func loadOriginalBaseIfNeeded() {")]
for text in allowed:
    if not text:
        sys.exit("one of the three allowed callers could not be found — fix the extractor")

rest = []
for swift in sorted((ROOT / "BriefShow").glob("*.swift")):
    text = swift.read_text(encoding="utf-8")
    for text_to_drop in allowed:
        text = text.replace(text_to_drop, "")
    code = "\n".join(line.split("//", 1)[0] for line in text.splitlines())
    for call in ("loadBaseImage(at:", "loadPreviewBaseImage(at:"):
        for line in code.splitlines():
            if call in line and "static func" not in line:
                rest.append(f"{swift.name}: {line.strip()}")

wiring("nothing else in the app reaches past a flatten", not rest, f"{rest}")
for name, text in (("loadBaseImage(at:", allowed[2]), ("loadPreviewBaseImage(at:", allowed[2])):
    wiring(f"the hold is the one place that calls {name})",
           f"PhotoEditRenderer.{name}" in text)

wiring("the card's file is dropped wherever the base image is replaced",
       "originalBaseImage = nil" in load_images
       and "originalPreviewBaseImage = nil" in load_images
       and "originalBaseURL = nil" in load_images)

# What the hold RENDERS, which is the other half of "the real original": the
# baked copy with the sliders at zero is exactly the one step back the client
# said it must stop being.
wiring("and it renders with the settings at zero",
       "let effectiveSettings = showOriginal ? PhotoEditSettings() : settings" in render
       and "let effectiveSettings = showOriginal ? PhotoEditSettings() : settings" in refine)

# ------------------------------------------------------------------ the wheel

print("\nthe wheel, read out of Develop.swift")

monitor = body("    private func installScrollWheelMonitor() {")
wiring("the monitor decides nothing itself",
       "briefShowScrollWheelAction(" in monitor
       and "case .zoom(let steps):" in monitor
       and "case .resizeTool(let steps):" in monitor)
wiring("a zoom rung is the SAME stepZoom ⌘= and ⌘− press",
       "stepZoom(steps > 0 ? 1 : -1)" in monitor)
wiring("the travel is one value, held in one place",
       "@State private var scrollWheelTravel = ScrollWheelTravel()" in src
       and src.count("scrollWheelTravel = ScrollWheelTravel()") == 2)

print()
if compiled != 0:
    failures += 1
    print("the compiled half FAILED")
print("all good\n" if failures == 0 else f"{failures} FAILED\n")
sys.exit(0 if failures == 0 else 1)
