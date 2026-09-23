// Is Clarity the same picture whether the whole frame or only a part of it is
// rendered — and after the graph has been moved?
//
// Found 23.09: the live People layer (ImageLayer.liveSource) crops and
// translates the edited photo's graph, and with Clarity on, the person came out
// looking like a negative. Clarity's base is CIEdgePreserveUpsampleFilter; the
// suspicion is that it maps its small image by the extents it SEES at render
// time, so anything that renders a sub-rectangle or moves the graph afterwards
// — the live layer, a crop, a turned crop — gets a different base.
//
//     clarity-roi <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("clarity-roi <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1200) : 1200
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size))!
var s = PhotoEditSettings()
s.clarity = 0.4
let whole = PhotoEditRenderer.render(s, on: base, applyCrop: false)
let e = whole.extent
let part = CGRect(x: e.minX + e.width * 0.3, y: e.minY + e.height * 0.25,
                  width: e.width * 0.4, height: e.height * 0.5).integral

func bitmap(_ image: CIImage, _ rect: CGRect) -> [UInt8] {
    let w = Int(rect.width), h = Int(rect.height)
    var b = [UInt8](repeating: 0, count: w * h * 4)
    ctx.render(image, toBitmap: &b, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: srgb)
    return b
}
func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var sum = 0.0
    for i in stride(from: 0, to: a.count, by: 4) { for c in 0..<3 { sum += abs(Double(a[i+c]) - Double(b[i+c])) } }
    return sum / Double(a.count / 4 * 3)
}

// Reference: the whole frame rendered, then the part read out of the pixels.
let full = bitmap(whole, e)
var ref = [UInt8](repeating: 0, count: Int(part.width) * Int(part.height) * 4)
let fw = Int(e.width), fh = Int(e.height)
for y in 0..<Int(part.height) {
    for x in 0..<Int(part.width) {
        // CI rows are bottom-up in bounds; toBitmap writes top row first.
        let sx = Int(part.minX - e.minX) + x
        let sy = (fh - Int(part.maxY - e.minY)) + y
        for c in 0..<4 { ref[(y * Int(part.width) + x) * 4 + c] = full[(sy * fw + sx) * 4 + c] }
    }
}

let roi = diff(bitmap(whole, part), ref)
let moved = whole.cropped(to: part).transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY))
let translated = diff(bitmap(moved, CGRect(origin: .zero, size: part.size)), ref)
let fixed = whole.insertingIntermediate(cache: false).cropped(to: part)
    .transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY))
let translatedFixed = diff(bitmap(fixed, CGRect(origin: .zero, size: part.size)), ref)

print("mean difference from the whole-frame render, levels of 255:")
print(String(format: "  only the part rendered            %6.2f", roi))
print(String(format: "  part moved to the origin          %6.2f", translated))
print(String(format: "  moved, after insertingIntermediate %5.2f", translatedFixed))

// Scaled by almost nothing — what the live layer does to fit its stored grid —
// and then scaled back so the numbers compare.
for factor in [1.0005, 0.5] {
    let scaled = whole.cropped(to: part)
        .transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY))
        .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        .transformed(by: CGAffineTransform(scaleX: 1 / factor, y: 1 / factor))
    let viaIntermediate = whole.insertingIntermediate(cache: false).cropped(to: part)
        .transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY))
        .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        .insertingIntermediate(cache: false)
        .transformed(by: CGAffineTransform(scaleX: 1 / factor, y: 1 / factor))
    let r = CGRect(origin: .zero, size: part.size)
    print(String(format: "  scaled ×%.4f and back              %6.2f   with intermediate %6.2f",
                 factor, diff(bitmap(scaled, r), ref), diff(bitmap(viaIntermediate, r), ref)))
}
