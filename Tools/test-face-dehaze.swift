// Face Dehaze: does it take the veil off the face, and ONLY off the face?
//
//     face-dehaze <photo> [size] [out-dir]
//
// Renders the photo at 0 and at 50 / 100 Face Dehaze and measures, inside the
// faces Vision finds: the floor (2nd percentile of luma) — the veil lifts it,
// taking the veil off brings it down — and the spread (std of luma). Outside
// every face ellipse the picture must not move at all. Then the same number on
// a full-frame layer must give the same pixels as on the photo (THE MUST).
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("face-dehaze <photo> [size] [out]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1600) : 1600
let outDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else {
    print("could not load"); exit(1)
}
func render(_ amount: Double) -> CIImage {
    var s = PhotoEditSettings(); s.faceDehaze = amount
    return PhotoEditRenderer.render(s, on: base, applyCrop: false)
}
let plain = render(0)
let extent = plain.extent.integral
let w = Int(extent.width), h = Int(extent.height)
func pixels(_ i: CIImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes { ctx.render(i, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: srgb) }
    return out
}
var t0 = Date()
let faces = FaceDehazeFaces.faces(in: plain)
print(String(format: "faces: %d  (detect %.0f ms)", faces.count, Date().timeIntervalSince(t0) * 1000))
guard !faces.isEmpty else { print("nobody in \(url.lastPathComponent)"); exit(1) }
// The faces are looked up on every render; a slider step must not run Vision again.
for (label, tweak) in [("Exposure +0.3", { (s: inout PhotoEditSettings) in s.exposure = 0.3 }),
                       ("Contrast +0.4", { (s: inout PhotoEditSettings) in s.contrast = 0.4 }),
                       ("Dehaze +0.3", { (s: inout PhotoEditSettings) in s.dehaze = 0.3 })] {
    var s = PhotoEditSettings(); tweak(&s)
    let image = PhotoEditRenderer.render(s, on: base, applyCrop: false)
    t0 = Date(); let again = FaceDehazeFaces.faces(in: image)
    print(String(format: "after %@: %d face(s) in %.0f ms, Vision runs so far: %d", label as NSString, again.count,
                 Date().timeIntervalSince(t0) * 1000, FaceDehazeFaces.detectionCount))
}

// Face boxes in bitmap rows (top-down) and a generous outside test.
let boxes = faces.map { CGRect(x: $0.minX * Double(w), y: (1 - $0.maxY) * Double(h), width: $0.width * Double(w), height: $0.height * Double(h)) }
func inFace(_ x: Int, _ y: Int) -> Bool { boxes.contains { $0.insetBy(dx: $0.width * 0.15, dy: $0.height * 0.15).contains(CGPoint(x: x, y: y)) } }
func farFromFace(_ x: Int, _ y: Int) -> Bool { !boxes.contains { $0.insetBy(dx: -$0.width * 1.6, dy: -$0.height * 1.9).contains(CGPoint(x: x, y: y)) } }
func luma(_ p: [UInt8], _ i: Int) -> Double { 0.2126 * Double(p[i*4]) + 0.7152 * Double(p[i*4+1]) + 0.0722 * Double(p[i*4+2]) }

let before = pixels(plain)
var failures = 0
for amount in [0.5, 1.0] {
    t0 = Date()
    let edited = render(amount)
    let after = pixels(edited)
    let ms = Date().timeIntervalSince(t0) * 1000
    var a: [Double] = [], b: [Double] = [], outsideMoved = 0.0, outsideCount = 0
    for y in 0..<h { for x in 0..<w {
        let i = y * w + x
        if inFace(x, y) { a.append(luma(before, i)); b.append(luma(after, i)) }
        else if farFromFace(x, y) { outsideMoved = max(outsideMoved, abs(luma(before, i) - luma(after, i))); outsideCount += 1 }
    }}
    func floor(_ v: [Double]) -> Double { v.sorted()[v.count / 50] }
    func spread(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(v.count); return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)) }
    print(String(format: "Face Dehaze %3.0f: face floor %5.1f -> %5.1f   face spread %5.1f -> %5.1f   far outside moved max %.1f   (%.0f ms)",
                 amount * 100, floor(a), floor(b), spread(a), spread(b), outsideMoved, ms))
    if !(floor(b) < floor(a) && spread(b) > spread(a)) { print("  FAIL the face did not clear"); failures += 1 }
    if outsideMoved > 1 { print("  FAIL something far from every face moved"); failures += 1 }
    if let outDir, let cg = ctx.createCGImage(edited, from: extent) {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: outDir.appendingPathComponent("face-dehaze-\(Int(amount * 100)).png"))
    }
}
if let outDir, let cg = ctx.createCGImage(plain, from: extent) {
    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
        .write(to: outDir.appendingPathComponent("face-dehaze-0.png"))
}

// THE MUST is measured by Tools/run-layer-edit-parity-test.py, which has Face Dehaze in its list.
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) failed")
exit(failures == 0 ? 0 : 1)
