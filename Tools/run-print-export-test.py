#!/usr/bin/env python3
"""The export of a print — KORAK 198, step 7.

    python3 Tools/run-print-export-test.py

The plan's last step: *„izvoz na 300 dpi, koji treba i da poravna veličinu
izvoza pečene i nepečene slike"*.

Two things had to be true and neither was:

  1. THE PIXELS ARE THE PAPER. 8×10 at 300 dpi is 3000×2400 — from a live
     record and from a baked one alike. A baked print carries however many
     pixels the bake needed to keep the photograph at its own resolution (see
     briefShowBakeCanvasScale), so the same template exported two sizes
     depending on whether Flatten had been pressed.
  2. THE FILE SAYS 300 dpi. The same pixels at the default 72 are a print a
     lab will scale or refuse — 3000 px at 72 dpi is a 41-inch "8 × 10".

Two halves.

1. COMPILED. Tools/test-print-export.swift is built against the real
   Templates.swift and drives `briefShowFitToPrintCanvas`, plus
   `briefShowExportData` and `ExportFormat` pasted in out of Develop.swift.
   It WRITES real JPEG, PNG and TIFF files and reads their size and dpi back
   with ImageIO — the claim is about what is in the file, so the file is what
   is measured.

2. READ FROM THE SOURCE — the wiring:
     - all three export buttons go through ONE encoder. Three copies of
       "make a CGImage, wrap it, encode" is three places for the print size
       and the dpi to be forgotten in, and two of them would have been found
       by a client holding a print of the wrong size,
     - all three ask `printCanvasPixels`, and it reads the flattened
       snapshot — which is the only place a baked print's frame still exists,
     - the dpi is stamped only for a print,
     - the fit is a scale, not a crop or a stretch.

Negative controls, RUN rather than assumed (20.09):
  - the scale removed from the fit, so a big bake is merely CROPPED to the
    paper: 2 checks fail, and the one that matters is "the whole print is
    scaled onto the paper, not cropped to it" — the mark reads 0.170 of the
    width instead of 0.100. ⚠️ The SIZE checks all passed under that fault:
    a cropped 5100-wide bake is still 3000 × 2400. That is why the picture is
    measured and not only its dimensions;
  - the dpi passed as nil for a print: 3 checks fail, one per format, each
    reading 72 back out of the written file.
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEVELOP = ROOT / "BriefShow" / "Develop.swift"
TEMPLATES = ROOT / "BriefShow" / "Templates.swift"
TEST = ROOT / "Tools" / "test-print-export.swift"

develop = DEVELOP.read_text(encoding="utf-8")
templates = TEMPLATES.read_text(encoding="utf-8")

failures = 0


def wiring(label: str, passed: bool, detail: str = "") -> None:
    global failures
    if passed:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{('   ' + detail) if detail else ''}")


def extract(header: str, text: str = develop, where: str = "Develop.swift") -> str:
    """The whole declaration, bounded by brace balance."""
    start = text.find("\n" + header)
    if start == -1:
        sys.exit(f"{header!r} not found in {where} — was it renamed or moved?")
    start += 1
    depth, i = 0, text.index("{", start)
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    sys.exit(f"could not find the end of {header!r}")


print("\ncompiling the real encoder with the test")
sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                     capture_output=True, text=True, check=True).stdout.strip()

pasted = "\n\n".join([
    extract("enum ExportFormat: String, CaseIterable, Identifiable {"),
    extract("func briefShowExportData(_ rendered: CIImage,"),
])

test = TEST.read_text(encoding="utf-8")
anchor = "// ---- the real encoder, pasted in by the extractor at run time -------------"
if anchor not in test:
    sys.exit("marker line missing from test-print-export.swift")

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    main = work / "main.swift"
    main.write_text(test.replace(anchor, anchor + "\n" + pasted, 1), encoding="utf-8")
    binary = work / "print-export"
    build = subprocess.run(
        ["swiftc", "-O", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-macos13.0",
         str(TEMPLATES), str(main), "-o", str(binary)],
        capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        sys.exit("the compiled half did not build")
    compiled = subprocess.call([str(binary)])

print("\nwhat the source says, which no written file can show")

# ONE encoder. Counted, because the fault being fixed was three copies.
wiring("there is exactly one place that encodes an export",
       develop.count("func briefShowExportData(") == 1)
raw_encoders = [line.strip() for line in develop.splitlines()
                if "format.encode(" in line and "briefShowExportData" not in line]
wiring("and nothing else calls the encoder directly",
       len(raw_encoders) == 1 and "return format.encode(representation" in raw_encoders[0],
       f"{raw_encoders}")

# ⚠️ FOUR, not three. The fourth — the filmstrip's multi-selection export —
# was missed when this was written and found by the check above, which is the
# whole reason that check counts rather than trusting a list.
for name in ("private func exportEditedCopy() {",
             "private func exportSinglePhoto(_ url: URL) {",
             "private func exportSelectedPhotos(_ urls: [URL]) {",
             "private func exportAllEditedPhotos() {"):
    body = extract("    " + name)
    label = name.split("(")[0].replace("private func ", "")
    wiring(f"{label} asks what paper this print is on",
           "PhotoEditRenderer.printCanvasPixels(" in body)
    wiring(f"{label} lands it on that paper",
           "briefShowFitToPrintCanvas(rendered, canvas: canvas)" in body)
    wiring(f"{label} writes through the one encoder",
           "briefShowExportData(" in body)
    wiring(f"{label} stamps the dpi for a print and only for a print",
           "dpi: canvas == nil ? nil : PrintOutput.dpi" in body)

# The half nobody would think of: a baked print's record is EMPTY.
canvas_for = extract("    static func printCanvasPixels(for settings: PhotoEditSettings, photo: URL?) -> CGSize? {")
wiring("a live record's template is read off the record",
       "TemplateLibrary.shared.template(id: settings.templateID)" in canvas_for)
wiring("and a BAKED print's off the snapshot, which is the only place it is left",
       "FlattenedImageStore.snapshot(for: photo)" in canvas_for
       and "template(id: baked.templateID)" in canvas_for)
wiring("a photograph that is not a print asks for nothing",
       "return nil" in canvas_for)

# The fit itself: a scale, and the pure maths lives where the rest of the
# print geometry lives, so a test can drive it without a window.
fit = extract("func briefShowFitToPrintCanvas(_ image: CIImage, canvas: CGSize) -> CIImage {",
              templates, "Templates.swift")
wiring("the fit is one uniform scale, not two",
       "CGAffineTransform(scaleX: scale, y: scale)" in fit)
wiring("and the dpi it is measured against is the one constant",
       "PrintOutput.dpi" in develop and "static let dpi: Double = 300" in templates)

print()
if compiled != 0:
    failures += 1
    print("the compiled half FAILED")
print("all good\n" if failures == 0 else f"{failures} FAILED\n")
sys.exit(0 if failures == 0 else 1)
