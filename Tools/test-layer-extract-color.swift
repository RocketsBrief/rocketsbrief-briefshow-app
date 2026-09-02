// Drives the REAL extraction path out of Develop.swift — the shared context
// and pngData(for:pixelRect:) — rather than a copy of it.
//
// Run:  python3 Tools/run-layer-extract-color-test.py
//
// What this is for. "Select People" cuts the people out of the RENDERED photo
// and stores them as a layer. The client moved that layer aside, saw his own
// photograph next to it, and reported that the copy was a different person's
// colouring — *„dobio sam kopiju totalno drugačiju, vidi oči recimo"*.
//
// A cut-out is the same pixels as the picture it came out of, so the two have
// to match to the byte. What decides that is not the mask and not the PNG: it
// is WHICH CONTEXT evaluates the filter graph. Core Image applies exposure,
// contrast and saturation in the context's WORKING COLOUR SPACE, so the very
// same graph rendered through a linear-working context and through the app's
// sRGB one lands on different numbers — brighter, flatter, off-hue.
//
// So this measures exactly that: build an edited graph, render it the way the
// client SEES it, extract it the way the app STORES it, and compare the pixels.
import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// ---- the real declarations, pasted in by the extractor at run time ---------

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

/// The context the client actually looks through: LumenoLab's preview, the
/// filmstrip and the export all use these two settings (makeBriefEditsCIContext).
let viewedContext = CIContext(options: [
    .workingColorSpace: briefEditsSRGBColorSpace,
    .outputColorSpace: briefEditsSRGBColorSpace
])

func patch(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CIImage {
    let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                        space: briefEditsSRGBColorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    return CIImage(cgImage: ctx.makeImage()!)
}

/// One pixel out of the middle, as sRGB bytes.
func pixel(_ cg: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 4)
    let c = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: briefEditsSRGBColorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                          width: CGFloat(cg.width), height: CGFloat(cg.height)))
    return buf
}

/// The same shape of graph the editor builds over a photo: an exposure stage
/// and a contrast/saturation stage. The point is not these exact filters, it
/// is that they are TONE filters and therefore working-space dependent.
func edited(_ img: CIImage, ev: Float, contrast: Float, saturation: Float) -> CIImage {
    let e = CIFilter.exposureAdjust()
    e.inputImage = img
    e.ev = ev
    let c = CIFilter.colorControls()
    c.inputImage = e.outputImage!
    c.contrast = contrast
    c.saturation = saturation
    c.brightness = 0
    return c.outputImage!
}

let swatches: [(String, UInt8, UInt8, UInt8)] = [
    ("skin", 220, 180, 160),
    ("mid grey", 128, 128, 128),
    ("green dress", 60, 90, 40),
    ("eye brown", 92, 64, 46)
]

let edits: [(String, Float, Float, Float)] = [
    ("no edits at all", 0, 1, 1),
    ("exposure +0.62", 0.62, 1, 1),
    ("exposure -0.40", -0.40, 1, 1),
    ("contrast 1.2, saturation 1.15", 0, 1.2, 1.15)
]

print("cut-out colour against the photo it came from")

var worst = 0
for (editName, ev, contrast, saturation) in edits {
    var worstHere = 0
    var detail = ""
    for (name, r, g, b) in swatches {
        let graph = edited(patch(r, g, b), ev: ev, contrast: contrast, saturation: saturation)

        // As SEEN: rendered through the app's own context.
        let seen = pixel(viewedContext.createCGImage(graph, from: graph.extent)!)

        // As STORED: through the real extraction path, then decoded back the
        // way compositeLayers decodes a layer (CIImage(data:)).
        guard let png = pngData(for: graph, pixelRect: graph.extent),
              let decoded = CIImage(data: png) else {
            check("\(editName) / \(name) — extraction produced something", false)
            continue
        }
        let stored = pixel(viewedContext.createCGImage(decoded, from: decoded.extent)!)

        let drift = (0..<3).map { abs(Int(stored[$0]) - Int(seen[$0])) }.max()!
        if drift > worstHere {
            worstHere = drift
            detail = "\(name): seen (\(seen[0]),\(seen[1]),\(seen[2])) vs cut-out (\(stored[0]),\(stored[1]),\(stored[2]))"
        }
    }
    worst = max(worst, worstHere)
    // 1/255 of slack for rounding through 8-bit, and not a byte more: the
    // cut-out is meant to be the SAME pixels, not similar ones.
    check("\(editName) — cut-out matches the photo", worstHere <= 1,
          "worst channel off by \(worstHere)/255" + (worstHere > 1 ? " — \(detail)" : ""))
}

print("worst drift anywhere: \(worst)/255")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
