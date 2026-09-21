#!/usr/bin/env python3
"""Merge Layers with Image + Template — KORAK 208.

    python3 Tools/run-print-merge-test.py

The client, 21.09, asked whether the frame and the photo should merge for
real: yes — and, from 205, *„samo se ta dva merguju a treci ostane jer nije
bio selektovan"*. So the print is baked into the photograph and every layer
not ticked has to stay live and look EXACTLY as it did.

1. COMPILED with the real Templates.swift: a kept layer re-drawn onto the
   print by `briefShowPhotoSpaceOnPrint` and laid over the baked print gives
   the same pixels as the print drawn with the layer still on the photo —
   drawing over the photo, photo over the drawing, a turned crop, a moved,
   zoomed and turned picture. Three negative controls run every time.

2. READ FROM THE SOURCE: the renderer and the merge share the crop and the
   placement (one copy of that geometry, not two), the Image and Template rows
   carry circles, and Flatten Photo is untouched.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Templates.swift"
TEST = ROOT / "Tools" / "test-print-merge.swift"
develop = (ROOT / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")
templates = SOURCE.read_text(encoding="utf-8")

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
    binary = work / "printmerge"
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

print("\nwhat the source says")


def body(text: str, header: str) -> str:
    start = text.index(header)
    depth, i = 0, text.index("{", start)
    while True:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1


render = body(develop, "    static func render(_ settings: PhotoEditSettings, on base: PhotoBaseImage,")
compose = body(templates, "func briefShowComposeTemplate(photo: CIImage,\n                              template: PrintTemplate,\n                              art: CIImage?,")
wiring("the renderer crops through briefShowCropGeometry", "briefShowCropGeometry(" in render)
wiring("  and keeps no second copy of the crop arithmetic",
       "crop.x * extent.width" not in render)
wiring("the print places the photo through briefShowPhotoPlacementTransform",
       "briefShowPhotoPlacementTransform(" in compose)
wiring("  and stretches the drawing through briefShowArtOnCanvas",
       "briefShowArtOnCanvas(" in compose)

on_print = body(develop, "    static func layerOnPrint(")
wiring("a kept layer is moved by briefShowPhotoSpaceOnPrint", "briefShowPhotoSpaceOnPrint(" in on_print)
wiring("  its opacity, blend and sliders are not baked into it",
       "geometryOnly.opacity = 1" in on_print and "geometryOnly.adjustments = LocalAdjustmentSettings()" in on_print)

merge = body(develop, "    private func mergeIntoPhoto() {")
wiring("only the ticked layers go into the pixels",
       "bake.layers = snapshot.layers.filter { picked.contains($0.id) }" in merge)
wiring("only the TICKED lines of text are baked; the rest stay live",
       "let pickedTexts = snapshot.templateTexts.filter { pickedTextIDs.contains($0.id) }" in merge
       and "var movedTexts = keptTexts" in merge)
wiring("a layer that cannot be moved stops the merge rather than being lost",
       "movedLayers.count != kept.count" in merge)
wiring("without the frame ticked, the print stays a live setting",
       "merged.templateID = snapshot.templateID" in merge and "merged.crop = snapshot.crop" in merge)

wiring("the Template row has a circle", "isOn: templatePickedForMerge" in develop)
wiring("the Image row has a circle", "isOn: imagePickedForMerge" in develop)
wiring("the ticks are cleared when the picture changes",
       "private func loadImages(for url: URL) {\n        isLoadingPreview = true\n"
       "        imagePickedForMerge = false\n        templatePickedForMerge = false" in develop)

monitor = body(develop, "    private func installMergeClickMonitor() {")
wiring("⌘-click is caught before the row's drag can take it (a mouse-down monitor)",
       ".leftMouseDown" in monitor)
wiring("  only ⌘ alone — another modifier is handed back", "guard modifiers == .command," in monitor)
wiring("  only in the Develop window", "DevelopWindowController.windowTitle" in monitor)
wiring("  a click on no row is handed back, a click on a row is swallowed",
       monitor.count("return event") >= 2 and "return nil" in monitor)
wiring("the monitor is installed and removed with the scroll-wheel one",
       "installScrollWheelMonitor()\n            installMergeClickMonitor()" in develop
       and "removeScrollWheelMonitor()\n            removeMergeClickMonitor()" in develop)
wiring("every kind of row reports where it is",
       all(k in develop for k in [".background(mergeRowFrame(.text(item.id)))",
                                  ".background(mergeRowFrame(.template))",
                                  ".background(mergeRowFrame(.image))",
                                  ".background(mergeRowFrame(.layer(layer.id)))"]))
wiring("the list's view never takes a click", "override func hitTest(_ point: NSPoint) -> NSView? { nil }" in develop)
text_row = body(develop, "    private func textLayerRow(_ item: TemplateText) -> some View {")
wiring("a line of text has a circle and shows when it is ticked",
       "mergeCircle(isOn: isPicked" in text_row and "isSelected || isPicked" in text_row)
wiring("  and offers the merge on a right click", ".contextMenu { photoMergeMenuItem() }" in text_row)
wiring("ticked text goes into the print with the frame, or onto the uncropped photo without it",
       "bake.templateTexts = bakesTemplate ? pickedTexts : []" in merge
       and "briefShowTextsIntoUncroppedPhoto(" in merge)

flatten = body(develop, "    private func flattenPhoto(using snapshot: PhotoEditSettings? = nil,")
wiring("Flatten Photo still bakes everything", "PhotoEditSettings()" in flatten
       and "multiSelectedLayerIDs" not in flatten)

if compiled != 0 or failures:
    sys.exit("\nFAILED")
print("\nall good")
