#!/usr/bin/env python3
"""Builds and runs Tools/crop-zones.swift against the LIVE crop code.

The three functions under test are cut out of Develop.swift by name and
pasted into the harness, so the harness cannot pass while the app has moved
on — the same rule Tools/skymask.swift follows.
"""
import pathlib
import re
import subprocess
import textwrap
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"
HARNESS = ROOT / "Tools" / "crop-zones.swift"

# The enum, and the three statics the zones and the cursor angles come from.
WANTED = [
    ("enum", "CropHandle"),
    ("func", "cropFrameLocalPoint"),
    ("func", "cropResizeDegrees"),
    ("func", "cropHandle"),
]


def extract(text: str, kind: str, name: str) -> str:
    """Everything from a declaration's line to its matching closing brace."""
    pattern = rf"^[ \t]*(?:private |fileprivate |internal )?(?:static )?{kind} {name}\b"
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find {kind} {name} in {SOURCE.name}")

    start = match.start()
    depth = 0
    seen_brace = False
    for index in range(start, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
            seen_brace = True
        elif char == "}":
            depth -= 1
            if seen_brace and depth == 0:
                body = text[start:index + 1]
                # Only the DECLARATION LINE loses its modifiers. Stripping
                # `static` throughout would also strip it from the enum's own
                # members, which is then not valid Swift — an enum cannot hold
                # a stored property. `Self.` has no Self out here either.
                lines = body.split("\n")
                lines[0] = re.sub(r"\b(private|fileprivate|internal|static) ", "", lines[0])
                body = "\n".join(lines)
                body = re.sub(r"\b(private|fileprivate) ", "", body)
                body = body.replace("Self.", "")
                return textwrap.dedent(body)
    sys.exit(f"unbalanced braces while reading {kind} {name}")


def main() -> int:
    source = SOURCE.read_text()
    extracted = "\n\n".join(extract(source, kind, name) for kind, name in WANTED)
    harness = HARNESS.read_text().replace("// __EXTRACTED__", extracted)

    with tempfile.TemporaryDirectory() as directory:
        swift = pathlib.Path(directory) / "crop-zones.swift"
        binary = pathlib.Path(directory) / "crop-zones"
        swift.write_text(harness)

        build = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            return 1

        return subprocess.run([str(binary)]).returncode


if __name__ == "__main__":
    sys.exit(main())
