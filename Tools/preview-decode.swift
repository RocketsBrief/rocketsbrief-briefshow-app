// Harness for the preview's held demosaic (PhotoEditRenderer.cachedRAWDecode).
//
// ⚠️ The two functions under test are EXTRACTED FROM Develop.swift at build
// time by run-preview-decode-test.py. Only the three storage declarations are
// written out here, and if they drift from the source the extracted code will
// not compile — which is the point.
//
// What it has to prove, in this order of importance:
//   1. the picture does not change,
//   2. a Temperature/Tint/Exposure change still re-decodes,
//   3. it is actually faster.

import Foundation
import CoreImage
import AppKit

private let rawDecodeLock = NSLock()
private weak var rawDecodeFilter: CIRAWFilter?
private var rawDecodeKey: String?
private var rawDecodeImage: CIImage?

// __EXTRACTED__

let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  .cacheIntermediates: false])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("  ok    \(label)") }
    else { failures += 1; print("  FAIL  \(label) \(detail)") }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: preview-decode <a .NEF>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])

func previewFilter() -> CIRAWFilter {
    let filter = CIRAWFilter(imageURL: url)!
    filter.isDraftModeEnabled = true
    let longest = max(filter.outputImage!.extent.width, filter.outputImage!.extent.height)
    filter.scaleFactor = Float(2600 / longest)
    return filter
}

// A stand-in for the grade that runs after the decode. Its exact shape does
// not matter — what matters is that both paths get the SAME one.
func grade(_ image: CIImage) -> CIImage {
    image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08,
                                                         kCIInputSaturationKey: 1.1])
         .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.2])
}

func draw(_ image: CIImage) -> [UInt8] {
    let cg = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                   colorSpace: space, deferred: false)!
    var buffer = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    buffer.withUnsafeMutableBytes { raw in
        let c = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                          bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    return buffer
}

let filter = previewFilter()
filter.exposure = 0
filter.neutralTemperature = 5000
filter.neutralTint = 10

print("1. the picture")
let uncached = draw(grade(filter.outputImage!))
let cached = draw(grade(cachedRAWDecode(from: filter, exposure: 0, kelvin: 5000, tint: 10)))
var worst = 0
var differing = 0
for i in 0..<uncached.count {
    let difference = abs(Int(uncached[i]) - Int(cached[i]))
    if difference > 0 { differing += 1; worst = max(worst, difference) }
}
check("no pixel moves by more than 1/255", worst <= 1, "worst was \(worst)/255")
print(String(format: "        (%d of %d bytes differ at all — %.2f%%)",
             differing, uncached.count, Double(differing) / Double(uncached.count) * 100))

print("\n2. when it must decode again")
let first = cachedRAWDecode(from: filter, exposure: 0, kelvin: 5000, tint: 10)
check("the same three values reuse the held decode",
      cachedRAWDecode(from: filter, exposure: 0, kelvin: 5000, tint: 10) === first)
check("a different Exposure does NOT",
      cachedRAWDecode(from: filter, exposure: 0.5, kelvin: 5000, tint: 10) !== first)
_ = cachedRAWDecode(from: filter, exposure: 0, kelvin: 5000, tint: 10)
check("a different Temperature does NOT",
      cachedRAWDecode(from: filter, exposure: 0, kelvin: 6500, tint: 10) !== first)
_ = cachedRAWDecode(from: filter, exposure: 0, kelvin: 5000, tint: 10)
check("a different Tint does NOT",
      cachedRAWDecode(from: filter, exposure: 0, kelvin: 5000, tint: -20) !== first)

let other = previewFilter()
check("another photo's filter does NOT get this photo's decode",
      cachedRAWDecode(from: other, exposure: 0, kelvin: 5000, tint: 10) !== first)

releaseCachedRAWDecode()
check("releasing it drops the held image", rawDecodeImage == nil && rawDecodeFilter == nil)

print("\n3. speed")
func timed(_ block: () -> Void) -> Double {
    for _ in 0..<2 { block() }
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<8 { block() }
    return (CFAbsoluteTimeGetCurrent() - start) / 8
}
let before = timed { _ = context.createCGImage(grade(filter.outputImage!), from: filter.outputImage!.extent,
                                               format: .RGBA8, colorSpace: space, deferred: false) }
let after = timed {
    let base = cachedRAWDecode(from: filter, exposure: 0, kelvin: 5000, tint: 10)
    _ = context.createCGImage(grade(base), from: base.extent, format: .RGBA8, colorSpace: space, deferred: false)
}
print(String(format: "        decoding every frame  %6.1f ms  → %4.1f fps", before * 1000, 1 / before))
print(String(format: "        holding the decode    %6.1f ms  → %4.1f fps", after * 1000, 1 / after))
check("a frame is at least twice as cheap", after * 2 < before,
      String(format: "%.1f ms vs %.1f ms", after * 1000, before * 1000))

print("")
if failures == 0 { print("all checks passed") } else { print("\(failures) FAILED"); exit(1) }
