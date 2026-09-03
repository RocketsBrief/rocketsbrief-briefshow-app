#!/usr/bin/env python3
"""Measures how long the Generative Clean Up weights take to load into Core ML.

WHY THIS EXISTS
---------------
The client reported, from an Intel Mac on 3 September:

    "ta prva generative ai clean up action ... trajalo je 1.5 mozda 2 minuta ..
     sledeci generative ai action u istoj sesiji ... je odradio za 15 sekundi"

and the same again after quitting and reopening the app. Nothing was broken.
Two different costs were being confused:

  * INSTALLING the weights is a 1.8 GB download onto disk. Once, ever.
  * LOADING them is pulling 1.6 GB of UNet into Core ML and letting it compile
    for this machine's hardware. Once per LAUNCH, every launch.

The 1m45s gap between the first erase and the second IS that load. This script
puts a number on it instead of an adjective.

WHAT IT DOES NOT DO
-------------------
It does not measure an Intel Mac. There is no Intel Mac here. That is exactly
why the app itself now prints the same measurement at launch:

    [sd] weights loaded into Core ML in %.1f s

so the client's own figure can be read off their machine and compared with the
number this prints on Apple silicon. Do not quote this script's result as if it
described a Radeon.

HOW IT AVOIDS DRIFTING FROM THE APP
-----------------------------------
The model file names and the compute-unit choice are READ OUT OF
DevelopSDInpaint.swift, not retyped here. If prepare() starts loading a fifth
model, or stops asking for the Neural Engine, this fails or changes with it
rather than quietly measuring something the app no longer does.

Run:  python3 Tools/run-model-load-test.py
      python3 Tools/run-model-load-test.py --models /path/to/SD15-Inpainting
"""
import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "BriefShow" / "DevelopSDInpaint.swift"
src = SRC.read_text(encoding="utf-8")

# ---------------------------------------------------------------- from source

# prepare() loads its models through one local helper, as
#     let loadedUnet = try model("Unet.mlmodelc", aneConfiguration)
# Pulling the pairs out by text is what keeps this honest: a renamed file or a
# newly added model shows up here as a changed measurement, not as a stale one.
prepare_start = src.find("func prepare() throws")
if prepare_start == -1:
    sys.exit("prepare() was not found in DevelopSDInpaint.swift — was it renamed?")
prepare_end = src.find("\n    // The blob is already in the UNet's layout", prepare_start)
if prepare_end == -1:
    prepare_end = prepare_start + 8000
prepare = src[prepare_start:prepare_end]

loads = re.findall(r'try model\("([^"]+)",\s*(\w+)\)', prepare)
if not loads:
    sys.exit("no `try model(\"...\", ...)` calls found inside prepare() — has the "
             "loading been restructured? This harness measures those calls.")

# Which compute units each configuration asks for, again read rather than
# assumed. The ANE configuration is inside an #if, so both branches are found
# and the arm64 one is used — this script only ever runs on this machine.
ane_arm = re.search(r'#if arch\(arm64\)\s*\n\s*aneConfiguration\.computeUnits = \.(\w+)', prepare)
if not ane_arm:
    sys.exit("could not read the arm64 compute units for the UNet out of prepare()")
gpu = re.search(r'gpuConfiguration\.computeUnits = \.(\w+)', prepare)
if not gpu:
    sys.exit("could not read the compute units for the VAE passes out of prepare()")

UNITS = {"aneConfiguration": ane_arm.group(1), "gpuConfiguration": gpu.group(1)}
for name, configuration in loads:
    if configuration not in UNITS:
        sys.exit(f"prepare() loads {name} with an unknown configuration "
                 f"'{configuration}' — this harness knows only {sorted(UNITS)}")

# ------------------------------------------------------------------ the models

parser = argparse.ArgumentParser()
parser.add_argument("--models", type=pathlib.Path, default=None,
                    help="the SD15-Inpainting directory (default: the development copy)")
args = parser.parse_args()

# The same two places SDModelStore.resolve() looks, in the same order.
candidates = []
if args.models:
    candidates.append(args.models)
else:
    candidates += [
        pathlib.Path.home() / "Library" / "Containers" / "com.rocketsbrief.BriefShow"
        / "Data" / "Library" / "Application Support" / "BriefShow" / "CoreMLModels" / "SD15-Inpainting",
        pathlib.Path.home() / "Desktop" / "BriefShow" / "CoreMLModels" / "SD15-Inpainting",
    ]

models = next((c for c in candidates if (c / loads[0][0]).exists()), None)
if models is None:
    sys.exit("the weights were not found. Looked in:\n  " +
             "\n  ".join(str(c) for c in candidates) +
             "\nPass --models with the SD15-Inpainting directory.")

print(f"models   {models}")
print(f"loading  {', '.join(name for name, _ in loads)}")
print(f"units    UNet {UNITS[loads[0][1]]}, VAE {UNITS['gpuConfiguration']}\n")

# ------------------------------------------------------------------ the driver

lines = []
for name, configuration in loads:
    lines.append(f'''
    do {{
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .{UNITS[configuration]}
        let started = Date()
        _ = try MLModel(contentsOf: directory.appendingPathComponent("{name}"),
                        configuration: configuration)
        let seconds = Date().timeIntervalSince(started)
        total += seconds
        print(String(format: "  %-22@ %6.1f s", "{name}" as NSString, seconds))
    }}''')

driver = f'''import CoreML
import Foundation

let directory = URL(fileURLWithPath: "{models}")
var total: Double = 0
do {{
{"".join(lines)}
}} catch {{
    print("FAILED: \\(error)")
    exit(1)
}}
print(String(format: "  %-22@ %6.1f s", "TOTAL" as NSString, total))
'''

with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "load.swift"
    path.write_text(driver, encoding="utf-8")
    binary = pathlib.Path(tmp) / "load"
    build = subprocess.run(["swiftc", "-O", str(path), "-o", str(binary)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        sys.exit("the driver did not compile:\n" + build.stderr)

    # ⚠️ Core ML keeps its own on-disk cache of a model specialised for this
    # machine, so a SECOND run of this script is not measuring the same thing
    # as the client's first launch after installing. Both numbers are printed
    # by the app itself in normal use; what this gives is this machine's figure
    # under whatever cache state it is in, and that is worth saying out loud
    # rather than presenting one number as "the" load time.
    print("run 1 (whatever Core ML already had cached):")
    first = subprocess.run([str(binary)], capture_output=True, text=True)
    print(first.stdout, end="")
    if first.returncode != 0:
        sys.exit(first.stdout + first.stderr)

    print("\nrun 2 (fresh process, warm cache — the floor):")
    second = subprocess.run([str(binary)], capture_output=True, text=True)
    print(second.stdout, end="")
    if second.returncode != 0:
        sys.exit(second.stdout + second.stderr)

print("""
Read this against the client's own figure, not instead of it. The app prints
    [sd] weights loaded into Core ML in ... s
at launch on whatever machine it is running on. This machine has a Neural
Engine; a Radeon Pro 560X does not, and nothing here predicts it.""")
