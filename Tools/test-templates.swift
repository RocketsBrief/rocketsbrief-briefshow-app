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

// MARK: - What a flatten bakes at

print("\nthe scale a flatten bakes the print at")

let bakeTemplate = PrintTemplate(
    name: "mat", size: .eightBySix, orientation: .horizontal,
    slot: TemplateSlot(rect: NormalizedRect(x: 0.08, y: 0.08, width: 0.88, height: 0.76)),
    artOverPhoto: true, artRef: "mat.png", artPixelWidth: 2400, artPixelHeight: 1800)

// ⚠️ THE LOCKED RESOLUTION RULE, MEETING THE BAKE. The opening is 2,112 px of
// a 2,400 px print; a 6,000 px photograph laid into it at print size would be
// resampled to about a third on the way into the flattened file, and only
// Unflatten could get it back.
let bakeScale = briefShowBakeCanvasScale(photoWidth: 6000, photoHeight: 4000,
                                         template: bakeTemplate, placement: .centred)
let photoInPrint = briefShowPhotoRectOnCanvas(photoWidth: 6000, photoHeight: 4000,
                                              slot: bakeTemplate.slot.rect,
                                              canvasWidth: 2400, canvasHeight: 1800,
                                              placement: .centred)
check("the bake is drawn big enough to keep the photograph's own pixels",
      close(bakeScale, 6000 / Double(photoInPrint.width), 1e-9),
      "scale \(bakeScale), photo lands \(photoInPrint.width) px wide at print size")
check("which for this template is more than print size",
      bakeScale > 1.5, "got \(bakeScale)")

// A photograph SMALLER than its opening is not blown up to fill it: baking
// invented pixels is not keeping anything.
check("a small photograph does not drag the canvas up with it",
      briefShowBakeCanvasScale(photoWidth: 800, photoHeight: 600,
                               template: bakeTemplate, placement: .centred) == 1)

// ⚠️ 8 GB. A canvas is four bytes a pixel while it is written, so the ceiling
// is in megapixels rather than in a scale factor.
let huge = briefShowBakeCanvasScale(photoWidth: 100_000, photoHeight: 60_000,
                                    template: bakeTemplate, placement: .centred)
check("and the ceiling holds on a machine with 8 GB",
      2400 * huge * 1800 * huge <= 60_000_000 + 1,
      "\(Int(2400 * huge * 1800 * huge / 1_000_000)) MP")
check("a zoomed-in photograph needs less canvas, not more",
      briefShowBakeCanvasScale(photoWidth: 6000, photoHeight: 4000, template: bakeTemplate,
                               placement: { var p = SlotPlacement(); p.zoom = 2; return p }())
      < bakeScale)

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

// MARK: - The sync across a mixed selection

print("\nsyncing a template across a run of photographs")

// ⚠️ THE EXIF TAG, not the pixel counts. A camera held upright writes the
// sensor's own landscape pixels plus a tag saying "turn this"; 5…8 are the
// quarter turns. Reading width against height alone files every portrait frame
// from the client's Nikon as a landscape — and the sync would print them all
// sideways, quietly.
check("a landscape file with no tag is landscape",
      briefShowOrientationFromMetadata(pixelWidth: 6000, pixelHeight: 4000,
                                       exifOrientation: nil) == .horizontal)
check("the same pixels tagged 6 are an UPRIGHT photograph",
      briefShowOrientationFromMetadata(pixelWidth: 6000, pixelHeight: 4000,
                                       exifOrientation: 6) == .vertical)
check("and tagged 8 as well — the other quarter turn",
      briefShowOrientationFromMetadata(pixelWidth: 6000, pixelHeight: 4000,
                                       exifOrientation: 8) == .vertical)
for tag in 1...4 {
    check("tag \(tag) leaves the frame the way its pixels lie",
          briefShowOrientationFromMetadata(pixelWidth: 6000, pixelHeight: 4000,
                                           exifOrientation: tag) == .horizontal)
}
check("a portrait file tagged 7 reads back as landscape",
      briefShowOrientationFromMetadata(pixelWidth: 4000, pixelHeight: 6000,
                                       exifOrientation: 7) == .horizontal)

// The plan's own acceptance case: five landscapes and three uprights, one
// click, and not one photograph in a template of the wrong orientation.
var run = [h, v]
run = briefShowPairTemplates(h, v, in: run)
let landscapeFrame = run.first { $0.id == h.id }!
let selection: [TemplateOrientation] = [.horizontal, .horizontal, .horizontal, .horizontal,
                                        .horizontal, .vertical, .vertical, .vertical]
