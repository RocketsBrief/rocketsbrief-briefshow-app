// Clarity, proved on the two things it has to tell apart: an edge and a texture.
//
// ⚠️ THIS ONE CANNOT BE A TABLE TEST. Every other control in this family maps a
// pixel to a pixel, so its test can walk a ramp; Clarity is a SPATIAL operation
// — what it does to a pixel depends on its neighbours — so the instrument is a
// synthetic picture with a known edge and a known texture, and the columns are
// what happened to each of them.
//
//     clarity-local-contrast
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

var failures = 0
func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed { print("  ok    \(label)") }
    else { failures += 1; print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")") }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

let W = 480, H = 120
let rect = CGRect(x: 0, y: 0, width: W, height: H)

/// A step edge with fine texture on both sides — the two things Clarity treats
/// differently — and the mask's business is WHERE on the ramp they sit.
///
/// ⚠️ THE TEXTURE IS KEPT AWAY FROM THE EDGE, and the first version of this
/// harness did not do that and could not measure what it claimed. With ripple
/// running right up to the step, the brightest pixel beside the edge is a
/// ripple peak, so "the rim beside the edge" grew simply because the texture
/// grew — the reading came out 32 for a path whose halo is 1.7, and the control
/// that is supposed to be the WHOLE POINT of this file measured almost nothing.
/// A flat corridor either side of the step leaves a rim that is halo and
/// nothing else.
func plate(left: Double, right: Double, texture: Double = 0.05) -> CIImage {
    var bytes = [UInt8](repeating: 255, count: W * H * 4)
    for y in 0..<H {
        for x in 0..<W {
            let i = (y * W + x) * 4
            let step = x < W / 2 ? left : right
            let awayFromTheEdge = (x < 180 || x > 300) ? 1.0 : 0.0
            let ripple = awayFromTheEdge * texture * sin(Double(x) * 1.1) * cos(Double(y) * 0.9)
            let v = UInt8(min(max((step + ripple) * 255, 0), 255))
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
        }
    }
    return CIImage(bitmapData: Data(bytes), bytesPerRow: W * 4,
                   size: CGSize(width: W, height: H), format: .RGBA8, colorSpace: srgb)
}

func row(_ image: CIImage, at y: Int = 60) -> [Double] {
    var px = [Float](repeating: 0, count: W * 4)
    px.withUnsafeMutableBytes { raw in
        ctx.render(image.cropped(to: rect), toBitmap: raw.baseAddress!, rowBytes: W * 16,
                   bounds: CGRect(x: 0, y: y, width: W, height: 1), format: .RGBAf, colorSpace: srgb)
    }
    return (0..<W).map { Double(px[$0 * 4]) }
}

/// The texture, as levels of RMS, measured well away from the edge.
func texture(_ p: [Double]) -> Double {
    let slice = Array(p[320..<460])
    let mean = slice.reduce(0, +) / Double(slice.count)
    return (slice.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(slice.count)).squareRoot() * 255
}

/// The halo: how far the brightest pixel just past the edge stands above the
/// FLAT corridor beside it — not above the textured part, see `plate`.
func overshoot(_ p: [Double]) -> Double {
    let flat = Array(p[270..<300]).reduce(0, +) / 30
    let rim = Array(p[241..<268]).max() ?? flat
    return (rim - flat) * 255
}

func clarity(_ amount: Double, on image: CIImage) -> CIImage {
    PhotoEditRenderer.applyClarity(amount, to: image)
}

/// The path this replaced: CIUnsharpMask at the same radius, which is the same
/// arithmetic with a Gaussian base.
func oldClarity(_ amount: Double, on image: CIImage) -> CIImage {
    let radius = min(max(Double(max(W, H)) * 0.02, 8), 100)
    if amount > 0 {
        let f = CIFilter.unsharpMask()
        f.inputImage = image
        f.radius = Float(radius)
        f.intensity = Float(min(amount, 1) * 0.8)
        return (f.outputImage ?? image).cropped(to: rect)
    }
    let blurred = image.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: rect)
    let mix = CGFloat(min(-amount, 1) * 0.6)
    let blend = CIFilter.blendWithMask()
    blend.inputImage = blurred
    blend.backgroundImage = image
    blend.maskImage = CIImage(color: CIColor(red: mix, green: mix, blue: mix)).cropped(to: rect)
    return (blend.outputImage ?? image).cropped(to: rect)
}

let midtones = plate(left: 0.35, right: 0.62)

