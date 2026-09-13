#!/usr/bin/env python3
"""Dehaze: the atmospheric scattering model, measured against known haze.

    python3 Tools/run-dehaze-test.py [photo.NEF ...]

The client's specification of 13.09 asks for the real algorithm, and
BRIEFSHOW_DEVELOP_NOTES.md has carried the note that it was deferred since
August: estimate the atmospheric light A from the brightest pixels of the dark
channel, build a transmission map t(x) = 1 − ω·min_c(I_c/A_c) from the Dark
Channel Prior, refine it with a guided filter that uses the picture as its
guide, recover the scene with J = (I − A)/max(t, t₀) + A, add synthetic haze by
the same model on the negative half, and correct chroma afterwards.

⚠️ THIS IS THE ONE CONTROL WITH A GROUND TRUTH, and the harness is built around
that. A clean synthetic scene, a KNOWN atmospheric light, a KNOWN depth ramp,
the forward model run to make a hazy picture — and then the only question worth
asking: how much of the original comes back, and does the correction grow with
distance the way haze does.

⚠️ AND THE FILTER THE SPEC NAMES FOR THE REFINEMENT IS A NO-OP. `CIGuidedFilter`
returns its input unchanged on macOS 26 at every radius and epsilon — measured
in KORAK 186, and this is the second control it has bitten. The refinement is
`CIEdgePreserveUpsampleFilter`, a joint bilateral upsample with the coarse map
as its small image and the photograph as its guide, which is the same job.

Two halves.

The properties half runs Tools/test-dehaze-model.swift on the synthetic scene:
0 is the identity, A is found within a few levels and keeps the COLOUR of the
air, the recovery gets closer to the clean scene than both the hazy picture and
the old path, the far end is moved far more than the near one (which is the
whole difference between a model and a look), the negative half puts the air
back thickest at the far end, the slider is monotonic, the chroma comes back
without breaking, and the shadows do not collapse onto black. It also reads
Develop.swift for the 🔴 MUST and prints what a render costs — including how much
of it is finding A.

The photograph half needs a RAW and prints what the model makes of a real frame,
with the old path computed alongside.
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

photos = sys.argv[1:]
missing = [p for p in photos if not pathlib.Path(p).exists()]
if missing:
    sys.exit("missing: " + ", ".join(missing))

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)

    binary = lrcal.build(work, main="test-dehaze-model.swift")
    failed = subprocess.call([str(binary), str(ROOT / "BriefShow" / "Develop.swift")])

    if photos:
        ramp = lrcal.build(work, main="test-dehaze-photo.swift")
        for photo in photos:
            print()
            failed |= subprocess.call([str(ramp), photo])
    else:
        print("\n(no photo given — the synthetic half above stands on its own)")

    sys.exit(failed)
