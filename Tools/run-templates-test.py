#!/usr/bin/env python3
"""The print template model — the compiled half and the wiring half.

    python3 Tools/run-templates-test.py

KORAK 198, step 1. The template is a CANVAS of print proportions holding one
slot and one drawing, plus a switch saying whether the drawing is over the
photograph or under it — which is what makes the client's two cases ("photo
below the template", "photo above it") one mechanism instead of two.

Two halves.

1. COMPILED. Tools/test-templates.swift is built against the real
   BriefShow/Templates.swift — the file that ships — and drives its own
   functions. Nothing in the test is a copy of the geometry. What it holds
   down: the pixel sizes are arithmetic off ONE dpi (8x6 -> 2400x1800,
   8x10 -> 3000x2400), fit and fill never stretch a photograph, a placement
   frames the same photograph at preview size and at 300 dpi, the hole is read
   out of the alpha channel AND a transparent margin round a drawing is not
   mistaken for it, and a portrait photograph either follows the pair to a
   vertical template or gets NOTHING.

2. READ FROM THE SOURCE — the two locked rules of the notes, which no unit
   test can see:
     - the dpi is written once and everything else is arithmetic off it,
     - a template's PIXELS never enter a record: the photo's blob carries an
       ID and the drawing lives in Application Support, under the path named
       "BriefShow" (a path to the client's data, not the product's name).

The negative control is in the notes: over a Templates.swift with the
edge-touching rule removed, the framed-drawing check fails and nothing else
does.
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Templates.swift"
TEST = ROOT / "Tools" / "test-templates.swift"

source = SOURCE.read_text()

# The checks about NUMBERS have to read the code, not the prose around it: the
# comments quote the sizes 2400x1800 and 3000x2400 on purpose, and a check that
# counts them there would be reading its own documentation.
code = "\n".join(line.split("//", 1)[0] for line in source.splitlines())

failures = 0


def wiring(label: str, passed: bool, detail: str = "") -> None:
    global failures
    if passed:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{('   ' + detail) if detail else ''}")


print("\ncompiling the real Templates.swift with the test")
sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                     capture_output=True, text=True, check=True).stdout.strip()

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    binary = work / "templates"
    # The test is top-level code, and swiftc only allows that in a file called
    # main.swift — so it is copied under that name rather than written under it.
    main = work / "main.swift"
    shutil.copy(TEST, main)
    build = subprocess.run(
        ["swiftc", "-O", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-macos13.0",
         str(SOURCE), str(main), "-o", str(binary)],
        capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        sys.exit("the compiled half did not build")
    compiled = subprocess.call([str(binary)])

print("\nwhat the source says, which no unit test can see")

# The dpi lives once. A second literal 300 used as a resolution is how a file
# ends up printing at 300 while another one prints at 240.
dpi_sites = re.findall(r"dpi[^\n]*?=\s*([0-9]+)", code)
wiring("the print resolution is written exactly once", dpi_sites == ["300"],
       f"found {dpi_sites}")
wiring("300 is the number", "static let dpi: Double = 300" in code)
wiring("every pixel size is arithmetic off it",
       code.count("* dpi") >= 2 and "2400" not in code and "3000" not in code)

# The second locked rule of the notes.
template_struct = source.split("struct PrintTemplate", 1)[-1].split("\n}", 1)[0]
wiring("a template carries a REF to its drawing, not the drawing",
       "artRef: String" in template_struct
       and ": Data" not in template_struct
       and "imageData" not in template_struct)
wiring("the store keeps drawings under the path named BriefShow",
       'appendingPathComponent("BriefShow/Templates"' in source)
wiring("the drawing's name on disk is its contents, as the layer blobs are",
       "static func artName(for data: Data)" in source and "fingerprint(data)" in source)

# The edge rule — the one that decided the hole finder.
wiring("a transparent region touching the edge is not a hole",
       "touchesEdge" in source and "!touchesEdge.contains" in source)
wiring("finding the hole is help, not a condition — there is a way through without it",
       "case needsRectangle" in source and "fallbackSlot" in source)
wiring("the import can be overruled on which paper it is",
       "size: PrintSize? = nil" in source)

# One slot today, and the reason it is a field rather than an array.
wiring("one slot, one photograph — the client's answer of 20.09",
       "var slot: TemplateSlot" in source and "var slots:" not in source)
wiring("the switch the client asked for is a single stored flag",
       "var artOverPhoto: Bool" in source)

# The pair, and the refusal that keeps sync honest.
wiring("a pair must be two different orientations of one paper size",
       "a.orientation != b.orientation" in source and "a.size == b.size" in source)
wiring("a photograph the chosen template cannot hold returns nothing",
       "briefShowTemplateForPhoto" in source and "return nil" in source)

# The resolution rule at the top of the notes: nothing here resizes a photo.
wiring("nothing in this file scales a photograph down",
       "previewMax" not in source and "thumbnail" not in source.lower())

print("\nwhat Develop.swift does with it — step 2, the wiring")

develop = (ROOT / "BriefShow" / "Develop.swift").read_text()
develop_code = "\n".join(line.split("//", 1)[0] for line in develop.splitlines())

# The record. An ID and a placement, and nothing that holds pixels.
settings_struct = develop.split("struct PhotoEditSettings", 1)[-1].split("\n}", 1)[0]
wiring("the photo's record carries the template's ID",
       "var templateID: UUID?" in settings_struct
       and "var templatePlacement" in settings_struct)
wiring("and the client's below/above switch, per photo",
       "var templateArtOverPhoto: Bool?" in settings_struct)
wiring("it is in the coding keys, so it is actually written",
       "case templateID, templatePlacement, templateArtOverPhoto" in develop_code)

# ⚠️ The migration rule this document has been bitten by before: a record
# written yesterday must decode, and must decode to the photo it was.
wiring("an older record still decodes — decodeIfPresent, not decode",
       "decodeIfPresent(UUID.self, forKey: .templateID)" in develop_code
       and "decode(UUID.self, forKey: .templateID)" not in develop_code)

wiring("a template counts as an edit, so Reset and the export lists see it",
       "&& templateID == nil" in develop_code)

# ⚠️ ORDER. The template is the paper the finished photograph is laid on, so
# it goes after everything that works on the photograph — crop and vignette
# included. Anywhere earlier and the next pass treats the mat as picture.
render = develop_code.split("static func render(", 1)[-1].split("\n    }", 1)[0]
compose_at = render.find("briefShowComposeTemplate")
vignette_at = render.rfind("applyVignette")
crop_at = render.find("if applyCrop, let crop = settings.crop")
wiring("the canvas is composed in render", compose_at != -1)
wiring("AFTER the crop and AFTER the vignette",
       compose_at > vignette_at > crop_at > 0,
       f"compose {compose_at}, vignette {vignette_at}, crop {crop_at}")
wiring("and only on renders that carry the crop — the measuring ones stay bare",
       "if applyCrop, let template = TemplateLibrary.shared.template(" in develop_code)

# The panel. Its own button, which is what the client asked for.
wiring("Templates is its own tab, not a row inside Tools",
       "case templates = \"Templates\"" in develop_code
       and "tabItem(.templates)" in develop_code
       and "case .templates:" in develop_code)
wiring("there is a way to import a drawing",
       "func importTemplateFromDisk()" in develop_code and "NSOpenPanel()" in develop_code)
wiring("choosing a template follows the PAIR, as step 4's sync will",
       "briefShowTemplateForPhoto(" in develop_code)
wiring("a fresh template starts centred rather than inheriting the last one's framing",
       "settings.templatePlacement = .centred" in develop_code)
wiring("the note does not follow the client onto the next photograph",
       "templateNote = nil" in develop_code.split("private func selectPhoto(", 1)[-1].split("\n    }", 1)[0])
# Step 3 — the photograph is moved and zoomed inside its opening.
wiring("the photo can be dragged inside its opening",
       "func templateSlotDragOverlay(" in develop_code
       and "briefShowPlacementAfterDrag(" in develop_code)

# ⚠️ The gate. Every tool on the canvas claims the same drag, and a template
# layer that ignored them would quietly break painting, cropping and masks.
gate = develop_code.split("private var isTemplateSlotEditable: Bool {", 1)[-1].split("}", 1)[0]
for tool in ("isCropping", "isRemoveBrushActive", "layerEraserActive",
             "selectedAdjustmentIndex", "activeSelection", "selectedLayerIndex", "isSpaceHeld"):
    wiring(f"the slot drag stands down for {tool}", tool in gate)

wiring("the wheel over the photo zooms it in the opening",
       "if isTemplateSlotEditable {" in develop_code
       and "setTemplateZoom(settings.templatePlacement.zoom * factor)" in develop_code)
wiring("and there is a slider for the same thing, with the client's range",
       "SlotPlacement.minimumZoom...SlotPlacement.maximumZoom" in develop_code)
wiring("every zoom goes through the clamp, so zooming out pulls the framing in",
       "briefShowClampedPlacement(" in develop_code
       and "next.zoom = zoom" in develop_code)
wiring("switching Fit/Fill re-clamps — the two do not allow the same travel",
       "settings.templatePlacement.mode = mode\n                        " in develop
       and "setTemplateZoom(settings.templatePlacement.zoom)" in develop_code)
wiring("the drag measures the photo AFTER the turns and the crop",
       "rotationQuarterTurns % 2" in develop_code and "crop.width" in
       develop_code.split("private var templatePhotoPixelSize", 1)[-1].split("\n    }", 1)[0])

# ⚠️ The client read these two as black in the dark theme. Inherited colour is
# how that happened once before, on the recipe card (KORAK 182).
wiring("both template labels set their own colour rather than inheriting one",
       develop_code.split("private func templateTile(", 1)[-1].split("\n    }", 1)[0].count("foregroundColor") >= 2)

wiring("deleting a template takes it off this photo first",
       "func deleteTemplate(" in develop_code and "removeTemplateFromPhoto()" in develop_code)

print("")
if failures or compiled != 0:
    print(f"{failures} wiring check(s) failed" if failures else "the compiled half failed")
    sys.exit(1)
print("all green")
