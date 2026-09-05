// Renders a photograph through the app's REAL develop pipeline, headlessly.
//
// Built and driven by Tools/run-lightroom-calibration.py. Compiled against the
// app's own sources, so it can never drift from what the app does — the same
// discipline as Tools/inpaint-sweep.swift.
//
//   calibrate render <photo> <preset.xmp|-> <out.png> [longEdge] [k=v ...]
//   calibrate ramp   <preset.xmp|-> [k=v ...]
//
// `ramp` puts a 0...255 grey step wedge through the pipeline and prints what
// comes out. That is how the non-monotonic tone curve of 05.09.2026 was found:
// a photograph shows you that something is wrong, a ramp tells you what.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

func applyOverrides(_ s: inout PhotoEditSettings, _ kv: [String]) {
    for pair in kv {
        let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard p.count == 2, let v = Double(p[1]) else { continue }
        switch p[0] {
        case "exposure": s.exposure = v
        case "contrast": s.contrast = v
        case "highlights": s.highlights = v
        case "shadows": s.shadows = v
        case "whites": s.whites = v
        case "blacks": s.blacks = v
        case "saturation": s.saturation = v
        case "vibrance": s.vibrance = v
        case "temperature": s.temperature = v
        case "tint": s.tint = v
        case "texture": s.texture = v
        case "clarity": s.clarity = v
        case "dehaze": s.dehaze = v
        case "vignette": s.vignette = v
        case "sharpness": s.sharpness = v
        case "mixer0":
            for b in ColorBand.allCases {
                var m = s.colorMixer[b] ?? ColorMixerBand()
                m.hue = 0; m.saturation = 0; m.luminance = 0
                s.colorMixer[b] = m
            }
        default: break
        }
    }
}

func loadPreset(_ path: String) -> PhotoEditSettings {
    guard path != "-" else { return PhotoEditSettings() }
    guard let r = try? LightroomPresetImport.read(URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write("preset unreadable: \(path)\n".data(using: .utf8)!)
        return PhotoEditSettings()
    }
    return r.preset.settings
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

let all = Array(CommandLine.arguments.dropFirst())
guard let mode = all.first else { print("render|ramp"); exit(2) }
let args = Array(all.dropFirst())

if mode == "ramp" {
    var s = loadPreset(args[0])
    applyOverrides(&s, Array(args.dropFirst()))
    let w = 256, h = 8
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            px[i] = UInt8(x); px[i + 1] = UInt8(x); px[i + 2] = UInt8(x); px[i + 3] = 255
        }
    }
    let img = CIImage(bitmapData: Data(px), bytesPerRow: w * 4,
                      size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: srgb)
    let out = PhotoEditRenderer.render(s, on: .standard(img))
    guard let cg = ctx.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: srgb) else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    print("in     R    G    B")
    for x in stride(from: 0, to: 256, by: 8) {
        guard let c = rep.colorAt(x: min(x, cg.width - 1), y: cg.height / 2) else { continue }
        print(String(format: "%4d %4.0f %4.0f %4.0f", x,
                     c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255))
    }
    exit(0)
}

guard args.count >= 3 else { print("render <photo> <xmp|-> <out.png> [long] [k=v ...]"); exit(2) }
guard let base = PhotoEditRenderer.loadBaseImage(from: URL(fileURLWithPath: args[0])) else {
    print("cannot open \(args[0])"); exit(1)
}
var settings = loadPreset(args[1])
applyOverrides(&settings, args.count > 4 ? Array(args.dropFirst(4)) : [])
var image = PhotoEditRenderer.render(settings, on: base)
if args.count > 3, let long = Double(args[3]), long > 0 {
    let e = image.extent
    let k = long / Double(max(e.width, e.height))
    if k < 1 { image = image.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
}
guard let cg = ctx.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb),
      let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
    print("render failed"); exit(1)
}
try d.write(to: URL(fileURLWithPath: args[2]))
print("\(cg.width)x\(cg.height) -> \(args[2])")
