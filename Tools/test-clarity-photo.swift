// Clarity on a real photograph, with the OLD path computed alongside.
//
// ⚠️ THE COLUMNS ARE LOCAL CONTRAST, NOT BRIGHTNESS. Clarity is not supposed to
// move a mean anywhere — it is supposed to change how far a pixel sits from its
// own neighbourhood. So every column is the RMS of (pixel − the average of the
// 5×5 around it), measured inside a band chosen on the untouched render, and the
// bands are the spec's: the midtones are where the work belongs, the highlights
// and the shadows are where the mask is supposed to keep it out.
//
//     clarity-photo <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("clarity-photo <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1400) : 1400

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

var width = 0, height = 0

func render(_ image: CIImage) -> [Double]? {
    let w = Int(image.extent.width), h = Int(image.extent.height)
    guard w > 0, h > 0 else { return nil }
    width = w; height = h
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                   bounds: image.extent, format: .RGBA8, colorSpace: srgb)
    }
    var luma = [Double](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        luma[i] = 0.2126 * Double(buffer[i * 4]) + 0.7152 * Double(buffer[i * 4 + 1])
                + 0.0722 * Double(buffer[i * 4 + 2])
    }
    return luma
}

func photo(_ clarity: Double, old: Bool) -> [Double]? {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else { return nil }
    var settings = PhotoEditSettings()
    if !old { settings.clarity = clarity }
    var image = PhotoEditRenderer.render(settings, on: base)
    if old && clarity != 0 {
        // The shipping path exactly: CIUnsharpMask one way, a mix toward a
        // Gaussian of the same radius the other.
        let extent = image.extent
        let radius = min(max(Double(max(extent.width, extent.height)) * 0.02, 8), 100)
        if clarity > 0 {
            let f = CIFilter(name: "CIUnsharpMask")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(radius, forKey: kCIInputRadiusKey)
            f.setValue(min(clarity, 1) * 0.8, forKey: kCIInputIntensityKey)
            image = (f.outputImage ?? image).cropped(to: extent)
        } else {
            let blurred = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
            let mix = CGFloat(min(-clarity, 1) * 0.6)
            let f = CIFilter(name: "CIBlendWithMask")!
            f.setValue(blurred, forKey: kCIInputImageKey)
            f.setValue(image, forKey: kCIInputBackgroundImageKey)
            f.setValue(CIImage(color: CIColor(red: mix, green: mix, blue: mix)).cropped(to: extent),
                       forKey: kCIInputMaskImageKey)
            image = (f.outputImage ?? image).cropped(to: extent)
        }
    }
    return render(image)
}

guard let neutral = photo(0, old: false) else { print("could not open \(url.path)"); exit(1) }
let w = width, h = height

/// How far each pixel sits from the average of the 5×5 around it — the thing
/// Clarity moves, computed once per render and then read per band.
func localContrast(_ luma: [Double]) -> [Double] {
    var out = [Double](repeating: 0, count: w * h)
    for y in 2..<(h - 2) {
        for x in 2..<(w - 2) {
            var sum = 0.0
            for dy in -2...2 {
                for dx in -2...2 { sum += luma[(y + dy) * w + x + dx] }
            }
            out[y * w + x] = luma[y * w + x] - sum / 25
        }
    }
    return out
}

let neutralDetail = localContrast(neutral)

var shadowBand: [Int] = [], midBand: [Int] = [], highBand: [Int] = []
for y in 2..<(h - 2) {
    for x in 2..<(w - 2) {
        let i = y * w + x
        switch neutral[i] {
        case ..<40: shadowBand.append(i)
        case 100..<180: midBand.append(i)
        case 215...: highBand.append(i)
        default: break
        }
    }
}

func rms(_ detail: [Double], over indices: [Int]) -> Double {
    guard !indices.isEmpty else { return 0 }
    return (indices.map { detail[$0] * detail[$0] }.reduce(0, +) / Double(indices.count)).squareRoot()
}
func mean(_ luma: [Double], over indices: [Int]) -> Double {
    guard !indices.isEmpty else { return 0 }
    return indices.reduce(0.0) { $0 + luma[$1] } / Double(indices.count)
}

