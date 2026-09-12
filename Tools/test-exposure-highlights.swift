// What Exposure does to the HIGHLIGHTS — the client's complaint, measured.
//
// 12.09: *„jel lightroomov expose radi drugacije nego nas? nekako bude bas lepo
// o a ovde malo pomerim sve se zapali!"* — in Lightroom a nudge of Exposure
// looks good; here a nudge burns the picture out.
//
// Exposure here is a plain gain: the number goes into CIRAWFilter.exposure (or
// CIExposureAdjust) and every value is multiplied by 2^EV. A pixel already near
// white has nowhere to go, so it clips — and once clipped, the detail in it is
// gone rather than compressed. Lightroom's Exposure is NOT a plain gain: it
// carries a shoulder, so raising it rolls the top of the range toward white
// instead of pushing it through.
//
// So this prints, for a ramp of Exposure values: how much of the frame is at or
// near white, how much of it CHANGED, and what the midtones did. The midtone
// column is the control — a "fix" for burning that also darkens the middle of
// the picture has not fixed anything, it has just turned Exposure down.
//
//     exposure-highlights <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("exposure-highlights <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 900) : 900

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

func load() -> PhotoBaseImage? {
    PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size))
}

func pixels(_ settings: PhotoEditSettings) -> [UInt8]? {
    guard let base = load() else { return nil }
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

struct Reading {
    var clipped = 0.0      // % of samples at 255 — detail that no longer exists
    var nearWhite = 0.0    // % above 250
    var midtone = 0.0      // mean of what was midtone BEFORE the change
}

guard let neutral = pixels(PhotoEditSettings()) else {
    print("could not open \(url.path)"); exit(1)
}

// Which samples were midtones in the untouched picture — the same samples are
// followed through the ramp, so the column means "what happened to these",
// not "what is midtone now".
var midtoneIndices: [Int] = []
for i in stride(from: 0, to: neutral.count, by: 4) {
    for c in 0..<3 where neutral[i + c] > 80 && neutral[i + c] < 160 {
        midtoneIndices.append(i + c)
    }
}

func measure(_ buffer: [UInt8]) -> Reading {
    var reading = Reading()
    var counted = 0.0
    for i in stride(from: 0, to: buffer.count, by: 4) {
        for c in 0..<3 {
            let v = buffer[i + c]
            if v == 255 { reading.clipped += 1 }
            if v > 250 { reading.nearWhite += 1 }
            counted += 1
        }
    }
    reading.clipped = reading.clipped / counted * 100
    reading.nearWhite = reading.nearWhite / counted * 100
    var sum = 0.0
    for index in midtoneIndices { sum += Double(buffer[index]) }
    reading.midtone = midtoneIndices.isEmpty ? 0 : sum / Double(midtoneIndices.count)
    return reading
}

print("photo: \(url.lastPathComponent)\n")
print("Exposure    at 255 (gone)   over 250      midtones")
print(String(repeating: "-", count: 56))

for ev in [0.0, 0.10, 0.25, 0.50, 0.75, 1.0] {
    var settings = PhotoEditSettings()
    settings.exposure = ev
    guard let buffer = pixels(settings) else { continue }
    let reading = measure(buffer)
    print(String(format: "%+5.2f EV %12.2f%% %11.2f%% %13.1f",
                 ev, reading.clipped, reading.nearWhite, reading.midtone))
}

print()
print("'at 255' is detail that cannot be brought back by lowering Exposure again;")
print("'midtones' is the control — a shoulder must leave this column alone.")
