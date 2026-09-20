#!/usr/bin/env python3
"""Builds the font catalogue that ships inside the app.

    python3 Tools/make-google-font-catalogue.py

KORAK 198, step 6. The client's decision, 20.09: the catalogue STAYS IN THE
APP, so the list of fonts is there from the first launch with no network — and

    ⛔ IT HOLDS EXACTLY THREE FIELDS: name, category, styles.

His words: *„neka bude ono sto nam treba za fontove, ime, kategorija i
stilovi"*. Google's own metadata carries dozens more — dates, popularity,
scripts, coverage, file sizes — and none of them draws a single row in this
app. Anything added here changes the size of the release and needs his word,
because keeping the release the same size is the whole point of the decision.

The FONTS themselves are not in the app and never will be: all 1946 families
are about 1.5 GB. They are downloaded on demand, once, and kept on the
client's own disk.

Rerun this when the catalogue should be refreshed; it overwrites the file in
place and prints what changed in size.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "BriefShow" / "GoogleFontsCatalogue.json"
SOURCE = "https://fonts.google.com/metadata/fonts"

# Google names a style by its weight and whether it slants. These are the names
# the font files themselves carry, so a row in the app reads the same as the
# face CoreText reports once the file is registered.
WEIGHTS = {
    "100": "Thin",
    "200": "ExtraLight",
    "300": "Light",
    "400": "Regular",
    "500": "Medium",
    "600": "SemiBold",
    "700": "Bold",
    "800": "ExtraBold",
    "900": "Black",
}


def style_name(key: str):
    """"400" -> "Regular", "700i" -> "Bold Italic", "400i" -> "Italic".

    None for a weight that has no name — and that is not a rounding of the
    problem, it is the answer to it. A VARIABLE family reports the ends of its
    own axis as well as the nine named weights: "1" for Google Sans Flex, and
    "1000" for twenty-two families including DM Sans and Cairo. Those are not
    styles anybody asks for by name, the app has no name to show for them, and
    — the part that would have bitten — `briefShowGoogleFontStyleAxes` cannot
    turn them back into a weight, so a row called "1000" would have been
    downloaded as Regular and quietly set the text in the wrong face.

    The nine named weights of those families are all still here.
    """
    italic = key.endswith("i")
    weight = key[:-1] if italic else key
    name = WEIGHTS.get(weight)
    if name is None:
        return None
    if not italic:
        return name
    return "Italic" if name == "Regular" else f"{name} Italic"


def main() -> int:
    raw = subprocess.run(["curl", "-s", "-m", "60", SOURCE],
                         capture_output=True)
    if raw.returncode != 0 or not raw.stdout:
        sys.exit("could not fetch the catalogue — no network?")
    text = raw.stdout.decode("utf-8")
    # Google guards the endpoint against being read as script; the JSON starts
    # after that prefix.
    if text.startswith(")]}'"):
        text = text.split("\n", 1)[1]
    metadata = json.loads(text)
    families = metadata["familyMetadataList"]

    catalogue = []
    for family in families:
        # Only what is open source: this is a photographer's print going to a
        # lab, and a font he may not embed is not a font this app offers.
        if not family.get("isOpenSource", False):
            continue
        styles = [name for name in (style_name(key) for key in family.get("fonts", {}))
                  if name is not None]
        # Regular first, then the rest in the order Google lists them — the
        # same order the picker shows and the same first choice a new piece of
        # text is set in.
        if "Regular" in styles:
            styles.insert(0, styles.pop(styles.index("Regular")))
        if not styles:
            continue
        catalogue.append({
            "name": family["family"],
            "category": family.get("category", ""),
            "styles": styles,
        })

    catalogue.sort(key=lambda entry: entry["name"])
    before = OUT.stat().st_size if OUT.exists() else 0
    OUT.write_text(json.dumps(catalogue, ensure_ascii=False, separators=(",", ":")) + "\n",
                   encoding="utf-8")
    after = OUT.stat().st_size

    unnamed = sum(1 for family in families
                  for key in family.get("fonts", {})
                  if style_name(key) is None)
    print(f"families offered: {len(catalogue)} of {len(families)} "
          f"({len(families) - len(catalogue)} left out)")
    print(f"unnamed weights dropped (variable-axis ends): {unnamed}")
    print(f"catalogue: {after:,} bytes" + (f" (was {before:,})" if before else ""))
    print(f"written to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
