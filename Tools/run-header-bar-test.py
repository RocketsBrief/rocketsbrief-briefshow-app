#!/usr/bin/env python3
"""Runs Tools/test-header-bar.swift against the REAL header bar layout rule.

Pulls `headerBarColumns` out of Develop.swift by text and wraps it in a plain
enum, so the test measures the app's own arithmetic rather than a copy of it.
The bar itself is SwiftUI and cannot be driven from here — what CAN be checked
is the rule that decides how many cells go in a row, which is where every one
of the client's three requirements actually lives:

  - the same number of cells in every row,
  - never a gap at the end of a row or at the sides,
  - and a count that changes as the panel is dragged wider or narrower.

It also counts the buttons in headerBarItems, because the divisor rule is only
gap-free for counts with useful divisors — twelve has five, eleven has none.
"""
import pathlib, re, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "BriefShow" / "Develop.swift").read_text(encoding="utf-8")

failures = 0


def check(condition, what):
    global failures
    if condition:
        print("ok    " + what)
    else:
        failures += 1
        print("FAIL  " + what)


# ---- 1. the button count, which the divisor rule depends on -----------------
start = src.find("    private var headerBarItems: [HeaderBarItem] {")
if start == -1:
    sys.exit("headerBarItems not found in Develop.swift — was it renamed?")
end = src.index("    private func headerBarCell(", start)
items_body = src[start:end]

actions = items_body.count("HeaderBarItem(id: \"")
tab_cases = len(re.findall(r"case (edit|retouch|layers) = ", src))
total = actions + tab_cases - 1  # the last HeaderBarItem(id:) builds each tab

check(total == 12,
      "the bar holds %d buttons (%d actions + %d tabs)" % (total, actions - 1, tab_cases))
check(12 % 6 == 0 and 12 % 4 == 0 and 12 % 3 == 0,
      "twelve splits 6×2, 4×3 and 3×4 — every one of them a full grid")
check("isDisabled: isFlattening || !isFlattenedPhoto" in items_body,
      "Unflatten keeps a permanent cell and greys out, so the count never changes")

# ---- 2. the real layout rule, compiled and measured -------------------------
marker = "    private static func headerBarColumns(for width: CGFloat, count: Int) -> Int {"
start = src.find(marker)
if start == -1:
    sys.exit("headerBarColumns not found in Develop.swift — was it renamed?")

open_brace = src.index("{", src.index("-> Int", start))
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
    sys.exit("headerBarColumns never closes — brace matching failed.")

function = src[start:i + 1].replace("private static func", "func")
print("\nextracted headerBarColumns from Develop.swift, compiling…")

harness = (root / "Tools" / "test-header-bar.swift").read_text(encoding="utf-8")
anchor = "// ---- the real function, pasted in by the extractor at run time -------------"
if anchor not in harness:
    sys.exit("marker line missing from test-header-bar.swift")
combined = harness.replace(anchor, anchor + "\n" + function, 1)

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(combined)
    path = f.name

run = subprocess.run(["swift", path], capture_output=True, text=True)
print(run.stdout.strip())
if run.stderr.strip():
    print(run.stderr.strip())

# ⚠️ A silent pass is not a pass. Running the harness as a SECOND file to
# `swift` did exactly that once — exit code 0, no output at all, because only
# the first file's top-level code runs — and it read as green.
if "RESULT:" not in run.stdout:
    print("FAIL  the harness printed no RESULT line — it did not actually run")
    failures += 1
if run.returncode != 0:
    failures += 1

print()
print("RESULT: OK" if failures == 0 else "RESULT: %d FAILURE(S)" % failures)
sys.exit(0 if failures == 0 else 1)
