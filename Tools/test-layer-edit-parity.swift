// Does a slider on a LAYER do what the same slider on the PHOTO does?
//
// The client's report, 12.09: after Select People splits a photograph into a
// People layer and a Background layer, "taj edit nije uopšte isti kao main edit
// jedne slike" — clicking the People layer and moving Exposure or Contrast must
// land where the very same number lands on the plain photo in Create ▸ Edit.
//
// The two are different code. The photo goes through PhotoEditRenderer.render;
// a layer goes through applyLocalToneColorDetail, and a derived (People /
// Background) layer applies that to the photo's OWN rendered pixels through its
// matte. So the comparison that answers the client is exact:
//
//     A = render(photo with <slider> = v)
//     B = render(neutral photo + a full-frame derived layer, adjustments.<slider> = v)
//
// The matte is white everywhere, so B covers the whole frame and nothing else
// differs — any gap between A and B is the slider meaning two different things.
//
//     layer-parity <photo> [size] [only=<name>]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("layer-parity <photo> [size] [only=name]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 512) : 512
var only: String? = nil
for pair in args.dropFirst(2) where pair.hasPrefix("only=") {
    only = String(pair.dropFirst(5)).lowercased()
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

// A matte that is white everywhere: the layer IS the whole picture, so the two
// sides differ only in which code path put the tone on.
let matteExtent = CGRect(x: 0, y: 0, width: 256, height: 256)
let matte = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: matteExtent)
guard let maskPNG = ctx.pngRepresentation(of: matte, format: .RGBA8, colorSpace: srgb) else {
    print("could not build the matte"); exit(1)
}

// And one that is white on the left half only — used both to prove the photo
// UNDER a layer is left alone, and to time the realistic case, where the second
// decode is needed over part of the frame rather than all of it.
let leftHalf = CGRect(x: 0, y: 0, width: matteExtent.width / 2, height: matteExtent.height)
let halfMatte = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: leftHalf)
    .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: matteExtent))
guard let halfMaskPNG = ctx.pngRepresentation(of: halfMatte, format: .RGBA8, colorSpace: srgb) else {
    print("could not build the half matte"); exit(1)
}

func load() -> PhotoBaseImage? {
    PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size))
}

guard let probe = load() else { print("could not open \(url.path)"); exit(1) }
let probeExtent = PhotoEditRenderer.render(PhotoEditSettings(), on: probe).extent
let target = CGSize(width: probeExtent.width.rounded(), height: probeExtent.height.rounded())

