// No pass may leave the photograph's edge translucent.
//
// ⚠️ WHY THIS EXISTS. Laid into a print template, a photograph sits on white
// paper — and anything upstream that hands back a soft, partly transparent
// border shows up as a white feather along the edge of the print. The client
// saw exactly that on 20.09: *„zastu su krajeve slike blei? kao neki fheater
// bele boje da je implementovan?"*.
//
// It was Dehaze: the transmission map's edge-preserving upsample had nothing
// to read within about two patch radii of the frame, and returned alpha 74 at
// the outermost row, opaque only past row 64 of a 3000×2000 frame. Nothing
// caught it, because on a photograph filling the window a soft edge is
// invisible.
//
// So this walks every control that touches pixels and reads the alpha of all
// four edges. It is cheap, it is the only place this class of fault is
// visible, and the next blur added to the chain will be caught by it.
//
//     template-edge
import Foundation
import CoreImage
import AppKit

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

let context = CIContext(options: [.useSoftwareRenderer: true])

// A flat photograph: no edge of its own to confuse the measurement.
let pw = 1200, ph = 800
var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
for i in stride(from: 0, to: bytes.count, by: 4) {
    bytes[i] = 180; bytes[i + 1] = 60; bytes[i + 2] = 60; bytes[i + 3] = 255
}
let photo = CIImage(bitmapData: Data(bytes), bytesPerRow: pw * 4,
                    size: CGSize(width: pw, height: ph),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

func alpha(_ image: CIImage, x: CGFloat, y: CGFloat) -> Int {
    var out = [UInt8](repeating: 0, count: 4)
    context.render(image, toBitmap: &out, rowBytes: 4,
                   bounds: CGRect(x: x, y: y, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return Int(out[3])
}

/// The thinnest translucent band on any of the four edges, in pixels.
func softBand(_ image: CIImage) -> (edge: String, depth: Int) {
    let e = image.extent
    guard e.width > 8, e.height > 8 else { return ("no extent", 0) }
    var worst = ("none", 0)
    let probes: [(String, (Int) -> CGPoint)] = [
        ("top", { CGPoint(x: e.midX, y: e.maxY - CGFloat($0) - 1) }),
        ("bottom", { CGPoint(x: e.midX, y: e.minY + CGFloat($0)) }),
        ("left", { CGPoint(x: e.minX + CGFloat($0), y: e.midY) }),
        ("right", { CGPoint(x: e.maxX - CGFloat($0) - 1, y: e.midY) }),
    ]
    for (name, point) in probes {
        var depth = 0
        for step in 0..<100 {
            let p = point(step)
            if alpha(image, x: p.x, y: p.y) < 250 { depth = step + 1 } else { break }
        }
        if depth > worst.1 { worst = (name, depth) }
    }
    return worst
}

print("\nevery control, along all four edges")

let probes: [(String, (inout PhotoEditSettings) -> Void)] = [
    ("nothing set", { _ in }),
    ("exposure", { $0.exposure = 1 }),
    ("contrast", { $0.contrast = 0.6 }),
    ("highlights", { $0.highlights = -0.6 }),
    ("shadows", { $0.shadows = 0.6 }),
    ("whites", { $0.whites = 0.6 }),
    ("blacks", { $0.blacks = -0.6 }),
    ("saturation", { $0.saturation = 0.6 }),
    ("vibrance", { $0.vibrance = 0.6 }),
    ("temperature", { $0.temperature = 0.5 }),
    ("tint", { $0.tint = 0.5 }),
    ("sharpness", { $0.sharpness = 0.8 }),
    ("texture", { $0.texture = 0.8 }),
    ("clarity", { $0.clarity = 0.8 }),
    ("dehaze", { $0.dehaze = 0.8 }),
    ("dehaze, the other way", { $0.dehaze = -0.8 }),
    ("soft glow", { $0.softGlow = 0.8 }),
    ("vignette", { $0.vignette = 0.8 }),
    ("everything at once", {
        $0.exposure = 0.5; $0.contrast = 0.4; $0.clarity = 0.5; $0.texture = 0.5
        $0.dehaze = 0.5; $0.softGlow = 0.3; $0.sharpness = 0.5; $0.vignette = 0.4
    }),
]

for (label, set) in probes {
    var settings = PhotoEditSettings()
    set(&settings)
    let rendered = PhotoEditRenderer.render(settings, on: .standard(photo), applyCrop: false)
    let band = softBand(rendered)
    check("\(label): the edge is opaque", band.depth == 0,
          "\(band.depth) translucent px on the \(band.edge) edge")
}

// ⚠️ And the same photograph through the same pass has to keep its LOOK. The
// fix for the soft edge was a clamp inside the transmission map, and a clamp
// that changed the picture would be a different bug wearing the fix's clothes.
var dehazed = PhotoEditSettings(); dehazed.dehaze = 0.8
let middleOfDehazed = PhotoEditRenderer.render(dehazed, on: .standard(photo), applyCrop: false)
let e = middleOfDehazed.extent
var centre = [UInt8](repeating: 0, count: 4)
context.render(middleOfDehazed, toBitmap: &centre, rowBytes: 4,
               bounds: CGRect(x: e.midX, y: e.midY, width: 1, height: 1),
               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
var edgePixel = [UInt8](repeating: 0, count: 4)
context.render(middleOfDehazed, toBitmap: &edgePixel, rowBytes: 4,
               bounds: CGRect(x: e.midX, y: e.maxY - 1, width: 1, height: 1),
               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
check("a flat frame dehazes to the same colour at its edge as in its middle",
      abs(Int(centre[0]) - Int(edgePixel[0])) <= 2,
      "middle \(centre[0]), edge \(edgePixel[0])")

print("")
if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all passed")
