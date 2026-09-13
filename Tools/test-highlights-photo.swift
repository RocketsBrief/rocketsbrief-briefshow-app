// Does a blown area actually come BACK, or does it only get darker?
//
// ⚠️ THE SPREAD COLUMN IS THE WHOLE TEST. Any control that pulls the top of the
// range down will lower the count of pixels at 255, and that number on its own
// proves nothing: a picture dimmed is not a picture recovered. Recovery means
// the pixels that were ONE FLAT VALUE stop being one flat value — so the
// standard deviation INSIDE the region that was blown in the untouched render
// is what says whether there is detail there now.
//
// The region is chosen once, on the neutral render, and the same pixels are
// followed down the ramp — otherwise "the blown region" shrinks as the slider
// moves and the column measures a different place each row.
//
//     highlights-photo <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("highlights-photo <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1200) : 1200

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

func pixels(_ settings: PhotoEditSettings) -> [UInt8]? {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else { return nil }
    let image = PhotoEditRenderer.render(settings, on: base)
    let w = Int(image.extent.width), h = Int(image.extent.height)
    guard w > 0, h > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                   bounds: image.extent, format: .RGBA8, colorSpace: srgb)
    }
    return buffer
}

guard let neutral = pixels(PhotoEditSettings()) else {
    print("could not open \(url.path)"); exit(1)
}

// ⚠️ WHAT THE BLOWN AREA ACTUALLY IS, MEASURED BEFORE ANYTHING IS CLAIMED ABOUT
// IT — and the first two versions of this harness both got it wrong.
//
// Asked of the float render (Tools/run-highlights-headroom.py, the flat-white
// line): on the client's frames there is NOT ONE PIXEL with all three channels
// at or past 1.0. What is past white is always one channel, or two, while the
// others are under — 1.21% of `C4S_7891.NEF` and 12.26% of `C4S_5741.NEF`.
//
// That decides what recovery can mean here. A sky that renders as flat 255 is
// not a range of tones squashed against the ceiling — there is no range up
// there to unsquash. It is a set of COLOURS whose brightest channel has run past
// white, and pulling the lightness down brings that colour back. So the column
// that matters is the spread BETWEEN the channels of those pixels, not the
// spread of their luminance: luminance has nothing left to say, and colour has.
guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else {
    print("could not open \(url.path)"); exit(1)
}
let neutralImage = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
let fw = Int(neutralImage.extent.width), fh = Int(neutralImage.extent.height)
var floats = [Float](repeating: 0, count: fw * fh * 4)
floats.withUnsafeMutableBytes { raw in
    ctx.render(neutralImage, toBitmap: raw.baseAddress!, rowBytes: fw * 16,
               bounds: neutralImage.extent, format: .RGBAf, colorSpace: srgb)
}

// The pixels recovery is about: at least one channel past white, at least one
// still holding a value. These are the ones the OKLab path can bring back.
var recoverable: [Int] = []
// And the ones well below the knee, which must not move at all.
var darkIndices: [Int] = []
for i in stride(from: 0, to: neutral.count, by: 4) {
    let r = floats[i], g = floats[i + 1], b = floats[i + 2]
    if max(r, max(g, b)) > 1.0 { recoverable.append(i) }
    if max(Int(neutral[i]), max(Int(neutral[i + 1]), Int(neutral[i + 2]))) <= 100 {
        darkIndices.append(i)
    }
}

/// Rec. 709 luminance, the weights Core Image's own luma filters use.
func luma(_ buffer: [UInt8], _ i: Int) -> Double {
    0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])
}

func meanLuma(_ buffer: [UInt8], over indices: [Int]) -> Double {
    guard !indices.isEmpty else { return 0 }
    return indices.reduce(0.0) { $0 + luma(buffer, $1) } / Double(indices.count)
}

/// How much the tones that were PAST WHITE still differ from each other.
///
/// ⚠️ THIS IS THE COLUMN, and the two metrics tried before it were both wrong in
/// the same instructive way. `max - min` across a pixel's channels REWARDS
/// CLIPPING: a channel pinned at 255 sits further from its neighbours than the
/// same channel brought honestly back to 250, so the path that loses the most
/// information scores the highest. Luminance spread said nothing at all, because
/// not one pixel on these frames has all three channels past white.
///
/// What actually separates the two paths is this: CIToneCurve and a colour cube
/// both CLAMP their input at 1.0 — probed directly — so to the old path a
/// channel at 1.000 and one at 1.074 were the same number and came out as the
/// same number. The pre-scale is what gives them rows of their own. So the
/// measurement is the standard deviation of the OUTPUT brightest channel across
/// the pixels whose input brightest channel was above white. Near zero means
/// they were all flattened onto one value; anything above that is a difference
/// that survived.
func survivingVariation(_ buffer: [UInt8], over indices: [Int]) -> Double {
    guard !indices.isEmpty else { return 0 }
    var values: [Double] = []
    values.reserveCapacity(indices.count)
    for i in indices {
        values.append(Double(max(buffer[i], max(buffer[i + 1], buffer[i + 2]))))
    }
    let mean = values.reduce(0, +) / Double(values.count)
    return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
}

