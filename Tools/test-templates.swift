// The print template model, proved rather than looked at.
//
// This compiles the REAL BriefShow/Templates.swift — the file that ships —
// and drives its own functions. Nothing here is a copy of the geometry.
//
// Four things are being held down, and each one is a way the client loses
// paper if it slips:
//
//   1. the photograph is never stretched to meet a hole it does not fit,
//   2. the hole is found in the alpha channel and the FRAME around a drawing
//      is not mistaken for it,
//   3. a portrait photograph never lands in a landscape template, and
//   4. the print resolution is one number, and the pixel sizes are arithmetic
//      off it rather than typed in.
//
//     templates
import Foundation
import CoreGraphics

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - The print sizes are arithmetic, not typed in

print("\n300 dpi, and the sizes that follow from it")

check("8×6 horizontal is 2400×1800",
      PrintSize.eightBySix.pixels(orientation: .horizontal) == CGSize(width: 2400, height: 1800))
check("8×6 vertical is 1800×2400",
      PrintSize.eightBySix.pixels(orientation: .vertical) == CGSize(width: 1800, height: 2400))
check("8×10 horizontal is 3000×2400",
      PrintSize.eightByTen.pixels(orientation: .horizontal) == CGSize(width: 3000, height: 2400))
check("8×10 vertical is 2400×3000",
      PrintSize.eightByTen.pixels(orientation: .vertical) == CGSize(width: 2400, height: 3000))
check("the dpi is the only thing that decides them",
      PrintSize.eightByTen.pixels(orientation: .horizontal, dpi: 240) == CGSize(width: 2400, height: 1920))
check("the label reads long side first", PrintSize.eightByTen.label == "10 × 8 in")

// MARK: - Which paper a drawing is

print("\nthe paper read off the drawing's own proportions")

check("2400×1800 is an 8×6", briefShowPrintSize(forPixelWidth: 2400, height: 1800) == .eightBySix)
check("1800×2400 is an 8×6 too — the same paper turned round",
      briefShowPrintSize(forPixelWidth: 1800, height: 2400) == .eightBySix)
check("3000×2400 is an 8×10", briefShowPrintSize(forPixelWidth: 3000, height: 2400) == .eightByTen)
check("a drawing with a few pixels of bleed still lands",
      briefShowPrintSize(forPixelWidth: 2404, height: 1800) == .eightBySix)

// ⚠️ 4:3 and 4:5 are 6.7 % apart, and a template filed under the wrong one
// prints at the wrong size on the client's paper. So "no idea" has to be an
// answer the import can give, and the picker asks.
check("a square says nothing rather than guessing",
      briefShowPrintSize(forPixelWidth: 2000, height: 2000) == nil)
check("16:9 says nothing rather than guessing",
      briefShowPrintSize(forPixelWidth: 1920, height: 1080) == nil)

// MARK: - Orientation

print("\norientation, of drawings and of photographs")

check("wider than tall is horizontal", briefShowTemplateOrientation(width: 2400, height: 1800) == .horizontal)
check("taller than wide is vertical", briefShowTemplateOrientation(width: 1800, height: 2400) == .vertical)
check("square is square, and nobody but the client can file it",
      briefShowTemplateOrientation(width: 2000, height: 2000) == .square)
check("a square PHOTOGRAPH is called horizontal — step 4 must hand it something",
      TemplateOrientation.ofPhoto(width: 2000, height: 2000) == .horizontal)
check("a portrait photograph is vertical",
      TemplateOrientation.ofPhoto(width: 1800, height: 2400) == .vertical)

// MARK: - The slot on the canvas

print("\nthe slot in pixels, both ways up")

let slot = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
let canvas = CGSize(width: 2400, height: 1800)
let top = briefShowSlotPixelRect(slot, canvasWidth: canvas.width, canvasHeight: canvas.height)
let bottom = briefShowSlotPixelRect(slot, canvasWidth: canvas.width, canvasHeight: canvas.height,
                                    flipped: true)

check("the rectangle in top-left pixels", top == CGRect(x: 240, y: 360, width: 1200, height: 720))
check("the flip is the same rectangle measured from the other edge",
      bottom == CGRect(x: 240, y: 1800 - 360 - 720, width: 1200, height: 720))
