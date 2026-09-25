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


_default_step = re.search(r"func editSlider\([^)]*?step: Double = ([\d.]+)", source, re.S)
if not _default_step:
    sys.exit("could not read editSlider's default step out of Develop.swift")
DEFAULT_STEP = float(_default_step.group(1))


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
            # A call that does not name a step gets editSlider's own default,
            # read out of its signature rather than written down here — so the
            # comparison is between two REAL steps and not between two "not
            # stated"s, which would agree with each other whatever they were.
            float(step.group(1)) if step else DEFAULT_STEP,
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
# ⚠️ 25.09 the client widened EVERY slider by half: *„i svi trenutno slideri da
# se uvecaju 50% od trenutne granice"* — so Exposure is ±1.5 EV now, the third move.
for panel in ("photo", "layer", "mask"):
    span, step = panels[panel].get("Exposure", (None, None))
    check(f"{panel} Exposure is ±1.5 EV", span == (-1.5, 1.5), f"got {span}")
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
# ⚠️ THE FOURTH PLACE. Background Enhanced's card (12.09) puts Shadows,
# Saturation and Clarity in front of the client a fourth time, and a fourth
# place is exactly how the first three drifted apart. Its rows are not
# `editSlider` calls — the card has no keyboard nudge registry and no
# selected-slider highlight to hook into — so the range and step come from one
# named pair on BackgroundEnhancedTuning, and that pair is checked here against
# the panel the numbers end up on: a LAYER's, because the recipe writes on the
# Background layer.
print("\nand the Background Enhanced card, the fourth place these controls appear")

# The card's rows come from one table — BackgroundEnhancedTuning.Control — so
# each one's range, step and readout are read out of that enum and compared with
# the LAYER panel's row of the same name. The layer, not the photo, because the
# recipe writes on the Background layer.
#
# ⚠️ Exposure is the reason this reads a table instead of one shared pair. It is
# the ONE control here that does not step by 0.01 and does not read out as
# value × 100 — it steps by 0.05 and reads in stops, on the photo and on a layer
# alike. Six rows treated as identical would have got Exposure wrong and looked
# right doing it.
card_rows = re.search(r"enum Control: String, CaseIterable \{\s*case ([^\n]+)", source)
check("the card's rows come from one table", card_rows is not None)

card_range = re.search(r"var range: ClosedRange<Double> \{ (-?[\d.]+)\.\.\.(-?[\d.]+) \}", source)
card_step = re.search(r"var step: Double \{ self == \.exposure \? ([\d.]+) : ([\d.]+) \}", source)
check("and so do their range and step",
      card_range is not None and card_step is not None)

if card_rows and card_range and card_step:
    names = [name.strip() for name in card_rows.group(1).split(",")]
    card_span = (float(card_range.group(1)), float(card_range.group(2)))
    exposure_step = float(card_step.group(1))
    other_step = float(card_step.group(2))

    # All six he asked for, by name: his original three plus the three added on
    # 12.09 — *„tu bi ja stavio i exposure i contrast i dhaze"*.
    wanted = ["exposure", "contrast", "shadows", "saturation", "clarity", "dehaze"]
    check("the card carries all six controls he asked for",
          names == wanted, f"{names} vs {wanted}")

    for name in names:
        label = name.capitalize()
        if label not in panels["layer"]:
            check(f'"{label}" exists on the layer panel to be compared with', False)
            continue
        layer_span, layer_step = panels["layer"][label]
        step = exposure_step if name == "exposure" else other_step
        check(f'"{label}" — the card matches the layer panel',
              card_span == layer_span and step == layer_step,
              f"card {card_span}/{step} vs layer {layer_span}/{layer_step}")

    # ⚠️ And the readout, which is the half a range check cannot see: Exposure
    # reading "+30" instead of "+0.30" would be the same slider saying a
    # different thing, which is what the MUST is about.
    check("Exposure reads out in stops, the other five as value x 100",
          'String(format: "%+.2f", value)' in source
          and 'String(format: "%+.0f", value * 100)' in source)

print("\nwhat the photo has and a layer does not")
only_photo = sorted(set(panels["photo"]) - set(panels["layer"]))
print(f"  {', '.join(only_photo) if only_photo else 'nothing'}")

print()
if failures:
    print(f"{failures} checks failed")
    sys.exit(1)
print("all good")
