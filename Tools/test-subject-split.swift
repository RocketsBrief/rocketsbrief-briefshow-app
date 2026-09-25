// Background Exposure / Subjects Exposure / Background Dehaze (25.09): does each
// one move ONLY its own half of the photo?
//
//     subject-split <photo> [size] [out-dir]
//
// The person mask is read once, the same way the renderer reads it. Pixels well
// inside it (mask > 0.95) are "subjects", pixels well outside (< 0.05) are
// "background". A background slider must leave the subjects where they were
// (≤ 1 level) and move the background; a subjects slider the other way round.
// Vision must run once for the whole set of renders, not once per slider move.
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("subject-split <photo> [size] [out]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1600) : 1600
let outDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else {
    print("could not load"); exit(1)
}
let plain = PhotoEditRenderer.render(PhotoEditSettings(), on: base, applyCrop: false)
let extent = plain.extent.integral
let w = Int(extent.width), h = Int(extent.height)
func pixels(_ i: CIImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes { ctx.render(i, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: srgb) }
    return out
}
func luma(_ p: [UInt8], _ i: Int) -> Double { 0.2126 * Double(p[i*4]) + 0.7152 * Double(p[i*4+1]) + 0.0722 * Double(p[i*4+2]) }

guard let mask = SubjectMasker.personMask(for: plain, maxWorkingEdge: SubjectSplit.detectionSide) else {
    print("nobody in \(url.lastPathComponent)"); exit(1)
}
// The edge band is left out of both halves: the renderer softens the mask
// there on purpose (SubjectSplit.featherShare), so a pixel a few px from the
// outline is SUPPOSED to take part of both. Three feather widths either side.
let band = Double(max(extent.width, extent.height) * SubjectSplit.featherShare * 3)
let core = mask.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": band]).cropped(to: extent)
let outside = mask.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": band]).cropped(to: extent)
let corePixels = pixels(core), outsidePixels = pixels(outside)
var people: [Int] = [], behind: [Int] = []
for i in 0..<(w * h) {
    if Double(corePixels[i * 4]) / 255 > 0.95 { people.append(i) }
    else if Double(outsidePixels[i * 4]) / 255 < 0.05 { behind.append(i) }
}
print("people \(people.count) px, background \(behind.count) px of \(w * h)")

let before = pixels(plain)
func mean(_ p: [UInt8], _ idx: [Int]) -> Double { idx.reduce(0.0) { $0 + luma(p, $1) } / Double(max(idx.count, 1)) }
func maxMove(_ a: [UInt8], _ b: [UInt8], _ idx: [Int]) -> Double { idx.reduce(0.0) { max($0, abs(luma(a, $1) - luma(b, $1))) } }

var failures = 0
let cases: [(String, (inout PhotoEditSettings) -> Void, Bool)] = [
    ("Background Exposure +0.5", { $0.backgroundExposure = 0.5 }, true),
    ("Background Exposure -0.5", { $0.backgroundExposure = -0.5 }, true),
    ("Subjects Exposure +0.5", { $0.subjectsExposure = 0.5 }, false),
    ("Background Dehaze +0.6", { $0.backgroundDehaze = 0.6 }, true),
]
for (label, tweak, movesBackground) in cases {
    var s = PhotoEditSettings(); tweak(&s)
    let t0 = Date()
    let edited = PhotoEditRenderer.render(s, on: base, applyCrop: false)
    let after = pixels(edited)
    let ms = Date().timeIntervalSince(t0) * 1000
    let moved = movesBackground ? behind : people
    let still = movesBackground ? people : behind
    let shift = mean(after, moved) - mean(before, moved)
    let leak = maxMove(before, after, still)
    print(String(format: "%@: its half moved %+.1f levels (mean), the other half at most %.1f   (%.0f ms, Vision runs %d)",
                 label as NSString, shift, leak, ms, SubjectSplit.detectionCount))
    if abs(shift) < 2 { print("  FAIL its own half hardly moved"); failures += 1 }
    // One 8-bit step on all three channels is 1.0 of luma — rounding, not a move.
    if leak > 1.5 { print("  FAIL the other half moved"); failures += 1 }
    if let outDir, let cg = ctx.createCGImage(edited, from: extent) {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: outDir.appendingPathComponent("split-\(label.replacingOccurrences(of: " ", with: "_")).png"))
    }
}
if SubjectSplit.detectionCount != 1 {
    print("  FAIL Vision ran \(SubjectSplit.detectionCount) times, not once"); failures += 1
}
// Negative control: all three at zero must be the plain photo, to the pixel.
let zero = pixels(PhotoEditRenderer.render(PhotoEditSettings(), on: base, applyCrop: false))
let drift = maxMove(before, zero, Array(0..<(w * h)))
print(String(format: "all three at 0: max difference from the plain photo %.1f", drift))
if drift > 0 { print("  FAIL zero is not neutral"); failures += 1 }
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) failed")
exit(failures == 0 ? 0 : 1)
