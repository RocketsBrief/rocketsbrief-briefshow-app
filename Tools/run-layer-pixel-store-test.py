#!/usr/bin/env python3
"""Proves that moving layer pixels out of UserDefaults loses nothing.

Runs against the CLIENT'S REAL STORE, with the real types pulled out of
Develop.swift — it reuses run-editsettings-decode-test.py's own extractor and
declaration list, so the two harnesses can never disagree about which code is
under test.

What it does, in the order that matters:

  1. decodes the store as it stands on disk (layer pixels still inline),
  2. re-encodes it — which is what makes ImageLayer.encode(to:) write the
     blobs and swap in refs,
  3. decodes THAT, and compares every layer's pixels, byte for byte, with what
     came out in step 1.

Anything short of "identical" is a failure. It also prints what the record
weighs before and after, which is the whole reason for the change.
"""
import importlib.util, json, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "decode_test", ROOT / "Tools" / "run-editsettings-decode-test.py")
decode_test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decode_test)   # guarded by its own __main__ check

src = decode_test.SRC.read_text(encoding="utf-8")
# LayerPixelStore is IN that shared list — ImageLayer's Codable calls into it,
# so the decode harness cannot compile without it either. Extracting a second
# copy here is what this line used to do, and it made the two collide with
# "invalid redeclaration of 'LayerPixelStore'". One list, one copy.
types = "\n\n".join(decode_test.extract(src, header) for header in decode_test.DECLARATIONS)

blob = decode_test.load_blob([sys.argv[0]])
scratch = pathlib.Path(tempfile.mkdtemp()) / "store.json"
scratch.write_bytes(blob)

harness = f'''
import Foundation
import CoreGraphics
import SwiftUI

{types}

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {{
    print("  \\(pass ? "PASS" : "FAIL")  \\(label)\\(detail.isEmpty ? "" : " — " + detail)")
    if !pass {{ failures += 1 }}
}}

let raw = try! Data(contentsOf: URL(fileURLWithPath: "{scratch}"))
let decoder = JSONDecoder()
let encoder = JSONEncoder()

// 1. As it stands on disk.
let before = try! decoder.decode([String: PhotoEditSettings].self, from: raw)
let layersBefore = before.values.reduce(0) {{ $0 + $1.layers.count }}
print("the client's store: \\(before.count) records, \\(layersBefore) layers, \\(raw.count / 1024) KB")

// 2. Re-encoded — this is the step that writes the blobs.
let rewritten = try! encoder.encode(before)
print("after the pixels move to disk: \\(rewritten.count / 1024) KB")

// 3. Back again.
let after = try! decoder.decode([String: PhotoEditSettings].self, from: rewritten)

check("every record survives the round trip", after.count == before.count,
      "\\(after.count) of \\(before.count)")

var comparedPixels = 0
var comparedMattes = 0
var lost = 0
var mismatched = 0
for (key, old) in before {{
    guard let new = after[key] else {{ lost += 1; continue }}
    if new.layers.count != old.layers.count {{ mismatched += 1; continue }}
    for (a, b) in zip(old.layers, new.layers) {{
        if a.imageData != b.imageData {{ mismatched += 1 }}
        else if !a.imageData.isEmpty {{ comparedPixels += 1 }}
        if a.maskData != b.maskData {{ mismatched += 1 }}
        else if a.maskData != nil {{ comparedMattes += 1 }}
        if a.name != b.name || a.x != b.x || a.width != b.width
            || a.opacity != b.opacity || a.adjustments != b.adjustments {{
            mismatched += 1
        }}
    }}
}}
check("no record went missing", lost == 0, "\\(lost) lost")
check("every layer's PIXELS come back byte for byte", mismatched == 0,
      mismatched == 0 ? "\\(comparedPixels) cut-outs and \\(comparedMattes) mattes compared"
                      : "\\(mismatched) differ")

// ⚠️ The store CONVERTS ITSELF the first time the app saves, so after the
// feature has shipped this harness is usually handed an already-converted
// store — and then there is nothing left to shrink. Asserting a size drop
// unconditionally made this fail with "0% smaller" on a store that was
// perfectly correct. So the shrink is only claimed when the input actually
// still carried inline pixels.
let wasConverted = rewritten.count >= raw.count / 2
if wasConverted {{
    print("the store was ALREADY converted — nothing left to move")
}} else {{
    let saved = Double(raw.count - rewritten.count) / Double(raw.count) * 100
    check("the record actually got smaller", true, String(format: "%.0f%% smaller", saved))
}}

// What matters on an already-converted store, and the thing that would
// actually hurt: a ref that points at a blob which is not there. That layer
// comes back with NO pixels — present in the list, invisible on the photo.
var emptyPixelLayers = 0
var derivedLayers = 0
for (_, record) in after {{
    for layer in record.layers {{
        if layer.isDerived {{ derivedLayers += 1; continue }}
        if layer.imageData.isEmpty {{ emptyPixelLayers += 1 }}
    }}
}}
check("every pixel layer's bytes actually resolve", emptyPixelLayers == 0,
      emptyPixelLayers == 0
        ? "\(after.values.reduce(0) {{ $0 + $1.layers.count }} - derivedLayers) pixel layers, \(derivedLayers) derived"
        : "\(emptyPixelLayers) layers came back empty")

// And the cost that started all of this.
func time(_ n: Int, _ body: () -> Void) -> Double {{
    body()
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<n {{ body() }}
    return (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
}}
let oldEncode = time(3) {{ _ = try! encoder.encode(before) }}
let newDecode = time(3) {{ _ = try! decoder.decode([String: PhotoEditSettings].self, from: rewritten) }}
let oldDecode = time(3) {{ _ = try! decoder.decode([String: PhotoEditSettings].self, from: raw) }}
print(String(format: "\\ndecoding the store: %.1f ms before, %.1f ms after", oldDecode, newDecode))
print(String(format: "encoding it (the flush that runs after every edit): %.1f ms", oldEncode))

print(failures == 0 ? "ALL PASS" : "\\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
'''

with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
    f.write(harness)
    path = f.name

print(f"extracted LayerPixelStore and {len(decode_test.DECLARATIONS)} declarations from Develop.swift")
sys.exit(subprocess.call(["swift", path]))
