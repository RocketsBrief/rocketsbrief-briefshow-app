// What Contrast does to a real photograph — the four things the spec asks for,
// measured on the shipping pipeline rather than argued about.
//
// The client's 12.09 specification for Contrast says a plain stretch is not
// acceptable: the ends must roll off instead of clipping, the pivot must hold,
// and colour must not go *„toxic"* when the slider is pushed. Three of those
// four are visible in a photograph, and this prints them:
//
//   at 255 / at 0   the ends. A stretch about mid grey drives both up fast;
//                   an S with a rolloff should barely move them.
//   spread          the CONTROL, and the column to read first. It is the
//                   standard deviation of the tones that were midtones in the
//                   untouched frame. Contrast must RAISE it — a curve that
//                   protects the ends by doing nothing at all would look
//                   perfect in the first two columns and be useless.
//   chroma          mean OKLab chroma over the most colourful tenth of the
//                   frame. Should climb gently. A stretch per channel makes
//                   this run away, which is what the client sees as skin
//                   going orange.
//
//     contrast-photo <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("contrast-photo <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 900) : 900

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

// The samples that were midtones BEFORE anything was done, followed through the
// ramp — so "spread" means "what happened to these", not "what is midtone now".
var midtoneIndices: [Int] = []
for i in stride(from: 0, to: neutral.count, by: 4) {
    for c in 0..<3 where neutral[i + c] > 80 && neutral[i + c] < 160 {
        midtoneIndices.append(i + c)
    }
}

// And the most colourful tenth of the frame, picked once, on the untouched
// picture, for the same reason.
func chroma(_ buffer: [UInt8], at i: Int) -> Double {
    let lab = OKLab.from(r: ExposureCube.toLinear(Double(buffer[i]) / 255),
                         g: ExposureCube.toLinear(Double(buffer[i + 1]) / 255),
                         b: ExposureCube.toLinear(Double(buffer[i + 2]) / 255))
    return hypot(lab.a, lab.b)
}

var colourful: [(index: Int, chroma: Double)] = []
for i in stride(from: 0, to: neutral.count, by: 4) {
    colourful.append((i, chroma(neutral, at: i)))
}
colourful.sort { $0.chroma > $1.chroma }
let colourfulIndices = colourful.prefix(max(colourful.count / 10, 1)).map(\.index)

struct Reading {
    var clipped = 0.0
    var crushed = 0.0
    var spread = 0.0
    var chroma = 0.0
}

func measure(_ buffer: [UInt8]) -> Reading {
    var reading = Reading()
    var counted = 0.0
    for i in stride(from: 0, to: buffer.count, by: 4) {
        for c in 0..<3 {
            if buffer[i + c] == 255 { reading.clipped += 1 }
            if buffer[i + c] == 0 { reading.crushed += 1 }
            counted += 1
        }
    }
    reading.clipped = reading.clipped / counted * 100
    reading.crushed = reading.crushed / counted * 100

    var sum = 0.0
    for index in midtoneIndices { sum += Double(buffer[index]) }
    let mean = midtoneIndices.isEmpty ? 0 : sum / Double(midtoneIndices.count)
    var variance = 0.0
    for index in midtoneIndices {
        let d = Double(buffer[index]) - mean
        variance += d * d
    }
    reading.spread = midtoneIndices.isEmpty ? 0 : (variance / Double(midtoneIndices.count)).squareRoot()

    var chromaSum = 0.0
    for index in colourfulIndices { chromaSum += chroma(buffer, at: index) }
    reading.chroma = colourfulIndices.isEmpty ? 0 : chromaSum / Double(colourfulIndices.count)
    return reading
}

// The curve this replaced, so the two can be read side by side.
//
// ⚠️ This is the OLD path exactly, not an approximation of it: the five-knot
// CIToneCurve it used, applied to the neutral render. Everything `render` does
// AFTER contrast — saturation, vibrance, the colour mixer, texture, clarity,
// sharpening, vignette — is the identity at default settings, so a neutral
// render with the old filter on top IS what the old pipeline produced when the
// only slider moved was this one.
func oldPixels(_ contrast: Double) -> [UInt8]? {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else { return nil }
    var image = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
    if contrast != 0 {
        let bend = contrast * PhotoEditRenderer.contrastMidtoneBend
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0, y: 0)
        filter.point1 = CGPoint(x: 0.25, y: min(max(0.25 - bend, 0), 1))
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: min(max(0.75 + bend, 0), 1))
        filter.point4 = CGPoint(x: 1, y: 1)
        image = filter.outputImage ?? image
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

print("photo: \(url.lastPathComponent)\n")
print("                 at 255        at 0      spread     chroma")
print(String(repeating: "-", count: 60))

var previousSpread = -1.0
var spreadAlwaysRose = true

func row(_ label: String, _ reading: Reading) {
    print(label.padding(toLength: 13, withPad: " ", startingAt: 0)
          + String(format: "%8.2f%% %9.2f%% %11.2f %10.4f",
                   reading.clipped, reading.crushed, reading.spread, reading.chroma))
}

for c in [0.0, 0.10, 0.25, 0.50, 0.75, 1.0, -0.05, -0.10, -0.25, -0.50, -1.0] {
    var settings = PhotoEditSettings()
    settings.contrast = c
    guard let buffer = pixels(settings) else { continue }
    let reading = measure(buffer)
    row(String(format: "%+.2f  now", c), reading)
    if let was = oldPixels(c) { row("      before", measure(was)) }
    if c >= 0 {
        if reading.spread < previousSpread - 1e-9 { spreadAlwaysRose = false }
        previousSpread = reading.spread
    }
}

print()
if spreadAlwaysRose {
    print("spread rises all the way up the ramp — the contrast is really there.")
    exit(0)
}
print("FAIL: spread did not rise — the ends may be protected, but by doing nothing.")
exit(1)
