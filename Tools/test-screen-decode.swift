// Is the screen-sized sharp frame as sharp as native, and how much faster?
//
// 25.09: Create's sharp frame is rendered at what the view can show
// (ScreenBaseCache), not always native. This renders one NEF both ways with a
// real edit, brings the native one down to the same size with Lanczos (what the
// screen would have done to it), and compares: per-pixel difference, and
// sharpness as the mean |Laplacian| (a softer picture scores lower).
//
//     screen-decode <photo> [viewPixelsLongEdge=3000]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("screen-decode <photo> [view]"); exit(2) }
let url = URL(fileURLWithPath: first)
let viewLong = args.count > 1 ? CGFloat(Double(args[1]) ?? 3000) : 3000
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .cacheIntermediates: false])

var s = PhotoEditSettings()
s.contrast = 0.2; s.clarity = 0.25; s.texture = -0.3; s.saturation = 0.1; s.dehaze = 0.2

func time<T>(_ f: () -> T) -> (T, Double) { let t = Date(); let r = f(); return (r, Date().timeIntervalSince(t)) }
func bitmap(_ i: CIImage) -> ([UInt8], Int, Int) {
    let e = i.extent.integral; let w = Int(e.width), h = Int(e.height)
    var b = [UInt8](repeating: 0, count: w * h * 4)
    ctx.render(i, toBitmap: &b, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: srgb)
    return (b, w, h)
}
func sharp(_ b: [UInt8], _ w: Int, _ h: Int) -> Double {
    var sum = 0.0, n = 0
    for y in stride(from: 1, to: h - 1, by: 2) { for x in stride(from: 1, to: w - 1, by: 2) {
        func g(_ x: Int, _ y: Int) -> Double { let i = (y * w + x) * 4; return 0.3 * Double(b[i]) + 0.59 * Double(b[i+1]) + 0.11 * Double(b[i+2]) }
        sum += abs(4 * g(x, y) - g(x-1, y) - g(x+1, y) - g(x, y-1) - g(x, y+1)); n += 1
    } }
    return sum / Double(n)
}

let full = PhotoEditRenderer.loadBaseImage(from: url)!
let long = max(full.extent.width, full.extent.height)
let scale = min(1, viewLong / long)
print(String(format: "native long edge %.0f, view %.0f, scale %.3f", long, viewLong, scale))

// Warm both paths once so neither pays first-use costs in the timing.
_ = bitmap(PhotoEditRenderer.render(s, on: full, applyCrop: true))
let screen = PhotoEditRenderer.loadPreviewBaseImage(from: url, full: full, previewMax: (long * scale).rounded(.up), draft: false)
_ = bitmap(PhotoEditRenderer.render(s, on: screen, applyCrop: true))

var s2 = s; s2.contrast = 0.25   // a new edit, like the next slider release
let (nat, tNative) = time { bitmap(PhotoEditRenderer.render(s2, on: full, applyCrop: true)) }
let (scr, tScreen) = time { bitmap(PhotoEditRenderer.render(s2, on: screen, applyCrop: true)) }
print(String(format: "sharp frame: native %.2f s (%dx%d)   screen %.2f s (%dx%d)   %.1fx faster",
             tNative, nat.1, nat.2, tScreen, scr.1, scr.2, tNative / tScreen))

// Native brought down to the screen frame's size.
let nativeImage = PhotoEditRenderer.render(s2, on: full, applyCrop: true)
let down = nativeImage.applyingFilter("CILanczosScaleTransform", parameters: [
    kCIInputScaleKey: CGFloat(scr.2) / nativeImage.extent.height, kCIInputAspectRatioKey:
        (CGFloat(scr.1) / CGFloat(scr.2)) / (nativeImage.extent.width / nativeImage.extent.height)])
let d = bitmap(down.transformed(by: CGAffineTransform(translationX: -down.extent.minX, y: -down.extent.minY)))
let w = min(d.1, scr.1), h = min(d.2, scr.2)
var diff = 0.0
for y in 0..<h { for x in 0..<w { for c in 0..<3 {
    diff += abs(Double(d.0[(y * d.1 + x) * 4 + c]) - Double(scr.0[(y * scr.1 + x) * 4 + c]))
} } }
print(String(format: "mean |difference| %.2f levels", diff / Double(w * h * 3)))
print(String(format: "sharpness (mean |Laplacian|): native→screen %.2f   screen decode %.2f", sharp(d.0, d.1, d.2), sharp(scr.0, scr.1, scr.2)))

