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

        # ⚠️ Against the ACTION BAR, not against the export panel. The two
        # control panels are no longer laid out in the window at all - they are
        # the contents of draggable cards declared at the window root, after the
        # column - so "the timeline comes after the export panel" stopped being
        # a statement about the layout and started being a statement about
        # declaration order in a ZStack.
        check("and the timeline is last, along the bottom",
              where["TimelinePanel"] > window.index("SlideshowActionBar("))

    print("\nthe two ways this gets reversed later")

    # ⚠️ REVERSED 8.09, an hour after it was written, and the reason belongs
    # here. This first read "the preview stage has no fixed height ceiling" and
    # required `.infinity` — and the build that satisfied it took 40 GB and was
    # suspended by macOS the moment the Slideshow window opened. The window is
    # a column now and its parts came to ~840pt inside a 560pt window; asking
    # for an unbounded height on top of that gave the layout nothing to solve.
    #
    # So the rule is the opposite of what it was: the ceiling must be a NUMBER.
    # What the original check was really protecting is still protected, by the
    # second one — the picture must be free to grow well past the 260 it was
    # stuck at. A ceiling does that; an infinity does not, it just removes the
    # answer.
    stage = body_of(source, r"^struct CenterPreviewPanel: View[\s\S]*?^    var body: some View")
    frame = re.search(r"\.frame\(maxWidth: \.infinity, minHeight: (\d+), maxHeight: ([\w.]+)\)", stage)
    check("the preview stage's height ceiling is a number, never .infinity",
          frame is not None and frame.group(2).isdigit(),
          frame.group(0) if frame else "the stage frame was not found at all")

    # ⚠️ Lowered from 500 to 380 on 8.09, and the reason is the opposite of the
    # one that put the number there. The picture WAS free to grow past 260 - too
    # free: it took every point the window could spare and pushed Photos and
    # Music Playlist off the bottom of an 832pt display. The rule is still "well
    # past the 260 it was stuck at"; what changed is that a ceiling here is also
    # a ceiling on how much it can take from what sits under it.
    check("…and that ceiling still lets the picture grow well past the old 260",
          frame is not None and frame.group(2).isdigit() and int(frame.group(2)) >= 380,
          frame.group(2) if frame else "")

    check("…while its floor stays low enough to survive a short window",
          frame is not None and int(frame.group(1)) <= 220,
          frame.group(1) if frame else "")

    # ⚠️ REPLACED 8.09. This used to require a bounded, scrolling BAND holding
    # both control panels, because they were laid out in the window. They are
    # not any more: the row under the picture is buttons, and each panel is the
    # content of a card that opens over the window. *„nek budu samo dugmici …
    # bitno je da bude sve u jednom screen-u"*.
    #
    # The rule the old checks protected - the settings column must not take the
    # height the timeline needs - is protected far better now, because a card
    # costs the window nothing until it is opened. What has to be asserted
    # instead is that the panels really are in cards and not back in the column.
    check("the control row is buttons, not the panels themselves",
          "SlideshowActionBar(" in window,
          "the action bar is gone")

    for panel in ("LeftImportPanel", "RightExportPanel"):
        in_card = re.search(rf"FloatingCard\([\s\S]{{0,600}}?{panel}\(", window)
        check(f"{panel} is shown in a card, not laid out in the window",
              in_card is not None,
              "it is back in the window column")

    # ⚠️ THE ARITHMETIC THAT WAS MISSING. A column layout has to FIT the window
    # it is put in, and this one did not: the picture's floor, the band, the
    # timeline, the header and the footer came to roughly 840pt inside a window
    # created at 560, and later inside a 900pt window on an 832pt display.
    #
    # ⚠️ It is NOT what caused the memory runaway of the same afternoon. That
    # was a full-resolution RAW decode handed to a layer, and it reproduced on
    # code carrying none of this. The two were investigated together and are
    # unrelated; this note exists so the next reader does not re-merge them.
    #
    # Checked as a sum rather than as "the window looks big enough", because the
    # failure was a sum. Anyone raising the band or the picture's floor has to
    # raise the window with it, and this is what says so.
    # ⚠️ The window is no longer a literal - it is min(wanted, what the screen
    # can give), because 900 was as wrong as 560 had been: too tall for a 1280x832
    # display once the menu bar and the Dock are taken out, so the controls and
    # the timeline sat under the Dock. The number read here is the WANTED one,
    # and the sum below is what has to fit inside whatever the screen allows.
    controller = body_of(source, r"^final class BriefShowWindowController")

    min_size = re.search(r"window\.minSize = NSSize\(width: min\(\d+, \w+\),\s*height: min\((\d+),", controller)

    check("the window is sized against the screen, not a fixed number",
          "NSScreen.main?.visibleFrame" in controller,
          "a literal height cannot know what the display can show")

    check("the Slideshow window has a minimum size at all",
          min_size is not None,
          "it can be dragged down into a size the layout cannot satisfy")

    if frame and min_size:
        # Floor of the stack: picture floor + band + timeline(66) + header and
        # footer and spacings, kept deliberately rough and rounded UP.
        # The action bar is one row (~60) where the band was 170-300.
        needed = int(frame.group(1)) + 60 + 66 + 190
        # ⚠️ The "opens tall enough" half of this used to read
        # `windowHeight = min(<number>,` and there is no such line any more —
        # the window opens at the whole visibleFrame. The regex did not fail
        # loudly, it just stopped matching, and BOTH checks in this block went
        # silently unrun. A ruler that measures nothing reports no failures.
        # The opening height is covered by the visibleFrame check above; only
        # the floor is still a number that can be got wrong here.
        check(f"the window cannot be shrunk below the column (~{needed}pt)",
              int(min_size.group(1)) >= needed - 60,
              f"minSize is {min_size.group(1)}pt")

    print("\nthe column has to FOLLOW the window, not its own content")

    # ⚠️ THE HALF THE CONTAINER DID NOT FIX. KORAK 163 put a plain NSView
    # between the window and the hosting view so the WINDOW would stop
    # following the content. Reported again straight after, 8.09:
    # *„kada sam kliknuo na kousei 4:3 on je onaj black preview suzio … opet
    # je app window bio uskracen"*.
    #
    # `.fixedSize(horizontal: false, vertical: true)` was still on ContentView's
    # root, and it says: ignore the height the window proposes, take my ideal.
    # So the window was the right size and the column inside it was not — and
    # that ideal is re-measured when the theme changes, which is why choosing
    # Kousei 4:3 shrank the black stage.
    #
    # Both halves are needed and each one alone looks like a fix.
    check("ContentView's root is not sized to its own ideal height",
          ".fixedSize(" not in window,
          "a fixedSize is back on the column — the stage will shrink with the theme")

    root_frame = re.search(r"\.frame\(\s*minWidth: 980[\s\S]{0,240}?\)", window)
    check("…and its root frame takes the window's height",
          root_frame is not None and "maxHeight: .infinity" in root_frame.group(0),
          root_frame.group(0).replace("\n", " ") if root_frame else "the root frame was not found")

    # The ZStack filling the window is not enough on its own: the VStack inside
    # it would sit centred at its ideal height with the stage at whatever size
    # its content wanted. Removing this one puts the picture back at the mercy
    # of the theme without touching anything named fixedSize.
    check("…and so does the column inside it",
          ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)" in window,
          "the column asks only for its ideal height")

    print("\nall good" if failures == 0 else f"\n{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
