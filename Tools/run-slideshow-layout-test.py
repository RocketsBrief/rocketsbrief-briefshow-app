#!/usr/bin/env python3
"""Reads ContentView.swift for the Slideshow window's top-level layout.

    python3 Tools/run-slideshow-layout-test.py

Requested 8.09: *„da bude veliki deo samo za video gore ceo ekran a dole ispod
da budu svi dugmici koji trenutno postoje"*.

The preview used to sit in a row between two 290pt columns, so it was as wide
as whatever was left between them and as tall as the settings column allowed.
It is above them now, across the window.

Two of these three checks are not about the arrangement at all — they are the
ways this request gets quietly reversed later:

  * ⚠️ THE CEILING COMING BACK. The stage carried maxHeight: 260, and that,
    not its position, is what held the picture small. Move the panel and leave
    the ceiling and the client gets a wide band 260pt tall with empty space
    under it — the visible half of the request granted, the half that decides
    the size untouched. A number back in that maxHeight fails here.

  * ⚠️ AN UNBOUNDED CONTROL BAND. The settings column is ~500-600pt and grows
    with the theme. Stacked at natural height under a large picture it asks for
    a window over 1100pt tall, and on any smaller one SwiftUI takes the
    difference out of the picture. The band has to stay bounded, or the layout
    reverses itself on the client's own screen and not on this one.

And the plain one: nothing was dropped on the way. *„svi dugmici koji trenutno
postoje"* — all three panels and the timeline are still mounted, once each.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "ContentView.swift"

PANELS = ["CenterPreviewPanel", "LeftImportPanel", "RightExportPanel", "TimelinePanel"]


def strip_comments(text: str) -> str:
    """Code only — a rule proved by a word in a comment is not proved."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def body_of(text: str, declaration: str) -> str:
    match = re.search(declaration, text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find {declaration} in {SOURCE.name}")
    start = text.index("{", match.start())
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    sys.exit("unbalanced braces")


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

    # ContentView's own body — not one of the many other `var body` in this file.
    window = body_of(source, r"^struct ContentView: View \{[\s\S]*?^    var body: some View")

    print("the video on top, the controls under it")

    where = {}
    for panel in PANELS:
        found = [m.start() for m in re.finditer(rf"\b{panel}\(", window)]
        check(f"{panel} is mounted once", len(found) == 1, f"{len(found)} times")
        if len(found) == 1:
            where[panel] = found[0]

    if len(where) == len(PANELS):
        check("the preview comes before both control columns",
              where["CenterPreviewPanel"] < where["LeftImportPanel"] and
              where["CenterPreviewPanel"] < where["RightExportPanel"],
              "the preview is still in the row between them")

        check("the two control columns are side by side, in that order",
              where["LeftImportPanel"] < where["RightExportPanel"])

        check("and the timeline is last, along the bottom",
              where["TimelinePanel"] > where["RightExportPanel"])

    print("\nthe two ways this gets reversed later")

    # ⚠️ The ceiling. Read off the stage's own frame inside CenterPreviewPanel.
    stage = body_of(source, r"^struct CenterPreviewPanel: View[\s\S]*?^    var body: some View")
    frame = re.search(r"\.frame\(maxWidth: \.infinity, minHeight: (\d+), maxHeight: ([\w.]+)\)", stage)
    check("the preview stage has no fixed height ceiling",
          frame is not None and frame.group(2) == ".infinity",
          frame.group(0) if frame else "the stage frame was not found at all")

    check("…and it still cannot collapse to nothing",
          frame is not None and int(frame.group(1)) >= 260,
          frame.group(1) if frame else "")

    # ⚠️ The band. Bounded and scrolling, so the settings column cannot take
    # the height back out of the picture on a shorter window.
    band = window[where.get("LeftImportPanel", 0) - 400:where.get("LeftImportPanel", 0)] \
        if "LeftImportPanel" in where else ""
    check("the control band is inside a ScrollView",
          "ScrollView(.vertical)" in band,
          "the settings column can grow without limit")

    after = window[where.get("RightExportPanel", 0):] if "RightExportPanel" in where else ""
    check("…and that band has a fixed height",
          re.search(r"\.frame\(height: \d+\)", after) is not None,
          "the band is unbounded")

    print("\nall good" if failures == 0 else f"\n{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