let written = selection.map {
    briefShowSyncedTemplate(landscapeFrame, forPhotoOrientation: $0, catalogue: run)
}
check("five landscapes get the horizontal frame",
      written.prefix(5).allSatisfy { $0?.id == h.id })
check("three uprights get the vertical half of the pair",
      written.suffix(3).allSatisfy { $0?.id == v.id })
check("and NOT ONE photograph gets a template the wrong way up",
      zip(selection, written).allSatisfy { $0.1?.orientation == $0.0 })

// ⚠️ Without the pair it hands back nothing, and the caller has to say so —
// „sync radi samo za slike te orijentacije i kaže zašto".
check("with no pair, an upright photograph gets nothing rather than a sideways print",
      briefShowSyncedTemplate(h, forPhotoOrientation: .vertical, catalogue: [h]) == nil)
check("while the landscapes in the same run still get theirs",
      briefShowSyncedTemplate(h, forPhotoOrientation: .horizontal, catalogue: [h])?.id == h.id)
check("a square template takes either way up",
      briefShowSyncedTemplate(square, forPhotoOrientation: .vertical, catalogue: [square])?.id == square.id)

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

// MARK: - Dragging and zooming the photograph inside its opening

print("\nhow far the photograph may be taken, and how it gets there")

// An 8×6 canvas with the hole high on the paper and a caption band under it —
// the shape of the client's own template, and the reason the travel is not the
// same up as down.
let canvasW = 2400.0, canvasH = 1800.0
let highSlot = NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.76)
let openingSize = (width: highSlot.width * canvasW, height: highSlot.height * canvasH)
let wide = (width: 6000.0, height: 4000.0)                  // 3:2, overhangs left and right

var fillPlacement = SlotPlacement(); fillPlacement.mode = .fill
let travel = briefShowPlacementTravel(photoWidth: wide.width, photoHeight: wide.height,
                                      slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH,
                                      placement: fillPlacement)

// ⚠️ THE TWO RULES THAT DIED HERE, as checks. The first allowed half the
// overhang — 6 % of the slot sideways and EXACTLY ZERO vertically, reported as
// „drag ne radi". The second allowed half a slot, which is the same mistake one
// size smaller. What the client asked for is the whole template.
check("the middle of the photo reaches the LEFT edge of the paper",
      close(travel.minX, -(highSlot.x + highSlot.width / 2) * canvasW / openingSize.width, 1e-9),
      "got \(travel.minX)")
check("and the right edge",
      close(travel.maxX, (1 - highSlot.x - highSlot.width / 2) * canvasW / openingSize.width, 1e-9),
      "got \(travel.maxX)")
check("the travel is NOT the same up as down, because the hole is not centred",
      abs(travel.minY) < travel.maxY, "got \(travel.minY) up, \(travel.maxY) down")
check("down is as far as the bottom of the paper",
      close(travel.maxY, (1 - highSlot.y - highSlot.height / 2) * canvasH / openingSize.height, 1e-9),
      "got \(travel.maxY)")
check("and both axes move properly — the old rule gave 0.0625 and 0.0",
      travel.maxX > 0.5 && travel.maxY > 0.5, "got \(travel.maxX), \(travel.maxY)")

// The other half of the rule: a photograph zoomed past the paper can still be
// panned to its own far corner.
var zoomed5 = fillPlacement; zoomed5.zoom = 5
let roomAtFive = briefShowPlacementTravel(photoWidth: wide.width, photoHeight: wide.height,
                                          slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH,
                                          placement: zoomed5)
check("zoomed in past the paper, the travel follows the picture instead",
      roomAtFive.maxX > travel.maxX && roomAtFive.maxY > travel.maxY,
      "got \(roomAtFive.maxX), \(roomAtFive.maxY)")

// ⚠️ What is still refused: losing the photograph off the paper altogether.
var runAway = fillPlacement; runAway.offsetX = 50; runAway.offsetY = -50
let held = briefShowClampedPlacement(runAway, photoWidth: wide.width, photoHeight: wide.height,
                                     slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH)
check("a drag cannot take the photograph off the paper",
      close(held.offsetX, travel.maxX, 1e-9) && close(held.offsetY, travel.minY, 1e-9),
      "got \(held.offsetX), \(held.offsetY)")

