// How much light is there ABOVE white when Highlights gets the picture, and how
// much of the blown area is one channel rather than all three?
//
// ⚠️ THIS MEASUREMENT DECIDES THE DESIGN, which is why it is a program and not
// a paragraph. The client's specification for Highlights (13.09) asks for two
// different things at once:
//
//   * a targeted mask, a soft knee and desaturation at the extreme — all of
//     which are a function of the pixel, so a CIColorCube can do them;
//   * *„Ako je bar jedan RGB kanal pregoreo (>1.0), iskoristi informacije iz
//     ne-pregorelih kanala"* — recovery from light that is past white.
//
// A colour cube CANNOT do the second one: its axes are [0, 1] and it CLAMPS
// above that. Measured directly with an identity cube whose top entry was
// pulled to 0.5 — inputs of 1.0, 1.1, 1.5 and 2.0 all came out at 0.502, i.e.
// they all landed on the same top entry.
//
// So the question this answers is how much is actually lost by that clamp:
//
//   above white     pixels with any channel > 1 — what the clamp cannot see
//   headroom        how far past white the brightest of them goes
//   one channel     pixels where ONE channel is at white and another is well
//                   under it — the case the cube CAN reconstruct, because both
//                   numbers are inside its axes
//
//     highlights-headroom <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("highlights-headroom <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1200) : 1200

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else {
    print("could not open \(url.path)"); exit(1)
}

// Neutral settings: every control is at home, so what comes out is the picture
// as it stands when the tone curve — and therefore Highlights — gets it.
let image = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
let w = Int(image.extent.width), h = Int(image.extent.height)
var buffer = [Float](repeating: 0, count: w * h * 4)
buffer.withUnsafeMutableBytes { raw in
    // RGBAf, not RGBA8: the whole question is what sits above 1.0, and an
    // 8-bit buffer has already thrown that away.
    ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16,
               bounds: image.extent, format: .RGBAf, colorSpace: srgb)
}

var aboveWhite = 0
var peak: Float = 0
var oneChannelBlown = 0
var allThreeBlown = 0
var nearWhite = 0
let total = w * h

for i in stride(from: 0, to: buffer.count, by: 4) {
    let r = buffer[i], g = buffer[i + 1], b = buffer[i + 2]
    let high = max(r, max(g, b))
    let low = min(r, min(g, b))
    peak = max(peak, high)
    if high > 1.0 { aboveWhite += 1 }
    if high >= 0.99 {
        nearWhite += 1
        if low < 0.90 { oneChannelBlown += 1 } else { allThreeBlown += 1 }
    }
}

func percent(_ n: Int) -> Double { Double(n) / Double(total) * 100 }

// ⚠️ THE QUESTION THE COLUMNS ABOVE DO NOT ANSWER, and it is the one that says
// whether recovery is possible at all: inside the region that renders as FLAT
// WHITE — every channel at or past 1.0, which is what the client sees as a
// blown sky — is there any variation left in the float data, or is it one value?
//
// A pre-scale can only bring back a range that exists. If the decoder has
// already flattened these pixels to exactly 1.0, no arithmetic downstream can
// unflatten them, and Highlights can only dim them.
var flatWhiteLumas: [Double] = []
for i in stride(from: 0, to: buffer.count, by: 4) {
    let r = Double(buffer[i]), g = Double(buffer[i + 1]), b = Double(buffer[i + 2])
    if min(r, min(g, b)) >= 1.0 {
        flatWhiteLumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
    }
}

print("photo: \(url.lastPathComponent)   \(w)x\(h)\n")
print(String(format: "above white (any channel > 1)   %6.2f%%   — invisible to a colour cube", percent(aboveWhite)))
print(String(format: "headroom (brightest channel)    %6.3f", peak))
print(String(format: "at white (any channel >= 0.99)  %6.2f%%", percent(nearWhite)))
print(String(format: "  of those, ONE channel blown   %6.2f%%   — the cube CAN reconstruct these", percent(oneChannelBlown)))
print(String(format: "  of those, all three blown     %6.2f%%   — no colour left to reconstruct from", percent(allThreeBlown)))
print()
if flatWhiteLumas.isEmpty {
    print("flat white (every channel >= 1)  none")
} else {
    let mean = flatWhiteLumas.reduce(0, +) / Double(flatWhiteLumas.count)
    let spread = (flatWhiteLumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                  / Double(flatWhiteLumas.count)).squareRoot()
    print(String(format: "flat white (every channel >= 1)  %6.2f%% of the frame", percent(flatWhiteLumas.count)))
    print(String(format: "  its luminance, min … max       %.4f … %.4f", flatWhiteLumas.min()!, flatWhiteLumas.max()!))
    print(String(format: "  its spread                     %.5f   — what recovery has to work with", spread))
}

print()
print("The first line is what the cube's clamp costs. The last is whether there")
print("is anything left in the blown area to bring back at all.")
