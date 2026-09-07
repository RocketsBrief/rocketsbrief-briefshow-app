#!/usr/bin/env python3
"""Builds and runs Tools/ai-photo-lock.swift against the LIVE lock.

`isAIWorkingOnOpenPhoto` is cut out of Develop.swift by name and rewritten
from a View property into a free `var`, so the harness cannot pass while the
app has moved on — the same rule Tools/run-thumbnail-cache-test.py follows.

On top of the truth table the Swift side checks, this file reads the source
for the three things a truth table cannot see:

  * both ways out of a photograph — the filmstrip click and the arrow keys —
    ask the lock before they move,
  * `isFlatteningOpenPhoto` is raised in `flattenPhoto` and NOWHERE else, so
    the bulk bakes stay switchable on purpose,
  * every raise of it has a matching clear.
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"
HARNESS = ROOT / "Tools" / "ai-photo-lock.swift"

# The two functions that must not move a photograph while the lock is up.
GUARDED = ["handleFilmstripClick", "stepPhoto"]


def strip_comments(text: str) -> str:
    """Code only.

    ⚠️ Not decoration. Both position checks below were WRONG without this, and
    wrong in the direction that matters: the guard in `handleFilmstripClick`
    carries a comment explaining that Cmd- and plain clicks both reach
    selectPhoto, so a plain `.index("selectPhoto")` found the word in the
    prose above the guard and reported the guard as coming second. A test that
    reads comments is a test that fails when someone explains themselves.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def read_body(text: str, start: int) -> str:
    depth = 0
    seen = False
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
            seen = True
        elif text[index] == "}":
            depth -= 1
            if seen and depth == 0:
                return text[start:index + 1]
    sys.exit("unbalanced braces")


def extract_property(text: str) -> str:
    """`private var isAIWorkingOnOpenPhoto: Bool { ... }` → a plain `var`."""
    match = re.search(
        r"^[ \t]*(?:private )?var isAIWorkingOnOpenPhoto\b", text, re.MULTILINE)
    if not match:
        sys.exit("could not find isAIWorkingOnOpenPhoto in " + SOURCE.name)

    body = read_body(text, match.start())
    body = re.sub(r"\bprivate ", "", body, count=1)
    # runningRecipe is a PortraitRecipe? in the app and a String? here — the
    # lock only ever asks whether it is nil, which is what is under test.
    return textwrap.dedent(body)


def func_body(text: str, name: str) -> str:
    match = re.search(rf"^[ \t]*(?:private )?(?:@discardableResult\s+)?"
                      rf"(?:private )?func {name}\b", text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find func {name} in {SOURCE.name}")
    brace = text.index("{", match.start())
    return read_body(text, brace)


def check_source(text: str) -> int:
    failures = 0

    def check(label, condition):
        nonlocal failures
        if condition:
            print(f"  ok    {label}", flush=True)
        else:
            failures += 1
            print(f"  FAIL  {label}", flush=True)

    print("the source, for what a truth table cannot see", flush=True)

    for name in GUARDED:
        body = strip_comments(func_body(text, name))
        check(f"{name} asks the lock before it moves",
              "isAIWorkingOnOpenPhoto" in body)
        # The guard has to come before anything that selects, or it is not a
        # guard — it is a message printed after the damage.
        if "selectPhoto" in body:
            check(f"{name} asks BEFORE it selects",
                  body.index("isAIWorkingOnOpenPhoto") < body.index("selectPhoto"))

    # ⚠️ `var isFlatteningOpenPhoto = false` is the DECLARATION, not a clear.
    # Counting it made "cleared exactly once" read two and fail, which is the
    # useless kind of failure: correct code, wrong ruler.
    code = strip_comments(text)
    raises = re.findall(r"(?<!var )isFlatteningOpenPhoto = true", code)
    clears = re.findall(r"(?<!var )isFlatteningOpenPhoto = false", code)
    check("isFlatteningOpenPhoto is raised exactly once", len(raises) == 1)
    check("…and cleared exactly once", len(clears) == 1)

    flatten = func_body(text, "flattenPhoto")
    check("the one raise is inside flattenPhoto",
          "isFlatteningOpenPhoto = true" in flatten)
    check("…and so is the one clear",
          "isFlatteningOpenPhoto = false" in flatten)

    # ⚠️ The whole reason the flag exists. If either bulk path ever raises it,
    # a client watching forty photos bake loses the strip.
    for name in ["runBake", "runPortraitRecipes"]:
        check(f"{name} (bulk) does NOT raise it",
              "isFlatteningOpenPhoto" not in func_body(text, name))

    return failures


def main() -> int:
    source = SOURCE.read_text()

    # Flushed, or Python's buffered stdout lands AFTER the harness binary's
    # unbuffered output and the report reads back to front.
    if check_source(source):
        return 1
    print(flush=True)

    harness = HARNESS.read_text().replace("// __EXTRACTED__",
                                          extract_property(source))

    with tempfile.TemporaryDirectory() as directory:
        swift = pathlib.Path(directory) / "ai-photo-lock.swift"
        binary = pathlib.Path(directory) / "ai-photo-lock"
        swift.write_text(harness)

        build = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            return 1

        return subprocess.run([str(binary)]).returncode


if __name__ == "__main__":
    sys.exit(main())
