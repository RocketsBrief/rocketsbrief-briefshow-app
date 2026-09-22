#!/usr/bin/env python3
"""Merging layers, and the print shown as Image + Template — KORAK 205.

    python3 Tools/run-layer-merge-test.py

The client, 21.09:

    „ovde kada dodamo template, u layeru mora da se vidi Image i template!
     da moze da se klikne ne jedno ili drugo i da se edituje.. isto da mogu
     da recimo selektujem vise od jednog layera … i desni click da mi pokaze
     option mergelayers.. i samo se ta dva merguju a treci ostane jer nije bio
     selektovan.. e jedino kada idem na dugme flatten image onda da se naravne
     sve flatenuje"

Two halves.

1. COMPILED. Tools/test-layer-merge.swift is built against the REAL
   `ImageLayer`, `LayerBlendMode`, `briefShowLayerMergeRefusal`,
   `briefShowNextMergedLayerNumber` and `briefShowPNGData`, all pulled out of
   Develop.swift by text. What it holds: which selections may merge and which
   may not — with a reason that is a whole sentence, because a grey menu item
   with no explanation is a fault this document has had to fix twice already —
   the numbering, and that a merged layer really is PNG and really is cheap
   when it is mostly transparent.

2. READ FROM THE SOURCE — what no unit test can reach:
     - a merge takes the SELECTED layers and nothing else, and the ones that
       were not selected stay where they were,
     - the merged piece goes in at the topmost position it replaces, so the
       stack is not reshuffled under the client,
     - it is composited over TRANSPARENCY, so it carries no photograph,
     - it is drawn at the photograph's own resolution,
     - Flatten Photo is untouched — it still bakes everything,
     - the print shows as Image + Template, in the order the switch puts them.

Negative controls, RUN rather than assumed (21.09):
  - the mixed-selection branch removed from the rule: 3 checks fail — a People
    layer and a pasted piece would have been merged into one another;
  - the frame's row made to open the Templates tab on a single click again
    (the reported fault): "only a DOUBLE click opens the tab" fails;
  - `briefShowNextMergedLayerNumber` returning `used.count + 1`: "it takes the
    highest, not the count" fails — two merges would both come back as
    "Merged 2" after one was deleted.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEVELOP = ROOT / "BriefShow" / "Develop.swift"
TEST = ROOT / "Tools" / "test-layer-merge.swift"

develop = DEVELOP.read_text(encoding="utf-8")

failures = 0


def wiring(label: str, passed: bool, detail: str = "") -> None:
    global failures
    if passed:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{('   ' + detail) if detail else ''}")


def extract(header: str) -> str:
    start = develop.find("\n" + header)
    if start == -1:
        sys.exit(f"{header!r} not found in Develop.swift — was it renamed or moved?")
    start += 1
    depth, i = 0, develop.index("{", start)
    while i < len(develop):
        if develop[i] == "{":
            depth += 1
        elif develop[i] == "}":
            depth -= 1
            if depth == 0:
                return develop[start:i + 1]
        i += 1
    sys.exit(f"could not find the end of {header!r}")


print("\ncompiling the real layer types and merge rule with the test")
sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                     capture_output=True, text=True, check=True).stdout.strip()

# The same extraction discipline as run-editsettings-decode-test.py, and the
# same list of what ImageLayer needs before it will compile — named rather than
# discovered, so this cannot quietly start dragging in half the file.
pasted = "\n\n".join([
    extract("enum LayerPixelStore {"),
    extract("enum ColorBand:"),
    extract("struct ColorMixerBand:"),
    extract("struct ColorMixer:"),
    extract("enum LayerBlendMode:"),
    extract("struct LocalAdjustmentSettings:"),
    extract("struct ImageLayer:"),
    extract("func briefShowNextMergedLayerNumber(in layers: [ImageLayer]) -> Int {"),
    extract("func briefShowPNGData(_ image: CGImage) -> Data? {"),
    extract("func briefShowLayerMergeRefusal(_ layers: [ImageLayer]) -> String? {"),
    extract("func briefShowPhotoMergeRefusal(imagePicked: Bool, templatePicked: Bool,"),
    extract("enum MergeRowKey: Hashable {"),
    extract("func briefShowMergeRow(at point: CGPoint, in frames: [MergeRowKey: CGRect]) -> MergeRowKey? {"),
])

test = TEST.read_text(encoding="utf-8")
anchor = "// ---- the real types and rule, pasted in by the extractor at run time ------"
if anchor not in test:
    sys.exit("marker line missing from test-layer-merge.swift")

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    main = work / "main.swift"
    main.write_text(test.replace(anchor, anchor + "\n" + pasted, 1), encoding="utf-8")
    binary = work / "layer-merge"
    build = subprocess.run(
        ["swiftc", "-O", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-macos13.0", str(main), "-o", str(binary)],
        capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        sys.exit("the compiled half did not build")
    compiled = subprocess.call([str(binary)])

print("\nwhat the source says, which no unit test can reach")

merge = extract("    private func mergeSelectedLayers() {")
targets = extract("    private var layerMergeTargets: [ImageLayer] {")
composite = extract("    static func mergedLayerImage(_ layers: [ImageLayer], extent: CGRect) -> CIImage? {")
menu = extract("    private func layerOnlyMergeMenuItem(clickedOn layer: ImageLayer) -> some View {")
extend = extract("    private func extendLayerSelection(to id: UUID, shift: Bool) {")

wiring("a merge refuses whatever the rule refuses",
       "briefShowLayerMergeRefusal(targets) == nil" in merge)
wiring("the unselected layers are kept, not rebuilt",
       "settings.layers.filter { !ids.contains($0.id) }" in merge)
wiring("and the merged piece goes in where the topmost one was",
       "lastIndex(where: { ids.contains($0.id) })" in merge and "insert(" in merge)
wiring("the pieces are taken in STACK order, not in the order they were clicked",
       "settings.layers.filter { ids.contains($0.id) }" in targets)
wiring("the layer the editor is on is always part of the merge",
       "if let selectedLayerID { ids.insert(selectedLayerID) }" in targets)
wiring("it is composited over transparency, so it carries no photograph",
       "CIImage.empty().cropped(to: extent)" in composite)
wiring("and drawn at the photograph's own resolution",
       "fullBaseImage?.extent ?? previewBaseImage?.extent" in merge
       and "CGRect(origin: .zero, size: extent.size)" in merge)
wiring("the menu prints the reason when it cannot",
       "Text(refusal)" in menu and ".disabled(refusal != nil)" in menu)
wiring("right-clicking a layer outside the set means that layer",
       "? layerMergeTargets" in menu and ": [layer]" in menu)
# ⚠️ The circle, because the held key was not enough on the real machine.
row = extract("    private func layerRow(_ layer: ImageLayer) -> some View {")
toggle = extract("    private func toggleLayerInMergeSet(_ id: UUID) {")
wiring("every layer row carries a circle that picks it for a merge",
       "toggleLayerInMergeSet(layer.id)" in row
       and "checkmark.circle.fill" in row)
# ⚠️ What this guards is that the circle is its OWN Button with its OWN style,
# so the row's drag gesture cannot swallow the tap. It used to name
# `.buttonStyle(.plain)` literally, and on 23.09 every plain button in the app
# was given PlainHoverButtonStyle so it would answer the pointer like the rest.
# The circle is still its own button; only the style's name changed. Checking
# for "a style of its own" rather than for one spelling, so the next such change
# does not read as this button losing its handler.
wiring("and it is a button of its own, which the row's drag cannot swallow",
       ".buttonStyle(.plain)" in row or ".buttonStyle(PlainHoverButtonStyle" in row)
wiring("picking one circle brings the selected layer in with it",
       "multiSelectedLayerIDs.insert(selectedLayerID)" in toggle)
wiring("and unpicking the last one leaves nothing picked",
       "multiSelectedLayerIDs = []" in toggle)
wiring("⌘ adds one and ⇧ takes the run between",
       "multiSelectedLayerIDs.insert(id)" in extend
       and "Set(settings.layers[range].map(\\.id))" in extend)

# ⚠️ The client's own sentence: Flatten is the one that does everything.
flatten = extract("    private func flattenPhoto() {") if "    private func flattenPhoto() {" in develop else ""
wiring("Flatten Photo still bakes the whole photo, untouched by any of this",
       "mergeSelectedLayers" not in flatten and "multiSelectedLayerIDs" not in flatten)

# The print, as two rows.
layers_panel = extract("    private var layersSection: some View {")
photo_row = extract("    private func templatePhotoLayerRow() -> some View {")
template_row = extract("    private func templateLayerRow(_ template: PrintTemplate) -> some View {")
wiring("a print shows as Image and Template, both",
       "templateLayerRow(template)" in layers_panel and "templatePhotoLayerRow()" in layers_panel)
wiring("and their order follows the photo-under/photo-over switch",
       "if artOnTop {" in layers_panel
       and layers_panel.count("templateLayerRow(template)") == 2)
wiring("clicking the frame opens the tab it is worked on in",
       "panelTab = .templates" in template_row)
wiring("clicking the image picks the photo up in the frame",
       "templatePhotoSelected = true" in photo_row)
wiring("the frame's trash is the SAME call the Templates tab makes",
       "removeTemplateFromPhoto()" in template_row)
wiring("and the photograph has no trash and no eye — it is the photograph",
       "trash" not in photo_row and "eye" not in photo_row)
wiring("the empty line does not claim there is nothing, since the photo is a row",
       "Just the photo so far." in layers_panel
       and "settings.layers.isEmpty && settings.templateTexts.isEmpty" in layers_panel)

# The two kinds of merge, 21.09.
derived_merge = extract("    static func mergedDerivedLayerImage(_ layers: [ImageLayer],")
wiring("People and Background merge through the photo, not over transparency",
       "render(only, on: base, applyCrop: false)" in derived_merge)
wiring("and only those layers are on it while it renders",
       "only.layers = layers" in derived_merge)
wiring("the matte is the union of theirs",
       "maximumCompositing()" in derived_merge)
wiring("taken at full strength, because the render already used their opacity",
       "scaled by opacity" in derived_merge)
wiring("and the merge picks the right one of the two paths",
       "targets.allSatisfy(\\.isDerived)" in merge)

# The frame's row selects; it does not walk off to another tab.
wiring("clicking the frame's row selects it",
       "templateRowSelected = true" in template_row)
wiring("and only a DOUBLE click opens the tab",
       "if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {" in template_row
       and "panelTab = .templates" in template_row)
# KORAK 208: this used to hold that the two REFUSE a merge. They merge now —
# the menu on both rows is the merge into the photograph, reason included.
wiring("the frame and the photo both offer the merge into the photo",
       "printRowMergeMenuItem()" in template_row and "printRowMergeMenuItem()" in photo_row
       and "photoMergeMenuItem()" in extract("    private func printRowMergeMenuItem() -> some View {"))

# The photograph is always in the list.
wiring("the photograph is a row even with no frame on the photo",
       "if settings.templateID == nil {" in layers_panel
       and layers_panel.count("templatePhotoLayerRow()") == 3)
wiring("and it carries the file's own name",
       "selectedURL?.lastPathComponent" in photo_row)

print()
if compiled != 0:
    failures += 1
    print("the compiled half FAILED")
print("all good\n" if failures == 0 else f"{failures} FAILED\n")
sys.exit(0 if failures == 0 else 1)
