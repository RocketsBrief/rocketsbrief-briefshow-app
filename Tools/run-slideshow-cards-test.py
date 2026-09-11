#!/usr/bin/env python3
"""Reads ContentView.swift for the two things asked for on 11.09.

    python3 Tools/run-slideshow-cards-test.py

1. ONE CARD AT A TIME.
   *„na primer sada kliknem na Theme, i posle kliknem na settings, cim kliknem
   na settings da se zatvori theme sto sam otvorio"*.

   Each card owned an independent Bool and nothing coordinated them, so opening
   a second left the first behind it. These are deliberately NOT sheets — a
   sheet would have made them exclusive for free — so the exclusivity is
   written down, and this file is what keeps it written.

   ⚠️ The way this reverses later is not someone deleting showOnlyCard(). It is
   a SIXTH card being added with its own `isWhateverPresented = true` next to
   the five that go through the funnel: four cards behave and one does not, and
   only that one combination looks broken. So the check is not "showOnlyCard
   exists" but "no opener in the action bar sets a card flag directly".

2. THE FOLDER YOU ARE STANDING IN WINS.
   *„kada sam u folderu gde su slike, i kada kliknem na briefshow on mora UVEK
   da loaduje te slike u kom sam bio folderu"*.

   initialPhotoURLs only ever reached a FRESH window; a second press refocused
   the open one and kept the previous folder's photos. The window is not
   rebuilt — it would lose its position and size — the URLs are handed to the
   running view.

   ⚠️ Two halves, and each one alone looks like the fix: the controller has to
   POST when a window already exists, and the view has to RECEIVE. A post
   nobody listens to and a listener nobody posts to both leave the client
   looking at the previous folder.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "ContentView.swift"

CARD_FLAGS = [
    "isMusicSheetPresented",
    "isThemeSheetPresented",
    "isSettingsSheetPresented",
    "isExportSheetPresented",
]

failures = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global failures
    if ok:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}" + (f" — {detail}" if detail else ""))


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
    source = strip_comments(SOURCE.read_text(encoding="utf-8"))

    print("one card at a time")

    action_bar = re.search(r"SlideshowActionBar\(", source)
    check("the action bar is still mounted", action_bar is not None)
    if action_bar is None:
        return 1

    # The call site only - the arguments this view is handed, not the whole file.
    start = source.index("(", action_bar.start())
    depth = 0
    call = ""
    for i in range(start, len(source)):
        if source[i] == "(":
            depth += 1
        elif source[i] == ")":
            depth -= 1
            if depth == 0:
                call = source[start:i + 1]
                break

    direct = [flag for flag in CARD_FLAGS if re.search(rf"{flag}\s*=\s*true", call)]
    check("no opener in the action bar sets a card flag directly",
          not direct,
          f"{', '.join(direct)} bypasses showOnlyCard — that card will not close the others")

    openers = re.findall(r"onOpen(\w+):", call)
    routed = re.findall(r"showOnlyCard\(", call)
    check("every opener goes through the one funnel",
          len(routed) >= len(openers),
          f"{len(openers)} openers, {len(routed)} calls to showOnlyCard")

    funnel = body_of(source, r"private func showOnlyCard")
    missing = [flag for flag in CARD_FLAGS if flag not in funnel]
    check("and the funnel closes every card there is",
          not missing,
          f"showOnlyCard never touches {', '.join(missing)} — that one stays open behind the new card")

    # Opening a card must SET as well as clear: a funnel that only closes would
    # pass the check above and open nothing at all.
    check("…while still opening the one that was asked for",
          funnel.count("= music") + funnel.count("= theme")
          + funnel.count("= settings") + funnel.count("= export") == 4,
          "the funnel does not assign its parameters — every button would just close things")

    print("\nthe folder you are standing in wins")

    controller = body_of(source, r"^final class BriefShowWindowController")

    check("there is a channel to a window that is already open",
          "briefShowLoadPhotos" in source,
          "nothing carries photos to an open window")

    # The refocus branch is the one that used to drop the photos on the floor.
    reopen = re.search(r"if let controller = windowController \{(.*?)\n        \}",
                       controller, re.DOTALL)
    check("the already-open branch is still there to look at", reopen is not None)
    if reopen:
        check("…and it hands the photos over instead of only refocusing",
              "briefShowLoadPhotos" in reopen.group(1),
              "a second press refocuses the window and keeps the previous folder's photos")
        check("…and it does not post an empty list over a working slideshow",
              "isEmpty" in reopen.group(1),
              "pressing BriefShow with nothing selected would clear the window")

    # The receiving half. Both are needed and each alone looks like the fix.
    check("the running view listens for it",
          "briefShowLoadPhotos" in source and ".onReceive(NotificationCenter" in source,
          "the controller posts into a void")

    receiver = re.search(r"\.onReceive\(NotificationCenter\.default\.publisher\(for: \.briefShowLoadPhotos\)\)(.*?)\n        \}",
                         source, re.DOTALL)
    check("…and the listener is wired to the same name", receiver is not None)
    if receiver:
        check("…and imports down the same path a fresh window uses",
              "importPhotoURLs(" in receiver.group(1),
              "it sets state by hand instead of importing — thumbnails and preview state go stale")
        check("…and leaves the slideshow alone when the folder has not changed",
              "slideshowPhotoOrder" in receiver.group(1),
              "every press would rebuild the same slideshow and reset the preview")

    # The comparison is only honest if both sides are built the same way.
    order = body_of(source, r"private static func slideshowPhotoOrder")
    importer = body_of(source, r"private func importPhotoURLs")
    check("the same-folder test compares like with like",
          "slideshowPhotoOrder" in importer,
          "importPhotoURLs sorts its own way — the comparison would never match and every press would rebuild")
    check("…and that shared rule still filters to images and sorts by name",
          "conforms(to: .image)" in order and "localizedStandardCompare" in order,
          "the shared order changed shape")

    print("\nthe card is the size of what it shows, and opens at its button")

    card = body_of(source, r"struct FloatingCard<Content: View>")

    # ⚠️ A ScrollView offered a height TAKES that height. The cap was never the
    # bug and is not what was removed - it is a ceiling now, not a height.
    check("the card's scroller is given the content's height, not the cap",
          re.search(r"\.frame\(height: min\(max\(contentHeight", card) is not None,
          "the scroller is back to taking whatever it is offered — a 200pt card will stand 560pt tall")
    check("…and the cap is still there as a ceiling",
          "maxContentHeight" in card,
          "nothing stops a very tall panel from growing past the window")
    check("…and the content is actually measured",
          "CardContentHeightKey" in card,
          "the height it is given comes from nowhere")

    check("the card knows where its button is",
          "placeAtButtonIfNeeded" in card and "anchor" in card,
          "it will open in the middle of the window again")
    place = body_of(source, r"private func placeAtButtonIfNeeded")
    check("…and places itself only once",
          "didPlaceAtButton" in place,
          "it would snap back to the button while being dragged")
    check("…and never off the edge of the window",
          "limitX" in place and "limitY" in place,
          "a card opened at a button near the edge cannot be dragged back")

    # The button has to report its frame or the anchor is always nil.
    bar = body_of(source, r"private func action\(_ title: String")
    check("every action-bar button reports its frame",
          "SlideshowButtonAnchorKey" in bar,
          "no anchors are ever collected, so every card opens centred")

    check("dragging moves a flattened layer, not a live panel",
          ".compositingGroup()" in card,
          "the shadow is recomputed from the whole card on every frame of the drag")
    # Order matters: flatten first, then cast the shadow from the flat layer.
    check("…and it is flattened BEFORE the shadow",
          card.index(".compositingGroup()") < card.index(".shadow("),
          "compositingGroup after shadow flattens the shadow too and saves nothing")

    print("\nall good" if failures == 0 else f"\n{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
