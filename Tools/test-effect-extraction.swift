// Proves that pulling Sharpen, Texture, Clarity, Dehaze, Soft Glow and
// Vignette out of `render` into functions changed NOTHING about the photograph.
//
// Run:  python3 Tools/run-effect-extraction-test.py
//
// They were extracted so a LAYER can have the same effects the whole photo has
// — the client's *„nemam iste opcije za edit kao celokupan edit, a treba da
// bude sve kao edit za sliku"*. That is an addition, and an addition must not
// move a single pixel of what the photo already looked like: the look of this
// pipeline is signed off (see the locked section at the top of
// BRIEFSHOW_DEVELOP_NOTES.md).
//
// So this compiles BOTH versions side by side — the old inline code, taken out
// of git HEAD by the runner, and the new functions, taken off disk — runs them
// over the same image at a sweep of values, and compares every pixel. Anything
// but zero difference is a failure.
import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// ---- both implementations, pasted in by the extractor at run time ----------

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb,
                              .cacheIntermediates: false])

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

/// A picture with real structure: flat areas, hard edges, fine detail and a
/// colour range. A flat patch would let a texture or clarity difference hide.
let w = 700, h = 500
let sourceCG: CGImage = {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var state: UInt64 = 7
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    c.setFillColor(red: 0.45, green: 0.5, blue: 0.55, alpha: 1)
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for i in 0..<160 {
        c.setFillColor(red: CGFloat(i % 71) / 71, green: CGFloat(i % 37) / 37,
                       blue: CGFloat(i % 53) / 53, alpha: 1)
        c.fill(CGRect(x: next(w), y: next(h), width: 2 + next(60), height: 2 + next(60)))
    }
    // Fine lines, the frequency band Texture and Sharpness live in.
    c.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    for x in stride(from: 0, to: w, by: 6) {
        c.fill(CGRect(x: x, y: 0, width: 1, height: h))
    }
    return c.makeImage()!
}()
let source = CIImage(cgImage: sourceCG)

var bufA = [UInt8](repeating: 0, count: w * h * 4)
var bufB = [UInt8](repeating: 0, count: w * h * 4)

func compare(_ label: String, _ old: CIImage, _ new: CIImage) {
    ctx.render(old, toBitmap: &bufA, rowBytes: w * 4, bounds: source.extent, format: .RGBA8, colorSpace: srgb)
    ctx.render(new, toBitmap: &bufB, rowBytes: w * 4, bounds: source.extent, format: .RGBA8, colorSpace: srgb)
    var differing = 0
    var worst = 0
    for i in 0..<bufA.count where bufA[i] != bufB[i] {
        differing += 1
        worst = max(worst, abs(Int(bufA[i]) - Int(bufB[i])))
    }
    check(label, differing == 0,
          differing == 0 ? "identical" : "\(differing) channels differ, worst \(worst)/255")
}

print("the extracted effects against the code they came from")

for v in [-1.0, -0.6, -0.25, 0.25, 0.6, 1.0] {
    var s = OldSettings()
    s.texture = v
    compare(String(format: "texture %+.2f", v),
            oldTexture(s, to: source), PhotoEditRenderer.applyTexture(v, to: source))
}

for v in [-1.0, -0.5, 0.5, 1.0] {
    var s = OldSettings()
    s.clarity = v
    compare(String(format: "clarity %+.2f", v),
            oldClarity(s, to: source), PhotoEditRenderer.applyClarity(v, to: source))
}

for v in [-1.0, -0.4, 0.4, 1.0] {
    var s = OldSettings()
    s.dehaze = v
    compare(String(format: "dehaze %+.2f", v),
            oldDehaze(s, to: source), PhotoEditRenderer.applyDehaze(v, to: source))
}

for v in [0.3, 0.75, 1.0] {
    var s = OldSettings()
    s.softGlow = v
    compare(String(format: "soft glow %.2f", v),
            oldSoftGlow(s, to: source), PhotoEditRenderer.applySoftGlow(v, to: source))
}

for (sharp, radius) in [(0.25, 1.0), (0.6, 0.5), (1.0, 3.0), (0.5, 1.7)] {
    var s = OldSettings()
    s.sharpness = sharp
    s.sharpenRadius = radius
    compare(String(format: "sharpness %.2f radius %.2f", sharp, radius),
            oldSharpen(s, to: source), PhotoEditRenderer.applySharpen(sharp, radius: radius, to: source))
}

for (v, mid, feather, round) in [(-1.0, 0.5, 0.5, 0.0), (-0.5, 0.2, 0.9, 0.6),
                                 (0.5, 0.8, 0.1, -0.5), (1.0, 0.5, 0.5, 1.0)] {
    var s = OldSettings()
    s.vignette = v
    s.vignetteMidpoint = mid
    s.vignetteFeather = feather
    s.vignetteRoundness = round
    compare(String(format: "vignette %+.2f mid %.1f feather %.1f round %+.1f", v, mid, feather, round),
            oldVignette(s, to: source),
            PhotoEditRenderer.applyVignette(v, midpoint: mid, feather: feather, roundness: round, to: source))
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
