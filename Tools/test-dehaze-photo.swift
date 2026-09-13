// Dehaze on a real photograph, with the OLD path computed alongside.
//
// ⚠️ THERE IS NO GROUND TRUTH HERE — that is what the synthetic half is for
// (Tools/test-dehaze-model.swift, where the haze was put on by the model and the
// clean scene is known). What a real frame can say is different and still worth
// asking: what the algorithm thinks the light in the air is, whether the
// correction is actually SELECTIVE — hazy parts moved, clear parts left — and
// whether pulling hard breaks anything.
//
//     dehaze-photo <photo> [size]
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("dehaze-photo <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1400) : 1400

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else {
    print("could not open \(url.path)"); exit(1)
}
let neutralImage = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
let extent = neutralImage.extent
let w = Int(extent.width), h = Int(extent.height)
guard w > 1, h > 1 else { print("empty render"); exit(1) }

func pixels(_ image: CIImage) -> [Float] {
    var buffer = [Float](repeating: 0, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        ctx.render(image.cropped(to: extent), toBitmap: raw.baseAddress!, rowBytes: w * 16,
                   bounds: extent, format: .RGBAf, colorSpace: srgb)
    }
    return buffer
}
func photo(_ amount: Double) -> [Float] {
    var settings = PhotoEditSettings()
    settings.dehaze = amount
    return pixels(PhotoEditRenderer.render(settings, on: base))
}
func oldDehaze(_ amount: Double) -> [Float] {
    let d = Float(min(max(amount, -1), 1))
    let colour = CIFilter.colorControls()
    colour.inputImage = neutralImage
    colour.contrast = 1 + d * 0.35
    colour.saturation = 1 + d * 0.25
    colour.brightness = 0
    let curve = CIFilter.toneCurve()
    curve.inputImage = colour.outputImage ?? neutralImage
    curve.point0 = CGPoint(x: 0, y: CGFloat(-0.08 * d))
    curve.point1 = CGPoint(x: 0.25, y: CGFloat(0.25 - 0.05 * d))
    curve.point2 = CGPoint(x: 0.5, y: 0.5)
    curve.point3 = CGPoint(x: 0.75, y: 0.75)
    curve.point4 = CGPoint(x: 1, y: 1)
    return pixels((curve.outputImage ?? neutralImage).cropped(to: extent))
}

let neutral = pixels(neutralImage)

print("photo: \(url.lastPathComponent)  (\(w)x\(h))")
if let air = PhotoEditRenderer.atmosphericLight(of: neutralImage) {
    print(String(format: "the light in the air, as the algorithm reads it: (%.3f, %.3f, %.3f) — %.0f, %.0f, %.0f levels",
                 air.r, air.g, air.b, air.r * 255, air.g * 255, air.b * 255))
}

/// Where the model says the haze is — its own refined transmission map.
///
/// ⚠️ BANDED BY THE MAP, NOT BY THE DARK CHANNEL, and the first version of this
/// harness got that wrong in a way worth keeping: it ranked pixels by their raw
/// minimum channel, called the darkest quarter "clearest", and then reported
/// that the clear quarter moved more than the hazy one. Those pixels are not
/// clear, they are DARK — and dark pixels sit furthest from A, so the recovery
/// moves them most for any given transmission. The question a real frame can
/// answer without a ground truth is whether the correction follows the map, so
/// the map is what the bands are cut from. Whether the map itself is right is
/// the synthetic half's job (Tools/test-dehaze-model.swift), where the haze was
/// put on by the model and the answer is known.
var haziness = [Double](repeating: 0, count: w * h)
if let air = PhotoEditRenderer.atmosphericLight(of: neutralImage),
   let map = PhotoEditRenderer.transmissionMap(of: neutralImage, atmosphere: air) {
    let mapped = pixels(map)
    for i in 0..<(w * h) { haziness[i] = 1 - Double(mapped[i * 4]) }
} else {
    print("no transmission map — nothing to band by"); exit(1)
}
let ranked = (0..<(w * h)).sorted { haziness[$0] > haziness[$1] }
let quarter = max(ranked.count / 4, 1)
let haziest = Array(ranked.prefix(quarter))
let clearest = Array(ranked.suffix(quarter))

let air = PhotoEditRenderer.atmosphericLight(of: neutralImage) ?? (r: 0.9, g: 0.9, b: 0.9)

/// How hard the model pulled, as a SHARE of how far the pixel was from the light
/// in the air.
///
/// ⚠️ THIS IS THE CORRECTION FOR THE BIAS THAT MADE THE FIRST TWO VERSIONS OF
/// THIS HARNESS WRONG. The model's whole statement is J − I = (I − A)·(1/t − 1):
/// what the transmission map decides is the FACTOR, and the levels that come out
/// of it are that factor times the pixel's distance from A. A dark pixel sits
/// furthest from A, so it moves the most levels at any transmission at all — and
/// a column of levels therefore ranks pixels by darkness no matter what the map
/// says. Dividing it back out asks the question the map actually answers.
func pulled(_ after: [Float], over indices: [Int]) -> Double {
    var sum = 0.0
    var count = 0.0
    for i in indices {
        let distance = abs(Double(neutral[i * 4]) - air.r)
            + abs(Double(neutral[i * 4 + 1]) - air.g)
            + abs(Double(neutral[i * 4 + 2]) - air.b)
        guard distance > 0.05 else { continue }
        let move = abs(Double(after[i * 4] - neutral[i * 4]))
            + abs(Double(after[i * 4 + 1] - neutral[i * 4 + 1]))
            + abs(Double(after[i * 4 + 2] - neutral[i * 4 + 2]))
        sum += move / distance
        count += 1
    }
    return count > 0 ? sum / count : 0
}
func contrast(_ buffer: [Float], over indices: [Int]) -> Double {
    let values = indices.map {
        0.2126 * Double(buffer[$0 * 4]) + 0.7152 * Double(buffer[$0 * 4 + 1]) + 0.0722 * Double(buffer[$0 * 4 + 2])
    }
    let mean = values.reduce(0, +) / Double(values.count)
    return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot() * 255
}
func clipped(_ buffer: [Float]) -> Double {
    var count = 0.0
    for i in stride(from: 0, to: buffer.count, by: 4)
    where buffer[i] <= 0.001 && buffer[i + 1] <= 0.001 && buffer[i + 2] <= 0.001 { count += 1 }
    return count / Double(w * h) * 100
}

print(String(format: "\nthe quarter of the frame the map calls haziest, against the quarter it calls clearest (%d pixels each)\n", quarter))
print("Dehaze          HAZIEST pulled   clearest pulled   contrast, haziest   black pixels")
print(String(repeating: "-", count: 78))
print(String(format: "%-15@ %14.3f %17.3f %19.2f %14.2f%%",
             " 0.00" as NSString, 0.0, 0.0, contrast(neutral, over: haziest), clipped(neutral)))

var failed = false
for amount in [0.5, 1.0, -0.5, -1.0] {
    let now = photo(amount)
    let before = oldDehaze(amount)
    print(String(format: "%-15@ %14.3f %17.3f %19.2f %14.2f%%",
                 String(format: "%+.2f  now", amount) as NSString,
                 pulled(now, over: haziest), pulled(now, over: clearest),
                 contrast(now, over: haziest), clipped(now)))
    print(String(format: "%-15@ %14.3f %17.3f %19.2f %14.2f%%",
                 "       before" as NSString,
                 pulled(before, over: haziest), pulled(before, over: clearest),
                 contrast(before, over: haziest), clipped(before)))

    // ⚠️ SELECTIVITY IS THE CLAIM, and it is the one thing a real frame can
    // check without a ground truth: the haziest quarter must move further than
    // the clearest one. The old path cannot do this at all — it has no map.
    if pulled(now, over: haziest) <= pulled(now, over: clearest) * 1.25 {
        print("       FAIL: the clear quarter was pulled as hard as the hazy one — the map is not doing anything.")
        failed = true
    }
    if amount > 0 && clipped(now) > clipped(neutral) + 2 {
        print("       FAIL: pulling the haze off crushed more than 2% of the frame onto black.")
        failed = true
    }
}

print()
if !failed {
    print("The haze came off where the haze was, and nothing collapsed onto black.")
}
exit(failed ? 1 : 0)
