#!/usr/bin/env python3
"""THE MUST: a slider on a layer is the same slider as on the photo.

    python3 Tools/run-slider-parity-test.py

Stated by the client on 12.09, as a rule rather than a fix:

    *„znaci kalibriraj edit na oba slidebar-a i kada se edituje slika cela i
    kada se samo edituje layer — ta dva sidebar edita settingsa uvek moraju da
    budu ista kada se updatuju. znaci kada updatuje jedan settings za slike
    onda mora da se updatuje settings za layers isto"*

Three panels carry the same controls: the photo's own, a selected LAYER's, and
a selected MASK's. They are three separate `editSlider` calls, so nothing in the
compiler stops one from being changed and the others left behind — which is
exactly what happened to Exposure (photo ±3 → ±1.5 on 11.09, layer untouched)
and is what this file exists to stop.

⚠️ This test reads SOURCE, not pixels, on purpose. The other half of the MUST —
that the same number PRODUCES the same picture — is
Tools/run-layer-edit-parity-test.py, and that one needs a RAW photograph on the
machine. This one needs nothing, so the rule stays guarded on a machine with no
photographs on it, which this project has spent weeks being.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"
source = SOURCE.read_text(encoding="utf-8")

failures = 0


def check(label: str, passed: bool, detail: str = "") -> None:
    global failures
    print(f"  {'ok  ' if passed else 'FAIL'}  {label}" + (f" — {detail}" if detail and not passed else ""))
    if not passed:
        failures += 1


def sliders():
    """Every editSlider in the file as (panel, label, range, step).

    The call can run over several lines — the photo's Temperature builds its own
    Binding across four — so `range:` and `step:` are read out of a window after
    the label rather than out of one line.
    """
    found = {}
    for match in re.finditer(r'editSlider\("([^"]+)"', source):
        label = match.group(1).strip()
        window = source[match.start():match.start() + 600]
        key = re.search(r'key: "(layer|mask)\.', window)
        panel = key.group(1) if key else "photo"
        span = re.search(r"range: (-?[\d.]+)\.\.\.(-?[\d.]+)", window)
        if not span:
            continue
        step = re.search(r"step: ([\d.]+)", window)
        found.setdefault(panel, {})[label] = (
            (float(span.group(1)), float(span.group(2))),
            float(step.group(1)) if step else None,
        )
    return found


panels = sliders()
for name in ("photo", "layer", "mask"):
    if name not in panels:
        sys.exit(f"no {name} sliders found in Develop.swift — was editSlider renamed?")

print(f"found {len(panels['photo'])} photo sliders, "
      f"{len(panels['layer'])} layer, {len(panels['mask'])} mask\n")

# ⚠️ Exposure by name, because it is the one the client has now narrowed TWICE
# and the one whose range carries a meaning: the number is EV, so 1 is one stop
# — the same stop Lightroom's +1.00 is. Narrowing the travel does not change
# what a value means, it changes how far the thumb has to move to reach it.
print("Exposure, the control that has moved twice")
for panel in ("photo", "layer", "mask"):
    span, step = panels[panel].get("Exposure", (None, None))
    check(f"{panel} Exposure is ±1 EV", span == (-1.0, 1.0), f"got {span}")
    check(f"{panel} Exposure steps by 0.05", step == 0.05, f"got {step}")

print("\nevery control the photo and a layer share, side by side")
shared = [label for label in panels["photo"] if label in panels["layer"]]
check("they share more than a handful", len(shared) >= 12, f"only {len(shared)}")

for label in sorted(shared):
    photo_span, photo_step = panels["photo"][label]
    layer_span, layer_step = panels["layer"][label]
    span_text = f"{photo_span[0]}…{photo_span[1]}"
    check(f'"{label}" — same range and step ({span_text})',
          photo_span == layer_span and photo_step == layer_step,
          f"photo {photo_span}/{photo_step} vs layer {layer_span}/{layer_step}")

print("\nand the mask panel, which shares the same struct as a layer")
mask_shared = [label for label in panels["mask"] if label in panels["layer"]]
for label in sorted(mask_shared):
    mask_span, mask_step = panels["mask"][label]
    layer_span, layer_step = panels["layer"][label]
    check(f'"{label}" — same range and step',
          mask_span == layer_span and mask_step == layer_step,
          f"mask {mask_span}/{mask_step} vs layer {layer_span}/{layer_step}")

# ⚠️ A layer that is MISSING a control the photo has is the other half of the
# same complaint, reported once already: *„nemam iste opcije za edit kao
# celokupan edit"*. Listed rather than failed — Crop, Straighten and the like
# are geometry and have no meaning on a layer — but a new photo slider that
# never reached the layer panel shows up here the day it is added.
print("\nwhat the photo has and a layer does not")
only_photo = sorted(set(panels["photo"]) - set(panels["layer"]))
print(f"  {', '.join(only_photo) if only_photo else 'nothing'}")

print()
if failures:
    print(f"{failures} checks failed")
    sys.exit(1)
print("all good")
