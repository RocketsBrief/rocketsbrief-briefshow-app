// Harness for the fast first pass — the camera's own preview, shown while the
// real thumbnail is still being made.
//
// ⚠️ `makePlaceholderThumbnail` is EXTRACTED FROM Develop.swift at build time
// by run-placeholder-thumbnail-test.py. The three things it asks before it
// hands anything back are stubbed here as switches, so the truth table below
// drives the REAL function, not a copy of it.
//
// What it has to prove, in this order of importance:
//   1. it refuses every case where the fast picture would be WRONG rather than
//      merely different in tone — a JPEG, a flattened photo, an edited photo,
//   2. it hands back a picture for a plain RAW, and quickly,
//   3. that picture is NOT the real one — which is the whole reason it may
//      only ever be a stand-in, and the number nobody should forget.

import Foundation
import CoreImage
import AppKit
import ImageIO

// The three guards, as switches. Each stands for the real thing named in
// makePlaceholderThumbnail; the source test checks that it still calls them.
var stubIsRAW = true
var stubIsFlattened = false
var stubHasEdits = false

enum PhotoEditRenderer {
    static func isRAW(_ url: URL) -> Bool { stubIsRAW }
}
enum FlattenedImageStore {
    // Equal to the photo means "not flattened" — the shape the real guard uses.
    static func sourceURL(for url: URL) -> URL {
        stubIsFlattened ? url.appendingPathExtension("baked") : url
    }
}
enum PhotoEditStore {
    static func hasEdits(_ url: URL) -> Bool { stubHasEdits }
}

// __EXTRACTED__

var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("  ok    \(label)") }
    else { failures += 1; print("  FAIL  \(label) \(detail)") }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: placeholder-thumbnail <a .NEF>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let side: CGFloat = 384

func reset() {
    stubIsRAW = true
    stubIsFlattened = false
    stubHasEdits = false
}

print("when it must REFUSE — a wrong tone is a stand-in, a wrong photograph is a bug")

reset(); stubIsRAW = false
check("not a RAW → nil (no embedded preview to be cheap about)",
      makePlaceholderThumbnail(from: url, maxPixelSize: side) == nil)

reset(); stubIsFlattened = true
check("flattened → nil (the camera's preview predates what was baked in)",
      makePlaceholderThumbnail(from: url, maxPixelSize: side) == nil)

reset(); stubHasEdits = true
check("edited → nil (it knows nothing of the client's grade)",
      makePlaceholderThumbnail(from: url, maxPixelSize: side) == nil)

print("\nwhen it must ANSWER")

reset()
guard let placeholder = makePlaceholderThumbnail(from: url, maxPixelSize: side) else {
    print("  FAIL  a plain RAW got no placeholder")
    exit(1)
}
check("a plain RAW gets one", true)
check("it fits inside what was asked for",
      max(placeholder.size.width, placeholder.size.height) <= side,
      "\(placeholder.size)")

// Speed. Loose on purpose — the point is the ORDER of magnitude, not a number
// that fails on a warm laptop. Measured 8.9 ms against 65 ms four wide.
let start = DispatchTime.now()
for _ in 0..<5 { _ = makePlaceholderThumbnail(from: url, maxPixelSize: side) }
let each = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 5_000_000
check(String(format: "it is fast (%.1f ms, must stay under 40)", each), each < 40)

print("\nand why it is ONLY ever a stand-in")

// The real decode, the one the strip ends up showing.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
                                  .cacheIntermediates: false])
func realDecode() -> CGImage? {
    guard let filter = CIRAWFilter(imageURL: url) else { return nil }
    filter.isDraftModeEnabled = true
    if let full = filter.outputImage?.extent, full.width >= 1 {
        let longest = max(full.width, full.height)
        if longest > side { filter.scaleFactor = Float(side / longest) }
    }
    guard let out = filter.outputImage, out.extent.width >= 1 else { return nil }
    return context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: space)
}

func bytes(_ image: CGImage) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    buffer.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return buffer
}

var cgPlaceholder: CGImage?
var proposed = NSRect(x: 0, y: 0, width: placeholder.size.width, height: placeholder.size.height)
cgPlaceholder = placeholder.cgImage(forProposedRect: &proposed, context: nil, hints: nil)

if let real = realDecode(), let fast = cgPlaceholder,
   real.width == fast.width, real.height == fast.height {
    let a = bytes(real), b = bytes(fast)
    var square = 0.0
    for index in 0..<a.count {
        let delta = Double(a[index]) - Double(b[index])
        square += delta * delta
    }
    let rms = (square / Double(a.count)).squareRoot()
    // ⚠️ This is NOT a failure — it is the measurement that explains the whole
    // design. If it ever came out at zero the two paths would have become the
    // same picture, and THAT would be worth knowing too.
    print(String(format: "  note  RMS against the real decode: %.2f  (measured 10.6–19.2 across the client's seven)", rms))
    check("it really is a different picture, so it may not be kept", rms > 1,
          String(format: "RMS %.2f", rms))
} else {
    print("  note  could not compare sizes; skipped the difference measurement")
}

print(failures == 0 ? "\nall good" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
