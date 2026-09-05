// Does a filmstrip/grid thumbnail show the SAME picture as the big canvas?
//
// The client's report, 05.09: the photograph in Create is right, the thumbnail
// of that same photograph in the filmstrip and in the grid is not — and the
// two disagree only for RAW files.
//
// The two paths were never the same pipeline. The big canvas decodes a RAW
// through CIRAWFilter; the thumbnail asked ImageIO for a reduced image, which
// on a NEF is the CAMERA's own JPEG rendering, and then ran the edit over that
// as if it were an ordinary photograph — a different demosaic, and a different
// branch of render() for exposure and white balance.
//
//   parity <photo> <preset.xmp|-> [maxPixelSize]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("parity <photo> <xmp|-> [size]"); exit(2) }
let url = URL(fileURLWithPath: args[0])
let size = args.count > 2 ? (Double(args[2]) ?? 384) : 384

var settings = PhotoEditSettings()
if args[1] != "-", let read = try? LightroomPresetImport.read(URL(fileURLWithPath: args[1])) {
    settings = read.preset.settings
}

// k=v after the size, so a control can be taken out of the comparison and the
// residual attributed instead of guessed at.
for pair in args.dropFirst(3) {
    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
    guard kv.count == 2, let v = Double(kv[1]) else { continue }
    switch kv[0] {
    case "sharpness": settings.sharpness = v
    case "clarity": settings.clarity = v
    case "texture": settings.texture = v
    case "dehaze": settings.dehaze = v
    case "vignette": settings.vignette = v
    default: break
    }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

func pixels(_ image: CIImage, _ target: CGSize) -> [Double]? {
    guard let cg = ctx.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb) else {
        return nil
    }
    let w = Int(target.width), h = Int(target.height)
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    guard let bitmap = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: srgb,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    bitmap.interpolationQuality = .high
    bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buffer.map(Double.init)
}

func elapsed(_ work: () -> Void) -> Double {
    let start = Date()
    work()
    return Date().timeIntervalSince(start)
}

// ⚠️ Both timings below realise the pixels inside the measured block. Core
// Image is lazy: render() only builds the graph, so timing it alone says
// nothing — an earlier version of this harness reported the thumbnail path as
// four times SLOWER than the full decode purely because of that.

// The big canvas, shrunk to thumbnail size afterwards — the picture the client
// is looking at when he says the thumbnail is wrong.
guard let base = PhotoEditRenderer.loadBaseImage(from: url) else {
    print("could not open \(url.path)"); exit(1)
}
let canvas = PhotoEditRenderer.render(settings, on: base)
let scale = size / Double(max(canvas.extent.width, canvas.extent.height))
let target = CGSize(width: (Double(canvas.extent.width) * scale).rounded(),
                    height: (Double(canvas.extent.height) * scale).rounded())

var want: [Double]?
let canvasSeconds = elapsed {
    guard let fresh = PhotoEditRenderer.loadBaseImage(from: url) else { return }
    want = pixels(PhotoEditRenderer.render(settings, on: fresh), target)
}
guard let want else { print("canvas render failed"); exit(1) }

// The thumbnail, exactly as the strip and the grid build it.
var got: [Double]?
let thumbSeconds = elapsed {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: size) else { return }
    got = pixels(PhotoEditRenderer.render(settings, on: base), target)
}
guard let got else { print("thumbnail render failed"); exit(1) }

// The path that was there before, kept as the control: without it a "0.0"
// above could mean the fix worked or that both sides call the same function.
var old: [Double]?
let oldSeconds = elapsed {
    guard let plain = makeShowGridThumbnail(from: url, maxPixelSize: size),
          let cg = plain.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    old = pixels(PhotoEditRenderer.render(settings, on: .standard(CIImage(cgImage: cg))), target)
}

// ⚠️ RAW RMS IS THE WRONG VERDICT HERE, and saying so is the point of this
// block. Sharpness, Clarity and Texture work in PIXELS: at 384 px they cannot
// land where they land on a 5,176 px frame, so a thumbnail that is otherwise
// perfect still scores ~9 against the canvas. Lightroom's own thumbnails do
// the same thing. The question the client actually asked is whether it is the
// SAME PICTURE — same brightness, same colour — so the verdict is taken after
// averaging 4x4 blocks, which throws away exactly the detail scale that cannot
// match and keeps everything that must.
func blocked(_ p: [Double], _ size: CGSize, _ factor: Int) -> [Double] {
    let w = Int(size.width), h = Int(size.height)
    var out: [Double] = []
    for by in stride(from: 0, to: h - factor, by: factor) {
        for bx in stride(from: 0, to: w - factor, by: factor) {
            for c in 0..<3 {
                var acc = 0.0
                for y in by..<(by + factor) {
                    for x in bx..<(bx + factor) {
                        acc += p[(y * w + x) * 4 + c]
                    }
                }
                out.append(acc / Double(factor * factor))
            }
        }
    }
    return out
}

var sum = 0.0
var meanCanvas = 0.0
var meanThumb = 0.0
var counted = 0
for i in stride(from: 0, to: want.count, by: 4) {
    for c in 0..<3 {
        let d = got[i + c] - want[i + c]
        sum += d * d
        meanCanvas += want[i + c]
        meanThumb += got[i + c]
        counted += 1
    }
}
let rms = (sum / Double(counted)).squareRoot()
meanCanvas /= Double(counted)
meanThumb /= Double(counted)

print(String(format: "canvas   %5.0fx%-5.0f mean %6.1f   %.2fs",
             target.width, target.height, meanCanvas, canvasSeconds))
print(String(format: "thumbnail                  mean %6.1f   %.2fs", meanThumb, thumbSeconds))
print(String(format: "\nRMS between them: %.2f   (brightness gap %+.1f)", rms, meanThumb - meanCanvas))

if let old {
    var oldSum = 0.0, oldMean = 0.0, n = 0
    for i in stride(from: 0, to: want.count, by: 4) {
        for c in 0..<3 {
            let d = old[i + c] - want[i + c]
            oldSum += d * d; oldMean += old[i + c]; n += 1
        }
    }
    print(String(format: "the path this replaced:  mean %6.1f   %.2fs   RMS %.2f",
                 oldMean / Double(n), oldSeconds, (oldSum / Double(n)).squareRoot()))
}

let a = blocked(want, target, 4), b = blocked(got, target, 4)
var coarse = 0.0
for i in 0..<min(a.count, b.count) { coarse += (b[i] - a[i]) * (b[i] - a[i]) }
coarse = (coarse / Double(min(a.count, b.count))).squareRoot()
print(String(format: "same picture? RMS over 4x4 blocks: %.2f", coarse))

// ⚠️ THE FLOOR IS NOT ZERO, and pretending otherwise would make this test
// fail forever. Decoding at 384 px is not the same operation as decoding at
// 5,176 px and averaging down, and no thumbnail pipeline makes it so.
// Decomposed on the client's NEF with his preset, 05.09:
//
//     full preset                    block RMS 5.42
//     with Sharpness/Clarity/Texture/Dehaze all at zero   3.60   <- the floor
//     draft mode off as well                              ~3.5
//
// So ~3.6 is the resolution itself, and the rest is the detail controls
// working in pixels. What must NOT come back is the tone gap: the picture the
// client reported was 30.7 levels darker at 36.2 RMS.
if coarse > 6.5 || abs(meanThumb - meanCanvas) > 2 {
    print("RESULT: the thumbnail does NOT match the canvas")
    exit(1)
}
print("RESULT: OK — the thumbnail matches the canvas")
exit(0)