func pixels(_ image: CIImage) -> [Double]? {
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

/// The photograph with one slider moved.
func photoSide(_ key: WritableKeyPath<PhotoEditSettings, Double>, _ value: Double) -> [Double]? {
    guard let base = load() else { return nil }
    var settings = PhotoEditSettings()
    settings[keyPath: key] = value
    return pixels(PhotoEditRenderer.render(settings, on: base))
}

/// The same photograph, untouched, under a full-frame People/Background layer
/// carrying that one slider instead.
func layerSide(_ key: WritableKeyPath<LocalAdjustmentSettings, Double>, _ value: Double) -> [Double]? {
    guard let base = load() else { return nil }
    var layer = ImageLayer(name: "People", imageData: Data(),
                           x: 0, y: 0, width: 1, height: 1, maskData: maskPNG)
    layer.adjustments[keyPath: key] = value
    var settings = PhotoEditSettings()
    settings.layers = [layer]
    return pixels(PhotoEditRenderer.render(settings, on: base))
}

// Each control, at a value a client would actually reach for. Sharpness,
// Texture and Clarity work in pixels; both sides here render at the same size,
// so they are comparable to each other even though neither matches full
// resolution (see run-thumbnail-parity-test.py for why that is expected).
let controls: [(String, WritableKeyPath<PhotoEditSettings, Double>, WritableKeyPath<LocalAdjustmentSettings, Double>, Double)] = [
    ("Exposure +0.50", \.exposure, \.exposure, 0.5),
    ("Exposure -0.50", \.exposure, \.exposure, -0.5),
    ("Contrast +0.50", \.contrast, \.contrast, 0.5),
    ("Contrast -0.50", \.contrast, \.contrast, -0.5),
    ("Highlights -0.50", \.highlights, \.highlights, -0.5),
    ("Shadows +0.50", \.shadows, \.shadows, 0.5),
    ("Whites +0.50", \.whites, \.whites, 0.5),
    ("Blacks -0.50", \.blacks, \.blacks, -0.5),
    ("Temperature +0.50", \.temperature, \.temperature, 0.5),
    ("Tint +0.50", \.tint, \.tint, 0.5),
    ("Saturation +0.50", \.saturation, \.saturation, 0.5),
    ("Vibrance +0.50", \.vibrance, \.vibrance, 0.5),
    ("Sharpness 0.50", \.sharpness, \.sharpness, 0.5),
    ("Texture +0.50", \.texture, \.texture, 0.5),
    ("Clarity +0.50", \.clarity, \.clarity, 0.5),
    ("Dehaze +0.50", \.dehaze, \.dehaze, 0.5),
    ("Soft Glow 0.50", \.softGlow, \.softGlow, 0.5),
    ("Vignette +0.50", \.vignette, \.vignette, 0.5),
]

print("photo:  \(url.lastPathComponent)   rendered \(Int(target.width))x\(Int(target.height))\n")
print("control              photo mean   layer mean      gap     RMS    worst")
print(String(repeating: "-", count: 68))

var failures: [String] = []

for (label, photoKey, layerKey, value) in controls {
    if let only, !label.lowercased().contains(only) { continue }
    guard let a = photoSide(photoKey, value), let b = layerSide(layerKey, value) else {
        print("\(label): render failed"); exit(1)
    }
    var sum = 0.0, meanA = 0.0, meanB = 0.0, worst = 0.0
    var counted = 0
    for i in stride(from: 0, to: a.count, by: 4) {
        for c in 0..<3 {
            let d = b[i + c] - a[i + c]
            sum += d * d
            worst = max(worst, abs(d))
            meanA += a[i + c]; meanB += b[i + c]
            counted += 1
        }
    }
    let rms = (sum / Double(counted)).squareRoot()
    meanA /= Double(counted); meanB /= Double(counted)

    // ⚠️ THE FLOOR IS NOT ZERO, but it is close. Both sides render the same
    // pixels at the same size through the same filters; the only unavoidable
    // difference is the blend through the matte, which is white everywhere.
    // Anything the client can see is well above this.
    let bad = rms > 1.0 || abs(meanB - meanA) > 0.5
    if bad { failures.append(label) }
    print(String(format: "%-20s %9.2f %12.2f %8.2f %7.2f %8.1f  %@",
                 (label as NSString).utf8String!, meanA, meanB, meanB - meanA, rms, worst,
                 bad ? "  <-- DIFFERENT" : ""))
}

// IS EXPOSURE A STOP? The client asked it as a question — *„ali taj exposure da
// radi exposure kao lightroom.. jel tako?"* — and it is answerable.
//
// Lightroom's Exposure is in stops: +1.00 doubles the light. Ours is the same
// number in the same unit, handed to CIRAWFilter.exposure on a RAW and to
// CIExposureAdjust.ev otherwise, both of which multiply LINEAR light by 2^EV.
// Narrowing the slider to ±1 on 12.09 changed how far the thumb travels, not
// what a value means — so what is checked is the ratio, measured in a LINEAR
// colour space, where a stop is a factor of two.
//
// ⚠️ Linear, not sRGB. In sRGB the ratio comes out near 1.5 because of the
// transfer curve, and reading that as "not a stop" would be the ruler's fault,
// not the code's. And only pixels well below clipping count: a highlight that
// is already at white cannot double, in Lightroom either.
//
// ⚠️ AND THE ANSWER IS DIFFERENT ON A RAW, which cost this check one wrong
// reading before it was written properly. Measured 12.09 on the same
// photograph, +1.00 EV, median over ~300k unclipped samples:
//
//     C4S_7891.NEF     1.688
//     the same frame as a JPEG     2.000
//
// The JPEG number is the plain one: CIExposureAdjust multiplies linear light
// by 2^EV and nothing follows it. On the RAW the stop goes into the DECODER,
// before the RAW pipeline lays its own tone curve over the result — so the
// finished picture is a stop brighter in the scene, and less than twice as
// bright on screen. That is not a miscalibration; it is what Exposure does in
// Lightroom too, and it is the reason this app puts the number into
// CIRAWFilter.exposure rather than over the pixels afterwards.
if only == nil {
    let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
    let linearContext = CIContext(options: [.workingColorSpace: linear])

    func linearPixels(_ settings: PhotoEditSettings) -> [Double]? {
        guard let base = load() else { return nil }
        let image = PhotoEditRenderer.render(settings, on: base)
        guard let cg = linearContext.createCGImage(image, from: image.extent,
                                                   format: .RGBAf, colorSpace: linear),
              let data = cg.dataProvider?.data as Data? else { return nil }
        return data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            return (0..<floats.count).map { Double(floats[$0]) }
        }
    }

    var neutral = PhotoEditSettings()
    var oneStop = PhotoEditSettings()
    oneStop.exposure = 1

    if let dark = linearPixels(neutral), let bright = linearPixels(oneStop), dark.count == bright.count {
        // ⚠️ MIDTONES ONLY, and that is the point rather than a convenience.
        // Since 12.09 Exposure is not a flat 2^EV any more — it carries a
        // shoulder, so a tone near white deliberately moves LESS than a stop
        // (see ExposureCurve). Averaged over the whole frame this reads ~1.7
        // and means nothing. Where the stop must be exact is around middle
        // grey, 0.18 in linear light, which is the pivot the curve is built
        // around; a window either side of it is what is scored.
        var ratios: [Double] = []
        for i in stride(from: 0, to: dark.count, by: 4) {
            for c in 0..<3 where dark[i + c] > 0.08 && dark[i + c] < 0.30 {
                ratios.append(bright[i + c] / dark[i + c])
            }
        }
        ratios.sort()
        let median = ratios.isEmpty ? 0 : ratios[ratios.count / 2]

        var isRAW = false
        if let base = load(), case .raw = base { isRAW = true }

        print()
        print(String(format: "Exposure +1.00 around middle grey: ×%.3f  (over %d samples, %@)",
                     median, ratios.count, isRAW ? "RAW — decoder, then its tone curve" : "not RAW"))

        if isRAW {
            // A stop went in; the decoder's own tone curve is what keeps the
            // finished ratio under two. Bounded on BOTH sides: below 1.35 the
            // stop is being swallowed, at or above 2 it is not going through
            // the decoder's tone mapping at all.
            if median < 1.35 || median >= 2.0 {
                failures.append("Exposure +1.00 on a RAW (\(String(format: "%.3f", median)))")
            }
        } else if abs(median - 2) > 0.05 {
            // Nothing follows the curve on a JPEG, so middle grey has to land
            // on exactly one stop.
            failures.append("Exposure +1.00 is not one stop at middle grey (\(String(format: "%.3f", median)))")
        }
    }
}

