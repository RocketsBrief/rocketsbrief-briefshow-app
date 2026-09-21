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


def templates_source_or_develop(marker: str, text: str) -> str:
    """The body of a type, wherever it lives, so a check reads the thing it names."""
    return text.split(marker, 1)[-1].split("\n}", 1)[0] if marker in text else ""


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
templates_source = source
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
# ⚠️ CHANGED 20.09. Clicking a tile used to follow the pair — click the
# horizontal frame on an upright photograph and the vertical half arrived —
# and the client read that as the tiles not swapping. The pair rule stays, but
# it belongs to the sync, where nobody is clicking anything.
apply_body = develop_code.split("private func applyTemplate(", 1)[-1].split("\n    }", 1)[0]
wiring("clicking a tile uses THAT template, whatever way up the photo is",
       "settings.templateID = template.id" in apply_body
       and "briefShowTemplateForPhoto(" not in apply_body)
wiring("but it says which one would have fitted",
       "func orientationNote(" in develop_code and "pairID" in develop_code)
wiring("the pair rule is still there for the sync to use",
       "briefShowTemplateForPhoto(" in templates_source)
wiring("a first template starts centred; swapping keeps the framing being compared",
       "settings.templatePlacement = .centred" in apply_body
       and "if swapping {" in apply_body)
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

# Step 3, second half — the picture is picked up, turned and resized.
# ⚠️ The outline has to be GATED on the selection, not merely present in the
# file: a first version of this check only looked for the colour, and passed
# over a copy where the whole block was switched off.
overlay_body = develop_code.split("func templateSlotDragOverlay(", 1)[-1].split("\n    /// A corner handle", 1)[0]
wiring("picking the photo up is visible — an outline appears when it is selected",
       "if templatePhotoSelected {" in overlay_body and "layerSelectionColor" in overlay_body)
wiring("and the handles hang off that same gate",
       overlay_body.index("if templatePhotoSelected {") < overlay_body.index("templateHandleView("))
wiring("a click on the mat puts it down again",
       "templatePhotoSelected = false" in develop_code)
wiring("it can be turned, with the same detent and sign as a layer's knob",
       "func rotateTemplatePhoto(" in develop_code
       and "atan2(dx, -dy)" in develop_code
       and "(degrees / 5).rounded() * 5" in develop_code)
wiring("and resized from its corners, by the RATIO of two distances",
       "func resizeTemplatePhoto(" in develop_code and "start.zoom * Double(distance / start.distance)" in develop_code)
wiring("resizing keeps the photo's proportions — it goes through the zoom, never a stretch",
       "setTemplateZoom(start.zoom" in develop_code)
# ⚠️ ONE function for both, by name. Two of them is what put the outline off
# the picture by twice the offset: the renderer worked in Core Image's
# bottom-up coordinates and the outline in the screen's top-down ones.
outline_body = develop_code.split("func templatePhotoRectOnScreen(", 1)[-1].split("\n    }", 1)[0]
compose_body = templates_source.split("func briefShowComposeTemplate(photo: CIImage,\n                              template: PrintTemplate,\n                              art: CIImage?", 1)[-1]
wiring("the outline asks for the photo's rectangle by the shared function",
       "briefShowPhotoRectOnCanvas(" in outline_body)
# KORAK 208 moved the placement into briefShowPhotoPlacementTransform, which
# Merge Layers shares; the renderer reaches the same function through it.
placement_body = templates_source.split("func briefShowPhotoPlacementTransform(", 1)[-1].split("\n}\n", 1)[0]
wiring("and so does the renderer, instead of working it out its own way",
       "briefShowPhotoPlacementTransform(" in compose_body
       and "briefShowPhotoRectOnCanvas(" in placement_body
       and "flipped: true" not in compose_body and "flipped: true" not in placement_body)
wiring("the drag is measured in a named canvas space, so the outline cannot shake",
       'coordinateSpace: .named(Self.templateCanvasSpace)' in develop_code)
wiring("a turn is stored clockwise and the composition turns the other way to match",
       "rotated(by: CGFloat(-placement.rotationDegrees" in templates_source)
wiring("the photo is put down when the client moves to the next one",
       "templatePhotoSelected = false" in
       develop_code.split("private func selectPhoto(", 1)[-1].split("\n    }", 1)[0])

