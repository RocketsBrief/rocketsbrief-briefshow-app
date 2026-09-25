import Foundation
import CoreImage
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: 1600)!
for (name, v) in [("0", 0.0), ("100", 1.0), ("150", 1.5), ("dehaze100", -1.0)] {
    var s = PhotoEditSettings()
    if name == "dehaze100" { s.dehaze = 1 } else { s.backgroundDehaze = v }
    let r = PhotoEditRenderer.render(s, on: base, applyCrop: false)
    let cg = ctx.createCGImage(r, from: r.extent)!
    try! NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: out.appendingPathComponent("bg-\(name).jpg"))
}
print("ok")
