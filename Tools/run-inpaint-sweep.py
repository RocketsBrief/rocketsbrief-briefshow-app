#!/usr/bin/env python3
"""Builds and runs Tools/inpaint-sweep.swift against the REAL inpainting code.

Copies the app's own DevelopInpaint.swift, DevelopSDInpaint.swift,
DevelopLaMaInpaint.swift and DevelopCLIPTokenizer.swift into a build directory
and compiles them with the harness, rather than keeping a second copy of any of
them here. Same rule as run-layer-reorder-test.py: what is measured is what
ships, and it cannot quietly drift.

The models are NOT in git (see Tools/README.txt); they are read from
CoreMLModels/ beside this checkout, or from $BRIEFSHOW_MODELS.

Example — the measurement in KORAK 39, on the client's own beach frame:

  Tools/run-inpaint-sweep.py ~/Desktop/"RAW Tests Images"/C4S_7891.NEF \\
      0.06 0.33 0.16 0.125 --sweep 1.0,3.5,7.5 --prompts '@default||sand'
  Tools/run-inpaint-sweep.py ~/Desktop/"RAW Tests Images"/C4S_7891.NEF \\
      0.06 0.33 0.16 0.125 --lama

Then LOOK at the PNGs it writes. That is the whole point; there is no metric
here that can tell a plausible beach from an invented car.
"""
import argparse, os, pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
sources = ["DevelopInpaint.swift", "DevelopSDInpaint.swift",
           "DevelopLaMaInpaint.swift", "DevelopCLIPTokenizer.swift"]

parser = argparse.ArgumentParser()
parser.add_argument("photo")
parser.add_argument("ux", type=float); parser.add_argument("uy", type=float)
parser.add_argument("uw", type=float); parser.add_argument("uh", type=float)
parser.add_argument("--out", default=None, help="where to write the PNGs")
parser.add_argument("--lama", action="store_true", help="Quick Clean Up instead of SD")
parser.add_argument("--exemplar", action="store_true",
                    help="the patch-match path (InpaintPipeline.removal) instead of SD")
parser.add_argument("--onone", action="store_true",
                    help="compile -Onone, the way a Debug build of the app is — "
                         "the honest way to answer 'why does this take minutes in Xcode?'")
parser.add_argument("--sweep", default="7.5", help="guidance values, comma separated")
parser.add_argument("--prompts", default="@default", help="prompts, | separated")
parser.add_argument("--refine", default="@default",
                    help="refine strengths over LaMa's fill, comma separated; 'off' for the old start-from-noise path")
args = parser.parse_args()

photo = pathlib.Path(args.photo).expanduser()
if not photo.exists():
    sys.exit(f"no such photo: {photo}")

# A NEF is not something CIImage opens directly here; sips renders the same
# pixels the app's preview starts from.
work = pathlib.Path(tempfile.mkdtemp(prefix="inpaint-sweep-"))
if photo.suffix.lower() in {".nef", ".cr2", ".arw", ".dng", ".raf"}:
    rendered = work / "photo.jpg"
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "95",
                    str(photo), "--out", str(rendered)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    photo = rendered

for name in sources:
    shutil.copy(root / "BriefShow" / name, work / name)
shutil.copy(root / "Tools" / "inpaint-sweep.swift", work / "main.swift")

sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                     capture_output=True, text=True, check=True).stdout.strip()
build = subprocess.run(
    ["swiftc", "-Onone" if args.onone else "-O", "-sdk", sdk, "-target", "arm64-apple-macos13.0",
     *[str(work / n) for n in sources], str(work / "main.swift"),
     "-o", str(work / "sweep")],
    capture_output=True, text=True)
if build.returncode != 0:
    sys.exit(build.stderr[-4000:])

out = pathlib.Path(args.out) if args.out else work / "out"
env = dict(os.environ, SWEEP=args.sweep, PROMPTS=args.prompts, REFINE=args.refine)
env.setdefault("BRIEFSHOW_MODELS", str(root.parent / "CoreMLModels"))

cmd = [str(work / "sweep"), str(photo), str(out),
       str(args.ux), str(args.uy), str(args.uw), str(args.uh)]
if args.lama:
    cmd.append("lama")
elif args.exemplar:
    cmd.append("exemplar")
r = subprocess.run(cmd, env=env)
print(f"\nPNGs in {out}")
sys.exit(r.returncode)
