// Scans photographs for a LENS VEIL — the milky wash sun on the lens lays over
// the whole frame — by reading how far the darkest content of the frame has
// been lifted. A clear frame has something near black in some channel; a
// veiled one does not, anywhere.
//
//     dehaze-veil-scan <photo> [<photo> ...]
import Foundation
import CoreImage

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: 400) else { continue }
    let img = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
    guard let a = PhotoEditRenderer.atmosphericLight(of: img) else { continue }
    let v = PhotoEditRenderer.lensVeil(of: img, atmosphere: a) ?? -1
    print(String(format: "%@  veil %.3f  A (%.2f %.2f %.2f)", url.lastPathComponent, v, a.r, a.g, a.b))
}