var farAtFive = zoomed5; farAtFive.offsetX = roomAtFive.maxX
let backTo1 = briefShowClampedPlacement({ var p = farAtFive; p.zoom = 1; return p }(),
                                        photoWidth: wide.width, photoHeight: wide.height,
                                        slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH)
check("zooming back out pulls the framing in with it",
      close(backTo1.offsetX, travel.maxX, 1e-9), "got \(backTo1.offsetX)")

var tooFar = fillPlacement; tooFar.zoom = 99
check("the zoom has a ceiling",
      briefShowClampedPlacement(tooFar, photoWidth: wide.width, photoHeight: wide.height,
                                slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH).zoom
      == SlotPlacement.maximumZoom)
check("the whole photograph can be shrunk to a tenth",
      briefShowClampedPlacement({ var p = fillPlacement; p.zoom = 0.1; return p }(),
                                photoWidth: wide.width, photoHeight: wide.height,
                                slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH).zoom == 0.1)
check("and a zoom of nothing is refused",
      briefShowClampedPlacement({ var p = fillPlacement; p.zoom = 0; return p }(),
                                photoWidth: wide.width, photoHeight: wide.height,
                                slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH).zoom
      == SlotPlacement.minimumZoom)
check("an opening of no size refuses to move anything",
      briefShowPlacementTravel(photoWidth: 0, photoHeight: 0, slot: highSlot,
                               canvasWidth: canvasW, canvasHeight: canvasH,
                               placement: fillPlacement) == SlotTravel(minX: 0, maxX: 0, minY: 0, maxY: 0))

print("\nthe drag itself")

// The opening on screen is much smaller than the print; the translation is in
// points, and the offsets come out in slot widths either way.
let screenSlot = (width: 480.0, height: 360.0)
let dragged = briefShowPlacementAfterDrag(fillPlacement,
                                          translationX: 24, translationY: 18,
                                          slotWidthOnScreen: screenSlot.width,
                                          slotHeightOnScreen: screenSlot.height,
                                          photoWidth: wide.width, photoHeight: wide.height,
                                          slot: highSlot,
                                          canvasWidth: screenSlot.width / highSlot.width,
                                          canvasHeight: screenSlot.height / highSlot.height)
check("a drag of 24 pt across a 480 pt opening is 0.05 of a slot width",
      close(dragged.offsetX, 0.05, 1e-9), "got \(dragged.offsetX)")
check("and 18 pt down a 360 pt opening is 0.05 of its height — the axis that used to be dead",
      close(dragged.offsetY, 0.05, 1e-9), "got \(dragged.offsetY)")

// ⚠️ The photograph follows the POINTER, which means the same drag means the
// same thing whatever size the preview happens to be.
let draggedBig = briefShowPlacementAfterDrag(fillPlacement,
                                             translationX: 48, translationY: 36,
                                             slotWidthOnScreen: 960, slotHeightOnScreen: 720,
                                             photoWidth: wide.width, photoHeight: wide.height,
                                             slot: highSlot,
                                             canvasWidth: 960 / highSlot.width,
                                             canvasHeight: 720 / highSlot.height)
check("the same gesture on a preview twice the size lands in the same place",
      close(draggedBig.offsetX, dragged.offsetX, 1e-9) &&
      close(draggedBig.offsetY, dragged.offsetY, 1e-9))

check("a drag against an opening of no size changes nothing",
      briefShowPlacementAfterDrag(fillPlacement, translationX: 10, translationY: 10,
                                  slotWidthOnScreen: 0, slotHeightOnScreen: 0,
                                  photoWidth: wide.width, photoHeight: wide.height,
                                  slot: highSlot, canvasWidth: canvasW, canvasHeight: canvasH)
      == fillPlacement)

// MARK: - The canvas, rendered and read back pixel by pixel

print("\nthe finished canvas, measured")

let context = CIContext(options: [.useSoftwareRenderer: true])

/// The colour at a point of the canvas, read out of an actual render.
/// Top-left coordinates, so the numbers here read the way the slot is stored.
func colour(_ image: CIImage, atX x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
    let extent = image.extent
    let point = CGRect(x: extent.minX + CGFloat(x),
                       y: extent.minY + (extent.height - CGFloat(y) - 1),
                       width: 1, height: 1)
    var bytes = [UInt8](repeating: 0, count: 4)
    context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: point,
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
}

func isNear(_ got: (r: Int, g: Int, b: Int, a: Int)?, _ want: (Int, Int, Int), _ slack: Int = 12) -> Bool {
    guard let got else { return false }
    return abs(got.r - want.0) <= slack && abs(got.g - want.1) <= slack && abs(got.b - want.2) <= slack
}

