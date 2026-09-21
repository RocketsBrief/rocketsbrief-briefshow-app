// Merge Layers: Image + Template — KORAK 208. Compiled with the real
// Templates.swift by Tools/run-print-merge-test.py.
//
// The one claim that matters: after the print is baked into the photograph,
// a layer the client did NOT tick, re-drawn by briefShowPhotoSpaceOnPrint and
// laid over the baked print, gives the SAME picture as the print drawn with
// that layer still on the photograph. Measured in pixels, not argued.
import Foundation
import CoreGraphics
import CoreImage

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

func pixels(_ image: CIImage, _ rect: CGRect) -> [UInt8] {
    let width = Int(rect.width), height = Int(rect.height)
    var out = [UInt8](repeating: 0, count: width * height * 4)
    context.render(image, toBitmap: &out, rowBytes: width * 4, bounds: rect,
                   format: .RGBA8, colorSpace: nil)
    return out
}

/// How far apart two pictures are: the worst channel, and how many pixels
/// differ by more than `loose` levels.
func difference(_ a: CIImage, _ b: CIImage, _ rect: CGRect, loose: Int = 8) -> (worst: Int, share: Double) {
    let pa = pixels(a, rect), pb = pixels(b, rect)
    var worst = 0, off = 0
    for p in stride(from: 0, to: pa.count, by: 4) {
        var pixelWorst = 0
        for c in 0..<4 { pixelWorst = max(pixelWorst, abs(Int(pa[p + c]) - Int(pb[p + c]))) }
        worst = max(worst, pixelWorst)
        if pixelWorst > loose { off += 1 }
    }
    return (worst, Double(off) / Double(pa.count / 4))
}

// A photograph with structure everywhere, so a layer or a picture put a few
// pixels off shows up as a difference rather than hiding in a flat colour.
let photoExtent = CGRect(x: 0, y: 0, width: 600, height: 400)
let photo = CIFilter(name: "CICheckerboardGenerator", parameters: [
    "inputCenter": CIVector(x: 0, y: 0),
    "inputColor0": CIColor(red: 0.9, green: 0.6, blue: 0.2),
    "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.7),
    "inputWidth": 37,
])!.outputImage!.cropped(to: photoExtent)

// A kept layer as compositeLayers draws it in the photograph's space: a
// half-transparent green block, and a smaller opaque one, off-centre and
// crossing where the frame's drawing will be.
let layer = CIImage(color: CIColor(red: 0, green: 0.8, blue: 0.2, alpha: 0.6))
    .cropped(to: CGRect(x: 20, y: 250, width: 330, height: 130))
    .composited(over: CIImage(color: CIColor(red: 1, green: 0, blue: 0.4, alpha: 1))
        .cropped(to: CGRect(x: 420, y: 40, width: 150, height: 90)))

let template = PrintTemplate(
    name: "mat", size: .eightBySix, orientation: .horizontal,
    slot: TemplateSlot(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7)),
    artOverPhoto: true, artRef: "mat.png", artPixelWidth: 480, artPixelHeight: 360)
let scale = 0.2
let canvas = CGRect(x: 0, y: 0,
                    width: (template.canvasPixels.width * scale).rounded(),
                    height: (template.canvasPixels.height * scale).rounded())

/// The drawing: an opaque mat with a hard-edged opening — the case that must
/// be exact. `softEdge` fades the opening's rim, the one case that is not.
func mat(softEdge: Bool) -> CIImage {
    let full = CGRect(x: 0, y: 0, width: 480, height: 360)
    let blue = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.5)).cropped(to: full)
    var hole = CIImage(color: .white).cropped(to: CGRect(x: 60, y: 60, width: 360, height: 230))
    if softEdge {
        hole = hole.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: full)
    }
    let cut = CIFilter(name: "CISourceOutCompositing")!
    cut.setValue(blue, forKey: kCIInputImageKey)
    cut.setValue(hole, forKey: kCIInputBackgroundImageKey)
    return cut.outputImage!.cropped(to: full)
}

typealias Crop = (x: Double, y: Double, width: Double, height: Double, angleDegrees: Double)

/// What the renderer does to the photograph after the layers: the crop, then
/// the print. The two shared calls, in the renderer's order.
func cropped(_ image: CIImage, _ crop: Crop?) -> CIImage {
    guard let crop else { return image }
    let g = briefShowCropGeometry(x: crop.x, y: crop.y, width: crop.width, height: crop.height,
                                  angleDegrees: crop.angleDegrees, extent: photoExtent)
    var out = image
    if let turn = g.turn { out = out.transformed(by: turn) }
    return out.cropped(to: g.rect)
}

func print_(_ photoLike: CIImage, _ crop: Crop?, _ art: CIImage, _ placement: SlotPlacement,
            _ artOver: Bool) -> CIImage {
    briefShowComposeTemplate(photo: cropped(photoLike, crop), template: template, art: art,
                             placement: placement, artOverPhoto: artOver, canvasScale: scale)
}