check("the flip keeps the size", top.size == bottom.size)
check("a slot at the top flips to the bottom",
      briefShowSlotPixelRect(NormalizedRect(x: 0, y: 0, width: 1, height: 0.25),
                             canvasWidth: 100, canvasHeight: 100, flipped: true).minY == 75)

// ⚠️ The same slot measured on a preview-sized canvas and on the print canvas
// has to be the SAME PLACE. That is the whole reason the rectangle is stored
// in fractions and not in pixels.
let small = briefShowSlotPixelRect(slot, canvasWidth: 240, canvasHeight: 180)
check("the same slot is the same place at any canvas size",
      close(small.minX / 240, top.minX / 2400) && close(small.width / 240, top.width / 2400))

check("a slot inside the canvas is valid", slot.isValid)
check("a slot hanging off the edge is not",
      !NormalizedRect(x: 0.8, y: 0, width: 0.5, height: 0.5).isValid)
check("a slot with no width is not", !NormalizedRect(x: 0, y: 0, width: 0, height: 0.5).isValid)

// MARK: - The photograph in the slot: never stretched

print("\nfit and fill keep the photograph's own proportions")

let pixelSlot = CGRect(x: 0, y: 0, width: 1000, height: 800)          // 1.25
let landscape = (width: 6000.0, height: 4000.0)                       // 1.5, wider than the slot
let portrait = (width: 4000.0, height: 6000.0)                        // 0.667

for (label, photo) in [("landscape", landscape), ("portrait", portrait)] {
    for mode in SlotFitMode.allCases {
        var placement = SlotPlacement()
        placement.mode = mode
        let rect = briefShowPhotoRectInSlot(photoWidth: photo.width, photoHeight: photo.height,
                                            slot: pixelSlot, placement: placement)
        check("\(label) \(mode.label): the aspect is the photograph's, to the pixel",
              close(rect.width / rect.height, photo.width / photo.height, 1e-9),
              "got \(rect.width / rect.height), photo is \(photo.width / photo.height)")
    }
}

var fill = SlotPlacement(); fill.mode = .fill
var fit = SlotPlacement(); fit.mode = .fit

let filled = briefShowPhotoRectInSlot(photoWidth: landscape.width, photoHeight: landscape.height,
                                      slot: pixelSlot, placement: fill)
let fitted = briefShowPhotoRectInSlot(photoWidth: landscape.width, photoHeight: landscape.height,
                                      slot: pixelSlot, placement: fit)

check("fill leaves no corner of the slot showing", briefShowSlotIsCovered(photo: filled, slot: pixelSlot))
check("fill crops rather than shrinks — it overhangs the side it must",
      filled.width > pixelSlot.width + 0.5 && close(filled.height, pixelSlot.height, 0.5))
check("fit puts the whole photograph inside",
      fitted.width <= pixelSlot.width + 0.5 && fitted.height <= pixelSlot.height + 0.5)
check("fit on a photograph of other proportions does NOT cover the slot",
      !briefShowSlotIsCovered(photo: fitted, slot: pixelSlot))
check("both are centred when nothing is moved",
      close(filled.midX, pixelSlot.midX) && close(fitted.midY, pixelSlot.midY))

// A photograph of exactly the slot's proportions: fit and fill are the same
// rectangle, and it is the slot.
let exact = briefShowPhotoRectInSlot(photoWidth: 2500, photoHeight: 2000,
                                     slot: pixelSlot, placement: fill)
check("a photograph of the slot's own proportions lands on the slot exactly",
      close(exact.width, pixelSlot.width, 1e-6) && close(exact.height, pixelSlot.height, 1e-6))

print("\nmoving and zooming inside the slot")

var moved = SlotPlacement(); moved.offsetX = 0.25
let movedRect = briefShowPhotoRectInSlot(photoWidth: landscape.width, photoHeight: landscape.height,
                                         slot: pixelSlot, placement: moved)
check("an offset of 0.25 moves a quarter of the SLOT, not of the photograph",
      close(movedRect.midX - filled.midX, pixelSlot.width * 0.25))