// A drawing 2400x1800: an opaque white mat with a transparent opening at
// 10..90 % across and 10..90 % down, and one opaque BLUE stripe running
// through the middle of the opening. The stripe is the whole point — with an
// opaque mat and a photograph clipped to the slot, "photo under" and "photo
// over" would otherwise render identically, and the switch would look like it
// worked whichever way it was wired.
let artWidth = 2400, artHeight = 1800
var artPixels = [UInt8](repeating: 0, count: artWidth * artHeight * 4)
for row in 0..<artHeight {
    for column in 0..<artWidth {
        let index = (row * artWidth + column) * 4
        let insideHole = column >= 240 && column < 2160 && row >= 180 && row < 1620
        let onStripe = row >= 880 && row < 920
        if !insideHole || onStripe {
            // Premultiplied RGBA8: the mat is white, the stripe is blue.
            artPixels[index] = onStripe ? 0 : 255
            artPixels[index + 1] = onStripe ? 0 : 255
            artPixels[index + 2] = 255
            artPixels[index + 3] = 255
        }
    }
}
let art = CIImage(bitmapData: Data(artPixels), bytesPerRow: artWidth * 4,
                  size: CGSize(width: artWidth, height: artHeight),
                  format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

// A photograph 6000x4000 (3:2 — neither the canvas's shape nor the slot's),
// solid red with a green band down its left tenth, so which part of it landed
// in the opening can be read off the pixels.
let photoWidth = 6000, photoHeight = 4000
var photoPixels = [UInt8](repeating: 0, count: photoWidth * photoHeight * 4)
for row in 0..<photoHeight {
    for column in 0..<photoWidth {
        let index = (row * photoWidth + column) * 4
        photoPixels[index] = column < 600 ? 0 : 255
        photoPixels[index + 1] = column < 600 ? 255 : 0
        photoPixels[index + 2] = 0
        photoPixels[index + 3] = 255
    }
}
let photo = CIImage(bitmapData: Data(photoPixels), bytesPerRow: photoWidth * 4,
                    size: CGSize(width: photoWidth, height: photoHeight),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

let canvasTemplate = PrintTemplate(
    name: "mat", size: .eightBySix, orientation: .horizontal,
    slot: TemplateSlot(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
    artOverPhoto: true, artRef: "mat.png",
    artPixelWidth: artWidth, artPixelHeight: artHeight)

let under = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: art,
                                     placement: .centred, artOverPhoto: true)

check("the canvas is the PRINT size, whatever size the photograph was",
      under.extent.width == 2400 && under.extent.height == 1800,
      "got \(under.extent)")
check("outside the opening the drawing is what shows",
      isNear(colour(under, atX: 60, y: 60), (255, 255, 255)))
check("inside the opening the photograph is what shows",
      isNear(colour(under, atX: 1200, y: 1200), (255, 0, 0)),
      "got \(String(describing: colour(under, atX: 1200, y: 1200)))")

// ⚠️ The switch, measured on the one pixel that can tell the two apart.
check("photo UNDER: the drawing's stripe is drawn over the photograph",
      isNear(colour(under, atX: 1200, y: 900), (0, 0, 255)),
      "got \(String(describing: colour(under, atX: 1200, y: 900)))")

let over = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: art,
                                    placement: .centred, artOverPhoto: false)
check("photo OVER: the photograph covers the stripe",
      isNear(colour(over, atX: 1200, y: 900), (255, 0, 0)),
      "got \(String(describing: colour(over, atX: 1200, y: 900)))")
check("photo OVER: the drawing is still the backdrop outside the opening",
      isNear(colour(over, atX: 60, y: 60), (255, 255, 255)))

// ⚠️ THE ARITHMETIC, WRITTEN OUT, because the first version of these three
// checks was wrong about it and called a correct picture a failure. The
// opening is 1920x1440 at canvas x 240..2160; the photograph is 3:2, so
//   fill  scales by 1440/4000 = 0.36 -> 2160x1440, x 120..2280 (cropped to the
//         opening), and the green tenth down its left edge lands at x 120..336;
//   fit   scales by 1920/6000 = 0.32 -> 1920x1280, x 240..2160, y 260..1540,
//         and the green band lands at x 240..432.
// So x = 400 is the pixel that tells the two apart, and y = 1200 keeps clear
// of the drawing's stripe at y 880..920.
var fitPlacement = SlotPlacement(); fitPlacement.mode = .fit
let fitted2 = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: art,
                                       placement: fitPlacement, artOverPhoto: true)