// Decode a little LARGER than the screen and bring it down with Lanczos — the
// resampler the screen decode lacks. OVER=1.25,1.5,2 by default.
let overs = (ProcessInfo.processInfo.environment["OVER"] ?? "1.25,1.5,1.75,2").split(separator: ",").compactMap { Double($0) }
for over in overs {
    let sc = min(1, scale * CGFloat(over))
    let base = PhotoEditRenderer.loadPreviewBaseImage(from: url, full: full, previewMax: (long * sc).rounded(.up), draft: false)
    _ = bitmap(PhotoEditRenderer.render(s, on: base, applyCrop: true))
    let (b, t) = time { () -> ([UInt8], Int, Int) in
        let r = PhotoEditRenderer.render(s2, on: base, applyCrop: true)
        let k = CGFloat(scr.2) / r.extent.height
        let o = r.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        return bitmap(o.transformed(by: CGAffineTransform(translationX: -o.extent.minX, y: -o.extent.minY)))
    }
    print(String(format: "decode x%.2f (%.3f) then Lanczos: %.2f s  %.1fx faster  sharpness %.2f", over, sc, t, tNative / t, sharp(b.0, b.1, b.2)))
}

// The way the app does it (25.09): the FULL decode, Lanczos to the screen size
// first, then every edit on the smaller picture.
do {
    _ = bitmap(PhotoEditRenderer.render(s, on: full, applyCrop: true, decodeScale: scale))
    let (b, t) = time { () -> ([UInt8], Int, Int) in
        let r = PhotoEditRenderer.render(s2, on: full, applyCrop: true, decodeScale: scale)
        return bitmap(r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY)))
    }
    var dd = 0.0
    let ww = min(d.1, b.1), hh = min(d.2, b.2)
    for y in 0..<hh { for x in 0..<ww { for c in 0..<3 {
        dd += abs(Double(d.0[(y * d.1 + x) * 4 + c]) - Double(b.0[(y * b.1 + x) * 4 + c]))
    } } }
    print(String(format: "APP: full decode, Lanczos first, edits after: %.2f s  %.1fx faster  sharpness %.2f  mean |diff vs native→screen| %.2f  (%dx%d)",
                 t, tNative / t, sharp(b.0, b.1, b.2), dd / Double(ww * hh * 3), b.1, b.2))
}

// And the next edit after that, with the held decode — what every release after
// the first costs while White Balance is not touched.
do {
    var s3 = s2; s3.saturation = 0.2
    let (b, t) = time { () -> ([UInt8], Int, Int) in
        let r = PhotoEditRenderer.render(s3, on: full, applyCrop: true, decodeScale: scale)
        return bitmap(r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY)))
    }
    print(String(format: "APP, next edit (held decode): %.2f s  %.1fx faster than native  sharpness %.2f", t, tNative / t, sharp(b.0, b.1, b.2)))
}

// Lightroom's rule, as the app computes it: a 1500×1000 pt view on a 2× screen.
let ext = CGRect(x: 0, y: 0, width: 6048, height: 4024)
let v = CGSize(width: 1500, height: 1000)
var fails = 0
for (zoom, want) in [(1.0, 0.5), (1.5, 0.75), (2.0, 1.0), (4.0, 1.0)] as [(CGFloat, CGFloat)] {
    let got = briefShowSharpScale(extent: ext, settings: PhotoEditSettings(), applyCrop: true,
                                  view: v, zoom: zoom, backing: 2)
    let ok = abs(got - want) < 0.001
    if !ok { fails += 1 }
    print(String(format: "%@  zoom %.1f → scale %.3f (want %.3f)", ok ? "ok  " : "FAIL", zoom, got, want))
}
var cropped = PhotoEditSettings()
cropped.crop = EditCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
let c = briefShowSharpScale(extent: ext, settings: cropped, applyCrop: true, view: v, zoom: 1, backing: 2)
print(String(format: "%@  half-size crop at fit → scale %.3f (want 1: the crop is shown twice as large)", c == 1 ? "ok  " : "FAIL", c))
if c != 1 { fails += 1 }
exit(fails == 0 ? 0 : 1)
