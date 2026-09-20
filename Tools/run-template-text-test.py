#!/usr/bin/env python3
"""Text on the print — KORAK 198, step 5.

    python3 Tools/run-template-text-test.py

The client's words, 20.09: *„isto da moze da se doda Text na templateu, i da
koristi sva free google fonta"*. The Google catalogue is step 6; this is the
text, set in the fonts the machine already has.

Two halves.

1. COMPILED. Tools/test-template-text.swift is built against the real
   BriefShow/Templates.swift — the file that ships — and RENDERS through its
   own `briefShowComposeTemplate` and `briefShowComposeTextsOnPhoto`, then
   counts pixels. What it holds down is
   the one thing that decides whether this works at all: a text lands in the
   same place and at the same size on the preview canvas as on the 3000 px
   print. It also holds the size being INCHES of paper, the three alignments,
   text staying on top with the art either way up, an empty text drawing
   nothing, the drag staying on the paper, and a missing font still printing.

2. READ FROM THE SOURCE — the wiring a render cannot see:
     - the text is in the PHOTO's record and travels with `.template` in a
       sync, which is what the client asked the sync for,
     - taking the template off takes the text with it,
     - the arrow keys move a picked-up text, and the two selections (text and
       photograph) are never both on,
     - the record stores four numbers for a colour, not an archived NSColor,
     - Templates.swift still knows nothing about AppKit or SwiftUI: the batch
       flatten and the export draw these prints with no window anywhere.

Negative controls, RUN rather than assumed (20.09 and 21.09):
  - the hand-written `init(from:)` on TemplateText removed, leaving Swift's
    synthesized one: "a line written before the eye existed is visible" fails
    with "did not decode at all". ⚠️ This is how the fault was FOUND rather
    than a control written afterwards — Swift's synthesized decoding does not
    fall back on a property's default when a key is missing, it throws, and one
    line that will not decode turns every edit in the app into `[:]`;
  - the typing plate drawn in the app's own theme, which is the fault the
    client reported: 3 checks fail, black reading 1.3:1 against it. The same
    checks also caught the FIRST fix — near-white/near-black plates chosen by a
    luminance threshold — where the tan #B89973 came out at 2.5:1, readable on
    neither;
  - the hue wrap removed from `briefShowColor(from:)`: "a hue below zero wraps
    round the circle" fails, reading #FF0080 instead of the purple at 0.75.
    ⚠️ The check written first — "1.0 is the same red as 0.0" — passed under
    that fault, because the sector is taken modulo six anyway. A hue BELOW zero
    is the one the modulo cannot save;
  - the `gap >= 0` dropped from the second-click decision: "a clock that goes
    backwards opens nothing" fails — NTP or a sleep/wake would open a line for
    typing on a single click;
  - the id not cleared before the write in commitCanvasText: "submit and
    focus-loss together cannot write twice" fails. ⚠️ It first CRASHED the
    ruler instead of failing it (`str.index` on a string that was no longer
    there), which is a ruler that cannot report — now it measures;
  - the canvas offset dropped when laying text on a PHOTOGRAPH: "a cropped
    photo has its text in the same place" fails — a cropped photo's extent does
    not start at zero, so the writing lands off the picture entirely;
  - the font size taken as POINTS (`sizeInches * 72`) instead of inches of
    paper: 4 checks fail, and the numbers are the point of the whole step —
    a line 0.36 of the paper wide on the preview prints 0.072 wide, a fifth of
    what was placed;
  - the text composited UNDER what is already on the canvas: 6 checks fail,
    including both ways the print is stacked, with 0 lit pixels.
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATES = ROOT / "BriefShow" / "Templates.swift"
DEVELOP = ROOT / "BriefShow" / "Develop.swift"
TEST = ROOT / "Tools" / "test-template-text.swift"

templates = TEMPLATES.read_text(encoding="utf-8")
develop = DEVELOP.read_text(encoding="utf-8")

failures = 0


def wiring(label: str, passed: bool, detail: str = "") -> None:
    global failures
    if passed:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{('   ' + detail) if detail else ''}")


def body(text: str, marker: str) -> str:
    if marker not in text:
        return ""
    start = text.index(marker)
    depth, i = 0, text.index("{", start)
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    return ""


print("\ncompiling the real Templates.swift with the test")
sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                     capture_output=True, text=True, check=True).stdout.strip()

# The click decision lives in Develop.swift, which cannot be compiled on its
# own — so it is pasted in, the same way run-delete-key-test.py does it.
click = body(develop, "func briefShowIsSecondTextClick(previous: (id: UUID, at: Date)?,")
if not click:
    sys.exit("briefShowIsSecondTextClick not found in Develop.swift — renamed or moved?")

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    binary = work / "template-text"
    # swiftc allows top-level code only in main.swift, so the test is copied
    # under that name rather than written under it.
    main = work / "main.swift"
    anchor = "// ---- the real click decision, pasted in by the extractor at run time ------"
    test = TEST.read_text(encoding="utf-8")
    if anchor not in test:
        sys.exit("marker line missing from test-template-text.swift")
    main.write_text(test.replace(anchor, anchor + "\n" + click, 1), encoding="utf-8")
    build = subprocess.run(
        ["swiftc", "-O", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-macos13.0",
         str(TEMPLATES), str(main), "-o", str(binary)],
        capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        sys.exit("the compiled half did not build")
    compiled = subprocess.call([str(binary)])

print("\nwhat the source says, which no render can see")

# Where the text LIVES. In the photo's record, beside the placement — a text
# kept on the template would be one text for every photograph printed in it.
settings = body(develop, "struct PhotoEditSettings")
wiring("the text is in the photo's record",
       "var templateTexts: [TemplateText] = []" in settings)
wiring("and an older record decodes to a print with nothing written on it",
       "decodeIfPresent([TemplateText].self, forKey: .templateTexts) ?? []" in develop)
wiring("it is in the coding keys, so it survives a restart",
       re.search(r"case templateID, templatePlacement, templateArtOverPhoto, templateTexts",
                 develop) is not None)

# The sync. ⚠️ ITS OWN TICK since 20.09 („isto dodaj da text moze isto da se
# sync-uje"), and NOT the template's: by then text went on ordinary photographs
# too, and a tick called "Print Template" that also wrote words onto photos
# with no template in sight is a tick that lies.
merged = body(develop, "    private static func mergedSyncSettings(")
template_branch = merged.split("if items.contains(.template) {", 1)[-1].split("}", 1)[0]
text_branch = merged.split("if items.contains(.text) {", 1)[-1].split("}", 1)[0]
wiring("the text has its own tick in a sync",
       "result.templateTexts = source.templateTexts" in text_branch)
wiring("and the template's tick does not carry it",
       "templateTexts" not in template_branch)
wiring("the tick is a bit of its own", "static let text = SyncItem(rawValue: 1 << 22)" in develop)
wiring("it is a row in the dialog", 'Row(item: .text, title: "Text"' in develop)
wiring("and the dialog can tell when a photo has some",
       "case .text: return !settings.templateTexts.isEmpty" in develop)

sync_source = body(develop, "    private var syncSourceSettings: PhotoEditSettings {")
wiring("a sync off a BAKED photo reads the text out of its snapshot too",
       "source.templateTexts = baked.templateTexts" in sync_source)

remove = body(develop, "    private func removeTemplateFromPhoto() {")
wiring("taking the template off KEEPS the text — it belongs to the picture now",
       "settings.templateTexts = []" not in remove)

# One set of arrow keys, one thing they move — on a print or on a photograph.
wiring("the arrow keys move a picked-up text",
       "nudgeTemplateText(dxPixels:" in develop
       and "isTemplateSlotEditable || isTextEditable, selectedTemplateTextID != nil" in develop)

# Text on an ordinary photograph — the whole of the 20.09 change.
render = body(develop, "    static func render(_ settings: PhotoEditSettings, on base: PhotoBaseImage,")
wiring("a photo with no template still gets its text drawn",
       "briefShowComposeTextsOnPhoto(settings.templateTexts, over: output)" in render)
wiring("and only on the renders that are not MEASURING the photograph",
       "} else if applyCrop, !settings.templateTexts.isEmpty {" in render)
# ⚠️ PhotoEditSettings' own `isNeutral`, not the first one in the file — three
# other types have one, and reading a one-line ColorMixerBand instead is a
# check that can only ever fail.
neutral = body(settings, "    var isNeutral: Bool {")
wiring("a photo whose only edit is a line of text counts as edited",
       "templateTexts.isEmpty" in neutral)
wiring("Text has its own tab, beside Templates",
       'case text = "Text"' in develop and "tabItem(.text)" in develop)
wiring("and its own drag on the canvas when there is no template",
       "textOnlyDragOverlay(frame:" in develop
       and "settings.templateID == nil" in body(develop, "    private var isTextEditable: Bool {"))

# The two reports from the screenshot, 20.09: a popover you could see through
# and a black "Regular" on a dark field.
browser = body(develop, "    private func templateFontBrowser(index: Int) -> some View {")
wiring("the font browser paints its own background",
       "presentationBackgroundIfAvailable(AppColors.panel)" in browser
       and ".background(AppColors.panel)" in browser)
wiring("and does not leave a Picker to paint itself in the system's colours",
       "pickerStyle(.segmented)" not in browser)
editor = body(develop, "    private func textEditor(index: Int) -> some View {")
# ⚠️ The FACE control, not any control whose name ends in Picker: the colour
# well beside it is a `ColorPicker`, and looking for "Picker(" found that.
wiring("the face list is a Menu with its colours set, not a Picker",
       "Picker(\"\", selection: text.fontFace)" not in editor
       and "Menu {" in editor
       and "Text(settings.templateTexts[index].fontFace)" in editor)

# The cursor, and what selected looks like.
overlay = body(develop, "    private func templateTextBoxOverlay(_ item: TemplateText, frame: CGRect) -> some View {")
wiring("the pointer says the text can be picked up, and that it has been",
       "NSCursor.openHand.push()" in overlay and "NSCursor.closedHand.push()" in overlay)
wiring("every cursor push is popped",
       overlay.count("NSCursor.pop()") == 2 and overlay.count(".push()") == 2)
wiring("a selected text looks selected: outline, wash and corner dots",
       "layerSelectionColor.opacity(0.12)" in overlay
       and "stroke(layerSelectionColor, lineWidth: 1.4)" in overlay
       and "ForEach(LayerCorner.allCases" in overlay)
picking_up_text = develop.count("selectedTemplateTextID = item.id")
wiring("picking up a text puts the photograph down",
       develop.count("templatePhotoSelected = false") >= picking_up_text and picking_up_text >= 2)
wiring("and picking up the photograph is still its own thing",
       "templatePhotoSelected = true" in develop)

# The record is JSON. An archived NSColor in it is a blob inside a blob.
colour = body(templates, "struct TemplateTextColor")
wiring("a colour is four numbers, not an archived NSColor",
       "var red: Double" in colour and "NSColor" not in colour)

# The size, and the rule the whole feature rests on.
text_struct = body(templates, "struct TemplateText: Codable, Equatable, Identifiable {")
wiring("the size is in inches of print", "var sizeInches: Double" in text_struct)
wiring("and the box is a fraction of the canvas",
       "var box: NormalizedRect" in text_struct)
wiring("nothing in the record is a pixel",
       "Pixels" not in text_struct and "pixels" not in text_struct.lower().replace("pixelsperinch", ""))
wiring("an inch is read off the CANVAS, not off the dpi constant",
       "canvasWidth" in body(templates, "func briefShowPixelsPerInch("))

# Text is topmost and it is not a switch — checked in the render above, and
# the reason is here so a later session does not "add the option".
wiring("the composition lays the text through one way out",
       "func finished(" in templates and templates.count("return finished(") == 3)

# The file still draws prints with no window anywhere.
wiring("Templates.swift knows nothing about AppKit or SwiftUI",
       "import AppKit" not in templates and "import SwiftUI" not in templates)
wiring("and it draws its text with CoreText",
       "import CoreText" in templates and "CTFramesetterCreateWithAttributedString" in templates)

# The fonts. Step 6 swaps the LIST, not the two fields the record carries.
wiring("a text names a family and a face, the shape step 6 needs",
       "var fontFamily: String" in text_struct and "var fontFace: String" in text_struct)
wiring("a face that the new family does not have is replaced, not carried",
       "briefShowFontFaces(in: family)" in develop
       and "settings.templateTexts[index].fontFace = faces.first" in develop)

# Typing on the canvas — client, 21.09.
field = body(develop, "    private func canvasTextField(_ item: TemplateText, box: CGRect, frame: CGRect) -> some View {")
overlay_edit = body(develop, "    private func templateTextBoxOverlay(_ item: TemplateText, frame: CGRect) -> some View {")
commit = body(develop, "    private func commitCanvasText() {")

wiring("a second click on the canvas opens the line for typing",
       "briefShowIsSecondTextClick(" in overlay_edit and "beginEditingText(item)" in overlay_edit)
wiring("and it is not a count-2 gesture, which would hold the first click",
       "onTapGesture(count: 2)" not in overlay_edit)
wiring("while typing, the box carries no drag and no tap",
       "if isEditing {" in overlay_edit and "} else {" in overlay_edit)
wiring("the field writes into the SAME record the panel writes into",
       "settings.templateTexts[index].text = editingTextValue" in commit)
wiring("Esc throws the typing away, as it does on a folder row",
       "onExitCommand" in field and "editingTextID = nil" in field)
wiring("and losing focus to anything keeps it",
       "onChange(of: canvasTextFieldFocused)" in field and "commitCanvasText()" in field)
# ⚠️ `find`, not `index`: with the line removed the ruler THREW instead of
# reporting, which is a ruler that cannot fail — it only crashes.
cleared_at = commit.find("editingTextID = nil")
writes_at = commit.find("firstIndex(where:")
wiring("submit and focus-loss together cannot write twice",
       cleared_at != -1 and writes_at != -1 and cleared_at < writes_at,
       f"cleared at {cleared_at}, writes at {writes_at}")
wiring("what is typed is drawn at the size it will print",
       "item.sizeInches * pixelsPerInch" in field
       and "briefShowPhotoPixelsPerInch(" in field
       and "briefShowPixelsPerInch(template:" in field)
wiring("and on a plate, so it is not typed over its own drawn copy",
       "briefShowEditingPlate(for: item.color)" in field)
wiring("the plate follows the TEXT's colour, never the app's theme",
       "AppColors.background" not in field and "AppColors.panel" not in field)
wiring("and the caret is the text's colour too",
       ".tint(Color(nsColor: NSColor(srgbRed: item.color.red" in field)

# The colour picker, 21.09: *„ovo za boju texta mora da bude u themi app-a"*.
wiring("nothing opens the system's Colors window any more",
       "ColorPicker(" not in develop)
picker = body(develop, "    private func textColourPicker(index: Int) -> some View {")
wiring("the app draws its own picker, in its own panel colour",
       "presentationBackgroundIfAvailable(AppColors.panel)" in picker
       and ".background(AppColors.panel)" in picker)
wiring("its hue slider is the one this app already has, not a second kind",
       "GradientTrackSlider(" in picker)
wiring("a grey keeps the hue the slider is on",
       "textColourHue" in picker and "hsb.saturation < 0.001" in picker)
wiring("a hex that means nothing changes nothing",
       "if let picked = briefShowColor(fromHex: textColourHex" in picker)
wiring("and the swatches are named once, beside the colour maths",
       "briefShowTextSwatches" in picker
       and "let briefShowTextSwatches" in TEMPLATES.read_text(encoding="utf-8"))

# The Layers panel, 21.09: *„ovde mora da pokaze text layer … ali ga ne vidim
# kao layer"*.
layers = body(develop, "    private var layersSection: some View {")
row = body(develop, "    private func textLayerRow(_ item: TemplateText) -> some View {")
wiring("a line of text has a row in the Layers panel",
       "textLayerRow(item)" in layers)
wiring("and it is listed ABOVE the layers, which is where it is drawn",
       layers.index("textLayerRow(item)") < layers.index("ForEach(Array(settings.layers.reversed()))"))
wiring("⛔ a line of text is NOT turned into an ImageLayer to get there",
       "ImageLayer(" not in row and "settings.layers" not in row)
wiring("the row has an eye and a trash, like the rows beside it",
       "toggleTemplateTextVisible(item.id)" in row and "removeTemplateText(item.id)" in row)
wiring("and no grip, because there is nothing to reorder it against",
       "line.3.horizontal" not in row and "onDrag" not in row)
wiring("the eye is ONE function, called from both panels",
       develop.count("toggleTemplateTextVisible(item.id)") == 2
       and develop.count("private func toggleTemplateTextVisible(") == 1)
wiring("a hidden line cannot be grabbed on the canvas either",
       develop.count("settings.templateTexts.filter { $0.isVisible }") == 2)
wiring("and the drawing itself refuses it",
       "guard text.isVisible," in TEMPLATES.read_text(encoding="utf-8"))

print()
if compiled != 0:
    failures += 1
    print("the compiled half FAILED")
print("all good\n" if failures == 0 else f"{failures} FAILED\n")
sys.exit(0 if failures == 0 else 1)
