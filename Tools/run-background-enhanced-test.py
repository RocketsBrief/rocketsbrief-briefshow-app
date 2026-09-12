#!/usr/bin/env python3
"""Background Enhanced: the numbers, and the wiring that carries them.

    python3 Tools/run-background-enhanced-test.py

Asked for on 12.09: right-click a selection in the grid, Select People on every
photo, the client's three numbers on the BACKGROUND layer, then Flatten.

Two halves, both needed.

The numbers half compiles the app's own sources together with
Tools/test-background-enhanced.swift and runs `PortraitRecipe` itself, so what
is scored is the shipping recipe rather than a re-reading of it. That is where
a wrong scale (30 instead of 0.30), a flipped Shadows sign, or the recipe
landing on the PEOPLE would hide.

The wiring half is grep, and it guards what is not arithmetic: the grid's
right-click menu actually offers it, it runs the SAME service the editor's own
recipe buttons run rather than a second copy of the loop, and that service ends
in a flatten — the client asked for the bake out loud.
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

develop = (ROOT / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")
content = (ROOT / "BriefShow" / "ContentView.swift").read_text(encoding="utf-8")

failures = 0


def check(label: str, passed: bool, detail: str = "") -> None:
    global failures
    print(f"  {'ok  ' if passed else 'FAIL'}  {label}" + (f" — {detail}" if detail and not passed else ""))
    if not passed:
        failures += 1


# ----------------------------------------------------------------- the numbers

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    binary = lrcal.build(work, main="test-background-enhanced.swift")
    if subprocess.call([str(binary)]) != 0:
        failures += 1

# ------------------------------------------------------------------ the wiring

print("\nthe Create strip's right-click menu")
# Asked for second, with the grid's menu on screen: the same item has to be on
# the strip's menu too. run-strip-recipe-menu-test.py checks its shape there
# (the lock, the target rule, that it does not duplicate); what is checked here
# is only that it exists at all, so deleting it fails BOTH tests rather than
# silently thinning this one.
# ⚠️ It opens the CARD from 12.09, not the recipe — *„before enhance to get
# small modul card with all slide bar setting"* — so what is checked is that the
# menu leads to the card and that the card leads to the shared service. Checking
# for the old direct call would now fail while the feature works, and loosening
# it to "mentions the recipe somewhere" would pass while it was broken.
check("it offers Background Enhanced",
      "BackgroundEnhancedRequest(targets: bwTargets)" in develop)
check("under the same name as everywhere else",
      "PortraitRecipe.backgroundEnhanced.title" in develop)
check("and it opens the card rather than acting at once",
      "BackgroundEnhancedCard(" in develop
      and ".sheet(item: $backgroundEnhancedRequest)" in develop)
check("the card's Apply runs the recipe with the card's own numbers",
      "runPortraitRecipes([.backgroundEnhanced], on: targets, tuning: tuning)" in develop)

print("\nthe grid's right-click menu")
check("it offers Background Enhanced",
      "PortraitRecipe.backgroundEnhanced.title" in content)
check("pressing it opens the card",
      "BackgroundEnhancedRequest(targets: targets)" in content
      and ".sheet(item: $backgroundEnhancedRequest)" in content)
check("and the card's Apply runs the batch",
      "runBackgroundEnhancedInGrid(targets, tuning: tuning)" in content)
check("it acts on the WHOLE selection, not the photo under the cursor",
      "private func photoContextMenuItems(for url: URL)" in content
      and "selectedURLs.contains(url) && selectedURLs.count > 1" in content)

# ⚠️ The point of the extraction. Before this, the loop lived inside DevelopView
# and the grid could not reach it; the cheap way to ship this button was a
# second copy of it, and the second copy is the one that would have drifted from
# the client's numbers. If someone ever writes PeopleLayerFactory.make into
# ContentView.swift, that is what happened.
print("\none implementation, not two")
check("the grid calls the shared service",
      "PortraitRecipeService.run([.backgroundEnhanced], on: targets, tuning: tuning)" in content)
check("the editor calls the same service",
      "PortraitRecipeService.run(recipes, on: targets, tuning: tuning)" in develop)
# ⚠️ The card is a THIRD place that could have grown its own copy of the recipe,
# and it is the most tempting one — it already holds the layers and the base
# image. It must ask PortraitRecipe for the numbers like everyone else, or the
# picture in the card stops being the picture Apply produces.
card_start = develop.find("struct BackgroundEnhancedCard: View {")
card = develop[card_start:develop.find("\n/// One step back for the one-press", card_start)]
check("the card previews through the recipe itself, not its own copy of it",
      "PortraitRecipe.backgroundEnhanced" in card and "tuning: wanted" in card)
check("and the card does not flatten anything", "FlattenedImageStore.flatten" not in card)

print("\nthe card on screen")
# ⚠️ Reported 12.09: *„kad sam kliknuo backround enhance nisam dobio nikakav
# modul"* — it opened in one window and not in the other. SwiftUI honours ONE
# `.sheet` per view and both chains already carried others, so the card's sheet
# has to sit on a view of its own. This is checked in BOTH files because the
# symptom was that it worked in one of them.
for label, text in (("editor", develop), ("grid", content)):
    marker = text.find(".sheet(item: $backgroundEnhancedRequest)")
    before = text[max(0, marker - 200):marker]
    check(f"the {label}'s card sheet sits on its own view, not stacked on another",
          marker != -1 and ".background(" in before and "Color.clear" in before)

# ⚠️ Reported in the same message: *„vidis dole cancel slova kako su crna to
# nikako mora da budu siva"*. A bare SwiftUI button draws its label in the
# SYSTEM's text colour, which is black whenever the Mac is in light appearance —
# and this app's three themes have nothing to do with the Mac's.
check("every button in the card is painted from the app's own palette",
      'Button("Reset")' in card and 'Button("Cancel"' in card and 'Button("Apply")' in card
      and card.count(".buttonStyle(CardButtonStyle") == 3)
check("and that style reads its colours from AppColors",
      "CardButtonStyle" in develop
      and "foregroundColor(isEnabled ? AppColors.ink : AppColors.muted)" in develop)

# All six, in the enum that drives the rows AND in `applied`, which is what
# actually writes them onto the Background layer. One without the other is a
# slider that moves and changes nothing.
SIX = ("exposure", "contrast", "shadows", "saturation", "clarity", "dehaze")
check("the card carries all six controls, not the original three",
      "case exposure, contrast, shadows, saturation, clarity, dehaze" in develop)
check("and the recipe writes every one of them onto the Background layer",
      all(f"adjustments.{name} = tuning.{name}" in develop for name in SIX))
check("and the three that were added default to zero, so an untouched run is "
      "the recipe that shipped",
      "var exposure: Double = 0" in develop
      and "var contrast: Double = 0" in develop
      and "var dehaze: Double = 0" in develop
      and "var shadows: Double = -1" in develop
      and "var saturation: Double = 0.30" in develop
      and "var clarity: Double = 0.30" in develop)
check("the grid does NOT build people layers of its own",
      "PeopleLayerFactory" not in content)
check("the grid does NOT flatten on its own account",
      "FlattenedImageStore.flatten" not in content)

print("\nthe service does the whole job the client described")
service_start = develop.find("enum PortraitRecipeService {")
service = develop[service_start:develop.find("\nenum PhotoBakeService {", service_start)]
check("PortraitRecipeService exists", service_start != -1)
check("it splits people from background", "PeopleLayerFactory.make" in service)
check("both layers go on the photo",
      "layers.append(made.background)" in service and "layers.append(made.people)" in service)
check("then the recipe", "recipe.applied(to: photoSettings" in service)
check("then the flatten", "FlattenedImageStore.flatten" in service)
# The crop is a description of the photo, not pixels — flattenPhoto keeps it and
# so must this, or a cropped photo run through the recipe loses its crop.
check("the crop survives the bake", "cleared.crop = photoSettings.crop" in service)
check("it runs off the main thread", "developRenderQueue.async" in service)
check("the store is written and flushed before anyone is told",
      "PhotoEditStore.flushNow()" in service)

print("\nand the layer it writes on is decided in ONE place")
# `writesOnBackground` is the ONE place allowed to name the cases; the check is
# that nobody else does, not that nobody does. Written as "exactly once, and
# inside that property" rather than "not present", which the property's own body
# would fail.
declaration = "var writesOnBackground: Bool {"
property_start = develop.find(declaration)
property_end = develop.find("\n    }", property_start)
inside = develop[property_start:property_end] if property_start != -1 else ""
check("only `writesOnBackground` names the cases",
      develop.count("== .monoBackground") == 1 and "== .monoBackground" in inside,
      f"{develop.count('== .monoBackground')} places compare against .monoBackground")
check("`applied` asks the property", "let wantedID = writesOnBackground ?" in develop)

print()
if failures:
    print(f"{failures} checks failed")
    sys.exit(1)
print("all good")
