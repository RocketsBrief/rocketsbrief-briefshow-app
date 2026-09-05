#!/usr/bin/env python3
"""Scores this app's develop pipeline against the SAME photograph out of Lightroom.

This is the measurement behind the calibration work of 05.09.2026. The client's
ask was exact: the numbers on the right-hand panel should read the way
Lightroom's do, and a preset applied to the original should produce the picture
Lightroom produces. Neither half can be argued about — both can be measured.

    python3 Tools/run-lightroom-calibration.py <photo> <preset.xmp> <lightroom.jpg>
    python3 Tools/run-lightroom-calibration.py --ramp <preset.xmp> [k=v ...]

It compiles the app's OWN sources (Develop.swift, DevelopLightroomPreset.swift
and the rest) together with Tools/lightroom-calibration.swift, so the thing being
scored is the shipping pipeline and not a re-implementation of it. Two source
files are patched IN THE BUILD COPY only, never in the repo: BriefShowApp.swift
is left out because its @main collides with the harness, and the two ImageRenderer
call sites in ContentView.swift are stubbed because they are main-actor bound and
have nothing to do with rendering a photograph.

⚠️ WHAT THE NUMBER IS AND IS NOT. RMS against the Lightroom export is a distance,
not a verdict — the same caution Tools/measure-texture-density.py carries. A
change that lowers it is worth LOOKING at; it has not proved anything until the
picture is looked at. In particular, on a high-key frame the tone controls can
cancel each other, so "no tone curve at all" can score well while being plainly
wrong on the next photograph.

⚠️ ONE PRESET CANNOT CALIBRATE TEN SLIDERS. A preset that moves everything at
once fixes only the SUM. To calibrate a slider on its own, the pair has to move
that slider on its own: one NEF, and one Lightroom export with only Shadows set,
only Highlights set, and so on. Anything else is fitting one equation with ten
unknowns.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "BriefShow"

# Every source except the app entry point, whose @main would collide with the
# harness's own top-level code.
SOURCES = sorted(p.name for p in SRC.glob("*.swift") if p.name != "BriefShowApp.swift")

# The two types the harness needs that DO live in the entry point.
STUB_TYPES = ["final class ExternalFolderOpen", "final class ImportWindowRequest"]

IMAGE_RENDERER_SITES = [
    ("""        let renderer =
            ImageRenderer(
                content:
                    frameView
            )

        renderer.proposedSize =
            ProposedViewSize(
                width:
                    renderSize.width,
                height:
                    renderSize.height
            )

        renderer.scale = 1

        renderedImage =
            renderer.cgImage""",
     """        _ = frameView
        renderedImage = nil   // harness: not needed to render a photograph"""),
    ("""        let renderer = ImageRenderer(content: frameView)
        renderer.proposedSize = ProposedViewSize(width: renderSize.width, height: renderSize.height)
        renderer.scale = 1

        renderedImage = renderer.cgImage""",
     """        _ = frameView
        renderedImage = nil   // harness: not needed to render a photograph"""),
]


def grab(text: str, header: str) -> str:
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if header in line:
            depth, out = 0, []
            for j in range(i, len(lines)):
                out.append(lines[j])
                depth += lines[j].count("{") - lines[j].count("}")
                if depth == 0 and j > i:
                    return "\n".join(out)
    sys.exit(f"not found in BriefShowApp.swift — was it renamed?\n  {header}")


def build(work: pathlib.Path) -> pathlib.Path:
    for name in SOURCES:
        shutil.copy(SRC / name, work / name)

    content = (work / "ContentView.swift").read_text()
    for old, new in IMAGE_RENDERER_SITES:
        if old not in content:
            sys.exit("ContentView.swift changed shape — the ImageRenderer stub no longer applies.\n"
                     "Re-read the two call sites and update IMAGE_RENDERER_SITES.")
        content = content.replace(old, new, 1)
    (work / "ContentView.swift").write_text(content)

    app = (SRC / "BriefShowApp.swift").read_text()
    (work / "AppStubs.swift").write_text(
        "import Foundation\nimport SwiftUI\nimport AppKit\n\n"
        + "\n\n".join(grab(app, h) for h in STUB_TYPES) + "\n")

    shutil.copy(ROOT / "Tools" / "lightroom-calibration.swift", work / "main.swift")

    sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                         capture_output=True, text=True, check=True).stdout.strip()
    binary = work / "calibrate"
    result = subprocess.run(
        ["swiftc", "-O", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-macos13.0",
         *[str(work / n) for n in SOURCES],
         str(work / "AppStubs.swift"), str(work / "main.swift"), "-o", str(binary)],
        capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(result.stderr[-4000:])
    return binary


def score(rendered: pathlib.Path, reference: pathlib.Path, label: str) -> float:
    import numpy as np
    from PIL import Image
    a = Image.open(rendered).convert("RGB")
    b = Image.open(reference).convert("RGB").resize(a.size, Image.LANCZOS)
    x = np.asarray(a, dtype=np.float64)
    y = np.asarray(b, dtype=np.float64)
    rms = float(np.sqrt(((x - y) ** 2).mean()))
    print(f"  {label:<28} RMS {rms:6.2f}   mean {x.mean():6.1f} (Lightroom {y.mean():6.1f})")
    return rms


def main() -> int:
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)

    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        binary = build(work)

        if args[0] == "--ramp":
            return subprocess.run([str(binary), "ramp", *args[1:]]).returncode

        if len(args) < 3:
            sys.exit(__doc__)
        photo, preset, reference = (pathlib.Path(a) for a in args[:3])
        for path in (photo, preset, reference):
            if not path.exists():
                sys.exit(f"missing: {path}")

        print(f"photo:     {photo.name}")
        print(f"preset:    {preset.name}")
        print(f"reference: {reference.name}\n")

        # The neutral render is the control. A preset that scores WORSE than
        # doing nothing at all is not an approximation of the look, and that is
        # exactly what was found on 05.09.2026.
        variants = [("no preset (control)", "-", []),
                    ("the preset", str(preset), []),
                    ("preset, no tone curve", str(preset),
                     ["shadows=0", "highlights=0", "whites=0", "blacks=0"]),
                    ("preset, no colour mixer", str(preset), ["mixer0=1"])]

        results = {}
        for label, xmp, extra in variants:
            out = work / (label.replace(" ", "_").replace(",", "") + ".png")
            run = subprocess.run([str(binary), "render", str(photo), xmp, str(out), "1200", *extra],
                                 capture_output=True, text=True)
            if run.returncode != 0:
                print(run.stdout + run.stderr)
                return 1
            results[label] = score(out, reference, label)

        control = results["no preset (control)"]
        applied = results["the preset"]
        print()
        if applied > control:
            print(f"RESULT: the preset moves the picture AWAY from Lightroom "
                  f"({applied:.2f} vs {control:.2f} for doing nothing).")
            return 1
        print(f"RESULT: OK — the preset moves the picture toward Lightroom "
              f"({applied:.2f} vs {control:.2f} for doing nothing).")
        return 0


if __name__ == "__main__":
    sys.exit(main())
