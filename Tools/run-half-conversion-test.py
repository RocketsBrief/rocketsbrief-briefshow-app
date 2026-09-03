#!/usr/bin/env python3
"""Proves the Intel half-precision conversion is exactly what Float16 does.

Why this matters more than most harnesses in here: the Generative Clean Up
result is signed off and locked (see the top of BRIEFSHOW_DEVELOP_NOTES.md).
Making the pipeline compile on Intel meant touching the code that packs every
tensor it feeds the UNet — on BOTH processors. If that conversion is off by one
bit anywhere, the Apple Silicon output changes, and it changes silently.

So both implementations are compiled HERE, on this machine, and compared:

  * `Float16(x)` — what Apple Silicon has always used, straight from the CPU
  * `sdHalf(x)` on x86_64 — the hand-written one, extracted from Develop's
    SD file rather than retyped

Every one of the 2^32 float bit patterns is fed to both. Not a sample: the
whole space, because a rounding bug hides in exactly the values a sample
misses. NaN payloads are compared as "is it still a NaN", which is the only
thing that is defined about them.

Run:  python3 Tools/run-half-conversion-test.py   (~1-2 minutes)
      python3 Tools/run-half-conversion-test.py --quick   (a large sample)
"""
import pathlib, re, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "BriefShow" / "DevelopSDInpaint.swift"
src = SRC.read_text(encoding="utf-8")

# The x86_64 branch of the conversion, taken out of the file by text.
marker = "typealias SDHalf = UInt16"
start = src.find(marker)
if start == -1:
    sys.exit("the x86_64 SDHalf branch was not found — was it renamed or removed?")
func_start = src.find("@inline(__always)", start)
if func_start == -1:
    sys.exit("sdHalf's x86_64 definition was not found")
open_brace = src.index("{", src.index("func sdHalf", func_start))
depth, i = 0, open_brace
while i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
else:
    sys.exit("could not find the end of sdHalf")

body = src[func_start:i + 1]
# It returns SDHalf, which on THIS machine is Float16. Renamed so both can be
# compiled side by side here.
body = body.replace("func sdHalf(_ value: Float) -> SDHalf",
                    "func sdHalfIntel(_ value: Float) -> UInt16", 1)

quick = "--quick" in sys.argv
harness = f'''
import Foundation

{body}

var mismatches = 0
var firstBad: (UInt32, UInt16, UInt16)? = nil
var checked: UInt64 = 0

@inline(__always)
func compare(_ pattern: UInt32) {{
    let value = Float(bitPattern: pattern)
    let apple = Float16(value).bitPattern
    let intel = sdHalfIntel(value)
    if apple == intel {{ return }}
    // A NaN's payload is not defined by the conversion; that it is STILL a NaN
    // is. Both sides agreeing on nan-ness is the whole contract there.
    let appleIsNaN = (apple & 0x7C00) == 0x7C00 && (apple & 0x03FF) != 0
    let intelIsNaN = (intel & 0x7C00) == 0x7C00 && (intel & 0x03FF) != 0
    if appleIsNaN && intelIsNaN {{ return }}
    mismatches += 1
    if firstBad == nil {{ firstBad = (pattern, apple, intel) }}
}}

let quick = {str(quick).lower()}
if quick {{
    // Every half-representable value, every subnormal boundary, and a spread
    // of random patterns.
    for h in 0...UInt32(0xFFFF) {{
        compare(h << 16)
        compare(h)
        checked += 2
    }}
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<20_000_000 {{
        compare(UInt32.random(in: 0...UInt32.max, using: &rng))
        checked += 1
    }}
}} else {{
    var pattern: UInt32 = 0
    while true {{
        compare(pattern)
        checked += 1
        if pattern == UInt32.max {{ break }}
        pattern &+= 1
    }}
}}

print("compared \\(checked) float bit patterns")
if let bad = firstBad {{
    let v = Float(bitPattern: bad.0)
    print(String(format: "  FAIL  first mismatch at 0x%08X (%g): Float16 gave 0x%04X, the Intel path gave 0x%04X",
                 bad.0, v, bad.1, bad.2))
}}
print(mismatches == 0
      ? "  PASS  every conversion is bit-for-bit identical to Float16"
      : "  FAIL  \\(mismatches) conversions differ")
print(mismatches == 0 ? "ALL PASS" : "FAILED")
exit(mismatches == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / "half.swift"
    source.write_text(harness)
    binary = pathlib.Path(tmp) / "half"
    print(f"extracted sdHalf's x86_64 branch ({body.count(chr(10))} lines) from DevelopSDInpaint.swift")
    build = subprocess.run(["swiftc", "-O", "-o", str(binary), str(source)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-2000:])
        sys.exit("the extracted conversion did not compile")
    sys.exit(subprocess.call([str(binary)]))
