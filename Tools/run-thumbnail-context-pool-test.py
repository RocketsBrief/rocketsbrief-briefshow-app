#!/usr/bin/env python3
"""Builds and runs Tools/thumbnail-context-pool.swift against the LIVE pool.

    python3 Tools/run-thumbnail-context-pool-test.py [a .NEF]

`makeBriefEditsCIContext`, `briefEditsThumbnailCIContexts` and
`BriefEditsThumbnailContexts` are cut out of Develop.swift by name, so the
harness cannot pass while the app has moved on — the same rule
Tools/run-thumbnail-cache-test.py follows.

On top of what the Swift side checks, this file reads the source for the one
thing that ties the pool to its reason for existing: its size has to match how
wide the two thumbnail fills actually run. A pool of four in front of eight
workers, or of one in front of four, is the bug this change fixed coming back.
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
HARNESS = ROOT / "Tools" / "thumbnail-context-pool.swift"
DEFAULT_PHOTO = pathlib.Path.home() / "Downloads/Summer Walker and Original/C4S_9331.NEF"


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


def extract(text: str, pattern: str, what: str) -> str:
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find {what} in {SOURCE.name}")
    body = read_body(text, match.start())
    return textwrap.dedent(re.sub(r"\bprivate ", "", body))


def extract_let(text: str, name: str) -> str:
    """A one-line `let` — the pool itself, whose body has no braces to balance."""
    match = re.search(rf"^[ \t]*(?:private )?let {name}\b.*$", text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find let {name} in {SOURCE.name}")
    return re.sub(r"\bprivate ", "", match.group(0).strip())


def widths(text: str) -> list:
    """Every `maxConcurrentOperationCount = N` the thumbnail fills set."""
    return [int(n) for n in re.findall(r"maxConcurrentOperationCount = (\d+)", text)]


def check_source() -> int:
    failures = 0

    def check(label, condition, detail=""):
        nonlocal failures
        if condition:
            print(f"  ok    {label}", flush=True)
        else:
            failures += 1
            print(f"  FAIL  {label} {detail}", flush=True)

    print("the source", flush=True)

    develop = SOURCE.read_text()
    grid = GRID.read_text()

    pool = extract_let(develop, "briefEditsThumbnailCIContexts")
    size = re.search(r"\(0\.\.<(\d+)\)", pool)
    check("the pool declares its size as a number", size is not None, pool)
    if not size:
        return failures
    size = int(size.group(1))

    # ⚠️ The whole point. Both fills run four wide; a pool that does not match
    # them is either a bottleneck (too small) or memory for nothing (too big),
    # and on a 8 GB machine the second is not free either.
    found = widths(develop) + widths(grid)
    check(f"the pool ({size}) matches every thumbnail queue width {found}",
          found and all(width == size for width in found))

    # The single shared context this replaced must be gone, not merely unused —
    # a leftover would be the thing a later change reaches for by name.
    check("the old single briefEditsThumbnailCIContext is gone",
          "briefEditsThumbnailCIContext " not in develop
          and "briefEditsThumbnailCIContext)" not in develop)

    # Nothing may take a context except through the pool.
    check("the thumbnail render takes from the pool",
          "BriefEditsThumbnailContexts.take()" in develop)

    return failures


def main() -> int:
    if check_source():
        return 1
    print(flush=True)

    develop = SOURCE.read_text()
    parts = [
        extract(develop, r"^[ \t]*(?:private )?func makeBriefEditsCIContext\b",
                "func makeBriefEditsCIContext"),
        extract_let(develop, "briefEditsThumbnailCIContexts"),
        extract(develop, r"^[ \t]*(?:private )?enum BriefEditsThumbnailContexts\b",
                "enum BriefEditsThumbnailContexts"),
    ]
    harness = HARNESS.read_text().replace("// __EXTRACTED__", "\n\n".join(parts))

    photo = sys.argv[1] if len(sys.argv) > 1 else str(DEFAULT_PHOTO)
    if not pathlib.Path(photo).exists():
        sys.exit(f"no photo to test with: {photo}")

    with tempfile.TemporaryDirectory() as directory:
        swift = pathlib.Path(directory) / "thumbnail-context-pool.swift"
        binary = pathlib.Path(directory) / "thumbnail-context-pool"
        swift.write_text(harness)

        build = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            return 1

        return subprocess.run([str(binary), photo]).returncode


if __name__ == "__main__":
    sys.exit(main())
