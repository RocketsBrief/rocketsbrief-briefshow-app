#!/usr/bin/env python3
"""Auto-framing by faces: the geometry, and the wiring around it.

Two halves, and both are needed.

The geometry half pulls `enum FaceFraming` out of FaceFraming.swift by text and
runs Tools/test-face-framing.swift against the real thing — the same trick
run-slider-drag-test.py uses, and for the same reason: Vision cannot be
scripted against this window, but the arithmetic around it can, and that is
where a coordinate flip would hide.

The wiring half is grep, and it guards the promises that are not arithmetic:
the setting is OFF until the client asks, a hand-made crop is never overruled,
and the auto crop actually reaches the preview AND the export rather than only
one of them (either alone looks like a working feature on screen).
"""
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
framing_source = (root / "BriefShow" / "FaceFraming.swift").read_text(encoding="utf-8")
content_source = (root / "BriefShow" / "ContentView.swift").read_text(encoding="utf-8")

failures = 0


def check(label: str, passed: bool, detail: str = "") -> None:
    global failures
    print(f"  {'ok  ' if passed else 'FAIL'}  {label}" + (f" — {detail}" if detail and not passed else ""))
    if not passed:
        failures += 1


# ---------------------------------------------------------------- the geometry

marker = "enum FaceFraming {"
start = framing_source.find(marker)
if start == -1:
    sys.exit("enum FaceFraming not found in FaceFraming.swift — was it renamed?")

open_brace = framing_source.index("{", start)
depth, i = 0, open_brace
while i < len(framing_source):
    if framing_source[i] == "{":
        depth += 1
    elif framing_source[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
else:
    sys.exit("could not find the end of FaceFraming — unbalanced braces?")

extracted = framing_source[start:i + 1]

test = (root / "Tools" / "test-face-framing.swift").read_text(encoding="utf-8")
anchor = "// ---- the real type, pasted in by the extractor at run time ----------------"
if anchor not in test:
    sys.exit("marker line missing from test-face-framing.swift")

# AppKit and Vision are imported by the extracted code's own file, not by the
# test — the test is Foundation/CoreGraphics so the geometry can run anywhere.
combined = test.replace(anchor, anchor + "\nimport AppKit\nimport Vision\n" + extracted, 1)

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(combined)
    path = f.name

print(f"extracted FaceFraming ({extracted.count(chr(10))} lines) from FaceFraming.swift\n")
geometry = subprocess.call(["swift", path])

# ------------------------------------------------------------------ the wiring

print("\nwiring")

# ⚠️ The request was an opt-in, in as many words: *„ali da postoji opcija da
# klijent pre toga klikne na to da se auto kadrira"*. A default of true is not
# a smaller version of this feature, it is a different one.
check("the setting exists, and is OFF until the client switches it on",
      re.search(r'@AppStorage\("briefshow\.autoFrameFaces"\)\s+private var autoFrameFaces: Bool = false',
                content_source) is not None,
      "no opt-in setting, or it defaults to on")

check("…and it is a control in the Settings card, not a hidden default",
      'Toggle("Auto-Frame Faces", isOn: $autoFrameFaces)' in content_source,
      "nothing on screen turns it on")

check("…and it survives the window closing",
      "@AppStorage" in content_source.split("autoFrameFaces")[0][-400:],
      "the answer is forgotten between sessions")

# The merge direction. Reversed, a photo the client cropped by hand is quietly
# re-framed by a detector — the one thing this feature must never do.
merge = re.search(r"autoFaceCrops\.merging\(photoCropTransforms\)\s*\{\s*_,\s*manual in manual\s*\}",
                  content_source)
check("a crop the client made by hand always wins",
      merge is not None,
      "auto-framing can overwrite a manual crop")

check("…and switching it off gives every manual crop straight back",
      re.search(r"guard autoFrameFaces, !autoFaceCrops\.isEmpty else \{\s*return photoCropTransforms",
                content_source) is not None,
      "the auto crops linger after the setting is off")

# Both halves of "it works": what is on screen, and what is exported. A feature
# wired to only one of them looks finished and ships wrong.
uses = content_source.count("effectivePhotoCrops")
check("the auto crop reaches the live preview, the render and the export",
      uses >= 5, f"only {uses} places read the merged crops")

check("…and it is part of the preview's signature, so toggling re-renders it",
      "let signatureCrops = effectivePhotoCrops" in content_source,
      "an already-rendered preview would keep the old framing on screen")

check("…and the crop editor opens on what is actually on screen",
      "cropTransforms[url] ?? autoFaceCrops[url] ?? .default" in content_source,
      "the editor would show a default crop and jump on the first nudge")

# Vision over a folder of RAWs, on a machine with 8 GB. The import loop next
# door carries the same pool for the same measured reason.
scan = content_source[content_source.index("private func refreshAutoFaceCrops"):]
scan = scan[:scan.index("\n    }\n")]
check("the face pass runs off the main thread",
      "DispatchQueue.global" in scan,
      "a folder of photos would freeze the window")
check("…one photo at a time, in its own autoreleasepool",
      "autoreleasepool" in scan,
      "every photo's Vision intermediates stay alive until the loop ends")
check("…and never twice over the same photo",
      "autoFaceScannedURLs" in scan,
      "every preview tick would re-run Vision over the whole folder")

print("\nall good" if failures == 0 and geometry == 0 else f"\n{failures} FAILED in the wiring"
      if geometry == 0 else "\nthe geometry FAILED")
sys.exit(1 if failures or geometry else 0)