# The arrows, asked for 20.09 — and the filmstrip they must not take over.
keys = develop_code.split("[123, 124, 125, 126].contains(event.keyCode)")
wiring("the arrows nudge the picture in the template",
       "func nudgeTemplatePhoto(" in develop_code
       and "nudgeTemplatePhoto(dxPixels:" in develop_code)
# ⚠️ Against the CODE of the filmstrip walk, not against its comment: the
# comments are stripped out of develop_code, and a check that looks for one
# there can only ever fail.
wiring("only while it is picked up — otherwise they still walk the filmstrip",
       "isTemplateSlotEditable, templatePhotoSelected {" in develop_code
       and develop_code.index("isTemplateSlotEditable, templatePhotoSelected {")
           < develop_code.index("stepPhoto(by: event.keyCode == 124 ? 1 : -1)"))
wiring("the layer nudge still comes first, so a selected layer keeps its arrows",
       develop_code.index("nudgeLayer(at: index, dxPixels: -pixels") <
       develop_code.index("nudgeTemplatePhoto(dxPixels: -pixels"))
wiring("a nudge is whole PRINT pixels, so one press is one step at any preview size",
       "canvas.width" in develop_code.split("func nudgeTemplatePhoto(", 1)[-1].split("\n    }", 1)[0])
wiring("and it goes through the same clamp as the drag",
       "briefShowClampedPlacement(" in develop_code.split("func nudgeTemplatePhoto(", 1)[-1].split("\n    }", 1)[0])
wiring("⇧ makes the step ten, as it does for a layer",
       'flags == .shift ? 10 : 1' in develop_code)

# ⚠️ FLATTEN. The bake renders with applyCrop: false and the canvas is composed
# inside that branch, so a flatten never bakes the frame — which means dropping
# the id does not bake it either, it throws it away. Reported 20.09: „kada sam
# isao flatten photo desilo se ovo nema template-a".
# ⚠️ Each site is found by what CLOSES it, not by counting occurrences: the
# first version split on "var cleared = …" and, with one site emptied out,
# reported the fault against the other one's name.
# ⚠️ THIS TURNED ROUND ON 198.10. The template used to be carried THROUGH the
# flatten as a setting, like the crop; the client tried it and said what he
# means by the word — „jednom flatten to je to nema layera ne moze da se
# selektuje slika!". So the bake draws the print, and the record comes back
# with nothing in it to pick up.
flatten_body = develop_code.split("private func flattenPhoto(", 1)[-1].split("loadImages(for: photoAtActionTime)", 1)[0]
wiring("a flatten with a template bakes the print",
       "applyCrop: bakesTemplate" in flatten_body
       and "templateCanvasScale: bakeScale" in flatten_body)
wiring("and leaves nothing selectable behind",
       "cleared.templateID" not in flatten_body
       and "templatePhotoSelected = false" in flatten_body)
wiring("the crop goes in with it — a crop left live would crop the MAT",
       "if !bakesTemplate {" in flatten_body and "cleared.crop = cropToKeep" in flatten_body)
wiring("the bake is drawn at the scale that keeps the photo's pixels",
       "briefShowBakeCanvasScale(" in flatten_body)

# ⚠️ THE RECIPE BATCH is the other way round, and on purpose: it renders with
# applyCrop: false, bakes no canvas, and so must not drop what it did not bake.
#
# ⚠️ Anchored on the recipe undo, not on "outcome.settingsByURL[url] = cleared":
# the sync's own batch bake ends with that same line now, and the check read
# the wrong one of the two the moment it existed.
recipe_body = develop_code.split("PortraitRecipeUndoStore.record(", 1)[-1].split("outcome.settingsByURL[url] = cleared", 1)[0]
wiring("the recipe batch, which composes no canvas, keeps the template instead",
       "cleared.templateID" in recipe_body and "cleared.templatePlacement" in recipe_body)

wiring("a photo laid into a frame HAS something to bake",
       "keptByFlatten.templateID" not in develop_code)

# Step 4 — the sync across a selection.
sync_body = develop_code.split("private func syncSettingsToSelection(", 1)[-1].split("\n    //", 1)[0]
wiring("the sync has a row of its own",
       "static let template = SyncItem(rawValue: 1 << 21)" in develop_code
       and 'Row(item: .template, title: "Print Template"' in develop_code)
