#!/usr/bin/env python3
"""Builds and runs Tools/placeholder-thumbnail.swift against the LIVE fast pass.

    python3 Tools/run-placeholder-thumbnail-test.py [a .NEF]

`makePlaceholderThumbnail` is cut out of Develop.swift by name, so the harness
cannot pass while the app has moved on.

On top of the truth table the Swift side drives, this file reads both callers
for the two rules that keep the stand-in from becoming the picture. Neither is
visible from inside the function, and both are the difference between a fast
first pass and the defect of KORAK 128 coming back:

  * the placeholder is NEVER written to ThumbnailDiskCache — only a real
    render is, so nothing wrong is ever kept,
  * every caller writes it only into an EMPTY slot, and the real render
    overwrites unconditionally.
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"
GRID = ROOT / "BriefShow" / "ContentView.swift"
HARNESS = ROOT / "Tools" / "placeholder-thumbnail.swift"
DEFAULT_PHOTO = pathlib.Path.home() / "Downloads/Summer Walker and Original/C4S_9331.NEF"

# Every guard the fast pass must still ask before it hands anything back.
GUARDS = ["isRAW", "sourceURL", "hasEdits"]


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
        sys.exit(f"could not find func {name}")
    return read_body(text, text.index("{", match.start()))


def extract(text: str) -> str:
    match = re.search(r"^func makePlaceholderThumbnail\b", text, re.MULTILINE)
    if not match:
        sys.exit("could not find func makePlaceholderThumbnail in " + SOURCE.name)
    return textwrap.dedent(read_body(text, match.start()))


def check_source() -> int:
    failures = 0

    def check(label, condition, detail=""):
        nonlocal failures
        if condition:
            print(f"  ok    {label}", flush=True)
        else:
            failures += 1
            print(f"  FAIL  {label} {detail}", flush=True)

    print("the source, for the rules a truth table cannot see", flush=True)

    develop = SOURCE.read_text()
    grid = GRID.read_text()

    fast = strip_comments(func_body(develop, "makePlaceholderThumbnail"))
    for guard in GUARDS:
        check(f"the fast pass still asks {guard}", guard in fast)

    # ⚠️ THE RULE. A stand-in in the cache is a wrong picture kept for good,
    # and every later visit would hand it back in 0.72 ms looking authoritative.
    check("the fast pass never touches the cache",
          "ThumbnailDiskCache" not in fast)
    check("…and never stores anything",
          ".store(" not in fast)

    # Only the real render may write the cache, and it does so in exactly one
    # place — the same one KORAK 148 put it in.
    real = strip_comments(func_body(develop, "makeEditedShowGridThumbnail"))
    check("the real render is still the only writer",
          real.count("ThumbnailDiskCache.store") == 1)

    # Both callers: a stand-in goes into an EMPTY slot only. Without this the
    # fast pass can land after the render it stands in for and paint over it.
    strip = strip_comments(func_body(develop, "loadFilmstripThumbnail"))
    tiles = strip_comments(func_body(grid, "loadGridThumbnails"))

    for name, body, slot in [("the filmstrip", strip, "filmstripThumbnails"),
                             ("the grid", tiles, "gridThumbnails")]:
        check(f"{name} runs a fast pass", "makePlaceholderThumbnail" in body)
        check(f"{name} writes a stand-in only into an empty slot",
              f"{slot}[url] == nil" in body
              or f"{slot}[placeholderURL] == nil" in body)
        # A cache hit IS the picture, 0.72 ms away — a stand-in in front of it
        # would be a flicker in exchange for nothing.
        check(f"{name} skips the fast pass on a cache hit",
              "ThumbnailDiskCache.hasEntry" in body)

    return failures


def main() -> int:
    if check_source():
        return 1
    print(flush=True)

    harness = HARNESS.read_text().replace("// __EXTRACTED__",
                                          extract(SOURCE.read_text()))

    photo = sys.argv[1] if len(sys.argv) > 1 else str(DEFAULT_PHOTO)
    if not pathlib.Path(photo).exists():
        sys.exit(f"no photo to test with: {photo}")

    with tempfile.TemporaryDirectory() as directory:
        swift = pathlib.Path(directory) / "placeholder-thumbnail.swift"
        binary = pathlib.Path(directory) / "placeholder-thumbnail"
        swift.write_text(harness)

        build = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            return 1

        return subprocess.run([str(binary), photo]).returncode


if __name__ == "__main__":
    sys.exit(main())
