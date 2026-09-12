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
check("it offers Background Enhanced",
      "runPortraitRecipes([.backgroundEnhanced], on: bwTargets)" in develop)
check("under the same name as everywhere else",
      "PortraitRecipe.backgroundEnhanced.title" in develop)

print("\nthe grid's right-click menu")
check("it offers Background Enhanced",
      "PortraitRecipe.backgroundEnhanced.title" in content)
check("pressing it runs the batch",
      "runBackgroundEnhancedInGrid(targets)" in content)
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
      "PortraitRecipeService.run([.backgroundEnhanced], on: targets)" in content)
check("the editor calls the same service",
      "PortraitRecipeService.run(recipes, on: targets)" in develop)
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
