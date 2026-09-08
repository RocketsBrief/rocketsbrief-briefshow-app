#!/usr/bin/env python3
"""Reads ContentView.swift for the Kousei / Kirigami cards in the style picker.

    python3 Tools/run-theme-picker-test.py

Requested 8.09: *„tamo stoji kousei 4:3 i kirigami 4:3 i malo je neuredno … da
ima jedan kousei i da bude dugme da se izabere 4:3 layout i jos jedno dugme
free … i to je samo za kousei i kirigami"*. The picker listed four cards for
what is two styles, each spelling the same sentence twice.

What is checked is not that the menu looks tidier — it is the two ways tidying
it could quietly cost something:

  * ⚠️ A LOST VARIANT. Four themes have to stay reachable. Fold two cards into
    one and forget a branch, and Kousei 4:3 is still in the enum, still read in
    37 places, still saved in anyone's settings — and no longer selectable by
    anybody. Nothing on screen would say so.

  * ⚠️ THE ENUM IS NOT THE MENU. SlideshowVisualTheme's raw values are
    persisted strings. Folding .magazine43 into .magazine to tidy a picker
    would be a rendering change and a migration for existing users, which is
    not what was asked for. All four cases stay.

Plus the one thing the request was actually about: Kousei and Kirigami are
named ONCE each, and the 4:3 choice is a layout button rather than a style.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "ContentView.swift"

# theme case -> the layout button that must select it
VARIANTS = [
    (".magazine43", ".fourThree"),
    (".magazine", ".free"),
    (".origami43", ".fourThree"),
    (".origami", ".free"),
]


def strip_comments(text: str) -> str:
    """Code only — a rule proved by a word in a comment is not proved."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


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

    print("one card per style, two layouts on it")

    for name in ("Kousei", "Kirigami"):
        titles = re.findall(rf'title: "{name}[^"]*"', source)
        check(f'"{name}" is named once in the picker, not twice',
              len(titles) == 1, ", ".join(titles) or "not found")

    # ⚠️ Scoped to the picker, not the file. The per-theme help text still says
    # "Kousei 4:3 uses the same editorial pages…" and that is correct — it
    # describes a theme, which .magazine43 still is. What had to stop being a
    # style NAME is the card title, and only titles are checked here.
    all_titles = re.findall(r'title: "([^"]*)"', source)
    check("neither carries the crop in its card name any more",
          not any("4:3" in title for title in all_titles),
          ", ".join(t for t in all_titles if "4:3" in t))

    check("both use the one-style-two-layouts card",
          source.count("ThemePickerLayoutOption(") == 2,
          f'{source.count("ThemePickerLayoutOption(")} found')

    check("the layout buttons are Free and 4:3",
          'case .free: return "Free"' in source and 'case .fourThree: return "4:3"' in source)

    print("\nand no variant was lost on the way")

    # ⚠️ The enum is the contract with everything else in this file and with
    # every saved setting. Four cases, still.
    for case in ("case magazine =", "case magazine43 =", "case origami =", "case origami43 ="):
        check(f"SlideshowVisualTheme still has `{case.split()[1]}`",
              case in source, "the enum was folded to tidy the menu")

    # Each of the four is still assigned from a layout choice. Read out of the
    # ternary itself rather than by looking for the case name loose in the file
    # — the enum is mentioned all over this source, and a match there would
    # prove the case EXISTS, not that anything selects it.
    #
    # ⚠️ \b after the case name, and it matters: ".magazine" is a prefix of
    # ".magazine43", so an unanchored search finds the wrong one and reports a
    # lost variant as present. This check failed for that reason the first time
    # it ran, on correct code — the ruler, not the rule.
    ternaries = re.findall(
        r"selectedTheme = \(layout == \.fourThree\) \? (\.\w+) : (\.\w+)", source)
    reachable = {case for pair in ternaries for case in pair}
    for theme, _ in VARIANTS:
        check(f"{theme} is still reachable from the picker",
              theme in reachable,
              "no layout branch selects it; found " + (", ".join(sorted(reachable)) or "none"))

    # ⚠️ Kousei's settings were written out on BOTH of its old cards,
    # identically. They belong to the style, so they are set once now — and
    # once is also what stops the two from drifting apart again.
    kousei = source[source.find('title: "Kousei"'):]
    kousei = kousei[:kousei.find('title: "Kirigami"')]
    for setting in ("transitionStyle = .fade", "timingMode = .customSpeed",
                    "secondsPerPhoto = 4", "magazineImageFadeSeconds = 0.3",
                    "musicFadeInSeconds = 4", "shouldLoopPreview = false"):
        check(f"Kousei still sets `{setting}`, once",
              kousei.count(setting) == 1,
              f"{kousei.count(setting)} times")

    print("\nall good" if failures == 0 else f"\n{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
