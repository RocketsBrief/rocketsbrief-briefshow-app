// Renders a photograph at several Dehaze settings to PNG, so the result can be
// LOOKED AT. Every dehaze ruler so far has measured; the client's complaint on
// 13.09 is about what the picture looks like.
//
//     dehaze-look <photo> <outdir> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("dehaze-look <photo> <outdir> [size]"); exit(2) }
let url = URL(fileURLWithPath: args[0])
let outDir = URL(fileURLWithPath: args[1])
let size = args.count > 2 ? (Double(args[2]) ?? 1400) : 1400

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else {
    print("could not open \(url.path)"); exit(1)
}

func write(_ image: CIImage, _ name: String) {
    let e = image.extent
    guard let cg = ctx.createCGImage(image, from: e) else { print("no image for \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let path = outDir.appendingPathComponent(name + ".png")
    try? data.write(to: path)
    print("wrote \(path.path)  \(Int(e.width))x\(Int(e.height))")
}

for amount in [0.0, 0.5, 1.0, -0.5] {
    var s = PhotoEditSettings()
    s.dehaze = amount
    let tag = amount == 0 ? "00" : String(format: "%+03.0f", amount * 100)
    write(PhotoEditRenderer.render(s, on: base), "dehaze\(tag)")
}

// What the model THINKS: the light in the air, and the map it built.
let neutral = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
if let a = PhotoEditRenderer.atmosphericLight(of: neutral) {
    print(String(format: "A = (%.3f, %.3f, %.3f)", a.r, a.g, a.b))
    if let t = PhotoEditRenderer.transmissionMap(of: neutral, atmosphere: a) {
        write(t.cropped(to: neutral.extent), "transmission")
        // Read the map in bands from top (far) to bottom (near).
        let e = neutral.extent
        let w = Int(e.width), h = Int(e.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            ctx.render(t.cropped(to: e), toBitmap: raw.baseAddress!, rowBytes: w * 16,
                       bounds: e, format: .RGBAf, colorSpace: srgb)
        }
        print("transmission by band, top row of the file first:")
        for band in 0..<8 {
            let y0 = band * h / 8, y1 = (band + 1) * h / 8
            var sum = 0.0, n = 0.0
            for y in y0..<y1 { for x in 0..<w { sum += Double(buf[(y * w + x) * 4]); n += 1 } }
            print(String(format: "  band %d  t = %.3f", band, sum / n))
        }
    }
}