wiring("the row lights up only when the open photo has a template",
       "case .template: return settings.templateID != nil" in develop_code)

# ⚠️ Read off the TARGET. This is the rule: an upright frame in a run of
# landscapes gets the pair's vertical half, and if there is no pair it gets
# nothing — never a portrait printed sideways.
wiring("each target's own orientation decides which half it gets",
       "briefShowPhotoOrientation(at: target)" in sync_body
       and "briefShowSyncedTemplate(" in sync_body)
wiring("a photo that cannot take it keeps everything else that was ticked",
       "itemsForTarget.remove(.template)" in sync_body)
wiring("and the sync says how many were left out, and why",
       "skippedForOrientation" in sync_body and "has no pair" in develop)
wiring("orientation is read from metadata, without decoding the file",
       "CGImageSourceCopyPropertiesAtIndex(" in templates_source
       and "kCGImagePropertyOrientation" in templates_source)
wiring("the EXIF tag decides, not the pixel counts",
       "(5...8).contains(exifOrientation)" in templates_source)
# ⚠️ A flattened photo's record is EMPTY — that is what 198.10 settled — so a
# sync from it used to write no frame at all. Reported 20.09: „sync nije dodao
# frames na ostale slike kada je frame slika flattenovana".
source_body = develop_code.split("private var syncSourceSettings: PhotoEditSettings {", 1)[-1].split("\n    }", 1)[0]
wiring("a sync can still carry the frame off a flattened photo",
       "FlattenedImageStore.snapshot(for: selectedURL)" in source_body)
wiring("and takes ONLY the template from that snapshot — the rest is in the pixels",
       "source.templateID = baked.templateID" in source_body
       and "source.exposure" not in source_body and "source.crop" not in source_body)
wiring("it only reaches for the snapshot when the live record has no template",
       "source.templateID == nil," in source_body)
wiring("both the dialog's dot and the sync itself read through it",
       "SyncItem.modified(in: syncSourceSettings)" in develop_code
       and "let source = syncSourceSettings" in develop_code)

wiring("layers still have no sync bit, and the reason is written beside the template's",
       "static let layers = SyncItem" not in develop_code)

# The client's answer of 20.09 to „dodaj i za 8x10 template": the model always
# had the paper, but nothing could SAY which one a drawing is when the import
# guessed wrong.
wiring("every known paper can be chosen on a template",
       'Menu("Print Size")' in develop_code and "ForEach(PrintSize.known" in develop_code)
wiring("8×10 is one of them, and it is not typed into the panel",
       "static let eightByTen = PrintSize(shortInches: 8, longInches: 10)" in templates_source)
wiring("the orientation can be corrected too — a square drawing belongs to nobody",
       'Menu("Orientation")' in develop_code)
wiring("and the library lets go of BOTH ends of a pair it has invalidated",
       "templates[index].pairID = nil" in templates_source
       and "templates[partnerIndex].pairID = nil" in templates_source)

# The tick beside Synchronize.
wiring("there is a tick to bake the synced photos",
       "syncFlattensTargets" in develop_code
       and "flattenTargets: syncFlattensTargets" in develop_code)
wiring("it is off unless it is asked for",
       "@State private var syncFlattensTargets = false" in develop_code)
wiring("the bake runs one photo at a time — this machine has 8 GB",
       "for (index, url) in targets.enumerated()" in
       templates_source_or_develop("enum TemplateBatchFlatten", develop_code))
wiring("it bakes the print for a photo that has a template, and only the crop otherwise",
       "applyCrop: template != nil" in develop_code
       and "if template == nil {" in develop_code)
wiring("a photo with nothing to bake is counted, not baked",
       "outcome.skipped += 1" in develop_code)
wiring("the settings are flushed BEFORE the bake reads them back",
       develop_code.index("PhotoEditStore.flushNow()") < develop_code.index("flattenSyncedTargets("))

wiring("deleting a template takes it off this photo first",
       "func deleteTemplate(" in develop_code and "removeTemplateFromPhoto()" in develop_code)

print("")
if failures or compiled != 0:
    print(f"{failures} wiring check(s) failed" if failures else "the compiled half failed")
    sys.exit(1)
print("all green")