check("fill crops the overhang — the photograph's green tenth is cut back",
      isNear(colour(under, atX: 400, y: 1200), (255, 0, 0)),
      "got \(String(describing: colour(under, atX: 400, y: 1200)))")
check("fit keeps it, because the whole width is in the opening",
      isNear(colour(fitted2, atX: 400, y: 1200), (0, 255, 0)),
      "got \(String(describing: colour(fitted2, atX: 400, y: 1200)))")
check("fill fills the opening top to bottom, where fit leaves paper",
      isNear(colour(under, atX: 1200, y: 200), (255, 0, 0)) &&
      isNear(colour(fitted2, atX: 1200, y: 200), (255, 255, 255)),
      "fill \(String(describing: colour(under, atX: 1200, y: 200)))")

// ⚠️ What fit leaves empty is PAPER, not a hole. A PNG with a hole exported
// over nothing is a picture with a hole in it.
check("what the photograph does not cover inside the opening is white paper",
      isNear(colour(fitted2, atX: 1200, y: 250), (255, 255, 255)) &&
      colour(fitted2, atX: 1200, y: 250)?.a == 255,
      "got \(String(describing: colour(fitted2, atX: 1200, y: 250)))")

// Moving the photograph in the slot moves what is seen through it: +0.45 of a
// slot width is 864 px, so the green band travels from x 120..336 to
// x 984..1200 and x = 1100 turns from red to green.
var shifted = SlotPlacement(); shifted.offsetX = 0.45
let moved2 = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: art,
                                      placement: shifted, artOverPhoto: true)
check("before the shift, x 1100 is the middle of the photograph",
      isNear(colour(under, atX: 1100, y: 1200), (255, 0, 0)))
check("pushing the photograph right carries its green edge to that pixel",
      isNear(colour(moved2, atX: 1100, y: 1200), (0, 255, 0)),
      "got \(String(describing: colour(moved2, atX: 1100, y: 1200)))")
check("and what it uncovers on the left is paper, not a hole",
      isNear(colour(moved2, atX: 300, y: 1200), (255, 255, 255)) &&
      colour(moved2, atX: 300, y: 1200)?.a == 255)

// ⚠️ THE CLIP MOVED, 20.09, on the client's word: the photograph is held to
// the PAPER, not to the hole — *„da mogu bukvalno da je pomeram dragujem po
// celom templetu da izabere ja lokaciju"*. A mat still shows it only through
// its own opening, because the mat is opaque everywhere else; but pushed off
// centre with the photo ON TOP it may sit anywhere on the print.
var pushedOut = SlotPlacement(); pushedOut.offsetX = -0.6
let offCentre = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: art,
                                         placement: pushedOut, artOverPhoto: false)
check("with the photo on top it can be dragged out over the mat",
      isNear(colour(offCentre, atX: 120, y: 900), (255, 0, 0)),
      "got \(String(describing: colour(offCentre, atX: 120, y: 900)))")

let coveredByMat = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: art,
                                            placement: pushedOut, artOverPhoto: true)
// y = 1200 keeps clear of the drawing's own blue stripe at y 880…920, which
// runs the full width of the mat — the first version of this check read the
// stripe and called the mat a photograph.
check("and under the mat the same move shows only through the opening",
      isNear(colour(coveredByMat, atX: 120, y: 1200), (255, 255, 255)),
      "got \(String(describing: colour(coveredByMat, atX: 120, y: 1200)))")

// Nothing may spill off the paper, whatever the drawing does.
var runOff = SlotPlacement(); runOff.offsetX = 50
let heldOnPaper = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: nil,
                                           placement: briefShowClampedPlacement(
                                               runOff,
                                               photoWidth: 6000, photoHeight: 4000,
                                               slot: canvasTemplate.slot.rect,
                                               canvasWidth: 2400, canvasHeight: 1800),
                                           artOverPhoto: false)
check("the canvas is still the canvas, however far the photo was pushed",
      heldOnPaper.extent.width == 2400 && heldOnPaper.extent.height == 1800)