print("\nClarity 0 changes nothing at all")
let untouched = row(clarity(0, on: midtones))
let source = row(midtones)
check("the identity, exactly, not nearly",
      zip(untouched, source).allSatisfy { abs($0 - $1) < 1e-9 })

// ⚠️ THE MEASUREMENT THAT CONDEMNED THE OLD PATH, and the reason the spec says
// *„Izbegavaj prosti Gaussian blur jer uzrokuje pojavu oreola (halos)"*.
print("\nno halo against an edge — the Gaussian's whole problem")
let boostedNow = row(clarity(1, on: midtones))
let boostedBefore = row(oldClarity(1, on: midtones))
print(String(format: "  ..    overshoot beside the edge: source %.2f, before %.2f, now %.2f levels",
             overshoot(source), overshoot(boostedBefore), overshoot(boostedNow)))
check("the rim beside the edge is a fraction of what the old path left",
      overshoot(boostedNow) < overshoot(boostedBefore) / 5,
      String(format: "%.2f against %.2f", overshoot(boostedNow), overshoot(boostedBefore)))

print("\nand the texture it is actually for does go up")
print(String(format: "  ..    texture: source %.2f, before %.2f, now %.2f levels",
             texture(source), texture(boostedBefore), texture(boostedNow)))
check("Clarity +100 lifts the texture", texture(boostedNow) > texture(source) * 1.1,
      String(format: "%.2f → %.2f", texture(source), texture(boostedNow)))

// The spec's mask: nothing in the clouds, nothing in the blocked-up shadows.
print("\nthe midtone mask — the extremes are left alone")
let highlights = plate(left: 0.88, right: 0.97, texture: 0.02)
let shadows = plate(left: 0.02, right: 0.06, texture: 0.015)
for (name, plateImage) in [("highlights", highlights), ("shadows", shadows)] {
    let before = texture(row(plateImage))
    let now = texture(row(clarity(1, on: plateImage)))
    let was = texture(row(oldClarity(1, on: plateImage)))
    check("\(name) barely move at Clarity +100",
          abs(now - before) < abs(was - before),
          String(format: "%.2f → %.2f now, %.2f through the old path", before, now, was))
}
let midBefore = texture(source)
let midNow = texture(boostedNow)
check("while the midtones are where the work happens",
      (midNow - midBefore) / midBefore > 0.10,
      String(format: "%.0f%% more texture", (midNow - midBefore) / midBefore * 100))

// ⚠️ THE NEGATIVE HALF IS NOT "BLUR EVERYTHING" — the spec asks for the mid
// frequencies to go soft while the sharp edges stay, which is exactly what
// subtracting a band bounded at both ends does, and exactly what the old path
// (a mix toward a Gaussian) could not do.
print("\nnegative Clarity softens the texture and keeps the edge")
let softNow = row(clarity(-1, on: midtones))
let softBefore = row(oldClarity(-1, on: midtones))
check("the texture goes down", texture(softNow) < texture(source),
      String(format: "%.2f → %.2f", texture(source), texture(softNow)))
func edgeHeight(_ p: [Double]) -> Double {
    (Array(p[300..<460]).reduce(0, +) / 160 - Array(p[20..<180]).reduce(0, +) / 160) * 255
}
func edgeRise(_ p: [Double]) -> Double { (p[245] - p[235]) * 255 }
print(String(format: "  ..    the step's own rise across 10 px: source %.1f, before %.1f, now %.1f levels",
             edgeRise(source), edgeRise(softBefore), edgeRise(softNow)))
check("but the edge itself survives, where the old path smeared it",
      edgeRise(softNow) > edgeRise(softBefore),
      String(format: "%.1f against %.1f", edgeRise(softNow), edgeRise(softBefore)))
check("and the step is still the same height",
      abs(edgeHeight(softNow) - edgeHeight(source)) < 2,
      String(format: "%.1f → %.1f", edgeHeight(source), edgeHeight(softNow)))

// ⚠️ THE BOUND THAT KEEPS THE NEGATIVE HALF HONEST. It subtracts `strength` of
// the mid band, so at 1.0 it removes it exactly and anything above would turn it
// inside out — texture coming back as its own negative.
print("\nthe strength cannot invert the texture")
check("strength is at most 1.0", ClarityLocalContrast.strength <= 1.0,
      String(format: "%.2f", ClarityLocalContrast.strength))
var stillRight = true
for amount in stride(from: -1.0, through: -0.1, by: 0.1) {
    let p = row(clarity(amount, on: midtones))
    if zip(p, source).map({ ($0 - $1) }).reduce(0, +).isNaN { stillRight = false }
    if texture(p) > texture(source) + 1e-9 { stillRight = false }
}
check("no setting on the left half ever raises the texture", stillRight)

