// Drives the REAL decodedLayerImage / dataFingerprint / decodedLayerCache
// extracted from Develop.swift, rather than a copy of them.
//
// Run:  python3 Tools/run-layer-decode-cache-test.py
//
// Two things are being proved here and the SECOND one matters more.
//
// 1. Speed. Dragging a People layer juddered — *„drhti selection, nije smooth
//    movement"*. The cause was measured, not guessed: the cut-out's PNG was
//    decoded again on every frame of the drag.
//
// 2. ⚠️ QUALITY, WHICH IS NOT NEGOTIABLE. The client's next sentence was
//    *„nemoj da izgubi quality taj duplikat layer people ili background…
//    quality maximum original"*. A cache is the right kind of fix precisely
//    because it changes NOTHING about the pixels — but "it should be identical"
//    is exactly the sort of claim that has been wrong before in this project,
//    so it is measured: every pixel of a composite built through the cache is
//    compared with one built by decoding fresh, and the answer has to be zero
//    differences. Not "close". Zero.
import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// ---- the real declarations, pasted in by the extractor at run time ---------

/// Only the two fields decodedLayerImage actually reads. The runner says why
/// this stand-in is honest.
struct ImageLayer {
    let id: UUID
    let imageData: Data
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb,
                              .cacheIntermediates: false])

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

/// A cut-out the size Select People really makes: people fill a good part of a
/// 24MP frame. Detailed, not a flat fill — a flat PNG compresses to nothing and
/// would make the decode look free.
func cutoutPNG(width: Int, height: Int, seed: UInt64) -> Data {
    // Its own deterministic generator, so a failure is reproducible.
    var state = seed
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.clear(CGRect(x: 0, y: 0, width: width, height: height))
    for i in 0..<400 {
        c.setFillColor(red: CGFloat(i % 97) / 97, green: CGFloat(i % 61) / 61,
                       blue: CGFloat(i % 43) / 43, alpha: 1)
        c.fillEllipse(in: CGRect(x: next(width), y: next(height), width: 240, height: 240))
    }
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

let cutWidth = 1800, cutHeight = 2900
let png = cutoutPNG(width: cutWidth, height: cutHeight, seed: 12345)
let layer = ImageLayer(id: UUID(), imageData: png)
print("cut-out: \(cutWidth)x\(cutHeight), \(png.count / 1024) KB")

// The photo underneath, at the preview size renderNow works at.
let baseW = 1733, baseH = 2600
let baseCG = CGContext(data: nil, width: baseW, height: baseH, bitsPerComponent: 8, bytesPerRow: 0,
                       space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
baseCG.setFillColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
baseCG.fill(CGRect(x: 0, y: 0, width: baseW, height: baseH))
let base = CIImage(cgImage: baseCG.makeImage()!)

/// The same placement compositeLayers does: scale to the layer's box, offset.
func composite(_ source: CIImage) -> CIImage {
    let scaled = source
        .transformed(by: CGAffineTransform(scaleX: 0.8, y: 0.8))
        .transformed(by: CGAffineTransform(translationX: 120, y: 80))
    let f = CIFilter.sourceOverCompositing()
    f.inputImage = scaled
    f.backgroundImage = base
    return (f.outputImage ?? base).cropped(to: base.extent)
}

/// ⚠️ One buffer, allocated once and reused.
///
/// It was allocated inside this function to begin with, and that made the
/// timings below lie: an 18 MB allocation and zero-fill was being counted as
/// part of "a drag frame" in BOTH paths, putting the cached path at 26.9 ms
/// when the render itself is a fraction of that. The DIFFERENCE between the
/// two paths was still right — allocation cancels out — but the absolute
/// number is what the throttle is compared against, so it has to be the render
/// alone.
var renderBuffer = [UInt8](repeating: 0, count: baseW * baseH * 4)
func renderInto(_ image: CIImage) {
    ctx.render(image, toBitmap: &renderBuffer, rowBytes: baseW * 4, bounds: base.extent,
               format: .RGBA8, colorSpace: srgb)
}

func bitmap(_ image: CIImage) -> [UInt8] {
    renderInto(image)
    return renderBuffer
}

print("\nquality")

// Full resolution, byte for byte the stored bytes — nothing resampled on the
// way in.
guard let cached = decodedLayerImage(layer) else {
    print("  FAIL  the cache returned nothing")
    exit(1)
}
check("the layer decodes at its FULL size, not a reduced one",
      Int(cached.extent.width) == cutWidth && Int(cached.extent.height) == cutHeight,
      "\(Int(cached.extent.width))x\(Int(cached.extent.height))")

// The heart of it: cached pixels against freshly decoded pixels.
let fresh = CIImage(data: png)!
let viaCache = bitmap(composite(cached))
let viaFresh = bitmap(composite(fresh))
var differing = 0
var worstChannel = 0
for i in stride(from: 0, to: viaCache.count, by: 1) {
    let d = abs(Int(viaCache[i]) - Int(viaFresh[i]))
    if d != 0 {
        differing += 1
        worstChannel = max(worstChannel, d)
    }
}
check("every pixel is IDENTICAL to decoding fresh", differing == 0,
      differing == 0 ? "0 of \(viaCache.count / 4) pixels differ"
                     : "\(differing) channels differ, worst by \(worstChannel)/255")

print("\ncorrectness of the key")

// A cache hit must be the same decode, not a rebuild.
check("asking twice returns the same decode", decodedLayerImage(layer) === cached)

// Same layer id, different pixels — a bake, a flatten, a fresh Select People.
// Serving the old decode here would show the client the previous cut-out.
let replaced = ImageLayer(id: layer.id, imageData: cutoutPNG(width: cutWidth, height: cutHeight, seed: 999))
let afterReplace = decodedLayerImage(replaced)
check("replacing a layer's pixels does NOT serve the old decode",
      afterReplace != nil && afterReplace !== cached)

// An empty layer is a derived one; it has no pixels of its own.
check("a layer with no pixels decodes to nothing",
      decodedLayerImage(ImageLayer(id: UUID(), imageData: Data())) == nil)

print("\nspeed, one drag frame")

func time(_ n: Int, _ body: () -> Void) -> Double {
    body()
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<n { body() }
    return (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
}

let freshMs = time(5) { renderInto(composite(CIImage(data: png)!)) }
let cachedMs = time(5) { renderInto(composite(decodedLayerImage(layer)!)) }
print(String(format: "  decoding every frame (what it did): %.1f ms", freshMs))
print(String(format: "  through the cache (what it does):   %.1f ms", cachedMs))
check("a drag frame fits inside the 20ms render throttle", cachedMs < 20,
      String(format: "%.1f ms", cachedMs))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
