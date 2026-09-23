// Does putting a layer on a photo change the photo UNDER it when Clarity is on?
//
// It must not: a fully transparent layer adds nothing. Found 23.09 chasing the
// dark outline Background Enhanced left round people (screenshots 5 and 6):
// with Clarity on, a People cut-out made from the photo's own render did not
// sit invisibly on that same photo — the edge came out 16 levels darker.
//
//     clarity-layer <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("clarity-layer <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 800) : 800
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])
func load() -> PhotoBaseImage { PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size))! }

func pixels(_ image: CIImage) -> [UInt8] {
    let e = image.extent
    var b = [UInt8](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
    ctx.render(image, toBitmap: &b, rowBytes: Int(e.width) * 4, bounds: e, format: .RGBA8, colorSpace: srgb)
    return b
}
func mean(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var s = 0.0
    for i in stride(from: 0, to: min(a.count, b.count), by: 4) { for c in 0..<3 { s += abs(Double(a[i+c]) - Double(b[i+c])) } }
    return s / Double(a.count / 4 * 3)
}

// A 4×4 transparent PNG, placed in a corner.
let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
let png = ctx.pngRepresentation(of: clear, format: .RGBA8, colorSpace: srgb)!
let invisible = ImageLayer(name: "clear", imageData: png, x: 0, y: 0, width: 0.01, height: 0.01)

var failures = 0
for (label, key, value) in [("Clarity +0.2", \PhotoEditSettings.clarity, 0.2),
                            ("Texture -0.5", \PhotoEditSettings.texture, -0.5),
                            ("Dehaze +0.3", \PhotoEditSettings.dehaze, 0.3),
                            ("Exposure +0.5", \PhotoEditSettings.exposure, 0.5)] {
    var s = PhotoEditSettings()
    s[keyPath: key] = value
    let alone = pixels(PhotoEditRenderer.render(s, on: load()))
    s.layers = [invisible]
    let layered = pixels(PhotoEditRenderer.render(s, on: load()))
    let d = mean(alone, layered)
    print(String(format: "%-14@ photo vs photo + invisible layer: mean difference %.2f levels", label as NSString, d))
    if d > 0.5 { failures += 1 }
}
print(failures == 0 ? "RESULT: OK" : "RESULT: a layer changes the photo under it")
exit(failures == 0 ? 0 : 1)