// ⚠️ THE CHECK A FULL MATTE CANNOT MAKE, and it is the dangerous one.
//
// A RAW PhotoBaseImage carries ONE shared CIRAWFilter, and `rawShiftedPhoto`
// re-renders through that same instance with different numbers on it. If
// `filter.outputImage` were not a snapshot of the parameters as they stood, the
// second pass would reach back and move the photograph UNDER the layer too —
// the client would touch the People layer and watch the whole frame shift.
//
// With a white-everywhere matte that is invisible: the layer is the whole
// picture, so a corrupted underneath has nowhere to show. So the matte here is
// white on the left half and black on the right, and the two halves are scored
// against different references: the left must be the photo WITH the slider, the
// right must be the photo WITHOUT it, in one render.
if only == nil {
    /// Mean of one half of the frame. `left` picks the columns the white half
    /// of the matte covers.
    func halfMean(_ p: [Double], left: Bool) -> Double {
        let w = Int(target.width), h = Int(target.height)
        // The two columns either side of the matte's edge are a blend of both,
        // so they belong to neither reference — skipped rather than fudged.
        let margin = max(2, w / 64)
        var sum = 0.0
        var counted = 0
        for y in 0..<h {
            for x in 0..<w {
                let inLeft = x < w / 2 - margin
                let inRight = x > w / 2 + margin
                guard left ? inLeft : inRight else { continue }
                for c in 0..<3 {
                    sum += p[(y * w + x) * 4 + c]
                    counted += 1
                }
            }
        }
        return sum / Double(counted)
    }

    let value = 0.5
    guard let withSlider = photoSide(\.exposure, value),
          let untouched = photoSide(\.exposure, 0) else {
        print("half-matte references failed"); exit(1)
    }

    guard let base = load() else { print("half-matte render failed"); exit(1) }
    var layer = ImageLayer(name: "People", imageData: Data(),
                           x: 0, y: 0, width: 1, height: 1, maskData: halfMaskPNG)
    layer.adjustments.exposure = value
    var settings = PhotoEditSettings()
    settings.layers = [layer]
    guard let mixed = pixels(PhotoEditRenderer.render(settings, on: base)) else {
        print("half-matte render failed"); exit(1)
    }

    let insideWanted = halfMean(withSlider, left: true)
    let insideGot = halfMean(mixed, left: true)
    let outsideWanted = halfMean(untouched, left: false)
    let outsideGot = halfMean(mixed, left: false)

    print()
    print("half matte — Exposure +0.50 on the LEFT half only")
    print(String(format: "  inside the layer   want %6.2f   got %6.2f   gap %+5.2f", insideWanted, insideGot, insideGot - insideWanted))
    print(String(format: "  the photo outside  want %6.2f   got %6.2f   gap %+5.2f", outsideWanted, outsideGot, outsideGot - outsideWanted))

    if abs(insideGot - insideWanted) > 0.5 {
        failures.append("half matte: inside the layer")
    }
    if abs(outsideGot - outsideWanted) > 0.5 {
        failures.append("half matte: the photo OUTSIDE the layer moved")
    }
    print()
}

