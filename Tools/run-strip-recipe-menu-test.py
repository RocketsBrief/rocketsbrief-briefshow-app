#!/usr/bin/env python3
"""Reads Develop.swift for the three AI Portrait items on the strip's menu.

    python3 Tools/run-strip-recipe-menu-test.py

There is no truth table to drive here — this is a SwiftUI menu wired to two
async jobs — so the whole test is the source, and it checks the four things
that would break quietly rather than loudly:

  * all three items exist, on the same target rule as everything else in that
    menu (the whole selection when the right-clicked photo is part of one),
  * Subject Mono and Mono Background DUPLICATE first; Youthify does not,
  * ⚠️ the recipe runs over the COPIES and only AFTER the bake — the two ways
    this feature can silently write on the client's own photographs,
  * all three are off while a model is working on the open photo.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"

# label → the recipe it must run, and whether it copies first.
ITEMS = [
    ("Duplicate Subject Mono", ".subjectMono", True),
    ("Duplicate Mono Background", ".monoBackground", True),
    ("Youthify", ".youthify", False),
]


def strip_comments(text: str) -> str:
    """Code only — a rule proved by a word in a comment is not proved."""
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


def func_body(text: str, name: str) -> str:
    match = re.search(rf"^[ \t]*(?:private )?func {name}\b", text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find func {name} in {SOURCE.name}")
    return read_body(text, text.index("{", match.start()))


def button_action(text: str, label: str):
    """The closure of the Button whose label starts with `label`, and where it ends.

    ⚠️ Returns the END index too, because the `.disabled` modifier that has to
    follow each of these sits AFTER the closure. An earlier version of this
    test counted `isAIWorkingOnOpenPhoto` over a slice of the menu instead and
    read four for three buttons — it had swallowed Delete's own guard. Correct
    code, wrong ruler.
    """
    match = re.search(rf'Button\([^)]*"{re.escape(label)}', text)
    if not match:
        return "", -1
    # The action closure is the brace that follows the Button's closing paren.
    depth = 0
    index = match.start() + len("Button(")
    while index < len(text):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            if depth == 0:
                break
            depth -= 1
        index += 1
    brace = text.index("{", index)
    body = read_body(text, brace)
    return body, brace + len(body)


def main() -> int:
    failures = 0

    def check(label, condition, detail=""):
        nonlocal failures
        if condition:
            print(f"  ok    {label}")
        else:
            failures += 1
            print(f"  FAIL  {label} {detail}")

    source = strip_comments(SOURCE.read_text())

    print("the three items on the strip's right-click menu")

    for label, recipe, duplicates in ITEMS:
        action, end = button_action(source, label)
        check(f'"{label}" is there', bool(action))
        if not action:
            continue

        # ⚠️ The lock from KORAK 154. Checked here, per button, rather than by
        # counting over a slice of the menu — see button_action.
        check(f'"{label}" is off while a model works on the open photo',
              ".disabled(isAIWorkingOnOpenPhoto)" in source[end:end + 80],
              source[end:end + 60].strip())

        check(f'"{label}" runs {recipe}', recipe in action, action.strip())

        # Same target rule as Export, Delete and the plain Duplicate above it.
        check(f'"{label}" acts on the right-click selection',
              "bwTargets" in action, action.strip())

        if duplicates:
            # ⚠️ It must COPY. Both of these end in a flatten, so run in place
            # they would write over the photograph the client selected.
            check(f'"{label}" duplicates first',
                  "duplicatePhotos" in action and "thenRecipe:" in action,
                  action.strip())
        else:
            # ⚠️ …and Youthify must NOT, because that is how it was asked for.
            check(f'"{label}" does NOT duplicate',
                  "duplicatePhotos" not in action and "runPortraitRecipes" in action,
                  action.strip())

    print("\nthe handover, which is where this would go wrong quietly")

    code = strip_comments(func_body(SOURCE.read_text(), "duplicatePhotos"))

    # ⚠️ The SIGNATURE, which is not in the body — func_body starts at the
    # opening brace. Read from the declaration line instead.
    signature = re.search(r"func duplicatePhotos\([^{]*", strip_comments(SOURCE.read_text()))
    check("duplicatePhotos takes a recipe to run afterwards",
          signature is not None and "thenRecipe: PortraitRecipe? = nil" in signature.group(0),
          signature.group(0).strip() if signature else "no signature found")

    # ⚠️ THE bug this guards. `targets` are the client's own photographs and
    # `copies` are what was just made; running the recipe over `targets` would
    # flatten Subject Mono onto the originals, and nothing on screen would say
    # so until he looked at a photo he had not asked to change.
    chained = re.search(r"runPortraitRecipes\(\[thenRecipe\], on: (\w+)\)", code)
    check("the recipe runs over the COPIES, not the originals",
          chained is not None and chained.group(1) == "copies",
          chained.group(1) if chained else "no chained call found")

    # ⚠️ And after the bake, not alongside it: the recipe reads each copy's
    # baked file, which does not exist until runBake has written it.
    bake = code.find("runBake(")
    check("…and inside runBake's completion, not before it",
          bake != -1 and chained is not None and chained.start() > bake)

    print("\nall good" if failures == 0 else f"\n{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