// ⚠️ The same framing at preview size and at 300 dpi. The offsets are in slot
// widths for exactly this: a placement stored in pixels would reframe the
// photograph the moment the canvas changed size.
let bigSlot = CGRect(x: 0, y: 0, width: 3000, height: 2400)
let bigMoved = briefShowPhotoRectInSlot(photoWidth: landscape.width, photoHeight: landscape.height,
                                        slot: bigSlot, placement: moved)
check("the same placement frames the same photograph at any print size",
      close((bigMoved.midX - bigSlot.minX) / bigSlot.width,
            (movedRect.midX - pixelSlot.minX) / pixelSlot.width, 1e-9))

var zoomed = SlotPlacement(); zoomed.zoom = 2
let zoomedRect = briefShowPhotoRectInSlot(photoWidth: landscape.width, photoHeight: landscape.height,
                                          slot: pixelSlot, placement: zoomed)
check("zoom 2 is twice the size and still centred",
      close(zoomedRect.width, filled.width * 2) && close(zoomedRect.midX, pixelSlot.midX))
check("zoom above 1 still covers the slot", briefShowSlotIsCovered(photo: zoomedRect, slot: pixelSlot))

var backwards = SlotPlacement(); backwards.zoom = -3
let backwardsRect = briefShowPhotoRectInSlot(photoWidth: landscape.width, photoHeight: landscape.height,
                                             slot: pixelSlot, placement: backwards)
check("a zoom that makes no sense does not turn the photograph inside out",
      backwardsRect.width > 0 && backwardsRect.height > 0)
check("a photograph with no pixels does not divide by zero",
      briefShowPhotoRectInSlot(photoWidth: 0, photoHeight: 0, slot: pixelSlot,
                               placement: fill) == pixelSlot)

// MARK: - Finding the hole

print("\nthe hole, read out of the alpha channel")

/// A drawing: `opaque` everywhere, with rectangles punched transparent.
func drawing(width: Int, height: Int, holes: [(x: Int, y: Int, w: Int, h: Int)],
             border: Int = 0) -> [UInt8] {
    var alpha = [UInt8](repeating: 255, count: width * height)
    for hole in holes {
        for row in hole.y..<min(height, hole.y + hole.h) {
            for column in hole.x..<min(width, hole.x + hole.w) {
                alpha[row * width + column] = 0
            }
        }
    }
    if border > 0 {
        for row in 0..<height {
            for column in 0..<width
            where row < border || column < border || row >= height - border || column >= width - border {
                alpha[row * width + column] = 0
            }
        }
    }
    return alpha
}

let plain = drawing(width: 400, height: 300, holes: [(x: 40, y: 30, w: 320, h: 240)])
if let hole = briefShowTemplateHole(alpha: plain, width: 400, height: 300) {
    check("a clean rectangular opening comes back to the pixel",
          close(hole.rect.x, 40.0 / 400) && close(hole.rect.y, 30.0 / 300) &&
          close(hole.rect.width, 320.0 / 400) && close(hole.rect.height, 240.0 / 300),
          "got \(hole.rect)")
    check("a rectangle measures as a rectangle", close(hole.detection.rectangularity, 1.0, 1e-9))
    check("its coverage is the share of the drawing it takes",
          close(hole.detection.coverage, (320.0 * 240) / (400 * 300), 1e-9))
} else {
    check("a clean rectangular opening is found at all", false)
    failures += 2
}

// ⚠️ THE CASE THAT DECIDED THE ALGORITHM. A drawing exported with a
// transparent margin has one enormous transparent region running all the way
// round the frame, and it is bigger than the hole every single time. Taking
// "the largest transparent region" full stop would put the photograph behind
// the mat on exactly the files most likely to be handed over.
let framed = drawing(width: 400, height: 300, holes: [(x: 120, y: 90, w: 160, h: 120)], border: 20)
if let hole = briefShowTemplateHole(alpha: framed, width: 400, height: 300) {
    check("the transparent margin round the drawing is NOT the hole",
          close(hole.rect.x, 120.0 / 400) && close(hole.rect.width, 160.0 / 400),
          "got \(hole.rect)")
} else {
    check("the hole inside a transparent margin is still found", false)
}

let borderOnly = drawing(width: 400, height: 300, holes: [], border: 20)
check("a drawing that is only transparent round the edge gives nothing — the client draws it",
      briefShowTemplateHole(alpha: borderOnly, width: 400, height: 300) == nil)

