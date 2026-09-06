#!/usr/bin/env python3
"""Builds and runs Tools/preview-decode.swift against the LIVE render code.

cachedRAWDecode and releaseCachedRAWDecode are cut out of Develop.swift by
name, so the harness cannot pass while the app has moved on — the same rule
Tools/skymask.swift and Tools/run-crop-zone-test.py follow.
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"
HARNESS = ROOT / "Tools" / "preview-decode.swift"
DEFAULT_PHOTO = pathlib.Path.home() / "Downloads/Summer Walker and Original/C4S_9331.NEF"

WANTED = ["cachedRAWDecode", "releaseCachedRAWDecode"]


def extract(text: str, name: str) -> str:
    pattern = rf"^[ \t]*(?:private |fileprivate |internal )?(?:static )?func {name}\b"
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find func {name} in {SOURCE.name}")

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
                lines = body.split("\n")
                lines[0] = re.sub(r"\b(private|fileprivate|internal|static) ", "", lines[0])
                return textwrap.dedent("\n".join(lines))
    sys.exit(f"unbalanced braces while reading func {name}")


def main() -> int:
    photo = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PHOTO
    if not photo.exists():
        sys.exit(f"no photo to measure with: {photo}")

    source = SOURCE.read_text()
    extracted = "\n\n".join(extract(source, name) for name in WANTED)
    harness = HARNESS.read_text().replace("// __EXTRACTED__", extracted)

    with tempfile.TemporaryDirectory() as directory:
        swift = pathlib.Path(directory) / "preview-decode.swift"
        binary = pathlib.Path(directory) / "preview-decode"
        swift.write_text(harness)

        build = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            return 1

        return subprocess.run([str(binary), str(photo)]).returncode


if __name__ == "__main__":
    sys.exit(main())
