#!/usr/bin/env python3
"""Generative Clean Up: does it REMOVE, and does the app say what it is doing.

    python3 Tools/run-generative-base-test.py

`SDInpaintPipeline.generativeUsesLaMaBase` has now been set from both sides —
`false` on 8.09 at the client's request, kept on 9.09 after he tried it, and back
to `true` on 12.09 when he reported the thing it causes: *„Ai Generative Clean
Up is inviting (halucinating) something in the spot instead to remove the
selected area!"*

That is a switch, and three other things in the code have to agree with it. They
are far apart — two files, a thousand lines between the call sites — and nothing
fails loudly when one of them is left behind. So they are checked here, by
reading the sources. No photograph, no 1.6 GB of weights, no window: this runs on
any machine in under a second, which is the point.

  1. the refine strength is bypassed, not changed, when the base is off
  2. the oversize threshold follows the switch — 1400 is only honest while LaMa
     fills the hole first, and 600 is the number measured for pure noise
  3. the app only PROMISES "it will not invent anything" when it is LaMa's fill
     under the pixels, because that is LaMa's promise and not SD's
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SD = (ROOT / "BriefShow" / "DevelopSDInpaint.swift").read_text()
DEVELOP = (ROOT / "BriefShow" / "Develop.swift").read_text()

failures = 0


def check(label, condition, detail=""):
    global failures
    if condition:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{('   ' + detail) if detail else ''}")


match = re.search(r"static let generativeUsesLaMaBase = (true|false)", SD)
if not match:
    sys.exit("could not find generativeUsesLaMaBase in DevelopSDInpaint.swift")
uses_lama = match.group(1) == "true"

print(f"\ngenerativeUsesLaMaBase is {str(uses_lama).lower()}")

# The shipping answer to the client's report of 12.09. Written as a check rather
# than a comment because the flag is a one-word edit and this is the sentence
# that says which word is the tested one.
check("LaMa fills the hole before SD touches it", uses_lama,
      "false means SD starts from noise with an empty prompt, which is the "
      "configuration that invents")

check("the measured refine strength is bypassed by the switch, never rewritten",
      "generativeUsesLaMaBase ? 0.4 : nil" in SD,
      "0.4 is KORAK 150/151's measurement — at 0.55 a whole palm appeared")

check("the oversize threshold follows the switch",
      "SDInpaintPipeline.generativeUsesLaMaBase ? 1400 : 600" in DEVELOP,
      "1400 is true only because LaMa fills first; noise was measured at 600")

# The promise, and the guard in front of it. The sentence is only true of LaMa.
promise = "It will not invent anything"
guard = "guard SDInpaintPipeline.generativeUsesLaMaBase else {"
check("the 'will not invent anything' promise is in the app", promise in DEVELOP)
# rindex, not index: the sentence also appears in the comment that explains why
# the guard is there, and that comment is above the guard.
check("and it sits behind the switch, not in front of it",
      guard in DEVELOP
      and DEVELOP.index(guard) < DEVELOP.rindex(promise),
      "with the base off the app would be telling the client the opposite of "
      "what the model is about to do")

# The geometry is the thing that must NOT have moved while this was being
# answered: *„ne povecavaj SD"*, and the car comes from the size of the hole.
check("the SD canvas is still 512", "static let imageSide = 512" in SD
      or re.search(r"imageSide\s*=\s*512", SD) is not None)
check("and the step count is still 12",
      re.search(r"defaultSteps\s*=\s*12", SD) is not None)

print()
if failures:
    print(f"{failures} checks failed")
    sys.exit(1)
print("all good")
