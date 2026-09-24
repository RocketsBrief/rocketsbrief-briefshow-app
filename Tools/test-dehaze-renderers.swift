// Does Dehaze come out the same on a different Core Image renderer?
//
// Reported 23.09 from the client's Intel Mac (C4S Problem Screenshots 3, 7, 8):
// black blobs in the background, a hard contour across the sky with grey
// noise inside it, a background turned flat grey. None of it happens here on
// Apple silicon, and there is no Intel Mac on this desk — so this renders the
// SAME graph through renderers that are not the one the app ships on, and
// counts the pixels that go wrong the way the screenshots do. A filter that is
// fragile on another GPU is often fragile on the software renderer too.
//
//     dehaze-renderers <photo> [size] [dehaze] [out-dir]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("dehaze-renderers <photo> [size] [dehaze] [out]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1600) : 1600
let amount = args.count > 2 ? (Double(args[2]) ?? 0.31) : 0.31
let outDir = args.count > 3 ? URL(fileURLWithPath: args[3]) : nil

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let renderers: [(String, CIContext)] = [
    ("gpu (the app's)", CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb,
                                            .cacheIntermediates: false])),
    ("software", CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb,
                                     .cacheIntermediates: false, .useSoftwareRenderer: true])),
    ("gpu RGBAf", CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb,
                                      .cacheIntermediates: false,
                                      .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue)])),
    ("gpu RGBA8", CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb,
                                      .cacheIntermediates: false,
                                      .workingFormat: NSNumber(value: CIFormat.RGBA8.rawValue)])),
]

guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else {
    print("could not load \(url.path)"); exit(1)
}
var settings = PhotoEditSettings()
settings.dehaze = amount
// ALL=1: the client's whole panel from screenshot 7, not Dehaze alone.
if ProcessInfo.processInfo.environment["ALL"] == "1" {
    settings.texture = -0.48
    settings.clarity = 0.20
    settings.blacks = -0.27
    settings.saturation = 0.15
    settings.contrast = 0.2
    settings.highlights = -0.4
    settings.shadows = 0.3
}
let plain = PhotoEditRenderer.render(PhotoEditSettings(), on: base, applyCrop: false)
let edited = PhotoEditRenderer.render(settings, on: base, applyCrop: false)
let extent = plain.extent.integral
let w = Int(extent.width), h = Int(extent.height)

func pixels(_ image: CIImage, _ ctx: CIContext) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes {
        ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: extent,
                   format: .RGBA8, colorSpace: srgb)
    }
    return out
}
func luma(_ p: [UInt8], _ i: Int) -> Double {
    0.2126 * Double(p[i * 4]) + 0.7152 * Double(p[i * 4 + 1]) + 0.0722 * Double(p[i * 4 + 2])
}

let reference = pixels(edited, renderers[0].1)
let before = pixels(plain, renderers[0].1)
var failures = 0
for (name, ctx) in renderers {
    let p = pixels(edited, ctx)
    var diff = 0.0, crushed = 0, flattened = 0
    for i in 0..<(w * h) {
        let l = luma(p, i), was = luma(before, i)
        diff += abs(l - luma(reference, i))
        if was > 60 && l < 8 { crushed += 1 }                // the black blobs
        if abs(l - was) > 60 { flattened += 1 }              // anything torn far from the photo
    }
    let n = Double(w * h)
    print(String(format: "%-16@ vs app: %6.2f levels   crushed to black %5.2f%%   moved >60 levels %5.2f%%",
                 name as NSString, diff / n, Double(crushed) / n * 100, Double(flattened) / n * 100))
    if Double(crushed) / n > 0.001 || Double(flattened) / n > 0.01 { failures += 1 }
    if let outDir {
        let file = outDir.appendingPathComponent("dehaze-\(name.split(separator: " ")[0])-\(p.count).png")
        if let cg = ctx.createCGImage(edited, from: extent) {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }
}
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) renderer(s) tear the picture")
exit(failures == 0 ? 0 : 1)
