#!/usr/bin/env python3
"""Decodes the CLIENT'S REAL saved edits with the CURRENT PhotoEditSettings.

Why this exists, and why it is not optional when that struct changes:

    PhotoEditStore.allSettings does

        (try? JSONDecoder().decode([String: PhotoEditSettings].self, ...)) ?? [:]

    on ONE dictionary holding every edit the client has ever made. That is
    all-or-nothing. A single record that fails to decode does not get dropped
    on its own — the whole decode returns nil, every edit in the app becomes
    [:], and the next debounced flush writes that empty dictionary back over
    the client's work. There is no error, no dialog and no undo.

So any change to PhotoEditSettings has to be measured against records written
by an OLDER build, not against a fresh one. This reads the real blob straight
out of the installed app's preferences and decodes it with the struct as it is
in Develop.swift right now.

Same extraction discipline as run-layer-reorder-test.py: the types are pulled
out of the source by text at run time, so this cannot quietly keep testing a
stale copy. If a type is renamed or moved, it fails loudly with "not found".

    python3 Tools/run-editsettings-decode-test.py [path/to/edits.json]

With no argument it reads the live preference for com.rocketsbrief.BriefShow.
"""
import json
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "BriefShow" / "Develop.swift"
BUNDLE_ID = "com.rocketsbrief.BriefShow"
DEFAULTS_KEY = "com.rocketsbrief.briefshow.photoEditSettings"

# Every top-level declaration PhotoEditSettings needs to decode, named by the
# exact text its declaration starts with. Listed rather than discovered: a
# discovered closure would silently start pulling in half the file the day
# someone adds a property, and this test would stop being about Codable.
DECLARATIONS = [
    "enum ColorBand:",
    "struct ColorMixerBand:",
    "struct ColorMixer:",
    "struct EditCropRect:",
    "enum CropAspectRatioOption:",
    "enum LocalMaskType:",
    "enum PatchShape:",
    "struct LocalAdjustmentSettings:",
    "struct RadialMaskGeometry:",
    "struct GraduatedMaskGeometry:",
    "struct BrushStroke:",
    "struct BrushMaskGeometry:",
    "struct PatchGeometry:",
    "struct PatchStroke:",
    "struct LocalAdjustment:",
    "enum LayerBlendMode:",
    "enum SkyStyle:",
    "struct ImageLayer:",
    "struct PhotoEditSettings:",
]


def extract(src: str, header: str) -> str:
    """The whole declaration, bounded by brace balance from its opening brace."""
    start = src.find("\n" + header)
    if start == -1:
        sys.exit(f"{header!r} not found in Develop.swift — was it renamed or moved?")
    start += 1
    depth = 0
    i = src.index("{", start)
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return src[start:i + 1]


def load_blob(argv) -> bytes:
    if len(argv) > 1:
        return pathlib.Path(argv[1]).read_bytes()
    exported = subprocess.run(
        ["defaults", "export", BUNDLE_ID, "-"], capture_output=True
    )
    if exported.returncode != 0 or not exported.stdout:
        sys.exit(f"no preferences found for {BUNDLE_ID} — pass a JSON file instead")
    plist = plistlib.loads(exported.stdout)
    if DEFAULTS_KEY not in plist:
        sys.exit(f"{DEFAULTS_KEY} is not in {BUNDLE_ID}'s preferences — nothing saved yet")
    return plist[DEFAULTS_KEY]


def main() -> int:
    blob = load_blob(sys.argv)
    records = json.loads(blob)
    fields = sorted({k for v in records.values() for k in v})
    print(f"records in the client's store: {len(records)}")
    print(f"fields present across them:    {len(fields)}")

    # The whole point: which of the struct's keys these old records DO NOT
    # carry. Those are the ones decodeIfPresent has to cover.
    src = SRC.read_text(encoding="utf-8")
    settings_decl = extract(src, "struct PhotoEditSettings:")
    declared = set()
    for line in settings_decl.splitlines():
        line = line.strip()
        # Stored properties only. A computed one (`var isNeutral: Bool {`)
        # has no stored key and would show up as a phantom "missing field".
        if line.startswith("var ") and not line.rstrip().endswith("{"):
            declared.add(line[4:].split(":")[0].split("=")[0].strip())
    missing = sorted(declared - set(fields))
    print(f"declared but absent from every stored record: {missing or 'none'}")

    scratch = pathlib.Path(sys.argv[0]).resolve().parent / ".editsettings-test.json"
    scratch.write_bytes(blob)

    types = "\n\n".join(extract(src, header) for header in DECLARATIONS)
    harness = f'''
import Foundation
import CoreGraphics
import SwiftUI

{types}

// MARK: - the test

let url = URL(fileURLWithPath: "{scratch}")
let data = try! Data(contentsOf: url)

// Exactly the call PhotoEditStore.allSettings makes — the whole dictionary at
// once, so this fails the same all-or-nothing way the app would.
guard let all = try? JSONDecoder().decode([String: PhotoEditSettings].self, from: data) else {{
    // Decode one at a time to name the record that broke it, since the
    // dictionary decode above cannot say which one it was.
    let raw = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    for (key, value) in raw {{
        let one = try! JSONSerialization.data(withJSONObject: value)
        do {{ _ = try JSONDecoder().decode(PhotoEditSettings.self, from: one) }}
        catch {{ print("FAIL  \\(key): \\(error)") }}
    }}
    print("RESULT: FAILED — the app would wipe every edit in the store")
    exit(1)
}}

print("decoded: \\(all.count) records")

// Decoding is not enough: a record that decodes to DIFFERENT values is a
// silent edit change, which is worse than a crash. Re-encoding and comparing
// catches a field that decoded to the wrong default.
var mismatches = 0
let rawAll = try! JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
for (key, settings) in all {{
    guard let before = rawAll[key] else {{ continue }}
    let after = try! JSONSerialization.jsonObject(
        with: try! JSONEncoder().encode(settings)) as! [String: Any]
    for (field, value) in before {{
        guard let lhs = value as? Double, let rhs = after[field] as? Double else {{ continue }}
        if abs(lhs - rhs) > 1e-9 {{
            print("DRIFT \\(key).\\(field): \\(lhs) -> \\(rhs)")
            mismatches += 1
        }}
    }}
}}

if mismatches > 0 {{
    print("RESULT: FAILED — \\(mismatches) stored value(s) changed on the round trip")
    exit(1)
}}
print("RESULT: OK — every record survives, and no stored number moved")
'''

    print(f"extracted {len(DECLARATIONS)} declarations from Develop.swift, compiling…")
    result = subprocess.run(["swift", "-"], input=harness, text=True)
    scratch.unlink(missing_ok=True)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
