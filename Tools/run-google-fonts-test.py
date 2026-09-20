#!/usr/bin/env python3
"""The Google fonts — KORAK 198, step 6.

    python3 Tools/run-google-fonts-test.py           # no network needed
    python3 Tools/run-google-fonts-test.py --live    # also downloads one family

The client's answer to question 5, 20.09: the whole catalogue is visible with
its styles, a font is USED once it is downloaded, and once downloaded it works
on that computer forever. And his rule about the catalogue that ships:
*„neka bude ono sto nam treba za fontove, ime, kategorija i stilovi"*.

Two halves.

1. COMPILED. Tools/test-google-fonts.swift is built against the real
   BriefShow/Fonts.swift and BriefShow/Templates.swift and drives their own
   functions: a style name against a weight, the request that decides whether
   the answer is a .ttf or a woff2 CoreText cannot register, the check that
   what came back is a font at all, the file name, and the shipped catalogue
   decoded with the app's own type — including the three-field rule, counted.
   With --live it downloads one small family, registers it, and asks CoreText
   for it by name.

2. READ FROM THE SOURCE — what no unit test can see:
     - the fonts are registered AT LAUNCH, in BriefShowApp, because a print is
       drawn from the grid by the batch flatten, the sync's bake and the
       export, and none of those ever opens the text panel,
     - the record carries CORETEXT's name for a family, not the catalogue's,
     - the font files are NOT in the app bundle: they live in Application
       Support, under the path named BriefShow,
     - the licence is written beside every downloaded family,
     - the list of installed families is refreshed after a download, or the
       font the client just fetched is missing from the list he fetched it in.

Negative controls, RUN rather than assumed (20.09):
  - the css2 request sent with a SAFARI user agent: 2 checks fail — Google
    answers with woff2, and the download is refused with "what came back for
    Regular was not a font file" rather than leaving a dead row behind;
  - ⚠️ the user agent merely DROPPED does not break the download, and the
    docstring said it did until it was run: URLSession's own agent gets a .ttf
    as things stand today. Only the wiring check fails. The header pins the
    answer rather than fixing it, and the code now says so;
  - a fourth field added to the catalogue: the three-field check fails and
    nothing else does.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONTS = ROOT / "BriefShow" / "Fonts.swift"
TEMPLATES = ROOT / "BriefShow" / "Templates.swift"
APP = ROOT / "BriefShow" / "BriefShowApp.swift"
DEVELOP = ROOT / "BriefShow" / "Develop.swift"
CATALOGUE = ROOT / "BriefShow" / "GoogleFontsCatalogue.json"
TEST = ROOT / "Tools" / "test-google-fonts.swift"

fonts = FONTS.read_text(encoding="utf-8")
app = APP.read_text(encoding="utf-8")
develop = DEVELOP.read_text(encoding="utf-8")

live = "--live" in sys.argv
failures = 0


def wiring(label: str, passed: bool, detail: str = "") -> None:
    global failures
    if passed:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{('   ' + detail) if detail else ''}")


if not CATALOGUE.exists():
    sys.exit("GoogleFontsCatalogue.json is missing — run Tools/make-google-font-catalogue.py")

print("\ncompiling the real Fonts.swift with the test")
sdk = subprocess.run(["xcrun", "--show-sdk-path", "--sdk", "macosx"],
                     capture_output=True, text=True, check=True).stdout.strip()

with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp)
    binary = work / "google-fonts"
    main = work / "main.swift"
    shutil.copy(TEST, main)
    build = subprocess.run(
        ["swiftc", "-O", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-macos13.0",
         str(FONTS), str(TEMPLATES), str(main), "-o", str(binary)],
        capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        sys.exit("the compiled half did not build")
    arguments = [str(binary), str(CATALOGUE)]
    if live:
        arguments.append("--live")
    compiled = subprocess.call(arguments)

print("\nwhat the source says, which no unit test can see")

# The one that would be found only by a client whose print came out wrong.
#
# ⚠️ BriefShowApp's OWN init, not the first `init() {` in the file — that one
# belongs to a singleton three hundred lines above and this check passed over
# it while measuring nothing.
launch = app.split("struct BriefShowApp: App {", 1)[-1].split("init() {", 1)[-1] \
            .split("\n    }", 1)[0]
wiring("the downloaded fonts are registered AT LAUNCH",
       "FontStore.registerDownloadedFonts()" in launch)
wiring("and off the main thread", "DispatchQueue.global(qos: .utility).async {" in launch)

# A record has to carry the name CoreText files the family under.
wiring("the record takes CoreText's name for the family, not the catalogue's",
       "fontLibrary.coreTextFamilyName(for: family)" in develop
       and "registeredFamilyName(of:" in fonts)
wiring("and a face the new family does not have is replaced",
       develop.count("faces.first ?? \"Regular\"") >= 3)

# Where the files are, and where they are NOT.
wiring("the font files live in Application Support, not in the app",
       'appendingPathComponent("BriefShow/Fonts"' in fonts)
wiring("the path is named BriefShow, which is the client's data, not the product",
       "THE NAME ON DISK IS \"BriefShow\"" in fonts)
# ⚠️ The SCOPE argument, not the word. `.user` also appears inside
# `.userDomainMask`, which is how this check first failed on correct code.
scopes = re.findall(r"CTFontManagerRegisterFontsForURL\([^,]+,\s*\.([a-zA-Z]+)", fonts)
wiring("every registration is for this process alone, never the system",
       scopes == ["process", "process"], f"{scopes}")

# The licence goes with the font; these prints go to a lab.
wiring("a licence is written beside every downloaded family",
       "licenceURL(family:" in fonts and "licence.write(to: url" in fonts)
wiring("and a family with no licence text still records WHICH licence it is",
       "is distributed under the" in fonts)

# The list the client picks from has to know what he just downloaded.
wiring("the installed families are read again after a download",
       "briefShowRefreshInstalledFontFamilies()" in fonts)
wiring("and the face cache with them",
       "briefShowFontFaceCache.removeAllObjects()" in TEMPLATES.read_text(encoding="utf-8"))

# One download at a time, and a failure that says so.
wiring("a family cannot be asked for twice at once",
       "guard downloading == nil, !isDownloaded(family) else { return }" in fonts)
wiring("a failed download says why, out loud",
       "self.lastError = error.localizedDescription" in fonts
       and "fontLibrary.lastError" in develop)

# The catalogue, counted from the file rather than from the prose about it.
entries = json.loads(CATALOGUE.read_text(encoding="utf-8"))
keys = sorted({key for entry in entries for key in entry})
wiring("the shipped catalogue holds exactly three fields",
       keys == ["category", "name", "styles"], f"{keys}")
wiring("and every family in it", len(entries) > 1900, f"{len(entries)}")
size = CATALOGUE.stat().st_size
print(f"        catalogue: {size:,} bytes "
      f"({size / 115_247_153 * 100:.2f} % of the 11.40 release)")

print()
if compiled != 0:
    failures += 1
    print("the compiled half FAILED")
if not live:
    print("note: the live download was skipped — run with --live before a release")
print("all good\n" if failures == 0 else f"{failures} FAILED\n")
sys.exit(0 if failures == 0 else 1)
