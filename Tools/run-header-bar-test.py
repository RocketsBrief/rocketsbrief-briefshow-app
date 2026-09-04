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

# ---- 1b. the order the client asked for, and it is an ORDER, not a set ------
order = re.findall(r'HeaderBarItem\(id: "([a-z]+)"|tabItem\(\.([a-z]+)\)', items_body)
# tabItem()'s own body builds its id by concatenation ("tab." + rawValue), so
# it does not match the literal-id pattern and the list is the array's order.
sequence = [a or ("tab." + b) for a, b in order]
wanted = ["grid", "original", "ai", "crop", "tab.edit"]
check(sequence[:5] == wanted,
      "the bar opens with %s (found %s)" % (" → ".join(wanted), " → ".join(sequence[:5])))
check(sequence[-2:] == ["tab.retouch", "tab.layers"],
      "Retouch and Layers close the bar (found %s)" % " → ".join(sequence[-2:]))

# ---- 1c. the tooltip is attached to the CONTROL, not inside the label -------
# This is the bug the client reported: a macOS Button lays its own tracking
# area over its label, so .help() inside that label never fires.
cell_start = src.index("    private func headerBarCell(")
cell_end = src.index("    /// What the pointer is over", cell_start)
cell = src[cell_start:cell_end]
face = cell[cell.index("let face = Group {"):cell.index("return Group {")]
# The white system tooltip is deliberately gone: the caption under the bar says
# it already, immediately, and two labels for one button — one of them a second
# late — is worse than the one that is there.
# ⚠️ Comments stripped first. The check matched the comment that EXPLAINS why
# there is no .help() here, and reported the code as broken because the code
# says so in words.
cell_code = "\n".join(line for line in cell.splitlines()
                      if not line.strip().startswith("//"))
check(".help(" not in cell_code,
      "no system tooltip on the cells; the caption under the bar is the one way in")
check(".onHover { inside in" in cell,
      "every cell reports hover, so the caption under the bar can name it")
check("private var headerHoverCaption: some View" in src,
      "there is a caption under the bar that does not depend on the system tooltip")
hover_text = re.findall(r'help: "([^"]+)"', items_body) + re.findall(
    r'return "((?:Edit|Retouch|Layers)[^"]+)"', src)
check(hover_text and all(" - " in t and " — " not in t for t in hover_text),
      "every hover line uses the short dash, never the long one (%d lines)" % len(hover_text))

# ---- 1d. exactly ONE cell can be lit ---------------------------------------
# Reported as "edit ostaje uvek ukljucen": each cell used to decide its own lit
# state, so Edit sat lit under a live Crop or AI brush.
lit = re.findall(r"isActive: ([^,\n]+)", items_body)
check(lit and all(l.strip().startswith("activeHeaderCellID ==") for l in lit),
      "every lit state comes from the single activeHeaderCellID (%d cells)" % len(lit))
active = src[src.index("    private var activeHeaderCellID: String {"):]
active = active[:active.index("\n    }")]
check(active.count("return ") == 5,
      "activeHeaderCellID answers with exactly one id, in priority order")
check("releaseCanvasTools()" in items_body,
      "pressing a tab puts down whatever was holding the canvas")
check("releaseCanvasTools(keepAI: true)" in items_body
      and "releaseCanvasTools(keepCrop: true)" in items_body,
      "Crop and AI each put the other down")

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