print("\nmonotonic in the slider")
var rising = true
var previousTexture = -1.0
for amount in stride(from: -1.0, through: 1.0, by: 0.25) {
    let t = texture(row(clarity(amount, on: midtones)))
    if t < previousTexture - 0.01 { rising = false }
    previousTexture = t
}
check("dragging right never takes texture away", rising)

print("\nthe mask table is the mask")
let cube = ClarityMaskCube.data()
check("the table is the size CIColorCube expects",
      cube.count == ClarityMaskCube.dimension * ClarityMaskCube.dimension
                    * ClarityMaskCube.dimension * 4 * MemoryLayout<Float>.size)
cube.withUnsafeBytes { raw in
    let floats = raw.bindMemory(to: Float.self)
    let dimension = ClarityMaskCube.dimension
    var worst = 0.0
    for blue in stride(from: 0, to: dimension, by: 7) {
        for green in stride(from: 0, to: dimension, by: 7) {
            for red in stride(from: 0, to: dimension, by: 7) {
                let index = ((blue * dimension + green) * dimension + red) * 4
                let r = ExposureCube.toLinear(Double(red) / Double(dimension - 1))
                let g = ExposureCube.toLinear(Double(green) / Double(dimension - 1))
                let b = ExposureCube.toLinear(Double(blue) / Double(dimension - 1))
                let wanted = ClarityLocalContrast.midtoneWeight(OKLab.from(r: r, g: g, b: b).L)
                worst = max(worst, abs(Double(floats[index]) - wanted))
            }
        }
    }
    check("every entry is the midtone weight of its own lightness", worst < 1e-6,
          String(format: "%.8f", worst))
}
check("the mask is exactly zero outside the spec's band",
      ClarityLocalContrast.midtoneWeight(0.15) == 0
      && ClarityLocalContrast.midtoneWeight(0.10) == 0
      && ClarityLocalContrast.midtoneWeight(0.85) == 0
      && ClarityLocalContrast.midtoneWeight(0.92) == 0)
check("and strongest at the middle",
      ClarityLocalContrast.midtoneWeight(0.50) == 1)

print("\nwhat it costs")
for (w, h) in [(2600, 1733), (5176, 3448)] {
    var bytes = [UInt8](repeating: 128, count: w * h * 4)
    for i in stride(from: 0, to: bytes.count, by: 4) {
        let v = UInt8(100 + (i / 4 % 37))
        bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
    }
    let big = CIImage(bitmapData: Data(bytes), bytesPerRow: w * 4,
                      size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: srgb)
    func time(_ image: CIImage) -> Double {
        let started = Date()
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: srgb)
        }
        return Date().timeIntervalSince(started) * 1000
    }
    print(String(format: "  ..    %dx%d: neutral %.0f ms, Clarity +100 %.0f ms",
                 w, h, time(big), time(clarity(1, on: big))))
}

// ⚠️ THE MUST. One implementation, called by the photo and by a layer.
print("\nthe one place — Clarity has a single implementation")
let develop = (try? String(contentsOfFile: CommandLine.arguments.count > 1
                           ? CommandLine.arguments[1] : "BriefShow/Develop.swift",
                           encoding: .utf8)) ?? ""
if develop.isEmpty {
    check("Develop.swift could be read", false, "pass its path as argv[1]")
} else {
    let callSites = develop.components(separatedBy: "applyClarity(").count - 2
    check("the photo and a layer both call applyClarity", callSites >= 2, "\(callSites) call sites")
    // ⚠️ INSIDE applyClarity, NOT IN THE WHOLE FILE — the first version of this
    // check searched the file and failed on `applyTexture`, which is a
    // CIUnsharpMask on purpose and is a different control.
    let body: String = {
        guard let start = develop.range(of: "static func applyClarity("),
              let end = develop.range(of: "\n    }\n", range: start.upperBound..<develop.endIndex)
        else { return "" }
        return String(develop[start.lowerBound..<end.upperBound])
    }()
    check("applyClarity could be read out of the source", !body.isEmpty)
    check("and it no longer runs on a Gaussian base",
          !body.contains("unsharpMask") && !body.contains("CIGaussianBlur"))
    check("the base is the edge-preserving one",
          body.contains("edgePreservingBase(of: image"))
}

print()
if failures == 0 { print("all good"); exit(0) }
print("\(failures) checks failed")
exit(1)