let opaque = drawing(width: 400, height: 300, holes: [])
check("a drawing with no transparency at all gives nothing",
      briefShowTemplateHole(alpha: opaque, width: 400, height: 300) == nil)

let two = drawing(width: 400, height: 300, holes: [(x: 20, y: 20, w: 60, h: 60),
                                                   (x: 200, y: 100, w: 150, h: 150)])
if let hole = briefShowTemplateHole(alpha: two, width: 400, height: 300) {
    check("of two openings the LARGER is the slot", close(hole.rect.width, 150.0 / 400))
} else {
    check("two openings still give a slot", false)
}

let speck = drawing(width: 400, height: 300, holes: [(x: 10, y: 10, w: 6, h: 6)])
check("a speck of transparency is not an opening",
      briefShowTemplateHole(alpha: speck, width: 400, height: 300) == nil)

// A round opening: the rectangle is its box, and the number says so, so the
// import can tell the client rather than pretending it measured a rectangle.
var round = [UInt8](repeating: 255, count: 400 * 300)
for row in 0..<300 {
    for column in 0..<400 {
        let dx = (Double(column) - 200) / 150
        let dy = (Double(row) - 150) / 120
        if dx * dx + dy * dy <= 1 { round[row * 400 + column] = 0 }
    }
}
if let hole = briefShowTemplateHole(alpha: round, width: 400, height: 300) {
    check("a round opening still gives its bounding rectangle",
          close(hole.rect.width, 300.0 / 400, 0.01) && close(hole.rect.height, 240.0 / 300, 0.01),
          "got \(hole.rect)")
    check("and it is MARKED as not a rectangle — π/4, not 1",
          close(hole.detection.rectangularity, Double.pi / 4, 0.02) &&
          hole.detection.rectangularity < TemplateHoleDetection.rectangularThreshold,
          "got \(hole.detection.rectangularity)")
} else {
    check("a round opening is found", false)
    failures += 1
}

// Semi-transparent is not transparent: a drop shadow at 20 % alpha is part of
// the drawing, not part of the hole.
var shadowed = [UInt8](repeating: 255, count: 400 * 300)
for row in 30..<270 { for column in 40..<360 { shadowed[row * 400 + column] = 0 } }
for row in 20..<30 { for column in 40..<360 { shadowed[row * 400 + column] = 50 } }
if let hole = briefShowTemplateHole(alpha: shadowed, width: 400, height: 300) {
    check("a soft edge at 20 % alpha is drawing, not hole", close(hole.rect.y, 30.0 / 300))
} else {
    check("a soft-edged opening is found", false)
}

check("an empty buffer is refused rather than crashed into",
      briefShowTemplateHole(alpha: [], width: 0, height: 0) == nil)
check("a buffer shorter than it claims is refused",
      briefShowTemplateHole(alpha: [UInt8](repeating: 0, count: 10), width: 400, height: 300) == nil)

// An L-shaped opening: one region, and 4-connectivity has to keep it one.
let lShape = drawing(width: 400, height: 300, holes: [(x: 50, y: 50, w: 100, h: 200),
                                                      (x: 50, y: 150, w: 250, h: 100)])
if let hole = briefShowTemplateHole(alpha: lShape, width: 400, height: 300) {
    check("two overlapping rectangles are ONE opening, not two",
          close(hole.rect.width, 250.0 / 400) && close(hole.rect.height, 200.0 / 300),
          "got \(hole.rect)")
} else {
    check("an L-shaped opening is found", false)
}

// MARK: - The pair

print("\nthe horizontal and vertical pair")

func template(_ name: String, _ orientation: TemplateOrientation,
              _ size: PrintSize = .eightBySix) -> PrintTemplate {
    PrintTemplate(name: name, size: size, orientation: orientation,
                  slot: TemplateSlot(rect: TemplateImporter.fallbackSlot),
                  artRef: "\(name).png", artPixelWidth: 2400, artPixelHeight: 1800)
}

let h = template("frame H", .horizontal)
let v = template("frame V", .vertical)
let otherV = template("other V", .vertical)
let bigV = template("8×10 V", .vertical, .eightByTen)
let square = template("square", .square)

