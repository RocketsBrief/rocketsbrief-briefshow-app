// Every look slider reaches further than it did (25.09: 100 on the slider is
// 150 % of the old effect). For each control: the picture at the old end (1.0)
// and at the new end (1.5) — the new end must move the photo MORE than the old
// one did, or the extra travel is dead.
//
//     slider-reach <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("slider-reach <photo> [size]"); exit(2) }
let size = args.count > 1 ? (Double(args[1]) ?? 900) : 900
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
guard let base = PhotoEditRenderer.loadBaseImage(from: URL(fileURLWithPath: first), maxPixelSize: CGFloat(size)) else {
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
let before = pixels(plain)
func moved(_ s: PhotoEditSettings) -> Double {
    let after = pixels(PhotoEditRenderer.render(s, on: base, applyCrop: false))
    var total = 0.0
    for i in stride(from: 0, to: w * h * 4, by: 4) {
        total += abs(Double(after[i]) - Double(before[i])) + abs(Double(after[i+1]) - Double(before[i+1]))
            + abs(Double(after[i+2]) - Double(before[i+2]))
    }
    return total / Double(w * h * 3)
}
typealias Set_ = (inout PhotoEditSettings, Double) -> Void
let controls: [(String, Set_)] = [
    ("Exposure +", { $0.exposure = $1 }), ("Exposure −", { $0.exposure = -$1 }),
    ("Contrast +", { $0.contrast = $1 }), ("Contrast −", { $0.contrast = -$1 }),
    ("Highlights +", { $0.highlights = $1 }), ("Highlights −", { $0.highlights = -$1 }),
    ("Shadows +", { $0.shadows = $1 }), ("Shadows −", { $0.shadows = -$1 }),
    ("Whites +", { $0.whites = $1 }), ("Blacks −", { $0.blacks = -$1 }),
    ("Temperature +", { $0.temperature = $1 }), ("Tint +", { $0.tint = $1 }),
    ("Saturation +", { $0.saturation = $1 }), ("Vibrance +", { $0.vibrance = $1 }),
    ("Sharpness", { $0.sharpness = $1 }),
    ("Texture +", { $0.texture = $1 }), ("Texture −", { $0.texture = -$1 }),
    ("Clarity +", { $0.clarity = $1 }), ("Clarity −", { $0.clarity = -$1 }),
    ("Dehaze +", { $0.dehaze = $1 }), ("Dehaze −", { $0.dehaze = -$1 }),
    ("Subjects Dehaze", { $0.faceDehaze = $1 }), ("Soft Glow", { $0.softGlow = $1 }),
    ("Subjects Exposure +", { $0.subjectsExposure = $1 }), ("Background Exposure +", { $0.backgroundExposure = $1 }),
    ("Subjects Clarity +", { $0.subjectsClarity = $1 }), ("Background Clarity +", { $0.backgroundClarity = $1 }),
    ("Background Dehaze +", { $0.backgroundDehaze = $1 }),
    ("Background Saturation +", { $0.backgroundSaturation = $1 }),
    ("Subjects Contrast +", { $0.subjectsContrast = $1 }), ("Subjects Contrast −", { $0.subjectsContrast = -$1 }),
]
// Already at their physical end at the old 100: a corner that is black, a
// picture that is grey. Reported, not failed.
let atTheirEnd: Set<String> = ["Vignette", "Saturation −"]
var failures = 0
for (name, set) in controls {
    var one = PhotoEditSettings(); set(&one, 1.0)
    var more = PhotoEditSettings(); set(&more, 1.5)
    let a = moved(one), b = moved(more)
    let ok = b > a * 1.05
    print(String(format: "%@ %-24@ old end moved %6.2f   new end %6.2f   (×%.2f)", ok ? "ok  " : "FAIL",
                 name as NSString, a, b, a > 0 ? b / a : 0))
    if !ok && !atTheirEnd.contains(name) { failures += 1 }
}
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) failed")
exit(failures == 0 ? 0 : 1)
