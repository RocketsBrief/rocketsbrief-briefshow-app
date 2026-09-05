#!/usr/bin/env python3
"""Compares our render against the Lightroom export REGION BY REGION.

    python3 Tools/run-region-compare.py <photo> <preset.xmp|-> <lightroom.jpg> [k=v ...]
    python3 Tools/run-region-compare.py --dump <dir> <photo> <preset.xmp|-> <lightroom.jpg>

Global RMS says HOW FAR the picture is, never WHERE. The region table of KORAK 123
was written by hand each time it was needed and thrown away afterwards, which is
how a measurement stops being repeatable — so it lives here now.

Regions are normalised rectangles on the frame of `C4S_9331.NEF` / `CAS-5.jpg`,
the pair the calibration of 05.09.2026 was fitted on. FACE and ARM are a pair on
purpose: both are the same skin under the same light, so if the face reads dark
and the arm reads right, the difference is LOCAL and belongs to SubjectMasker;
if both read dark, it is global and belongs to the tone chain. Do not touch a
global constant for the face before this table says which of the two it is.

⚠️ The same caution as every other harness here: this compiles the app's own
sources through Tools/run-lightroom-calibration.py, so it measures the shipping
pipeline — but only as fresh as the build copy. It rebuilds on every run for
exactly that reason (KORAK 123: a stale copy produced a finding that looked like
a finding).
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# x0, y0, x1, y1 as fractions of width/height. Picked on the 900 px preview of
# CAS-5.jpg and kept deliberately inside each surface, away from every edge, so
# a few pixels of framing difference between the NEF and Lightroom's export
# cannot leak a neighbouring surface into the average.
REGIONS = {
    "nebo":   (0.11, 0.03, 0.33, 0.12),
    "more":   (0.67, 0.22, 0.83, 0.27),
    "fasada": (0.07, 0.42, 0.22, 0.55),
    "pod":    (0.72, 0.80, 0.94, 0.93),
    "lice":   (0.478, 0.30, 0.539, 0.417),
    "obraz":  (0.489, 0.335, 0.533, 0.405),
    "ruka":   (0.415, 0.52, 0.455, 0.63),
    "haljina": (0.50, 0.50, 0.57, 0.62),
}

# Which regions answer which question, printed under the table so the reader is
# not left to remember it.
PAIRS = [("lice", "ruka", "face vs arm — same skin, same light: LOCAL if they disagree")]


def load_builder():
    path = ROOT / "Tools" / "run-lightroom-calibration.py"
    spec = importlib.util.spec_from_file_location("lrcal", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def crop(arr, box):
    h, w = arr.shape[:2]
    x0, y0, x1, y1 = box
    return arr[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)]


def main() -> int:
    args = sys.argv[1:]
    dump = None
    if args and args[0] == "--dump":
        dump = pathlib.Path(args[1])
        dump.mkdir(parents=True, exist_ok=True)
        args = args[2:]
    if len(args) < 3:
        sys.exit(__doc__)

    photo, preset, reference = (pathlib.Path(a) for a in args[:3])
    overrides = args[3:]
    for path in (photo, reference):
        if not path.exists():
            sys.exit(f"missing: {path}")

    import numpy as np
    from PIL import Image

    lrcal = load_builder()
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        binary = lrcal.build(work)
        out = (dump / "ours.png") if dump else (work / "ours.png")
        run = subprocess.run([str(binary), "render", str(photo), str(preset), str(out),
                              "1200", *overrides], capture_output=True, text=True)
        if run.returncode != 0:
            print(run.stdout + run.stderr)
            return 1

        ours = Image.open(out).convert("RGB")
        theirs = Image.open(reference).convert("RGB").resize(ours.size, Image.LANCZOS)
        if dump:
            theirs.save(dump / "lightroom.png")
        a = np.asarray(ours, dtype=np.float64)
        b = np.asarray(theirs, dtype=np.float64)

        print(f"photo: {photo.name}   preset: {preset.name}   ref: {reference.name}")
        if overrides:
            print(f"overrides: {' '.join(overrides)}")
        print(f"rendered {ours.size[0]}x{ours.size[1]}, global RMS "
              f"{float(np.sqrt(((a - b) ** 2).mean())):.2f}\n")
        print(f"{'oblast':<9} {'naše R   G   B':<16} {'Lightroom R   G   B':<21} "
              f"{'razlika':<16} luma")
        totals = {}
        for name, box in REGIONS.items():
            x = crop(a, box).reshape(-1, 3).mean(axis=0)
            y = crop(b, box).reshape(-1, 3).mean(axis=0)
            d = x - y
            # Rec.709 luma, because "the face is darker" is a brightness claim
            # before it is a colour one.
            lx = float(np.dot(x, (0.2126, 0.7152, 0.0722)))
            ly = float(np.dot(y, (0.2126, 0.7152, 0.0722)))
            totals[name] = lx - ly
            print(f"{name:<9} {x[0]:5.0f}{x[1]:4.0f}{x[2]:4.0f}     "
                  f"{y[0]:5.0f}{y[1]:4.0f}{y[2]:4.0f}        "
                  f"{d[0]:+5.0f}{d[1]:+4.0f}{d[2]:+4.0f}     {lx - ly:+6.1f}")
        print(f"\n{'zbir |razlike| po oblastima':<28} "
              f"{sum(abs(v) for v in totals.values()):.1f} (luma)")
        for one, two, why in PAIRS:
            print(f"\n{why}\n  {one}: {totals[one]:+.1f}   {two}: {totals[two]:+.1f} "
                  f"→ {'LOCAL' if abs(totals[one] - totals[two]) > 4 else 'GLOBAL'}")
        if dump:
            print(f"\nwrote {dump}/ours.png and {dump}/lightroom.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