// What the second decode COSTS, at the resolution the client actually drags a
// slider against (loadPreviewBaseImage is 2600). Printed, not judged: a timing
// is not a verdict and a slow machine must not fail a correctness test. It is
// here so the price of `rawShiftedPhoto` is on the record next to the gap it
// closes, and so a future session that finds it too dear knows what it is
// buying back.
if only == nil {
    func timed(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    func preview() -> PhotoBaseImage? { PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: 2600) }

    // ⚠️ `render(toBitmap:)`, NOT `createCGImage` — and this cost two wrong
    // readings before it was believed.
    //
    // Core Image is lazy twice over. `createCGImage` hands back a CGImage that
    // is itself not rendered until something DRAWS it, so timing that call
    // reported the native-resolution render as 0.00s: not a fast render, no
    // render at all. (At 2600 px the number looked plausible only because the
    // parity measurements above draw their CGImage into a bitmap afterwards.)
    // Writing into memory the caller owns cannot be deferred.
    @discardableResult
    func realise(_ image: CIImage) -> Bool {
        // Spelled out rather than CGRect.isFinite, which needs macOS 15 and
        // this app ships back to 13.
        guard image.extent.width.isFinite, image.extent.height.isFinite else { return false }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                       bounds: image.extent, format: .RGBA8, colorSpace: srgb)
        }
        return true
    }

    var withLayer = PhotoEditSettings()
    // ⚠️ The HALF matte, deliberately. Under a white-everywhere matte the photo
    // underneath is completely hidden, and Core Image's region-of-interest then
    // has no reason to render it at all — the timing would show the cost of the
    // second decode while quietly dropping the first, which is not the shape of
    // anything a client does. Half and half is a People layer's real shape.
    var layer = ImageLayer(name: "People", imageData: Data(),
                           x: 0, y: 0, width: 1, height: 1, maskData: halfMaskPNG)
    layer.adjustments.exposure = 0.5
    withLayer.layers = [layer]

    /// The BEST of three, after a warm-up that is thrown away.
    ///
    /// ⚠️ The first version of this block reported the layered render as
    /// FASTER than the plain one, which is impossible — it does strictly more
    /// work. The first render in the process pays for Core Image building its
    /// kernels and the RAW pipeline waking up, and that one-off landed on
    /// whichever side ran first. Same family as the note at the top of
    /// test-thumbnail-parity.swift: a timing that measures the harness instead
    /// of the code reports a finding that is not there.
    func best(_ settings: PhotoEditSettings) -> Double {
        var fastest = Double.infinity
        for run in 0..<4 {
            guard let base = preview() else { continue }
            let seconds = timed { realise(PhotoEditRenderer.render(settings, on: base)) }
            if run > 0 { fastest = min(fastest, seconds) }   // run 0 is the warm-up
        }
        return fastest
    }

    _ = best(PhotoEditSettings())   // warm the process itself, before either side is timed
    let plain = best(PhotoEditSettings())
    let layered = best(withLayer)
    print(String(format: "at 2600 px: photo alone %.2fs   with a layer carrying Exposure %.2fs   (%+.2fs)",
                 plain, layered, layered - plain))

    // And once at the file's own resolution, which is what the export and the
    // refined render use — and the only place on an 8 GB machine where a second
    // decode could be more than a timing.
    // Best of three here too. A single native render read 0.32s plain against
    // 0.24s layered — the layered side doing strictly more work in less time,
    // which is the same "impossible" reading the warm-up note above describes,
    // and at this size one run is simply too noisy to subtract.
    func nativeBest(_ settings: PhotoEditSettings) -> Double {
        var fastest = Double.infinity
        for _ in 0..<3 {
            guard let base = PhotoEditRenderer.loadBaseImage(from: url) else { continue }
            var made = false
            let seconds = timed { made = realise(PhotoEditRenderer.render(settings, on: base)) }
            if made { fastest = min(fastest, seconds) }
        }
        return fastest
    }
    _ = nativeBest(PhotoEditSettings())
    let nativePlain = nativeBest(PhotoEditSettings())
    let nativeLayered = nativeBest(withLayer)
    print(String(format: "at native:  photo alone %.2fs   with a layer carrying Exposure %.2fs   (%+.2fs)",
                 nativePlain, nativeLayered, nativeLayered - nativePlain))
    print()
}

if failures.isEmpty {
    print("RESULT: OK — every slider means the same thing on a layer as on the photo")
    exit(0)
}
print()
print("RESULT: \(failures.count) of the sliders do NOT match: \(failures.joined(separator: ", "))")
exit(1)
