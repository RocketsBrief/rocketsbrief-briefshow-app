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
#
# ⚠️ "Background Enhanced" is matched by the EXPRESSION that builds its label,
# not by the words. Its name is taken from PortraitRecipe.backgroundEnhanced
# .title so that the menu, the grid's menu and the Sync dialog cannot end up
# calling one button three things — which means there is no literal here to
# search for, and a test that demanded one would be demanding the duplication.
ITEMS = [
    ("Duplicate Subject Mono", ".subjectMono", True),
    ("Duplicate Mono Background", ".monoBackground", True),
    ("Youthify", ".youthify", False),
    ("PortraitRecipe.backgroundEnhanced.title", ".backgroundEnhanced", False),
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


def func_body(text: str, name: str, after=None) -> str:
    """The body of `func name`, optionally the first one after `after`.

    `after` is how a function inside a particular type is reached — the service
    the recipes now run through has a `run` of its own, and there are others.
    """
    offset = 0
    if after is not None:
        offset = text.find(after)
        if offset == -1:
            sys.exit(f"could not find {after} in {SOURCE.name}")
    match = re.search(rf"^[ \t]*(?:(?:private|static|@\w+)\s+)*func {name}\b",
                      text[offset:], re.MULTILINE)
    if not match:
        sys.exit(f"could not find func {name} in {SOURCE.name}")
    start = offset + match.start()
    return read_body(text, text.index("{", start))


def button_action(text: str, label: str):
    """The closure of the Button whose label starts with `label`, and where it ends.

    ⚠️ Returns the END index too, because the `.disabled` modifier that has to
    follow each of these sits AFTER the closure. An earlier version of this
    test counted `isAIWorkingOnOpenPhoto` over a slice of the menu instead and
    read four for three buttons — it had swallowed Delete's own guard. Correct
    code, wrong ruler.
    """
    # Either a literal label ("Youthify") or the expression that builds one
    # (PortraitRecipe.backgroundEnhanced.title) — see ITEMS.
    quote = "" if label.startswith("PortraitRecipe") else '"'
    match = re.search(rf'Button\([^)]*{quote}{re.escape(label)}', text)
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

    print(f"the {len(ITEMS)} recipe items on the strip's right-click menu")

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
    # ⚠️ The trailing `[,)]` rather than `\)` is deliberate, and it cost two
    # FAILs on 8.09 to learn it twice. This matched `on: copies)` and nothing
    # else, so adding a SECOND argument to the call broke the check while the
    # guarantee it exists for was untouched. The ruler, not the rule — the same
    # mistake this file already records for `func_body` and for counting the
    # lock over a slice of the menu. Match the argument, not the punctuation
    # that happens to follow it.
    chained = re.search(r"runPortraitRecipes\(\[thenRecipe\], on: (\w+)\s*[,)]", code)
    check("the recipe runs over the COPIES, not the originals",
          chained is not None and chained.group(1) == "copies",
          chained.group(1) if chained else "no chained call found")

    # ⚠️ And after the bake, not alongside it: the recipe reads each copy's
    # baked file, which does not exist until runBake has written it.
    bake = code.find("runBake(")
    check("…and inside runBake's completion, not before it",
          bake != -1 and chained is not None and chained.start() > bake)

    print("\nand that the client is shown what the recipe made")

    # ⚠️ Reported 8.09: "napravio subject mono ali nije mi prikazao u gornjem
    # delu". The copy was only multi-selected, never opened, so the canvas kept
    # showing the untouched original and a recipe that worked looked exactly
    # like one that did nothing. duplicatePhotos leaves the preview alone ON
    # PURPOSE — see its own comment — and that is right for a plain Duplicate,
    # which happens mid-edit. It is wrong the moment a recipe is chained, when
    # the copy is the only thing the client asked for.
    check("the chained call asks for the result to be opened",
          chained is not None and "openFirstWhenDone: true" in code[chained.start():chained.start() + 120],
          code[chained.start():chained.start() + 90].strip() if chained else "")

    recipes_body = strip_comments(func_body(SOURCE.read_text(), "runPortraitRecipes"))
    recipes_signature = re.search(r"func runPortraitRecipes\([^{]*", strip_comments(SOURCE.read_text()))

    check("…and only the chained caller gets it — it is off by default",
          recipes_signature is not None and "openFirstWhenDone: Bool = false" in recipes_signature.group(0),
          recipes_signature.group(0).strip() if recipes_signature else "no signature found")

    # \s* rather than a single space: the guard is written over two lines since
    # the loop moved into PortraitRecipeService and the condition grew.
    opened = re.search(r"if openFirstWhenDone,\s*let (\w+) = (\w+)\.first", recipes_body)
    check("the photo it opens is picked in strip order",
          opened is not None and opened.group(2) == "targets",
          opened.group(0).strip() if opened else "no guarded open found")

    # ⚠️ NOT out of `results`. That is a dictionary and has no order, so "the
    # first" would be whichever copy hashing put first: right most of the time,
    # wrong unpredictably, and the kind of wrong nobody reports because it
    # looks like a choice.
    check("…never out of the unordered results dictionary",
          opened is not None
          and "results.first" not in recipes_body
          and "settingsByURL.first" not in recipes_body,
          "the open is taken from the dictionary")

    # ⚠️ selectPhoto reads the photo's record back out of PhotoEditStore, so it
    # has to run AFTER the write. Opened first, the canvas would show the copy
    # with its pre-recipe record - which is the original bug wearing a different
    # hat.
    #
    # The write moved out of this function on 12.09, when the loop became
    # PortraitRecipeService so the grid's "Background Enhanced" could run the
    # same one. So the ordering is now proved in two pieces instead of one, and
    # BOTH are needed: the open must sit in the service's `completion` (not its
    # `progress`, which runs per photo, before any of them are written), and the
    # service must write and flush before it calls that completion.
    service_body = func_body(SOURCE.read_text(), "run", after="enum PortraitRecipeService")
    wrote = service_body.find("PhotoEditStore.setSettings")
    flushed = service_body.find("PhotoEditStore.flushNow()")
    told = service_body.find("completion(outcome)")
    check("…and after the new settings are written, not before",
          -1 not in (wrote, flushed, told) and wrote < flushed < told,
          "the service tells its caller before writing the store")

    completion_at = recipes_body.find("completion:")
    check("…and the open waits for the whole run, not for one photo",
          completion_at != -1 and opened is not None and opened.start() > completion_at,
          "the open is not inside the completion closure")

    print("\nall good" if failures == 0 else f"\n{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
