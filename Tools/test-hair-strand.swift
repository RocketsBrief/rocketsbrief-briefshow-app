// Tests the ACTUAL hypothesis behind "Generative Clean Up didn't clean the
// hair, it did it like Quick" — see BRIEFSHOW_DEVELOP_NOTES.md, KORAK 107.
//
// The mechanism: DevelopInpaint.swift's own comment on the LaMa fill says the
// algorithm's *data* term "prefers fronts where a strong edge runs INTO the
// hole, which is what makes a railing or a horizon continue across the gap
// instead of being smeared over." A flyaway hair strand IS a strong, thin,
// linear edge. If the painted mask hugs the strand tightly, the unmasked
// pixels bordering the hole still show that edge — and the same behaviour
// that correctly continues a horizon may just as correctly continue the
// strand into the hole instead of erasing it.
//
// Both Quick and Generative call `SubjectMasker.grown(mask, by: 0.0025 *
// largerDimension)` — the SAME tiny growth. Generative's extra step (SD at
// refineStrength 0.3) is documented in KORAK 40 as barely touching LaMa's
// base once LaMa has filled the hole with something plausible, so if LaMa's
// own fill re-draws the strand, Generative has no real chance to remove what
// LaMa already put back.
//
// This is a SYNTHETIC test, not the client's photo — the client's files are
// on his machine, not this one. It exists to test the MECHANISM (a geometric
// property of how the algorithm scores fronts), which does not depend on
// which photograph the strand happens to be in. What it measures: does
// growing the mask further, before handing it to the real LaMa pipeline,
// stop the strand from being continued into the hole?
//
// Built and run by Tools/run-hair-strand-test.py, which copies the app's own
// DevelopInpaint.swift and DevelopLaMaInpaint.swift here — same rule as every
// other harness in this folder: what is measured is what ships.
import Foundation
import CoreImage
import AppKit

let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

// MARK: - The synthetic photo

// A bright, slightly noisy "sky" with a thin dark curved strand crossing it —
// a stand-in for a flyaway hair against an out-of-focus background, which is
// exactly the geometry in the client's screenshot (dark strand, bright sky).
let side = 900
var pixels = [UInt8](repeating: 0, count: side * side * 4)

// Deterministic "noise" so the test is reproducible without a seeded RNG
// dependency — a cheap hash of the coordinates.
func noise(_ x: Int, _ y: Int) -> Double {
    let n = sin(Double(x) * 12.9898 + Double(y) * 78.233) * 43758.5453
    return n - n.rounded(.down)
}

// The strand's centreline: a gently curved path, ~3px wide, matching the kind
// of single-hair thickness visible in the client's screenshot at full
// resolution.
//
// ⚠️ BOUNDED to the frame's middle third, not corner to corner. A strand
// spanning the WHOLE frame turns the mask into a near-full-height band, and
// `squareRegion` then has almost no real "known" sky left inside its own
// working square to copy from or to compare against — the first version of
// this test did exactly that, and the result was a wash: every growth radius
// looked about the same because the region itself was starved of context, not
// because growth stopped mattering. A real flyaway hair is a LOCAL mark near
// the head, not a seam across the whole photo, and the test should look like
// one.
let strandTop = Int(0.30 * Double(side))
let strandBottom = Int(0.62 * Double(side))
func strandDistance(_ x: Int, _ y: Int) -> Double {
    guard y >= strandTop, y <= strandBottom else { return .infinity }
    let t = Double(y - strandTop) / Double(strandBottom - strandTop)
    let curveX = 0.42 * Double(side) + 0.10 * Double(side) * sin(t * 2.4) + t * 0.08 * Double(side)
    return abs(Double(x) - curveX)
}

for y in 0..<side {
    for x in 0..<side {
        let index = (y * side + x) * 4
        let base = 225.0 + noise(x, y) * 12.0 // bright sky, mild texture
        let d = strandDistance(x, y)
        // Strand core is dark; it fades over ~2px so there is a real
        // anti-aliased edge for a tight mask to sit just outside of.
        let strand = max(0.0, 1.0 - d / 2.2)
        let value = base * (1 - strand) + 40.0 * strand
        let byte = UInt8(max(0, min(255, value.rounded())))
        pixels[index] = byte
        pixels[index + 1] = byte
        pixels[index + 2] = byte
        pixels[index + 3] = 255
    }
}

guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let cgPhoto = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
else {
    print("could not build the synthetic photo")
    exit(1)
}
let photo = CIImage(cgImage: cgPhoto)
let extent = photo.extent

// MARK: - The tight mask: exactly what a careful brush stroke gives

// White within 1.5px of the strand's centre — deliberately TIGHT, the way a
// client tracing a thin strand with a small brush would paint it, leaving the
// anti-aliased edge of the strand just outside the mask.
var maskBytes = [UInt8](repeating: 0, count: side * side)
for y in 0..<side {
    for x in 0..<side where strandDistance(x, y) <= 1.5 {
        maskBytes[y * side + x] = 255
    }
}
guard let maskProvider = CGDataProvider(data: Data(maskBytes) as CFData),
      let cgMask = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: side, space: CGColorSpace(name: CGColorSpace.linearGray)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: maskProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
else {
    print("could not build the mask")
    exit(1)
}
let tightMask = CIImage(cgImage: cgMask)

// MARK: - The growth radii to compare

// `SubjectMasker.grown(mask, by: max(width, height) * 0.0025)` is what BOTH
// Quick and Generative call TODAY, at whatever the photo's real dimensions
// are. On a 5176px NEF (the file measured in KORAK 39) that is ~13px — so
// that is the FIRST candidate here, not an arbitrary starting point.
let candidates: [(String, CGFloat)] = [
    ("current (13px, ~5176px NEF)", 13),
    ("20px", 20),
    ("30px", 30),
    ("45px", 45),
]

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hair-strand-out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

