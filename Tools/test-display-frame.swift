// Create's frame on the graphics card (IOSurface, 25.09) must be the SAME
// picture the old readback made — colour AND alpha.
//
//     display-frame <photo> [size] [exposure contrast dehaze]
import Foundation
import CoreImage
import AppKit
import IOSurface

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("display-frame <photo> [size]"); exit(2) }
let size = args.count > 1 ? (Double(args[1]) ?? 2600) : 2600
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])
let plainCtx = CIContext(options: [.cacheIntermediates: false])
guard let base = PhotoEditRenderer.loadBaseImage(from: URL(fileURLWithPath: first), maxPixelSize: CGFloat(size)) else {
    print("could not load"); exit(1)
}
var failures = 0
let looks: [(String, (inout PhotoEditSettings) -> Void)] = [
    ("plain", { _ in }),
    ("contrast +12, dehaze +1.5 (C4S_8928)", { $0.contrast = 0.121; $0.dehaze = 0.0148 }),
    ("dehaze +0.5", { $0.dehaze = 0.5 }),
    ("clarity +0.5", { $0.clarity = 0.5 }),
    ("straighten 5 (transparent corners)", { $0.straightenDegrees = 5 }),
]
for (label, tweak) in looks {
    var s = PhotoEditSettings(); tweak(&s)
    let rendered = PhotoEditRenderer.render(s, on: base, applyCrop: true)
    for (name, context) in [("sRGB context", ctx), ("default context", plainCtx)] {
        let rect = rendered.extent.integral
        let w = Int(rect.width), h = Int(rect.height)
        guard let cg = context.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: srgb, deferred: false),
              let frame = briefEditsDisplayFrame(rendered, from: rendered.extent, context: context),
              let surface = GPUFrameImage.surface(of: frame) else { print("render failed"); failures += 1; continue }
        let provider = cg.dataProvider!.data! as Data
        let cgBytes = [UInt8](provider)
        let cgRow = cg.bytesPerRow
        surface.lock(options: .readOnly, seed: nil)
        let sp = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let bpr = surface.bytesPerRow
        var maxd = 0, minAlpha = 255, surfMinAlpha = 255
        for y in stride(from: 0, to: min(h, cg.height), by: 3) { for x in stride(from: 0, to: min(w, cg.width), by: 3) {
            let c = y * cgRow + x * 4, o = y * bpr + x * 4
            for (k, j) in [(0, 2), (1, 1), (2, 0), (3, 3)] { maxd = max(maxd, abs(Int(cgBytes[c + k]) - Int(sp[o + j]))) }
            minAlpha = min(minAlpha, Int(cgBytes[c + 3])); surfMinAlpha = min(surfMinAlpha, Int(sp[o + 3]))
        }}
        surface.unlock(options: .readOnly, seed: nil)
        print(String(format: "%@ / %@: max byte difference %d, min alpha old %d new %d, alphaInfo %d",
                     label as NSString, name as NSString, maxd, minAlpha, surfMinAlpha, cg.alphaInfo.rawValue))
        if maxd > 1 { print("  FAIL the frame on the card is not the old picture"); failures += 1 }
    }
}
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) failed")
exit(failures == 0 ? 0 : 1)