// ⚠️ THE OUTLINE AND THE PICTURE, MEASURED AGAINST EACH OTHER. This is the
// fault the client saw: a positive offsetY moved the photograph UP in the
// print (Core Image counts rows from the bottom) while the selection outline,
// drawn in screen coordinates, moved DOWN — so the frame sat off the picture
// by twice the offset. Both now ask briefShowPhotoRectOnCanvas, and what it
// says is where the pixels are.
var down = SlotPlacement(); down.mode = .fit; down.zoom = 0.5; down.offsetY = 0.25
let movedDown = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: nil,
                                         placement: down, artOverPhoto: false)
let downRect = briefShowPhotoRectOnCanvas(photoWidth: 6000, photoHeight: 4000,
                                          slot: canvasTemplate.slot.rect,
                                          canvasWidth: 2400, canvasHeight: 1800,
                                          placement: down)
check("a positive offsetY puts the picture DOWN the page, where the outline draws it",
      isNear(colour(movedDown, atX: Int(downRect.midX), y: Int(downRect.midY)), (255, 0, 0)),
      "rect says \(downRect)")
check("and just above the outline there is paper, not picture",
      isNear(colour(movedDown, atX: Int(downRect.midX), y: Int(downRect.minY) - 30), (255, 255, 255)))
check("just inside its bottom edge there is picture",
      isNear(colour(movedDown, atX: Int(downRect.midX), y: Int(downRect.maxY) - 30), (255, 0, 0)))
check("and just below it, paper again",
      isNear(colour(movedDown, atX: Int(downRect.midX), y: Int(downRect.maxY) + 30), (255, 255, 255)))
check("the same for the left edge — the outline is the picture's own rectangle",
      isNear(colour(movedDown, atX: Int(downRect.minX) - 30, y: Int(downRect.midY)), (255, 255, 255)) &&
      isNear(colour(movedDown, atX: Int(downRect.minX) + 30, y: Int(downRect.midY)), (0, 255, 0)))

// ⚠️ WHICH WAY A TURN GOES, measured rather than reasoned about. The knob on
// the canvas reads CLOCKWISE, like the layer knob beside it, and Core Image
// counts its rows from the bottom — so the composition has to turn the other
// way to agree with the knob. The green tenth down the photograph's LEFT edge
// is what says which happened: turned 90° clockwise it belongs at the TOP.
//
// ⚠️ Measured at 0.6×, and the zoom is part of the measurement. Fit at 1×
// gives 1920×1280 and a quarter turn stands that on end — 1280 wide by 1920
// tall against an opening only 1440 tall — so the very band being looked for
// is clipped away by the hole. The first version of this check read red at
// the top and called the turn wrong; the turn was fine, the ruler was in the
// wrong place. At 0.6× the whole turned picture sits inside the opening:
// 1152×768 becomes 768×1152, y 324…1476.
var turned = SlotPlacement(); turned.mode = .fit; turned.zoom = 0.6; turned.rotationDegrees = 90
let rotated = briefShowComposeTemplate(photo: photo, template: canvasTemplate, art: nil,
                                       placement: turned, artOverPhoto: false)
check("a 90° turn is CLOCKWISE — the left edge of the photo ends up at the top",
      isNear(colour(rotated, atX: 1200, y: 380), (0, 255, 0)),
      "got \(String(describing: colour(rotated, atX: 1200, y: 380)))")
check("and the far edge ends up at the bottom",
      isNear(colour(rotated, atX: 1200, y: 1420), (255, 0, 0)),
      "got \(String(describing: colour(rotated, atX: 1200, y: 1420)))")
check("what the turned picture does not cover is paper, not a hole",
      isNear(colour(rotated, atX: 400, y: 900), (255, 255, 255)),
      "got \(String(describing: colour(rotated, atX: 400, y: 900)))")

// A vertical template of the same paper: the canvas turns, and so does the slot.
let verticalTemplate = PrintTemplate(
    name: "mat V", size: .eightBySix, orientation: .vertical,
    slot: TemplateSlot(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
    artOverPhoto: true, artRef: "matV.png",
    artPixelWidth: artHeight, artPixelHeight: artWidth)
let vertical = briefShowComposeTemplate(photo: photo, template: verticalTemplate, art: nil,
                                        placement: .centred, artOverPhoto: true)
check("a vertical template prints a vertical canvas",
      vertical.extent.width == 1800 && vertical.extent.height == 2400,
      "got \(vertical.extent)")
check("with no drawing at all the photograph still lands on paper",
      isNear(colour(vertical, atX: 900, y: 1200), (255, 0, 0)) &&
      isNear(colour(vertical, atX: 40, y: 40), (255, 255, 255)))

print("")
if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all passed")