try? context.writePNGRepresentation(of: photo, to: outDir.appendingPathComponent("0-original.png"),
                                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

// MARK: - The metric
//
// Along the KNOWN strand path (we generated it, so we know exactly where it
// is), measure the mean |Laplacian| INSIDE the region the tight mask covered
// — i.e. exactly where the strand used to be — against the mean |Laplacian|
// in flat sky nearby, at the same y-range but away from the strand entirely.
// A fill that erased the strand leaves that ratio near 1. A fill that
// continued the strand into the hole leaves it far above 1, because the
// output still has a dark line running through pixels that used to be flat.
func laplacian(_ image: CIImage, x: Int, y: Int, bytes: UnsafePointer<UInt8>, stride: Int) -> Double {
    func luma(_ dx: Int, _ dy: Int) -> Double {
        Double(bytes[(y + dy) * stride + (x + dx) * 4])
    }
    return abs(4 * luma(0, 0) - luma(-1, 0) - luma(1, 0) - luma(0, -1) - luma(0, 1))
}

func residualStrandScore(_ result: CIImage) -> Double {
    var buffer = [UInt8](repeating: 0, count: side * side * 4)
    buffer.withUnsafeMutableBytes { raw in
        context.render(result, toBitmap: raw.baseAddress!, rowBytes: side * 4,
                       bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
    var onStrand: [Double] = []
    var offStrand: [Double] = []
    buffer.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
        // On-strand: exactly where the strand used to be, y bounded to where
        // it actually ran.
        for y in max(strandTop, 1)..<min(strandBottom, side - 1) {
            for x in 1..<(side - 1) where strandDistance(x, y) <= 1.5 {
                onStrand.append(laplacian(result, x: x, y: y, bytes: bytes, stride: side * 4))
            }
        }
        // Off-strand: a block in the frame's near corner, well outside the
        // strand's y-range AND far from it in x — plain sky the strand never
        // touched and no hole ever reached, at any growth radius tested.
        for y in stride(from: side - 120, to: side - 20, by: 1) {
            for x in stride(from: 20, to: 120, by: 1) {
                offStrand.append(laplacian(result, x: x, y: y, bytes: bytes, stride: side * 4))
            }
        }
    }
    let onMean = onStrand.reduce(0, +) / Double(max(onStrand.count, 1))
    let offMean = offStrand.reduce(0, +) / Double(max(offStrand.count, 1))
    return onMean / max(offMean, 0.01)
}

// MARK: - Run LaMa through each growth radius, exactly as quickAIRemoval does

guard LaMaInpaintPipeline.isAvailable else {
    print("LaMa is not available on this machine — checked the bundle and " +
          "~/Desktop/BriefShow/CoreMLModels/LaMa/LaMa.mlmodelc")
    exit(1)
}

print("synthetic photo \(side)x\(side), strand ~3px wide, tight mask 1.5px half-width\n")
print(String(format: "%-28@ %10@ %@", "growth radius" as NSString, "on/off ratio" as NSString, "reads as" as NSString))

for (label, radius) in candidates {
    let grownMask = SubjectMasker.grown(tightMask, by: radius)
    guard let maskBox = InpaintPipeline.maskBoundingBox(grownMask, extent: extent, context: context),
          let region = InpaintPipeline.squareRegion(around: maskBox, in: extent) else {
        print("\(label): could not compute a region")
        continue
    }
    let sideLength = LaMaInpaintPipeline.imageSide
    guard var buffers = InpaintPipeline.makeBuffers(
        image: photo, mask: grownMask, region: region,
        width: sideLength, height: sideLength, context: context
    ) else {
        print("\(label): could not build buffers")
        continue
    }
    let originalKnown = buffers.known
    do {
        try LaMaInpaintPipeline.shared.fill(&buffers)
    } catch {
        print("\(label): LaMa failed — \(error)")
        continue
    }
    guard let removal = InpaintPipeline.package(
        buffers: buffers, originalKnown: originalKnown, region: region, imageExtent: extent,
        growRadius: 2, blurRadius: InpaintPipeline.featherRadius(0.35, originalKnown: originalKnown, side: sideLength)
    ), let patch = CIImage(data: removal.pngData) else {
        print("\(label): packaging failed")
        continue
    }
    let target = CGRect(x: extent.minX + removal.boundsUnit.minX * extent.width,
                        y: extent.minY + (1 - removal.boundsUnit.minY - removal.boundsUnit.height) * extent.height,
                        width: removal.boundsUnit.width * extent.width,
                        height: removal.boundsUnit.height * extent.height)
    let placed = patch
        .transformed(by: CGAffineTransform(scaleX: target.width / patch.extent.width,
                                           y: target.height / patch.extent.height))
        .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
    let composited = placed.composited(over: photo).cropped(to: extent)

    let score = residualStrandScore(composited)
    let verdict = score < 1.3 ? "strand gone" : (score < 2.0 ? "faint residue" : "strand continued")
    print(String(format: "%-28@ %10.2f   %@", label as NSString, score, verdict as NSString))

    let safeName = label.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "(", with: "")
        .replacingOccurrences(of: ")", with: "").replacingOccurrences(of: ",", with: "")
    try? context.writePNGRepresentation(of: composited, to: outDir.appendingPathComponent("\(safeName).png"),
                                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

print("\nPNGs in \(outDir.path) — look at them, the ratio is a summary, not the whole story.")
