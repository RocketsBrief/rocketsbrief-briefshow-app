// Is there a frame around the subject once the layers are split and edited?
//
// Reported 24.09 on the Intel: *„Posle editovanja slike i odvajanja subject i
// backrounda i menjanja settings ipak se malo vidi okvir oko subjecta posle
// flatten image"*.
//
// run-enhance-edge-test only asks whether the ring comes out DARKER than both
// sides. A frame can also be the untouched photo showing through the soft edge,
// which is lighter than a darkened background — so this compares the render
// with the composite it should be: subject·m + background·(1 − m), each side
// rendered with its own layer's numbers over the WHOLE frame.
//
//     subject-edge <photo> [size] [out-dir]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("subject-edge <photo> [size] [out]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1600) : 1600
let outDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])
func load() -> PhotoBaseImage { PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size))! }

var photo = PhotoEditSettings()
photo.contrast = 0.2
photo.saturation = 0.15
// HEAVY=1: close to the client's own panel (screenshot 7, 23.09).
if let one = ProcessInfo.processInfo.environment["HEAVY_ONLY"] {
    switch one {
    case "texture": photo.texture = -0.48
    case "clarity": photo.clarity = 0.20
    case "dehaze": photo.dehaze = 0.31
    case "blacks": photo.blacks = -0.27
    default: break
    }
}
if ProcessInfo.processInfo.environment["HEAVY"] == "1" {
    photo.texture = -0.48
    photo.clarity = 0.20
    photo.dehaze = 0.31
    photo.blacks = -0.27
}

let base0 = load()
let full = PhotoEditRenderer.render(photo, on: base0, applyCrop: false)
guard let made = PeopleLayerFactory.make(from: full, confinedTo: nil,
                                         backgroundName: "Background", peopleName: "Subjects") else {
    print("nobody"); exit(1)
}
let e = full.extent
let w = Int(e.width), h = Int(e.height)
let white = CIImage(color: .white).cropped(to: e)
let whiteMatte = PhotoEditRenderer.maskPNG(white, extent: e)!

func rgba(_ i: CIImage) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: w * h * 4)
    ctx.render(i.cropped(to: e), toBitmap: &b, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: srgb)
    return b
}
// The matte exactly as the Background layer stores it, inverted back.
let storedBackground = CIImage(data: made.background.maskData!)!
let m = rgba(storedBackground).map { 255 - $0 }

func check(_ recipes: [PortraitRecipe], label: String) -> Double {
    var s = photo
    s.layers = [made.background, made.people]
    for r in recipes {
        var t = BackgroundEnhancedTuning.defaults(for: r)
        // TUNE_ONLY=clarity|shadows|saturation|…: that one number, the rest 0.
        if let only = ProcessInfo.processInfo.environment["TUNE_ONLY"] {
            var one = BackgroundEnhancedTuning(exposure: 0, contrast: 0, shadows: 0,
                                               saturation: 0, clarity: 0, dehaze: 0)
            switch only {
            case "clarity": one.clarity = t.clarity
            case "shadows": one.shadows = t.shadows
            case "saturation": one.saturation = t.saturation
            default: break
            }
            t = one
        }
        s = r.applied(to: s, backgroundID: made.background.id, peopleID: made.people.id,
                      tuning: t)
    }
    var drawn = s
    if ProcessInfo.processInfo.environment["NO_LAYERS"] == "1" { drawn.layers = [] }
    let out = rgba(PhotoEditRenderer.render(drawn, on: load(), applyCrop: false))

    // Each side over the whole frame: a full-frame derived layer with a white
    // matte and that side's own numbers.
    func side(_ layer: ImageLayer) -> [UInt8] {
        var one = photo
        var l = ImageLayer(name: "all", imageData: Data(), x: 0, y: 0, width: 1, height: 1,
                           maskData: whiteMatte)
        l.adjustments = layer.adjustments
        one.layers = [l]
        return rgba(PhotoEditRenderer.render(one, on: load(), applyCrop: false))
    }
    let bg = side(s.layers[0]), fg = side(s.layers[1])
    if let outDir {
        var ideal = [UInt8](repeating: 255, count: out.count)
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Double(m[i]) / 255
            for c in 0..<3 { ideal[i+c] = UInt8(max(0, min(255, (Double(fg[i+c]) * a + Double(bg[i+c]) * (1 - a)).rounded()))) }
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        ideal.withUnsafeBufferPointer { memcpy(rep.bitmapData!, $0.baseAddress!, out.count) }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: outDir.appendingPathComponent("ideal-\(label).png"))
    }

    var ring = 0.0, ringN = 0, solid = 0.0, solidN = 0
    var worst = 0.0
    for i in stride(from: 0, to: out.count, by: 4) {
        let a = Double(m[i]) / 255
        func lum(_ p: [UInt8]) -> Double { 0.2126 * Double(p[i]) + 0.7152 * Double(p[i+1]) + 0.0722 * Double(p[i+2]) }
        let ideal = lum(fg) * a + lum(bg) * (1 - a)
        let d = lum(out) - ideal
        if a > 0.15 && a < 0.85 { ring += d; ringN += 1; worst = max(worst, abs(d)) }
        else if a < 0.03 || a > 0.97 { solid += abs(d); solidN += 1 }
    }
    let r = ring / Double(max(ringN, 1)), sd = solid / Double(max(solidN, 1))
    print(String(format: "%-22@ ring off ideal %+6.2f (worst %5.1f, %d px)   solid areas |off| %5.2f",
                 label as NSString, r, worst, ringN, sd))
    if let outDir {
        let img = PhotoEditRenderer.render(drawn, on: load(), applyCrop: false)
        try? ctx.pngRepresentation(of: img, format: .RGBA8, colorSpace: srgb)?
            .write(to: outDir.appendingPathComponent("edge-\(label).png"))
    }
    return abs(r)
}

print("photo: \(url.lastPathComponent)  \(w)x\(h)\n")
let a = check([.backgroundEnhanced], label: "background enhanced")
let b = check([.subjectEnhanced], label: "subject enhanced")
let c = check([.backgroundEnhanced, .subjectEnhanced], label: "both")
let bad = max(a, b, c) > 1.5
print(bad ? "\nRESULT: FRAME around the subject" : "\nRESULT: OK")
exit(bad ? 1 : 0)