func clipped(_ buffer: [UInt8]) -> Double {
    var count = 0.0, total = 0.0
    for i in stride(from: 0, to: buffer.count, by: 4) {
        for c in 0..<3 {
            if buffer[i + c] == 255 { count += 1 }
            total += 1
        }
    }
    return count / total * 100
}

// The path this replaced, so the two can be read side by side.
//
// ⚠️ This is the OLD Highlights exactly, not an approximation: the row it had in
// the shared five-knot curve — weights [0, 0, 0.10, 1.00, 0.30], scaled by
// `highlightControlScale` and `toneControlStrength` — applied to the neutral
// render through the same CIToneCurve it always used. Everything `render` does
// after the tone curve is the identity at default settings, so this IS what the
// old pipeline produced when the only slider moved was this one.
func oldPixels(_ highlights: Double) -> [UInt8]? {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else { return nil }
    var image = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
    if highlights != 0 {
        let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]
        let weights: [Double] = [0.00, 0.00, 0.10, 1.00, 0.30]
        let amount = highlights * PhotoEditRenderer.highlightControlScale
        var ys = xs
        for knot in 0..<5 {
            ys[knot] = xs[knot] + amount * weights[knot] * PhotoEditRenderer.toneControlStrength
        }
        ys[0] = max(ys[0], 0)
        for knot in 1..<5 {
            let floorValue = ys[knot - 1] + PhotoEditRenderer.toneMinimumSlope * (xs[knot] - xs[knot - 1])
            ys[knot] = max(ys[knot], floorValue)
        }
        let points = (0..<5).map { CGPoint(x: xs[$0], y: ys[$0]) }
        image = PhotoEditRenderer.applyToneCurve(points, to: image)
    }
    let w = Int(image.extent.width), h = Int(image.extent.height)
    guard w > 0, h > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                   bounds: image.extent, format: .RGBA8, colorSpace: srgb)
    }
    return buffer
}

print("photo: \(url.lastPathComponent)")
let recoverableShare = Double(recoverable.count) / Double(fw * fh) * 100
print(String(format: "pixels with a channel past white: %d (%.2f%% of the frame)",
             recoverable.count, recoverableShare))
print(String(format: "dark pixels watched: %d\n", darkIndices.count))
print("Highlights   at 255    their mean   SURVIVING    dark mean")
print(String(repeating: "-", count: 60))

var spreadAtNeutral = 0.0
var bestSpread = 0.0
var darkAtNeutral = 0.0
var worstDarkDrift = 0.0

for h in [0.0, -0.25, -0.50, -0.75, -1.0, 0.5, 1.0] {
    var settings = PhotoEditSettings()
    settings.highlights = h
    guard let buffer = pixels(settings) else { continue }
    let mean = meanLuma(buffer, over: recoverable)
    let spread = survivingVariation(buffer, over: recoverable)
    let dark = meanLuma(buffer, over: darkIndices)
    print(String(format: "%-12@ %8.2f%% %12.1f %13.2f %11.1f",
                 String(format: "%+.2f  now", h) as NSString,
                 clipped(buffer), mean, spread, dark))
    if let was = oldPixels(h) {
        print(String(format: "%-12@ %8.2f%% %12.1f %13.2f %11.1f",
                     "      before" as NSString, clipped(was),
                     meanLuma(was, over: recoverable),
                     survivingVariation(was, over: recoverable),
                     meanLuma(was, over: darkIndices)))
    }
    if h == 0 {
        spreadAtNeutral = spread
        darkAtNeutral = dark
    } else {
        if h < 0 { bestSpread = max(bestSpread, spread) }
        worstDarkDrift = max(worstDarkDrift, abs(dark - darkAtNeutral))
    }
}

print()
print(String(format: "variation among the above-white tones: %.2f levels at rest, %.2f at best pull",
             spreadAtNeutral, bestSpread))
print(String(format: "shadows drifted by at most %.2f of a level", worstDarkDrift))
print()

var failed = false

// ⚠️ RECOVERY NEEDS SOMETHING TO RECOVER FROM. `C4S_8932.NEF` has 0.04% of
// itself past white and a brightest channel of 1.011 — pulling that down can
// only dim it, and a test that called that a failure would be reporting physics
// as a defect. Half a percent of the frame separates "nothing there" from "the
// thing the client is pointing at": the fifteen RAWs on this machine run from
// 0.04% to 30.6%.
if recoverableShare < 0.5 {
    print(String(format: "Only %.2f%% of this frame has a channel past white — too little to test recovery on.",
                 recoverableShare))
    print("The ramp above still stands, and the shadow column below still applies.")
} else if bestSpread <= spreadAtNeutral {
    print("FAIL: the tones that were past white all came out the same — they were flattened, not recovered.")
    failed = true
}

// ⚠️ The spec says below middle grey is untouched. A cube cannot be EXACTLY
// untouched — it quantises, and the pre-scale means even a tone the curve
// leaves alone goes through the table — so what is checked is that the drift is
// under a level, which is below what 8 bits can show.
if worstDarkDrift > 1.0 {
    print("FAIL: the shadows moved — Highlights must not reach below the knee.")
    failed = true
}
if !failed {
    print(recoverableShare < 0.5
          ? "The shadows stayed where they were."
          : "The tones that were past white stay apart, and the shadows stay where they were.")
}
exit(failed ? 1 : 0)
