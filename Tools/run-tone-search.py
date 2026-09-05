#!/usr/bin/env python3
"""Sweeps the tone-chain constants against the Lightroom export, and scores the FACE.

    python3 Tools/run-tone-search.py <photo> <preset.xmp> <lightroom.jpg>
    python3 Tools/run-tone-search.py ... --grid tone=0.10,0.14 hi=0.35,0.50 mid=0.10,0.30

The client's ask at the end of 05.09 was "the face has to be brighter, and the
eyes bluer".
Both are measurable, and the ablation that came first says where they live:

    variant          face   arm    eye-blue
    full preset     -20.8  -9.4      -15.8
    highlights=0     -6.3  +2.5      -14.1   <- Highlights is what darkens the face
    shadows=0       -21.3  -9.8      -15.7   <- Shadows +70 does almost NOTHING

So the two tone controls are mis-scaled in opposite directions on this frame.
This tool sweeps the three constants that govern that — `toneControlStrength`,
`highlightControlScale`, and the leak Shadows is allowed into the midtone knot —
and prints what each combination does to every region at once, because moving
one of them always moves the sky, the deck and the white point too.

⚠️ Constants are patched into the BUILD COPY as environment reads, so the whole
grid runs on ONE compile of the current source. That is deliberate: the finding
of KORAK 123 was caused by a build copy that had drifted from the source, and
the only sure defence is to never keep one around.

⚠️ Lower RMS is not the goal and never was. Sharpening raised RMS while making
the picture right (KORAK 124). Read the region columns and the white share; use
RMS only to notice that something moved.
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# (constant as written in Develop.swift, environment variable, default)
KNOBS = [
    ("static let toneControlStrength = 0.10",
     'static let toneControlStrength = ProcessInfo.processInfo.environment["S_TONE"].flatMap(Double.init) ?? 0.10',
     "S_TONE", 0.10),
    ("static let highlightControlScale = 0.50",
     'static let highlightControlScale = ProcessInfo.processInfo.environment["S_HI"].flatMap(Double.init) ?? 0.50',
     "S_HI", 0.50),
    ("            [0.30, 1.00, 0.60, 0.00, 0.00],",
     '            [0.30, 1.00, ProcessInfo.processInfo.environment["S_MID"].flatMap(Double.init) ?? 0.60, 0.00, 0.00],',
     "S_MID", 0.60),
]

EYE = (0.487, 0.333, 0.500, 0.345)


def parse_grid(args):
    grid = {"tone": [None], "hi": [None], "mid": [None]}
    key = {"tone": "S_TONE", "hi": "S_HI", "mid": "S_MID"}
    rest = []
    for a in args:
        if "=" in a and a.split("=")[0] in grid:
            name, values = a.split("=", 1)
            grid[name] = [float(v) for v in values.split(",")]
        else:
            rest.append(a)
    return {key[k]: v for k, v in grid.items()}, rest


def main() -> int:
    args = sys.argv[1:]
    if "--grid" in args:
        i = args.index("--grid")
        env_grid, _ = parse_grid(args[i + 1:])
        args = args[:i]
    else:
        env_grid = {k: [None] for _, _, k, _ in KNOBS}
    if len(args) < 3:
        sys.exit(__doc__)
    photo, preset, reference = (pathlib.Path(a) for a in args[:3])

    import numpy as np
    from PIL import Image

    spec = importlib.util.spec_from_file_location(
        "lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
    lrcal = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lrcal)
    spec2 = importlib.util.spec_from_file_location(
        "rc", ROOT / "Tools" / "run-region-compare.py")
    rc = importlib.util.module_from_spec(spec2)
    spec2.loader.exec_module(rc)

    luma = lambda v: float(np.dot(v, (0.2126, 0.7152, 0.0722)))

    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        binary = lrcal.build(work, patches=[("Develop.swift", old, new)
                                            for old, new, _, _ in KNOBS])
        ref_img = None
        rows = []
        combos = [(t, h, m) for t in env_grid["S_TONE"]
                  for h in env_grid["S_HI"] for m in env_grid["S_MID"]]

        print(f"{'tone':>5} {'hi':>5} {'mid':>5} | {'RMS':>5} {'>250':>6} | "
              f"{'lice':>6} {'obraz':>6} {'ruka':>6} {'oko':>6} | "
              f"{'nebo':>6} {'more':>6} {'fasada':>6} {'pod':>6}")
        for tone, hi, mid in combos:
            env = dict(os.environ)
            for name, value in (("S_TONE", tone), ("S_HI", hi), ("S_MID", mid)):
                if value is not None:
                    env[name] = repr(value)
            out = work / f"o_{tone}_{hi}_{mid}.png"
            run = subprocess.run([str(binary), "render", str(photo), str(preset),
                                  str(out), "1200"], capture_output=True, text=True, env=env)
            if run.returncode != 0:
                print(run.stdout + run.stderr)
                return 1
            a = np.asarray(Image.open(out).convert("RGB"), dtype=np.float64)
            if ref_img is None:
                ref_img = np.asarray(Image.open(reference).convert("RGB")
                                     .resize(Image.open(out).size, Image.LANCZOS), dtype=np.float64)
                white_target = float((ref_img.mean(axis=2) > 250).mean() * 100)
                print(f"(Lightroom: {white_target:.1f}% of the frame above 250)\n")
            rms = float(np.sqrt(((a - ref_img) ** 2).mean()))
            white = float((a.mean(axis=2) > 250).mean() * 100)
            errs = {}
            for name in ("lice", "obraz", "ruka", "nebo", "more", "fasada", "pod"):
                box = rc.REGIONS[name]
                errs[name] = (luma(rc.crop(a, box).reshape(-1, 3).mean(axis=0))
                              - luma(rc.crop(ref_img, box).reshape(-1, 3).mean(axis=0)))
            ea = rc.crop(a, EYE).reshape(-1, 3).mean(axis=0)
            eb = rc.crop(ref_img, EYE).reshape(-1, 3).mean(axis=0)
            eye = (ea[2] - ea[0]) - (eb[2] - eb[0])
            label = tuple(v if v is not None else d for v, (_, _, _, d) in
                          zip((tone, hi, mid), KNOBS))
            print(f"{label[0]:5.2f} {label[1]:5.2f} {label[2]:5.2f} | {rms:5.2f} {white:5.1f}% | "
                  f"{errs['lice']:+6.1f} {errs['obraz']:+6.1f} {errs['ruka']:+6.1f} {eye:+6.1f} | "
                  f"{errs['nebo']:+6.1f} {errs['more']:+6.1f} {errs['fasada']:+6.1f} {errs['pod']:+6.1f}")
            rows.append((label, rms, white, errs, eye))

        best = min(rows, key=lambda r: abs(r[3]["lice"]) + abs(r[3]["ruka"])
                   + 0.5 * sum(abs(r[3][k]) for k in ("nebo", "more", "fasada", "pod")))
        print(f"\nsmallest region error: tone={best[0][0]} hi={best[0][1]} mid={best[0][2]}"
              f"  (face {best[3]['lice']:+.1f}, arm {best[3]['ruka']:+.1f}, "
              f"white {best[2]:.1f}%)")
        print("⚠️ Look at the picture before believing it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