print("photo: \(url.lastPathComponent)  (\(w)x\(h))")
print(String(format: "bands: shadows %d (%.1f%%)  midtones %d (%.1f%%)  highlights %d (%.1f%%)\n",
             shadowBand.count, Double(shadowBand.count) / Double(w * h) * 100,
             midBand.count, Double(midBand.count) / Double(w * h) * 100,
             highBand.count, Double(highBand.count) / Double(w * h) * 100))

print("Clarity          MIDTONES     shadows   highlights    midtone mean")
print(String(repeating: "-", count: 66))

let restMid = rms(neutralDetail, over: midBand)
let restShadow = rms(neutralDetail, over: shadowBand)
let restHigh = rms(neutralDetail, over: highBand)
let restMean = mean(neutral, over: midBand)
var liftedMid = 0.0, softenedMid = .infinity as Double
var worstHighDrift = 0.0, worstShadowDrift = 0.0
var oldHighDrift = 0.0, oldShadowDrift = 0.0
var worstMeanDrift = 0.0

for amount in [0.0, 0.5, 1.0, -0.5, -1.0] {
    for old in [false, true] {
        guard let luma = photo(amount, old: old) else { continue }
        let detail = localContrast(luma)
        let m = rms(detail, over: midBand), s = rms(detail, over: shadowBand), hi = rms(detail, over: highBand)
        print(String(format: "%-15@ %9.3f %11.3f %12.3f %15.2f",
                     (old ? "      before" : String(format: "%+.2f  now", amount)) as NSString,
                     m, s, hi, mean(luma, over: midBand)))
        if amount == 0 { break }
        if old {
            oldHighDrift = max(oldHighDrift, abs(hi - restHigh))
            oldShadowDrift = max(oldShadowDrift, abs(s - restShadow))
        } else {
            if amount > 0 { liftedMid = max(liftedMid, m) } else { softenedMid = min(softenedMid, m) }
            worstHighDrift = max(worstHighDrift, abs(hi - restHigh))
            worstShadowDrift = max(worstShadowDrift, abs(s - restShadow))
            worstMeanDrift = max(worstMeanDrift, abs(mean(luma, over: midBand) - restMean))
        }
    }
}

print()
print(String(format: "midtone local contrast: %.3f at rest, %.3f at +100, %.3f at -100", restMid, liftedMid, softenedMid))
print(String(format: "highlights moved by at most %.3f   (the old path: %.3f)", worstHighDrift, oldHighDrift))
print(String(format: "shadows moved by at most    %.3f   (the old path: %.3f)", worstShadowDrift, oldShadowDrift))
print(String(format: "the midtone mean drifted by %.2f of a level", worstMeanDrift))
print()

var failed = false
if liftedMid <= restMid {
    print("FAIL: Clarity +100 did not raise the midtone local contrast at all.")
    failed = true
}
if softenedMid >= restMid {
    print("FAIL: Clarity -100 did not soften the midtones.")
    failed = true
}
// ⚠️ THE MASK IS THE CLAIM, and the comparison is against the path this
// replaced rather than against zero: a cube quantises and a bilateral filter is
// not the identity anywhere, so "untouched" means "moved less than the control
// that had no mask at all".
if worstHighDrift >= oldHighDrift {
    print("FAIL: the highlights moved as much as they did through the old, unmasked path.")
    failed = true
}
if worstShadowDrift >= oldShadowDrift {
    print("FAIL: the shadows moved as much as they did through the old, unmasked path.")
    failed = true
}
// Clarity changes where a pixel sits against its neighbours, not how bright the
// picture is. A mean that walks is an exposure shift hiding in a texture control.
if worstMeanDrift > 2.0 {
    print("FAIL: the midtones changed brightness — Clarity is local contrast, not exposure.")
    failed = true
}
if !failed {
    print("The midtones gained and lost their local contrast on demand, the extremes stayed put,")
    print("and the picture did not change brightness.")
}
exit(failed ? 1 : 0)
