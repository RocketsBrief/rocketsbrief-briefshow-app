#!/usr/bin/env python3
"""Builds and runs Tools/thumbnail-cache.swift against the LIVE cache code.

ThumbnailDiskCache and filmstripThumbnailPixelSize are cut out of
Develop.swift by name, so the harness cannot pass while the app has moved on.
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "Develop.swift"
HARNESS = ROOT / "Tools" / "thumbnail-cache.swift"

WANTED = [("enum", "ThumbnailDiskCache")]
CONSTANTS = ["filmstripThumbnailPixelSize"]


def extract(text: str, kind: str, name: str) -> str:
    pattern = rf"^[ \t]*(?:private |fileprivate |internal )?(?:static )?{kind} {name}\b"
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find {kind} {name} in {SOURCE.name}")

    depth = 0
    seen_brace = False
    for index in range(match.start(), len(text)):
        char = text[index]
        if char == "{":
            depth += 1
            seen_brace = True
        elif char == "}":
            depth -= 1
            if seen_brace and depth == 0:
                body = text[match.start():index + 1]
                lines = body.split("\n")
                lines[0] = re.sub(r"\b(private|fileprivate|internal) ", "", lines[0])
                # `private` on MEMBERS has to go too — the harness reads
                # `side`, and a nested private would hide it.
                body = "\n".join(lines).replace("private static", "static")
                return textwrap.dedent(body)
    sys.exit(f"unbalanced braces while reading {kind} {name}")


def extract_constant(text: str, name: str) -> str:
    match = re.search(rf"^[ \t]*(?:private )?let {name}\b.*$", text, re.MULTILINE)
    if not match:
        sys.exit(f"could not find let {name} in {SOURCE.name}")
    return re.sub(r"\bprivate ", "", match.group(0).strip())


def main() -> int:
    source = SOURCE.read_text()
    parts = [extract(source, kind, name) for kind, name in WANTED]
    parts += [extract_constant(source, name) for name in CONSTANTS]
    harness = HARNESS.read_text().replace("// __EXTRACTED__", "\n\n".join(parts))

    with tempfile.TemporaryDirectory() as directory:
        swift = pathlib.Path(directory) / "thumbnail-cache.swift"
        binary = pathlib.Path(directory) / "thumbnail-cache"
        swift.write_text(harness)

        build = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            return 1

        return subprocess.run([str(binary)]).returncode


if __name__ == "__main__":
    sys.exit(main())
