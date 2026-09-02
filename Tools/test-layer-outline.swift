// Drives the REAL layerOutlineImage(for:) filter chain extracted from
// Develop.swift, rather than a copy of it — same reason as every other test in
// here: a copy drifts silently and then proves nothing.
//
// Run:  python3 Tools/run-layer-outline-test.py
//
// What is actually being proved, and why it is worth a harness: the client
// reported that selecting a Background layer washed the photo in magenta so he
// could not see his own edits. The fix draws the matte's EDGE instead. "It
// draws a line now" is not something that can be settled by reading — the old
// version also looked correct on inspection — so this measures the alpha the
// overlay puts on the picture: transparent INSIDE the region, transparent
// outside it, and opaque only on the boundary.
import Foundation
import AppKit
import CoreImage

// ---- the real function, pasted in by the extractor at run time -------------

let overlayContext = CIContext()

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

/// A grey matte like the one maskPNG stores: white where the layer is.
/// 512x512, with the "layer" a rectangle from (128,128) to (384,384).
func syntheticMaskPNG() -> Data {
    let side = 512
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 128, y: 128, width: 256, height: 256))
    let cg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])!
}

/// The overlay's alpha at a pixel, 0...1, read back out of the NSImage the
/// app would hand to SwiftUI.
func alphaMap(_ image: NSImage) -> (w: Int, h: Int, at: (Int, Int) -> Double) {
    var rect = CGRect(origin: .zero, size: image.size)
    let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, { x, y in Double(buf[(y * w + x) * 4 + 3]) / 255.0 })
}

print("layer outline overlay")

guard let image = layerOutlineImage(maskData: syntheticMaskPNG()) else {
    print("  FAIL  the overlay produced nothing at all")
    exit(1)
}

let map = alphaMap(image)
check("overlay is the size of the matte", map.w == 512 && map.h == 512, "\(map.w)x\(map.h)")

// INSIDE the region. This is the whole report: the wash covered exactly here.
var insideMax = 0.0
for y in 170...340 {
    for x in 170...340 {
        insideMax = max(insideMax, map.at(x, y))
    }
}
check("inside the region is CLEAR (the wash is gone)", insideMax < 0.02,
      String(format: "worst alpha inside = %.3f", insideMax))

// OUTSIDE it, where the layer is not.
var outsideMax = 0.0
for y in 5...100 {
    for x in 5...100 {
        outsideMax = max(outsideMax, map.at(x, y))
    }
}
check("outside the region is CLEAR", outsideMax < 0.02,
      String(format: "worst alpha outside = %.3f", outsideMax))

// ON the boundary — the line itself, which is the thing that replaced the
// wash. Sampled as a band a few pixels either side of the edge, because the
// gradient's radius decides how wide it lands.
func edgeMax(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Double {
    var best = 0.0
    for y in ys { for x in xs { best = max(best, map.at(x, y)) } }
    return best
}
let left = edgeMax(122...134, 200...300)
let top = edgeMax(200...300, 122...134)
let right = edgeMax(378...390, 200...300)
let bottom = edgeMax(200...300, 378...390)
check("there IS a line on the left edge", left > 0.5, String(format: "%.3f", left))
check("there IS a line on the top edge", top > 0.5, String(format: "%.3f", top))
check("there IS a line on the right edge", right > 0.5, String(format: "%.3f", right))
check("there IS a line on the bottom edge", bottom > 0.5, String(format: "%.3f", bottom))

// The line has to be thin. A "line" 40px wide is a wash with a hole in it.
var lineWidth = 0
for x in 100...170 where map.at(x, 256) > 0.1 {
    lineWidth += 1
}
check("the line is THIN, not a band", lineWidth > 0 && lineWidth <= 8, "\(lineWidth) px across")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
