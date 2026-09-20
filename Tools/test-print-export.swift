// What comes out of Export when the photograph is a print.
//
// Two halves of one fact, and both are measured by writing real files and
// reading them back:
//
//   1. the PIXELS are the paper — 8×10 at 300 dpi is 3000×2400, whether the
//      frame is still live on the record or already baked into the photo. It
//      was not: a baked print carries however many pixels the bake needed to
//      keep the photograph at its own resolution, so the same template
//      exported two different sizes.
//   2. the FILE SAYS 300 dpi. The same pixels at the default 72 are a print a
//      lab will scale or refuse — the client would be holding a 41-inch
//      "8 × 10".
//
// briefShowFitToPrintCanvas comes from the real Templates.swift, which this is
// compiled against. briefShowExportData and ExportFormat are pasted in out of
// Develop.swift by the runner.
//
//     print-export
import Foundation
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

// What the app hands the encoder, by the same two names.
let briefEditsCIContext = CIContext(options: [.useSoftwareRenderer: true])
let briefEditsSRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// ---- the real encoder, pasted in by the extractor at run time -------------

func colour(_ width: Double, _ height: Double) -> CIImage {
    CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

// MARK: - The pixels are the paper

print("\nthe print comes out as its paper, whatever it was rendered at")

let canvas = CGSize(width: 3000, height: 2400)      // 8 × 10 at 300 dpi

do {
    // A LIVE record: the composition already draws the canvas at 1×.
    let live = briefShowFitToPrintCanvas(colour(3000, 2400), canvas: canvas)
    check("a live print is already the paper and is left alone",
          live.extent.width == 3000 && live.extent.height == 2400,
          "\(live.extent.size)")

    // A BAKED print: briefShowBakeCanvasScale grew the canvas so the
    // photograph kept its own pixels. 1.7 is the sort of number it produces.
    let baked = briefShowFitToPrintCanvas(colour(5100, 4080), canvas: canvas)
    check("a baked print lands on the same paper",
          baked.extent.width == 3000 && baked.extent.height == 2400,
          "\(baked.extent.size)")

    // And the other way: a bake smaller than the paper is brought up to it,
    // rather than writing a print that is short of its own size.
    let small = briefShowFitToPrintCanvas(colour(1500, 1200), canvas: canvas)
    check("and so does one baked smaller",
          small.extent.width == 3000 && small.extent.height == 2400,
          "\(small.extent.size)")

    // The rounding this exists to swallow.
    let ragged = briefShowFitToPrintCanvas(colour(3000.0001, 2400.0001), canvas: canvas)
    check("a rounded half-pixel does not write a 3001-pixel file",
          ragged.extent.width == 3000 && ragged.extent.height == 2400,
          "\(ragged.extent.size)")

    let vertical = briefShowFitToPrintCanvas(colour(4080, 5100),
                                             canvas: CGSize(width: 2400, height: 3000))
    check("a vertical print lands on vertical paper",
          vertical.extent.width == 2400 && vertical.extent.height == 3000,
          "\(vertical.extent.size)")
}

do {
    // Nothing is stretched on the way. Both sides come from the same template,
    // so the aspect is already right — this is the check that says so out loud.
    let before = 5100.0 / 4080.0
    let fitted = briefShowFitToPrintCanvas(colour(5100, 4080), canvas: canvas)
    let after = Double(fitted.extent.width / fitted.extent.height)
    check("the proportions are untouched", abs(before - after) < 1e-9,
          "\(before) against \(after)")
}

do {
    // ⚠️ THE CHECK THE SIZE CHECKS DO NOT MAKE, and the negative control found
    // it: with the scale removed, a 5100-wide bake CROPPED to 3000 still reads
    // as "3000 × 2400" and every size check above passes — while the client
    // gets the middle of his print and loses the frame round it.
    //
    // So the PICTURE is measured: a mark down the left tenth of the bake has
    // to still be a tenth of the paper afterwards, not a sixth.
    let mark = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 510, height: 4080))
        .composited(over: colour(5100, 4080))
    let fitted = briefShowFitToPrintCanvas(mark, canvas: canvas)

    var pixels = [UInt8](repeating: 0, count: 3000 * 4)
    pixels.withUnsafeMutableBytes { raw in
        briefEditsCIContext.render(fitted, toBitmap: raw.baseAddress!, rowBytes: 3000 * 4,
                                   bounds: CGRect(x: fitted.extent.minX, y: fitted.extent.midY,
                                                  width: 3000, height: 1),
                                   format: .RGBA8, colorSpace: briefEditsSRGBColorSpace)
    }
    var red = 0
    for x in 0..<3000 where pixels[x * 4] > 200 && pixels[x * 4 + 1] < 80 {
        red += 1
    }
    check("the whole print is scaled onto the paper, not cropped to it",
          abs(Double(red) / 3000.0 - 0.1) < 0.005,
          "the mark is \(String(format: "%.3f", Double(red) / 3000.0)) of the width, not 0.100")
}

// MARK: - The file says 300 dpi

print("\nthe file says what size of paper it is")

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("briefshow-print-export-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

/// What the WRITTEN file claims about itself, read back with ImageIO.
func writtenFacts(_ data: Data, extension ext: String) -> (width: Int, height: Int, dpi: Double)? {
    let url = scratch.appendingPathComponent("print.\(ext)")
    try? data.write(to: url)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }
    let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
    return (width, height, dpi)
}

let print8x10 = briefShowFitToPrintCanvas(colour(5100, 4080), canvas: canvas)

for format in ExportFormat.allCases {
    guard let data = briefShowExportData(print8x10, format: format, quality: 0.92,
                                         dpi: 300, context: briefEditsCIContext),
          let facts = writtenFacts(data, extension: format.fileExtension) else {
        check("\(format.title) was written at all", false)
        continue
    }
    check("\(format.title) is 3000 × 2400 pixels",
          facts.width == 3000 && facts.height == 2400,
          "\(facts.width) × \(facts.height)")
    check("\(format.title) says 300 dpi", abs(facts.dpi - 300) < 0.5, "\(facts.dpi)")
}

do {
    // An ordinary photograph has no physical size to claim, and nothing
    // pretends otherwise.
    guard let data = briefShowExportData(colour(1200, 800), format: .jpeg, quality: 0.92,
                                         dpi: nil, context: briefEditsCIContext),
          let facts = writtenFacts(data, extension: "jpg") else {
        check("a plain photo was written", false)
        exit(1)
    }
    check("a photograph that is not a print keeps the default 72",
          abs(facts.dpi - 72) < 0.5, "\(facts.dpi)")
    check("and its own pixels", facts.width == 1200 && facts.height == 800,
          "\(facts.width) × \(facts.height)")
}

do {
    // The pixels are untouched by the stamp: same bytes of picture, a
    // different line of metadata.
    let withDPI = briefShowExportData(print8x10, format: .png, quality: 1,
                                      dpi: 300, context: briefEditsCIContext)
    let without = briefShowExportData(print8x10, format: .png, quality: 1,
                                      dpi: nil, context: briefEditsCIContext)
    let a = writtenFacts(withDPI ?? Data(), extension: "png")
    let b = writtenFacts(without ?? Data(), extension: "png")
    check("stamping the dpi changes no pixels",
          a?.width == b?.width && a?.height == b?.height,
          "\(String(describing: a)) against \(String(describing: b))")
}

print(failures == 0 ? "\nall passed\n" : "\n\(failures) FAILED\n")
exit(failures == 0 ? 0 : 1)
