#!/usr/bin/env python3
"""Reads Develop.swift for the filmstrip's "still loading" row.

    python3 Tools/run-filmstrip-loading-bar-test.py

Requested 8.09: *„Jel moze da bude loading bar u desnom cosku kada se udje u
Create dok on loaduje NEF slike … vrti se kruzic ali se ne vidi tacno kad je
kraj tog loada"*. The strip's per-tile spinners said a tile was coming; nothing
said when the folder was DONE.

Three things are checked, and only the third is about the bar being there. The
other two are the ways this feature fails quietly:

  * ⚠️ THE STUCK BAR. The count comes off `filmstripThumbnailsInFlight`, so the
    row only disappears when that set empties. The real decode's completion
    removes the url and THEN guards on the image — a decode that returns nil
    still clears. Reorder those two lines and a single unreadable RAW leaves
    "Loading photos… 1 left" on screen until the window closes, with nothing
    loading. That is worse than the spinner this replaced.

  * ⚠️ NO PERCENTAGE. The strip is a LazyHStack and asks for thumbnails on
    demand, so there is no honest denominator: over the folder's count the bar
    would never arrive, and over "asked for so far" it would run BACKWARDS as
    the client scrolls. The people search and the flatten bar already refuse
    invented percentages for weaker reasons than this one.

  * the row exists at all, next to the other two status rows rather than over
    the photographs — the strip's right end was deliberately emptied once
    already (Select All / Sync / Export moved to the right-click menu) and is
    not the place to put something back.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"


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


def named_body(text: str, pattern: str, what: str) -> str:
    """Body of a func or a computed property, found by declaration."""
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find {what} in {SOURCE.name}")
    return read_body(text, text.index("{", match.start()))


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

    print("the row that says the folder is still loading")

    header = named_body(source, r"^[ \t]*private var panelHeader\b", "panelHeader")

    check("it is in the panel, beside the people and flatten rows",
          "filmstripThumbnailsInFlight" in header,
          "no filmstrip row in panelHeader")

    check("…and the two rows it stands next to are still there",
          "isFindingPeople" in header and "isFlattening" in header)

    # A count that falls to zero, then the row goes. Not a fraction.
    check("it says how many are left",
          re.search(r"filmstripThumbnailsInFlight\.count\) left", header) is not None,
          "the count is not shown")

    # ⚠️ ProgressView(value:) anywhere in this row would be the invented
    # percentage. Indeterminate is the honest shape here, as it is for the
    # other two.
    row = header[header.find("filmstripThumbnailsInFlight"):] if "filmstripThumbnailsInFlight" in header else ""
    check("the bar is indeterminate — no invented percentage",
          "ProgressView(value:" not in row and "progressViewStyle(.linear)" in row,
          "a value-driven ProgressView is in the loading row")

    # A single re-decode after a slider drag must not flash it.
    check("one stray re-decode does not flash it",
          re.search(r"filmstripThumbnailsInFlight\.count >= 3", header) is not None,
          "the row is not gated above a stray refresh")

    print("\nthe stuck bar, which is the way this fails quietly")

    loader = named_body(source, r"^[ \t]*private func loadFilmstripThumbnail\b",
                        "loadFilmstripThumbnail")

    check("a url goes in-flight before the decode is queued",
          loader.find("filmstripThumbnailsInFlight.insert") != -1 and
          loader.find("filmstripThumbnailsInFlight.insert") < loader.find("filmstripThumbnailQueue.addOperation"))

    removed = loader.find("filmstripThumbnailsInFlight.remove")
    guarded = loader.find("guard let image")
    check("…and it is taken OUT before the nil-image guard, not after",
          removed != -1 and guarded != -1 and removed < guarded,
          "a failed decode would leave the row on screen for good")

    # The real pass is unconditional; only the placeholder pass is skipped on a
    # cache hit. If the real one were ever skipped after the insert, nothing
    # would clear the set.
    check("the decode that clears it is always queued",
          loader.count("filmstripThumbnailQueue.addOperation") == 1 and
          "if !ThumbnailDiskCache.hasEntry(for: url) {" in loader)

    print("\nall good" if failures == 0 else f"\n{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
