#!/usr/bin/env python3
"""The grid lays a folder out BEFORE it has any pictures, and lays it out once.

Reported 23.09: *„kad ulazim u folder gde ima vise od 100 slika one se ne pojave
… vec prazan ekran frozen i odjenom sve se pojave"*. It was never the decoding —
250 JPEGs cost 30.6 ms each through the real path, under two seconds across four
workers. It was the layout: every tile took its width from its loaded thumbnail,
so each batch of ten that landed reshaped ten tiles and made FlowLayout, which is
not lazy, measure all 250 subviews twice. Twenty-five reflows on the main thread.

This reads the live source for the rules that keep that fixed, then extracts
photoAspectRatioFromHeader and runs it over real photographs.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "ContentView.swift"
HARNESS = ROOT / "Tools" / "grid-shape.swift"

FOLDERS = [
    pathlib.Path.home() / "Desktop" / "Esti's Pictures" / "Bali 2024 🥑🥥🏖️✈️ ",
    pathlib.Path.home() / "Desktop" / "RAW Tests Images",
    pathlib.Path.home() / "Downloads",
]

checks = []


def check(name, ok, detail=""):
    checks.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}")
    if not ok and detail:
        print(f"          {detail}")


def extract_function(text, name):
    start = re.search(rf"^func {name}\(", text, re.MULTILINE)
    if not start:
        return None
    i = text.index("{", start.start())
    depth, j = 0, i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start.start(): j + 1]
        j += 1
    return None


src = SOURCE.read_text(encoding="utf-8")

print("1. the rules that stop the reflow, read out of the live source")

cell = src[src.index("private func thumbnailCell(for url: URL)"):][:2600]
check("a tile asks the file header for its shape", "gridAspectRatios[url]" in cell,
      "thumbnailCell no longer consults gridAspectRatios")
check("the loaded picture still wins when there is one, for the cropped photo",
      cell.index("image.map") < cell.index("gridAspectRatios[url]"),
      "the header must be the FALLBACK, or a cropped tile gets the wrong shape")
check("and 4:3 is the last resort, not the first", "?? (4.0 / 3.0)" in cell)

load = src[src.index("private func loadGridThumbnails(for urls: [URL])"):][:5200]
check("the shapes are read before any decoding is queued",
      load.index("gridAspectQueue") < load.index("gridPlaceholderQueue"))
check("the shape pass is cancelled with the others when another folder opens",
      "gridAspectQueue.cancelAllOperations()" in load)
check("photos already measured are skipped", "gridAspectRatios[$0] == nil" in load)

# The whole point: ONE write to @State. A write per photo, or per batch, is a
# full FlowLayout pass each — which is the bug, not the fix.
aspect_block = load[load.index("gridAspectQueue.cancelAllOperations()"):]
aspect_block = aspect_block[:aspect_block.index("// Both passes hand the grid")] \
    if "// Both passes hand the grid" in aspect_block else aspect_block[:2000]
check("the shapes reach the view in ONE write, not one per photo",
      aspect_block.count("DispatchQueue.main.async") == 1,
      f"found {aspect_block.count('DispatchQueue.main.async')} main-thread writes")

print("\n2. the quality rule the client restated on 23.09, unchanged")
check("the loupe still asks for the drawn size, never a flat number",
      "min(max(cellSize.width, cellSize.height) * scale, 6000)" in src,
      "the Space loupe must decode at what it will actually draw")
check("the shape pass decodes nothing",
      "CGImageSourceCreateThumbnail" not in (extract_function(src, "photoAspectRatioFromHeader") or "x"),
      "reading a header must not turn into a decode")

print("\n3. Back cannot walk the client out of his own folder")
# It lives on the folder tree's root row, next to the ESTI label - it was tried
# in the grid header first, where it displaced the wordmark and truncated every
# other button in the row.
parent = src[src.index("private var parentOfSelection: URL?"):][:1100]
check("Back is bounded by the open tree",
      'parentPath == rootPath || parentPath.hasPrefix(rootPath + "/")' in parent)
check("and disappears at the root", "guard currentPath != rootPath else { return nil }" in parent)
check("Back is NOT in the grid header, where it cost every other button its label",
      "gridParentFolderURL" not in src)

print("\n4. every button grows its label on hover")
# Asked for on 23.09: *„proveri sva dugmica i koje nema dodaj tu animaciju"*.
# A ButtonStyle cannot hold @State, so the hover lives either in a Label view
# the style delegates to, or in the HoverGrow modifier.
develop = (ROOT / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")
both = src + "\n" + develop


def style_body(text, name):
    m = re.search(rf"(?:private |fileprivate )?struct {name}: ButtonStyle", text)
    if not m:
        return ""
    i = text.index("{", m.start())
    depth, j = 0, i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[m.start():j + 1]
        j += 1
    return ""


styles = sorted(set(re.findall(r"(?:private |fileprivate )?struct (\w+): ButtonStyle", both)))
check("every ButtonStyle in the app was found", len(styles) >= 10, str(styles))
without = []
for name in styles:
    body = style_body(both, name)
    delegated = re.findall(r"\b(\w*Label)\b", body)
    blob = body
    for label in set(delegated):
        lm = re.search(rf"(?:private |fileprivate )?struct {label}: View", both)
        if lm:
            blob += both[lm.start(): lm.start() + 3000]
    grows = ("hoverGrow(" in body) or ("isHovered" in blob and "scaleEffect" in blob)
    if not grows:
        without.append(name)
check("no ButtonStyle is left without a hover animation", not without,
      "missing: " + ", ".join(without))

# The 77 plain buttons - the Create tool rail the client pointed at among them.
# `.plain` draws no chrome and, on its own, answers the pointer with nothing.
plain_left = []
for name in ["ContentView.swift", "Develop.swift", "AccountUI.swift",
             "Shortcuts.swift", "Theme.swift"]:
    text = (ROOT / "BriefShow" / name).read_text(encoding="utf-8")
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if not re.search(r"\.buttonStyle\((?:\.plain|PlainButtonStyle\(\)|\.borderless)\)", line):
            continue
        back = "\n".join(lines[max(0, i - 40):i])
        # A button that animates on hover by hand is fine, and must NOT also get
        # the style - the two scales would multiply.
        if "onHover" in back and "scaleEffect" in back:
            continue
        plain_left.append(f"{name}:{i + 1}")
check("no plain button is left without a hover animation", not plain_left,
      "missing: " + ", ".join(plain_left[:10]))

rail = develop[develop.index("private func toolButton("):][:2200]
check("the Create tool rail the client pointed at is one of them",
      "PlainHoverButtonStyle" in rail, rail[-300:])
check("a disabled button does not answer the pointer",
      "isHovered && isEnabled" in src,
      "a dimmed control that grows under the mouse reads as clickable")

print("\n5. nothing the client browses is kept forever")
# Reported 23.09: *„kada radim duze da ne krene da laguje"*. Measured on real
# photographs: a grid tile is 0.45 MB and a loupe image 10.8 MB, and neither
# cache was ever emptied - five folders was 565 MB, a hundred Space presses 1.1 GB.
check("opening another folder lets the last one go",
      "forgetCaches(outside: Set(sortedURLs))" in src,
      "a folder walked out of must not stay in memory for the session")
forget = src[src.index("private func forgetCaches(outside keep: Set<URL>)"):][:900]
for name in ["gridThumbnails", "loupeImages", "loupeImagePixelSizes"]:
    check(f"{name} is pruned to the open folder", f"{name} = {name}.filter" in forget, forget)
check("the shapes are KEPT, so a folder walked back into lays out at once",
      "gridAspectRatios.count > 20_000" in forget,
      "two numbers a photo is not what was costing the memory")

remember = src[src.index("private func rememberLoupeImage(_ url: URL)"):][:1100]
check("the loupe keeps a bounded handful, not everything ever opened",
      "let cap = 8" in remember and "loupeImages.removeValue" in remember, remember)
check("and never drops what is on screen right now",
      "previewSelectedURLs.contains(oldest)" in remember, remember)
check("quality is untouched: the loupe still decodes at the drawn size",
      "min(max(cellSize.width, cellSize.height) * scale, 6000)" in src)

print("\n6. the work is sized to the machine, not to the one it was written on")
hard = []
for name in ["ContentView.swift", "Develop.swift"]:
    text = (ROOT / "BriefShow" / name).read_text(encoding="utf-8")
    for i, line in enumerate(text.split("\n")):
        if re.search(r"maxConcurrentOperationCount\s*=\s*\d+", line):
            hard.append(f"{name}:{i + 1}")
check("no worker count is a written-down number any more", not hard,
      "hard-coded: " + ", ".join(hard))
budget = src[src.index("enum MachineBudget {"):][:1200]
check("workers come from the core count", "activeProcessorCount" in budget)
check("and are clamped by memory, because a demosaic holds hundreds of MB",
      "physicalMemory" in budget and "gigabytes <= 8" in budget, budget)
# An optimization for old hardware that slows this machine down gets reverted.
check("this machine (8 cores, 8 GB) still gets the 4 it was measured at",
      "min(cores - 2, 6)" in budget and "gigabytes <= 8 ? 4 : 6" in budget, budget)

print("\n7. the real function, over real photographs")
fn = extract_function(src, "photoAspectRatioFromHeader")
if not fn:
    check("photoAspectRatioFromHeader found in ContentView.swift", False)
else:
    check("photoAspectRatioFromHeader found in ContentView.swift", True)
    folder = next((f for f in FOLDERS if f.is_dir()), None)
    if folder is None:
        print("  note  no folder of photographs on this machine - the measured half is skipped")
    else:
        harness = HARNESS.read_text(encoding="utf-8").replace("// EXTRACTED_FUNCTION", fn)
        with tempfile.TemporaryDirectory() as tmp:
            swift = pathlib.Path(tmp) / "grid-shape.swift"
            binary = pathlib.Path(tmp) / "grid-shape"
            swift.write_text(harness, encoding="utf-8")
            build = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                                   capture_output=True, text=True)
            if build.returncode != 0:
                check("the harness builds", False, build.stderr[-400:])
            else:
                run = subprocess.run([str(binary), str(folder), "60"],
                                     capture_output=True, text=True)
                out = run.stdout
                print("        " + out.replace("\n", "\n        ").rstrip())
                if run.returncode == 3:
                    print("  note  that folder holds no photographs")
                else:
                    nums = dict(re.findall(r"^(\w[\w ]*?)\s+([\d.]+)", out, re.MULTILINE))
                    measured = int(float(nums.get("measured", 0)))
                    mismatched = int(float(nums.get("mismatched", 1)))
                    cost = float(re.search(r"cost\s+([\d.]+) ms", out).group(1))
                    check("every photograph answered", measured >= 10, out)
                    # The one that matters: the header shape IS the shape the
                    # real thumbnail arrives at, so nothing reflows.
                    check("the header shape matches the real thumbnail's", mismatched == 0, out)
                    check("cheap enough to run over a folder first (< 5 ms a file)", cost < 5.0, out)

print()
if all(checks):
    print("all checks passed")
    sys.exit(0)
print(f"{checks.count(False)} of {len(checks)} checks FAILED")
sys.exit(1)