check("a horizontal and a vertical of one format may be paired", briefShowCanPairTemplates(h, v))

// ⚠️ Two horizontals joined would leave sync believing it had a vertical to
// give — and it would print every portrait in the selection sideways, quietly.
check("two of the same orientation may NOT", !briefShowCanPairTemplates(v, otherV))
check("two different paper sizes may not", !briefShowCanPairTemplates(h, bigV))
check("a square has no partner to be", !briefShowCanPairTemplates(square, v))
check("nothing pairs with itself", !briefShowCanPairTemplates(h, h))

var catalogue = [h, v, otherV]
catalogue = briefShowPairTemplates(h, v, in: catalogue)
check("both sides point at each other",
      catalogue.first(where: { $0.id == h.id })?.pairID == v.id &&
      catalogue.first(where: { $0.id == v.id })?.pairID == h.id)
check("a pair that was refused changes nothing",
      briefShowPairTemplates(v, otherV, in: catalogue) == catalogue)

// Re-pairing H with a different vertical must leave the old partner holding
// nothing, not holding a pointer at a template that has forgotten it.
catalogue = briefShowPairTemplates(h, otherV, in: catalogue)
check("re-pairing clears the partner that was dropped",
      catalogue.first(where: { $0.id == v.id })?.pairID == nil &&
      catalogue.first(where: { $0.id == h.id })?.pairID == otherV.id &&
      catalogue.first(where: { $0.id == otherV.id })?.pairID == h.id)

print("\nwhich template a photograph gets")

let paired = catalogue.first(where: { $0.id == h.id })!
check("a landscape photograph keeps the template that was chosen",
      briefShowTemplateForPhoto(width: 6000, height: 4000, chosen: paired,
                                catalogue: catalogue)?.id == h.id)
check("a PORTRAIT photograph follows the pair to the vertical one",
      briefShowTemplateForPhoto(width: 4000, height: 6000, chosen: paired,
                                catalogue: catalogue)?.id == otherV.id)

// ⚠️ The answer step 4 has to say out loud. Nothing is better than a portrait
// printed into a landscape template.
check("without a pair, a portrait photograph gets NOTHING rather than the wrong way round",
      briefShowTemplateForPhoto(width: 4000, height: 6000, chosen: h,
                                catalogue: [h]) == nil)
check("a square template takes either photograph",
      briefShowTemplateForPhoto(width: 4000, height: 6000, chosen: square,
                                catalogue: [square])?.id == square.id)
check("a square photograph counts as landscape and keeps the chosen template",
      briefShowTemplateForPhoto(width: 4000, height: 4000, chosen: paired,
                                catalogue: catalogue)?.id == h.id)

// MARK: - What gets written down

print("\nwhat a template carries when it is stored")

let encoded = try! JSONEncoder().encode(catalogue)
let decoded = try! JSONDecoder().decode([PrintTemplate].self, from: encoded)
check("a catalogue survives the round trip unchanged", decoded == catalogue)

let json = String(data: encoded, encoding: .utf8) ?? ""
check("the drawing is referred to by name", json.contains("artRef"))
check("the switch the client asked for is stored", json.contains("artOverPhoto"))

// ⚠️ The second locked rule. A photo's record is one JSON blob rewritten after
// every change; a template's PIXELS in there would be rewritten with it.
check("no pixels are written into the catalogue",
      !json.contains("imageData") && !json.contains("inlineImageData") && encoded.count < 4096,
      "\(encoded.count) bytes for three templates")

let blob = Data(repeating: 7, count: 1024)
check("the drawing's name on disk is its contents, so importing it twice writes one file",
      TemplateStore.artName(for: blob) == TemplateStore.artName(for: blob))
check("and two different drawings are two names",
      TemplateStore.artName(for: blob) != TemplateStore.artName(for: Data(repeating: 9, count: 1024)))
check("it is a .png on disk", TemplateStore.artName(for: blob).hasSuffix(".png"))

var trio = catalogue
trio = TemplateStore.remove(paired, from: trio)
check("removing a template takes it out of the catalogue", !trio.contains { $0.id == h.id })
check("and nobody is left pointing at it", !trio.contains { $0.pairID == h.id })

print("")
if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all passed")
