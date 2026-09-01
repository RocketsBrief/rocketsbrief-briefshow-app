import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let ctx = CIContext()
let extent = CGRect(x: 0, y: 0, width: 420, height: 260)
let longEdge = max(extent.width, extent.height)
let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!

func octave(_ cells: Double, _ weight: Double) -> CIImage {
    let cell = longEdge / cells
    return noise
        .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
        .applyingFilter("CIColorMonochrome", parameters: [
            kCIInputColorKey: CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            kCIInputIntensityKey: 1])
        .clampedToExtent()
        .applyingGaussianBlur(sigma: cell * 0.85)
        .cropped(to: extent)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
}

let summed = octave(42, 0.25)
    .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: octave(14, 0.75)])
    .cropped(to: extent)

// Read in LINEAR space — the space the filters themselves work in.
let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
let cg = ctx.createCGImage(summed, from: extent, format: .RGBA8, colorSpace: linear)!
let px = NSBitmapImageRep(cgImage: cg).bitmapData!
let n = Int(extent.width) * Int(extent.height)
var vals = (0..<n).map { Double(px[$0 * 4]) / 255.0 }
vals.sort()
func pct(_ p: Double) -> Double { vals[min(n - 1, Int(p * Double(n)))] }
print(String(format: "LINEAR  mean %.3f  p05 %.3f  p25 %.3f  p50 %.3f  p75 %.3f  p95 %.3f",
             vals.reduce(0,+)/Double(n), pct(0.05), pct(0.25), pct(0.50), pct(0.75), pct(0.95)))

// What band maps p05->0 and p95->1, and what coverage each threshold gives.
let lo = pct(0.05), hi = pct(0.95)
print(String(format: "suggested gain %.3f  bias %.3f", 1/(hi-lo), -lo/(hi-lo)))
for amount in [0.18, 0.35, 0.40, 0.45, 0.72, 0.85] {
    let t = min(max(1 - amount, 0.08), 0.88)
    let cut = lo + t * (hi - lo)
    let above = Double(vals.filter { $0 >= cut }.count) / Double(n)
    print(String(format: "amount %.2f -> threshold %.2f -> coverage %.2f", amount, t, above))
}