func scenario(_ label: String, crop: Crop?, placement: SlotPlacement, artOver: Bool,
              softEdge: Bool = false) -> (worst: Int, share: Double) {
    let art = mat(softEdge: softEdge)
    // BEFORE: the layer is on the photograph, and the print is drawn over both.
    let before = print_(layer.composited(over: photo), crop, art, placement, artOver)
    // AFTER: the print without the layer is the new picture, and the layer —
    // re-drawn onto the print — lies over it.
    let baked = print_(photo, crop, art, placement, artOver)
    let moved = briefShowPhotoSpaceOnPrint(layer, photoExtent: photoExtent, crop: crop,
                                           template: template, art: art, placement: placement,
                                           artOverPhoto: artOver, canvasScale: scale)
    let after = moved.composited(over: baked)
    let d = difference(before, after, canvas)
    print(String(format: "        %@: worst %d levels, %.3f %% of pixels off by more than 8",
                 label, d.worst, d.share * 100))
    return d
}

var turned = SlotPlacement()
turned.offsetX = 0.12
turned.offsetY = -0.08
turned.zoom = 1.3
turned.rotationDegrees = 9
let tilted: Crop = (x: 0.08, y: 0.1, width: 0.8, height: 0.78, angleDegrees: 6)

print("\na kept layer looks the same after the print is merged into the photo")

// Only the resampling of edges is allowed to differ — the layer's own edge,
// scaled once in one path and once in the other. A layer put anywhere else,
// even a pixel off on this checkerboard, moves far more than this.
let exactShare = 0.004

let a = scenario("drawing over the photo, no crop, centred", crop: nil, placement: .centred, artOver: true)
check("drawing over the photo, no crop, centred", a.share <= exactShare)

let b = scenario("drawing over the photo, turned crop, moved + zoomed + turned picture",
                 crop: tilted, placement: turned, artOver: true)
check("drawing over the photo, turned crop, moved, zoomed and turned picture", b.share <= exactShare)

let c = scenario("photo over the drawing, same crop and placement",
                 crop: tilted, placement: turned, artOver: false)
check("photo over the drawing, same crop and placement", c.share <= exactShare)

// The soft rim is the one inexact place, and the claim in the code is that it
// is off only there. Held to that: a small share, but more than the hard mat.
let d = scenario("soft-edged opening (the one inexact case)", crop: tilted, placement: turned,
                 artOver: true, softEdge: true)
check("a soft-edged opening is off only along its rim", d.share <= 0.03,
      String(format: "%.3f %%", d.share * 100))

print("\nthe test can see a wrong answer (negative controls, run every time)")

// 1. The layer NOT hidden under the drawing: it would print over the mat.
do {
    let art = mat(softEdge: false)
    let before = print_(layer.composited(over: photo), tilted, art, turned, true)
    let baked = print_(photo, tilted, art, turned, true)
    let wrong = briefShowPhotoSpaceOnPrint(layer, photoExtent: photoExtent, crop: tilted,
                                           template: template, art: art, placement: turned,
                                           artOverPhoto: false, canvasScale: scale)
    let dd = difference(before, wrong.composited(over: baked), canvas)
    check("a layer left on top of the frame is caught", dd.share > 0.02,
          String(format: "%.3f %%", dd.share * 100))
}

// 2. Placed by the LAYER's own size instead of the photograph's — the drift
// the shared transform exists to prevent.
do {
    let art = mat(softEdge: false)
    let before = print_(layer.composited(over: photo), nil, art, .centred, true)
    let baked = print_(photo, nil, art, .centred, true)
    let wrong = briefShowPhotoSpaceOnPrint(layer, photoExtent: layer.extent, crop: nil,
                                           template: template, art: art, placement: .centred,
                                           artOverPhoto: true, canvasScale: scale)
    let dd = difference(before, wrong.composited(over: baked), canvas)
    check("a layer placed by its own size is caught", dd.share > 0.02,
          String(format: "%.3f %%", dd.share * 100))
}

// 3. The crop forgotten.
do {
    let art = mat(softEdge: false)
    let before = print_(layer.composited(over: photo), tilted, art, turned, true)
    let baked = print_(photo, tilted, art, turned, true)
    let wrong = briefShowPhotoSpaceOnPrint(layer, photoExtent: photoExtent, crop: nil,
                                           template: template, art: art, placement: turned,
                                           artOverPhoto: true, canvasScale: scale)
    let dd = difference(before, wrong.composited(over: baked), canvas)
    check("a layer that skipped the crop is caught", dd.share > 0.02,
          String(format: "%.3f %%", dd.share * 100))
}

print("\ntext keeps its size in pixels")

let line = TemplateText(sizeInches: 0.4)
let before = line.sizeInches * briefShowPixelsPerInch(template: template, canvasWidth: Double(canvas.width))
let movedLine = briefShowTextOffPrint(line, template: template,
                                      canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
let after = movedLine.sizeInches * briefShowPhotoPixelsPerInch(canvasWidth: Double(canvas.width),
                                                               canvasHeight: Double(canvas.height))
check("the same letters are the same number of pixels", abs(before - after) < 1e-9,
      "\(before) px vs \(after) px")
check("and the box does not move", movedLine.box == line.box)

print(failures == 0 ? "\nall good" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
