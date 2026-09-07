// Harness for the pool of thumbnail CIContexts.
//
// ⚠️ `makeBriefEditsCIContext`, the pool and `BriefEditsThumbnailContexts` are
// EXTRACTED FROM Develop.swift at build time by
// run-thumbnail-context-pool-test.py, so the harness cannot pass while the app
// has moved on.
//
// What it proves, in this order of importance:
//   1. the picture is byte for byte the same through every context in the
//      pool — this is the guarantee the whole change rests on, and the one
//      that would resurrect KORAK 128 if it ever stopped being true,
//   2. the pool really hands out every context, not the same one four times.
//
// ⚠️ It does NOT assert that the pool is faster, and that is deliberate. The
// speed was measured — 66.9/62.7/59.4/60.8 ms shared against 45.4/51.1/50.1/
// 51.2 ms pooled, four wide — but only with 25 s of cooling before every
// trial. Without that, this machine's own heat swamps the difference and an
// earlier reading of the same question came out backwards. A timing assertion
// here would fail on a warm laptop and teach everyone to ignore it. The
// method is written down in BRIEFSHOW_DEVELOP_NOTES.md instead; re-measure
// there, do not guess from a red test.

import Foundation
import CoreImage
import AppKit

let briefEditsSRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// __EXTRACTED__

var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("  ok    \(label)") }
    else { failures += 1; print("  FAIL  \(label) \(detail)") }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: thumbnail-context-pool <a .NEF>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])

// The thumbnail's own graph, at the cache's own size.
func graph() -> CIImage? {
    guard let filter = CIRAWFilter(imageURL: url) else { return nil }
    filter.isDraftModeEnabled = true
    if let full = filter.outputImage?.extent, full.width >= 1 {
        let longest = max(full.width, full.height)
        if longest > 512 { filter.scaleFactor = Float(512 / longest) }
    }
    return filter.outputImage
}

func bytes(_ image: CGImage) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    buffer.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: briefEditsSRGBColorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return buffer
}

print("the pool")

check("it holds four contexts, one per thumbnail worker",
      briefEditsThumbnailCIContexts.count == 4,
      "got \(briefEditsThumbnailCIContexts.count)")

// Four takes must touch all four, or the pool is a shared context wearing a
// costume — which is exactly the state this change exists to leave behind.
var seen: Set<ObjectIdentifier> = []
for _ in 0..<briefEditsThumbnailCIContexts.count {
    seen.insert(ObjectIdentifier(BriefEditsThumbnailContexts.take()))
}
check("four takes hand out four different contexts",
      seen.count == briefEditsThumbnailCIContexts.count,
      "got \(seen.count)")

// …and then it comes back round rather than running off the end.
let firstAgain = ObjectIdentifier(BriefEditsThumbnailContexts.take())
check("the fifth take comes back round", seen.contains(firstAgain))

print("\nthe picture, through every context in the pool")

guard let image = graph(), image.extent.width >= 1 else {
    print("  FAIL  could not build the thumbnail graph for \(url.lastPathComponent)")
    exit(1)
}

var reference: [UInt8]?
var worst = 0.0
for (index, context) in briefEditsThumbnailCIContexts.enumerated() {
    guard let rendered = context.createCGImage(image, from: image.extent,
                                               format: .RGBA8,
                                               colorSpace: briefEditsSRGBColorSpace) else {
        print("  FAIL  context \(index) rendered nothing")
        failures += 1
        continue
    }
    let pixels = bytes(rendered)
    guard let reference else {
        reference = pixels
        print("  ok    context 0 rendered \(rendered.width)x\(rendered.height) — the reference")
        continue
    }
    guard pixels.count == reference.count else {
        check("context \(index) is the same size as context 0", false)
        continue
    }
    var square = 0.0
    for offset in 0..<pixels.count {
        let delta = Double(pixels[offset]) - Double(reference[offset])
        square += delta * delta
    }
    let rms = (square / Double(pixels.count)).squareRoot()
    worst = max(worst, rms)
    check("context \(index) is byte for byte context 0", rms == 0,
          String(format: "RMS %.6f", rms))
}

print(String(format: "\nworst RMS across the pool: %.6f", worst))
print(failures == 0 ? "all good" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
