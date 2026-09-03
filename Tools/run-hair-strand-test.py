#!/usr/bin/env python3
"""Tests whether growing the removal mask further stops LaMa from continuing
a flyaway hair strand into the hole instead of erasing it.

WHY THIS EXISTS — see BRIEFSHOW_DEVELOP_NOTES.md, KORAK 107. Reported: "AI
Generative clean hair nije lepo ocistio odradio je kao quick clean up" — a
photo of a stray hair against bright sky, cleaned up but still visible.

Both Quick and Generative call the SAME mask growth today:
`SubjectMasker.grown(mask, by: 0.0025 * largerDimension)`. DevelopInpaint.swift's
own comment on LaMa's fill explains why a thin strand is a hard case for it:
the algorithm's data term "prefers fronts where a strong edge runs INTO the
hole" — exactly what makes a horizon or a railing continue correctly, and
exactly what a hair strand also is. If the mask hugs the strand tightly, the
edge still borders the hole and can be continued rather than erased. This
harness tests whether growing the mask further (so no strand edge borders the
hole at all) changes that.

Uses a SYNTHETIC photo — a curved dark strand over bright noisy "sky" — because
the client's real file is on his machine, not this one. The mechanism tested is
geometric (how the algorithm scores fronts to fill), not photograph-specific,
so a synthetic case can test it honestly; it cannot stand in for confirming the
client's own photo looks right, which needs his screen.

Compiles and runs the app's OWN DevelopInpaint.swift and DevelopLaMaInpaint.swift
— same rule as every harness here: what is measured is what ships.

Run:  python3 Tools/run-hair-strand-test.py
"""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
# DevelopInpaint.swift reads SDInpaintPipeline.isDebugging (a debug print
# gate), and DevelopSDInpaint.swift in turn declares a `CLIPTokenizer?`
# property — so all three come along even though this harness never calls
# into prompts or SD, same full set run-inpaint-sweep.py uses.
sources = ["DevelopInpaint.swift", "DevelopLaMaInpaint.swift", "DevelopSDInpaint.swift",
          "DevelopCLIPTokenizer.swift"]

work = pathlib.Path(tempfile.mkdtemp(prefix="hair-strand-"))
for name in sources:
    (work / name).write_bytes((root / "BriefShow" / name).read_bytes())
(work / "main.swift").write_bytes((root / "Tools" / "test-hair-strand.swift").read_bytes())

sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                     capture_output=True, text=True, check=True).stdout.strip()
binary = work / "hairtest"
build = subprocess.run(
    ["swiftc", "-O", "-sdk", sdk, "-target", "arm64-apple-macos13.0",
     *[str(work / n) for n in sources], str(work / "main.swift"),
     "-o", str(binary)],
    capture_output=True, text=True)
if build.returncode != 0:
    sys.exit(build.stderr[-4000:])

out = work / "out"
r = subprocess.run([str(binary), str(out)])
print(f"\n(working files were in {work})")
sys.exit(r.returncode)
