#!/usr/bin/env python3
"""Checks the "quit 4 seconds after Download Update" behaviour two ways.

Part 1 reads the REAL UpdateRequiredOverlay out of AccountUI.swift and asserts
how the quit is wired: on a timer started at the press, four seconds, cancelled
only when the browser hand-off actually failed. A screen test is not possible
from here — the overlay only draws when the server offers a version newer than
the bundle's — so the wiring is checked in the source instead of guessed at.

Part 2 runs Tools/test-update-quit.swift, which measures that GCD really does
fire the work item at four seconds and really does stay cancelled.
"""
import pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "AccountUI.swift").read_text(encoding="utf-8")

marker = "struct UpdateRequiredOverlay: View {"
start = src.find(marker)
if start == -1:
    sys.exit("UpdateRequiredOverlay not found in AccountUI.swift — was it renamed?")

open_brace = src.index("{", start)
depth, i = 0, open_brace
while i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
else:
    sys.exit("UpdateRequiredOverlay never closes — brace matching failed.")

overlay = src[start:i + 1]

failures = 0


def check(condition, what):
    global failures
    if condition:
        print("ok    " + what)
    else:
        failures += 1
        print("FAIL  " + what)


delay = re.search(r"quitDelay:\s*TimeInterval\s*=\s*([0-9.]+)", overlay)
check(delay is not None and float(delay.group(1)) == 4.0,
      "the delay is four seconds (found %s)" % (delay.group(1) if delay else "nothing"))

check("asyncAfter(" in overlay and "Self.quitDelay" in overlay,
      "the quit is scheduled with that delay, not called straight away")

check("NSApplication.shared.terminate(nil)" in overlay,
      "it is a real quit, not just closing a window")

# The regression this replaces: terminate used to sit inside the completion
# handler behind `guard error == nil`, so no callback meant no quit.
handler = overlay[overlay.find("NSWorkspace.shared.open("):]
check("terminate" not in handler,
      "terminate is NOT inside the browser hand-off's completion handler any more")
check("guard error != nil else { return }" in handler and "quit.cancel()" in handler,
      "the completion handler only ever CANCELS, and only when the hand-off failed")

check("guard !quittingForUpdate else { return }" in overlay,
      "a second press cannot start a second quit timer")
check(".disabled(quittingForUpdate)" in overlay,
      "the button is disabled once pressed")
check("will close in a few seconds" in overlay,
      "the client is told on screen that the app is about to close on purpose")

print()
swift = root / "Tools" / "test-update-quit.swift"
print("running %s …" % swift.name)
run = subprocess.run(["swift", str(swift)], capture_output=True, text=True)
print(run.stdout.strip())
if run.stderr.strip():
    print(run.stderr.strip())
if run.returncode != 0:
    failures += 1

print()
print("RESULT: OK" if failures == 0 else "RESULT: %d FAILURE(S)" % failures)
sys.exit(0 if failures == 0 else 1)
