//  Templates.swift
//  KORAK 198, step 1 — the print template as a CANVAS, not as one more layer.
//
//  The client asked for 8×6 and 8×10 templates, horizontal and vertical, with
//  a hole the photograph lands in, and for the photograph to be able to sit
//  EITHER below the template art or above it. Those two are not the same
//  mechanism in the model the app has today:
//
//    photo BELOW — the art is a PNG with a transparent rectangle, drawn over
//      the photograph; the photograph shows through the hole. That is what an
//      ImageLayer above the background already does.
//    photo ABOVE — the art is a backdrop (a frame, a mat, a colour) and the
//      photograph sits ON it. Today's model cannot: the background IS the
//      photograph, and nothing can be put under it.
//
//  So the template is a CANVAS of fixed print proportions holding a slot and
//  one piece of art, plus a single switch saying which of the two is on top.
//  The photograph becomes the slot's CONTENT rather than the backdrop, and
//  both of the client's cases are then one mechanism instead of two.
//
//  ⚠️ TWO LOCKED RULES THIS FILE MUST NOT BREAK (both from the notes):
//
//  1. RESOLUTION. A photograph in LumenoLab works at the file's own
//     resolution. The canvas here is a PRINT size, which is where the pixels
//     are GOING; it is never the resolution they are worked at. Nothing in
//     this file downsamples a photograph, and the renderer must keep taking it
//     from `fullBaseImage`.
//  2. WHERE THINGS ARE KEPT. Every edit lives in one JSON blob in
//     UserDefaults that is rewritten after each change. So a photo's record
//     stores the template's ID and the slot placement — NEVER the template's
//     pixels. The art itself lives on disk in Application Support, the same
//     rule (and the same directory) that LayerPixelStore already follows.
//
//  This step is the model and the geometry only. No UI: the button, the picker
//  and the work inside the slot are step 2 and step 3.

import Foundation
import Combine
import CoreGraphics
import CoreImage
import CoreText
import ImageIO

// MARK: - The one place the print resolution is written

enum PrintOutput {

    /// 300 dpi, the client's answer of 20.09.
    ///
    /// ⚠️ It is a constant HERE and read everywhere else. The export sizes it
    /// implies (8×6 → 2400×1800, 8×10 → 3000×2400) are arithmetic, not typed
    /// in, so changing this number changes every one of them at once. A dpi
    /// copied into a second file is the kind of thing that stays 300 in one
    /// place and becomes 240 in the other.
    static let dpi: Double = 300
}

// MARK: - Print size

/// A print size in inches, held SHORT side first so one value covers both
/// orientations: 8×6 and 6×8 are the same paper turned round.
struct PrintSize: Codable, Equatable, Hashable {
    var shortInches: Double
    var longInches: Double

    static let eightBySix = PrintSize(shortInches: 6, longInches: 8)
    static let eightByTen = PrintSize(shortInches: 8, longInches: 10)

    /// The two the client named. Others can be added; nothing here is a list
    /// of four templates, it is a list of paper sizes.
    static let known: [PrintSize] = [.eightBySix, .eightByTen]

    /// "8 × 6 in" — long side first, which is how prints are ordered.
    var label: String {
        "\(briefShowTrimmedInches(longInches)) × \(briefShowTrimmedInches(shortInches)) in"
    }

    /// Long side ÷ short side. 8×6 is 1.333…, 8×10 is 1.25.
    var aspect: Double { longInches / shortInches }

    /// The pixel size of the canvas at the print resolution, laid out for the
    /// orientation asked for. A square template has no long side to place, so
    /// it takes the long one for both — it is the client's to correct.
    func pixels(orientation: TemplateOrientation, dpi: Double = PrintOutput.dpi) -> CGSize {
        let long = (longInches * dpi).rounded()
        let short = (shortInches * dpi).rounded()
        switch orientation {
        case .horizontal: return CGSize(width: long, height: short)
        case .vertical:   return CGSize(width: short, height: long)
        case .square:     return CGSize(width: long, height: long)
        }
    }
}

/// "8" not "8.0", "8.5" when it is one.
func briefShowTrimmedInches(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value.rounded())) : String(format: "%g", value)
}

/// Which known paper an imported drawing is, read off its own proportions.
///
/// ⚠️ A GUESS, and deliberately a narrow one. 4:3 and 4:5 are 2.6 % apart in a
/// world where a client's PNG can carry a bleed of a few pixels, so the
/// tolerance is tight and "no idea" is a legitimate answer: the import then
/// asks. Silently filing an 8×10 under 8×6 would print the photograph at the
/// wrong size, which is the one mistake here that costs paper.
func briefShowPrintSize(forPixelWidth width: Int, height: Int,
                        tolerance: Double = 0.01) -> PrintSize? {
    guard width > 0, height > 0 else { return nil }
    let long = Double(max(width, height))
    let short = Double(min(width, height))
    let aspect = long / short
    var best: PrintSize?
    var bestError = Double.greatestFiniteMagnitude
    for size in PrintSize.known {
        let error = abs(aspect - size.aspect) / size.aspect
        if error < bestError { bestError = error; best = size }
    }
    return bestError <= tolerance ? best : nil
}

// MARK: - Orientation

/// ⚠️ Read from the DRAWING, not typed in by the client. This is what step 4's
/// rule ("a vertical photograph gets a vertical template") runs on, so it has
/// to come off the file itself — but `square` exists because a square drawing
/// belongs to neither, and nobody but the client can say which pile it goes
/// in.
enum TemplateOrientation: String, Codable, Equatable, CaseIterable {
    case horizontal
    case vertical
    case square

    var label: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical:   return "Vertical"
        case .square:     return "Square"
        }
    }

    /// The orientation a PHOTOGRAPH asks for. A square photograph is called
    /// horizontal here on purpose: step 4 has to hand it SOME template, and a
    /// third pile that exists for one pixel of difference would be a pile the
    /// client has to fill.
    static func ofPhoto(width: Int, height: Int) -> TemplateOrientation {
        height > width ? .vertical : .horizontal
    }
}

func briefShowTemplateOrientation(width: Int, height: Int) -> TemplateOrientation {
    if width > height { return .horizontal }
    if height > width { return .vertical }
    return .square
}

// MARK: - The slot

/// A rectangle in CANVAS FRACTIONS, origin top-left, the way the drawing's own
/// pixels are laid out.
///
/// ⚠️ Fractions, never pixels. The same template is measured at import from a
/// PNG of whatever size the client drew, and printed at 300 dpi; a slot stored
/// in pixels would be right in exactly one of those. Core Image counts rows
/// from the BOTTOM, so the flip happens at the one place that draws — see
/// `briefShowSlotPixelRect(flipped:)`.
struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var isValid: Bool {
        width > 0 && height > 0 &&
        x >= 0 && y >= 0 && x + width <= 1.0001 && y + height <= 1.0001
    }
}

/// How the photograph meets a slot it does not have the proportions of.
///
/// ⚠️ Neither of these stretches. A photograph squeezed to fit a 4:5 hole is
/// the sort of thing that is only noticed once it is on paper.
enum SlotFitMode: String, Codable, Equatable, CaseIterable {
    /// The whole photograph inside the slot; the slot shows through where the
    /// proportions differ.
    case fit
    /// The slot fully covered; the photograph is cropped where it overhangs.
    /// This is the default — a print with a gap in the hole is not a print.
    case fill

    var label: String { self == .fit ? "Fit" : "Fill" }
}

/// Where the photograph sits INSIDE its slot. Lives in the photo's record,
/// not in the template: the template is a shape, this is one photograph's
/// place in it.
struct SlotPlacement: Codable, Equatable {
    var mode: SlotFitMode = .fill
    /// Offsets in SLOT widths/heights, so they survive both the import size
    /// and the print size. 0 is centred.
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// 1 = exactly fit/fill. Above 1 the photograph is pushed in closer.
    var zoom: Double = 1
    /// CLOCKWISE, like the rotate knob on the canvas and like a layer's own.
    var rotationDegrees: Double = 0

    static let centred = SlotPlacement()

    /// How far in and how far out the photograph may be taken inside its
    /// opening.
    ///
    /// ⚠️ 0.1, NOT 0.5. The client asked to be able to shrink the whole
    /// photograph inside the frame the way a layer shrinks — *„da mogu celu
    /// sliku da smanjim"* — and half size is not small. Below 1 in Fill the
    /// paper starts to show, which is his business and not the app's. A zoom
    /// of 0 is a photograph that is not there; 20× is one pixel across a
    /// print.
    static let minimumZoom = 0.1
    static let maximumZoom = 5.0

}

/// How far the photograph may be taken, in slot widths, measured from the
/// middle of the opening.
///
/// ⚠️ ASYMMETRIC, and it has to be: the opening is rarely in the middle of the
/// paper. The client's own template has its hole high on an 8×6 with a caption
/// band underneath, so "as far down as up" would stop the photograph short of
/// the bottom of the print while letting it run off the top.
struct SlotTravel: Equatable {
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
}

/// Where the photograph is allowed to go.
///
/// Two things at once, and the larger of them wins on each side:
///
///  - **the whole canvas.** The client asked to put the picture anywhere on
///    the template — *„da mogu bukvalno da je pomeram dragujem po celom
///    templetu da izabere ja lokaciju"* — so the middle of the photograph may
///    reach any point of the paper, not only of the hole.
///  - **half the overhang**, which is what lets a photograph BIGGER than the
///    opening be panned until its own far edge arrives. It grows with the
///    zoom: at 3× there is a lot of picture to reach.
///
/// ⚠️ TWO RULES DIED HERE, and both were the app deciding for the client.
/// First "never let a white sliver open down the edge of the print", which
/// measured out as six per cent of travel sideways and exactly none
/// vertically — reported as „drag ne radi". Then "at least keep the middle of
/// the picture inside the hole", which is this same mistake one size smaller.
/// What is left refuses only to lose the photograph off the paper altogether.
func briefShowPlacementTravel(photoWidth: Double, photoHeight: Double,
                              slot: NormalizedRect,
                              canvasWidth: Double, canvasHeight: Double,
                              placement: SlotPlacement) -> SlotTravel {
    let slotRect = briefShowSlotPixelRect(slot, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    guard photoWidth > 0, photoHeight > 0,
          slotRect.width > 0, slotRect.height > 0,
          canvasWidth > 0, canvasHeight > 0 else {
        return SlotTravel(minX: 0, maxX: 0, minY: 0, maxY: 0)
    }

    let scaleX = slotRect.width / photoWidth
    let scaleY = slotRect.height / photoHeight
    let base = placement.mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
    let zoom = max(SlotPlacement.minimumZoom, min(placement.zoom, SlotPlacement.maximumZoom))
    let width = photoWidth * base * zoom
    let height = photoHeight * base * zoom

    let overhangX = abs(width - slotRect.width) / (2 * slotRect.width)
    let overhangY = abs(height - slotRect.height) / (2 * slotRect.height)

    // From the middle of the opening out to each edge of the paper, in slot
    // widths — which is the unit the offsets are stored in.
    let left = Double(slotRect.midX) / Double(slotRect.width)
    let right = Double(canvasWidth - slotRect.midX) / Double(slotRect.width)
    let up = Double(slotRect.midY) / Double(slotRect.height)
    let down = Double(canvasHeight - slotRect.midY) / Double(slotRect.height)

    return SlotTravel(minX: -max(overhangX, left),
                      maxX: max(overhangX, right),
                      minY: -max(overhangY, up),
                      maxY: max(overhangY, down))
}

/// The placement, kept inside what the paper allows.
func briefShowClampedPlacement(_ placement: SlotPlacement,
                               photoWidth: Double, photoHeight: Double,
                               slot: NormalizedRect,
                               canvasWidth: Double, canvasHeight: Double) -> SlotPlacement {
    var next = placement
    next.zoom = max(SlotPlacement.minimumZoom, min(placement.zoom, SlotPlacement.maximumZoom))
    let travel = briefShowPlacementTravel(photoWidth: photoWidth, photoHeight: photoHeight,
                                          slot: slot,
                                          canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                          placement: next)
    next.offsetX = min(max(next.offsetX, travel.minX), travel.maxX)
    next.offsetY = min(max(next.offsetY, travel.minY), travel.maxY)
    return next
}

/// Where a drag leaves the photograph.
///
/// ⚠️ The translation is in POINTS ON SCREEN and the offsets are in slot
/// widths, so the slot's size on screen is what converts them. That is also
/// what makes the drag feel right at any preview size: the photograph follows
/// the pointer, rather than moving a fixed fraction per point dragged.
func briefShowPlacementAfterDrag(_ start: SlotPlacement,
                                 translationX: Double, translationY: Double,
                                 slotWidthOnScreen: Double, slotHeightOnScreen: Double,
                                 photoWidth: Double, photoHeight: Double,
                                 slot: NormalizedRect,
                                 canvasWidth: Double, canvasHeight: Double) -> SlotPlacement {
    guard slotWidthOnScreen > 0, slotHeightOnScreen > 0 else { return start }
    var next = start
    next.offsetX = start.offsetX + translationX / slotWidthOnScreen
    next.offsetY = start.offsetY + translationY / slotHeightOnScreen
    return briefShowClampedPlacement(next,
                                     photoWidth: photoWidth, photoHeight: photoHeight,
                                     slot: slot,
                                     canvasWidth: canvasWidth, canvasHeight: canvasHeight)
}

struct TemplateSlot: Codable, Equatable, Identifiable {
    var id = UUID()
    var rect: NormalizedRect
    /// What the import measured about the hole it found, kept so the UI can
    /// say why it is asking. nil when the client drew the rectangle himself.
    var detection: TemplateHoleDetection?
}

// MARK: - The template

/// ⚠️ ONE SLOT, ONE PHOTOGRAPH — the client's answer of 20.09 to question 3.
/// A collage of several holes is deferred, not refused, which is why the slot
/// is a named field and not an anonymous rectangle: adding `[TemplateSlot]`
/// later is a migration, and this file should not pretend it has already
/// happened.
struct PrintTemplate: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var size: PrintSize
    var orientation: TemplateOrientation
    var slot: TemplateSlot

    /// The switch the client asked for, and the whole reason this type is a
    /// canvas. false — the art is a backdrop and the photograph sits ON it.
    /// true — the art is drawn OVER the photograph and the photograph shows
    /// through its hole.
    var artOverPhoto: Bool = true

    /// The name of the drawing's blob on disk. NEVER the pixels — see the
    /// second locked rule at the top of this file.
    var artRef: String
    var artPixelWidth: Int
    var artPixelHeight: Int

    /// The horizontal and vertical drawings of one format, joined. Step 4's
    /// sync needs the pair: without it a mixed selection has nothing to give
    /// the photographs of the other orientation, and it has to SAY so rather
    /// than quietly print them sideways.
    var pairID: UUID?

    /// The canvas the export writes, in pixels.
    var canvasPixels: CGSize { size.pixels(orientation: orientation) }

    /// The drawing's own proportions, which the slot fractions were measured
    /// against.
    var artAspect: Double {
        artPixelHeight > 0 ? Double(artPixelWidth) / Double(artPixelHeight) : 1
    }
}

// MARK: - Geometry, all of it pure so it can be tested without a window

/// The slot in the pixels of a canvas of this size.
///
/// `flipped` is for Core Image, which counts rows from the bottom while the
/// stored fraction counts from the top. One flag at the one call site that
/// draws beats a second copy of the rectangle held the other way up.
func briefShowSlotPixelRect(_ rect: NormalizedRect,
                            canvasWidth: Double,
                            canvasHeight: Double,
                            flipped: Bool = false) -> CGRect {
    let x = rect.x * canvasWidth
    let width = rect.width * canvasWidth
    let height = rect.height * canvasHeight
    let y = flipped ? (1.0 - rect.y - rect.height) * canvasHeight : rect.y * canvasHeight
    return CGRect(x: x, y: y, width: width, height: height)
}

/// Where the photograph lands inside the slot: aspect KEPT, cropped or
/// letterboxed by the mode, then moved and zoomed by the placement.
///
/// ⚠️ The offsets are in slot widths, so the same placement means the same
/// framing at preview size and at 300 dpi. That is the whole reason they are
/// not stored in pixels.
func briefShowPhotoRectInSlot(photoWidth: Double,
                              photoHeight: Double,
                              slot: CGRect,
                              placement: SlotPlacement) -> CGRect {
    guard photoWidth > 0, photoHeight > 0, slot.width > 0, slot.height > 0 else { return slot }

    let scaleX = slot.width / photoWidth
    let scaleY = slot.height / photoHeight
    let base = placement.mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
    let zoom = max(0.01, placement.zoom)
    let width = photoWidth * base * zoom
    let height = photoHeight * base * zoom

    let centreX = slot.midX + placement.offsetX * slot.width
    let centreY = slot.midY + placement.offsetY * slot.height
    return CGRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height)
}

/// THE rectangle the photograph occupies on the canvas, in TOP-LEFT pixels.
///
/// ⚠️ ONE FUNCTION, ON PURPOSE, and it exists because there were two. The
/// composition worked the placement out against a slot already flipped into
/// Core Image's bottom-up coordinates, while the selection outline on the
/// canvas worked it out against the screen's top-down ones — so a positive
/// `offsetY` moved the picture UP in the print and the outline DOWN over it.
/// The client saw the result immediately: *„zasto ovaj selection ne prati
/// ivice slike??"*.
///
/// Now both ask this, and the renderer flips the answer at the last moment.
func briefShowPhotoRectOnCanvas(photoWidth: Double, photoHeight: Double,
                                slot: NormalizedRect,
                                canvasWidth: Double, canvasHeight: Double,
                                placement: SlotPlacement) -> CGRect {
    let slotRect = briefShowSlotPixelRect(slot, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    return briefShowPhotoRectInSlot(photoWidth: photoWidth, photoHeight: photoHeight,
                                    slot: slotRect, placement: placement)
}

/// Does this photograph, placed like this, leave any of the slot uncovered?
/// The export asks before it writes: a print with a transparent sliver down
/// one edge is a reprint.
func briefShowSlotIsCovered(photo: CGRect, slot: CGRect, tolerance: Double = 0.5) -> Bool {
    photo.minX <= slot.minX + tolerance &&
    photo.minY <= slot.minY + tolerance &&
    photo.maxX >= slot.maxX - tolerance &&
    photo.maxY >= slot.maxY - tolerance
}

// MARK: - Finding the hole

/// What the alpha channel said about the hole, kept with the slot.
struct TemplateHoleDetection: Codable, Equatable {
    /// Transparent pixels in the region ÷ the area of its bounding box. 1.0 is
    /// a true rectangle; a heart-shaped opening comes back near 0.78 and the
    /// client should be told the rectangle is only its box.
    var rectangularity: Double
    /// The share of the whole drawing the hole takes.
    var coverage: Double

    /// Below this the UI says "this opening is not a rectangle — check it".
    static let rectangularThreshold = 0.97
}

struct TemplateHole: Equatable {
    var rect: NormalizedRect
    var detection: TemplateHoleDetection
}

/// The largest transparent region of a drawing, as a rectangle in canvas
/// fractions.
///
/// ⚠️ IT IS HELP, NOT A CONDITION. The client's own answer of 20.09 is that he
/// brings his own PNGs; some will have a clean transparent rectangle and some
/// will be transparent all round the outside instead. So this returns nil
/// rather than guessing, and the import then lets him drag the rectangle
/// himself — which the UI in step 2 must offer whatever this says.
///
/// Regions TOUCHING THE EDGE are not holes. A drawing exported with a
/// transparent margin has one enormous transparent region running round the
/// whole frame, and it is bigger than the hole every time; taking the largest
/// region full stop would put the photograph behind the mat on exactly the
/// files most likely to be handed over.
///
/// Run-length connected components: each row is cut into transparent runs and
/// each run is joined to the ones it overlaps in the row above. That costs the
/// runs, not the pixels — a template drawing is a handful of runs per row, so
/// this measures a 3000×2400 PNG without ever holding a label per pixel.
func briefShowTemplateHole(alpha: [UInt8],
                           width: Int,
                           height: Int,
                           threshold: UInt8 = 8,
                           minimumCoverage: Double = 0.01) -> TemplateHole? {
    guard width > 0, height > 0, alpha.count >= width * height else { return nil }

    struct Run {
        var start: Int
        var end: Int       // exclusive
        var label: Int
    }

    var parent: [Int] = []
    func makeLabel() -> Int { parent.append(parent.count); return parent.count - 1 }
    func find(_ a: Int) -> Int {
        var root = a
        while parent[root] != root { root = parent[root] }
        var walk = a
        while parent[walk] != root { let next = parent[walk]; parent[walk] = root; walk = next }
        return root
    }
    func union(_ a: Int, _ b: Int) {
        let (ra, rb) = (find(a), find(b))
        if ra != rb { parent[rb] = ra }
    }

    var previous: [Run] = []
    var runs: [(row: Int, start: Int, end: Int, label: Int)] = []

    for row in 0..<height {
        var current: [Run] = []
        var column = 0
        let rowStart = row * width
        while column < width {
            guard alpha[rowStart + column] <= threshold else { column += 1; continue }
            var end = column
            while end < width && alpha[rowStart + end] <= threshold { end += 1 }
            var label = -1
            for above in previous where above.start < end && column < above.end {
                if label == -1 { label = find(above.label) } else { union(label, above.label) }
            }
            if label == -1 { label = makeLabel() }
            current.append(Run(start: column, end: end, label: label))
            runs.append((row, column, end, label))
            column = end
        }
        previous = current
    }
    guard !parent.isEmpty else { return nil }

    var area = [Int: Int]()
    var minX = [Int: Int](), maxX = [Int: Int](), minY = [Int: Int](), maxY = [Int: Int]()
    var touchesEdge = Set<Int>()
    for run in runs {
        let label = find(run.label)
        area[label, default: 0] += run.end - run.start
        minX[label] = min(minX[label] ?? Int.max, run.start)
        maxX[label] = max(maxX[label] ?? Int.min, run.end - 1)
        minY[label] = min(minY[label] ?? Int.max, run.row)
        maxY[label] = max(maxY[label] ?? Int.min, run.row)
        if run.row == 0 || run.row == height - 1 || run.start == 0 || run.end == width {
            touchesEdge.insert(label)
        }
    }

    let candidates = area.keys.filter { !touchesEdge.contains($0) }
    guard let best = candidates.max(by: { (area[$0] ?? 0) < (area[$1] ?? 0) }),
          let left = minX[best], let right = maxX[best],
          let top = minY[best], let bottom = maxY[best] else { return nil }

    let boxWidth = right - left + 1
    let boxHeight = bottom - top + 1
    let filled = Double(area[best] ?? 0)
    let coverage = filled / Double(width * height)
    guard coverage >= minimumCoverage else { return nil }

    let rect = NormalizedRect(x: Double(left) / Double(width),
                              y: Double(top) / Double(height),
                              width: Double(boxWidth) / Double(width),
                              height: Double(boxHeight) / Double(height))
    let detection = TemplateHoleDetection(
        rectangularity: filled / Double(boxWidth * boxHeight),
        coverage: coverage)
    return TemplateHole(rect: rect, detection: detection)
}

/// The alpha channel of a drawing, one byte per pixel, top row first.
///
/// `CGImageAlphaInfo.alphaOnly` is what keeps this honest about memory: a
/// 3000×2400 PNG costs 7 MB here instead of the 29 MB a colour copy would, and
/// this machine has 8 GB.
func briefShowAlphaChannel(of image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }

    // ⚠️ CGContext draws bottom-up and the stored fractions count from the
    // top, so the rows are turned over here — once, at the one place the
    // pixels are read — rather than leaving every later reader to remember it.
    var flipped = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
        let source = (height - 1 - row) * width
        let destination = row * width
        flipped.replaceSubrange(destination..<(destination + width),
                                with: bytes[source..<(source + width)])
    }
    return flipped
}

// MARK: - Where imported drawings live

/// The client's own PNGs, and the catalogue of what they are.
///
/// The same directory rule as LayerPixelStore, and for the same reason: the
/// folder on disk is named "BriefShow" because it is a PATH to his data, not
/// the product's name. Renaming it orphans every template he has imported.
enum TemplateStore {

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("BriefShow/Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var catalogueURL: URL? {
        directory?.appendingPathComponent("templates.json")
    }

    /// Content-addressed, exactly as the layer blobs are: importing the same
    /// drawing twice writes one file, and a drawing already on disk is never
    /// rewritten.
    static func artName(for data: Data) -> String {
        "\(data.count)-\(fingerprint(data)).png"
    }

    private static func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        let count = data.count
        let starts = [0, count / 3, count / 2, max(0, count - 96)]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for start in starts {
                for index in start..<min(start + 96, count) {
                    hash = (hash ^ UInt64(raw[index])) &* 1099511628211
                }
            }
        }
        return hash ^ UInt64(count)
    }

    static func artURL(for ref: String) -> URL? {
        directory?.appendingPathComponent(ref)
    }

    static func artData(for ref: String) -> Data? {
        guard let url = artURL(for: ref) else { return nil }
        return try? Data(contentsOf: url)
    }

    @discardableResult
    static func writeArt(_ data: Data) -> String? {
        guard let directory else { return nil }
        let name = artName(for: data)
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try data.write(to: url, options: .atomic) } catch { return nil }
        }
        return name
    }

    static func loadCatalogue() -> [PrintTemplate] {
        guard let catalogueURL, let data = try? Data(contentsOf: catalogueURL) else { return [] }
        return (try? JSONDecoder().decode([PrintTemplate].self, from: data)) ?? []
    }

    static func saveCatalogue(_ templates: [PrintTemplate]) {
        guard let catalogueURL,
              let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: catalogueURL, options: .atomic)
    }

    /// Drop a template and the drawing under it — but only when no other
    /// template is using that drawing, since two imports of the same PNG share
    /// one blob.
    ///
    /// ⚠️ It does NOT write the catalogue; the caller does, once, with whatever
    /// else changed in the same gesture. A store function that saves as a side
    /// effect is also a store function that a test cannot call without
    /// overwriting the client's own catalogue.
    static func remove(_ template: PrintTemplate, from templates: [PrintTemplate]) -> [PrintTemplate] {
        var remaining = templates.filter { $0.id != template.id }
        for index in remaining.indices where remaining[index].pairID == template.id {
            remaining[index].pairID = nil
        }
        if !remaining.contains(where: { $0.artRef == template.artRef }),
           let url = artURL(for: template.artRef) {
            try? FileManager.default.removeItem(at: url)
        }
        return remaining
    }
}

// MARK: - Import

enum TemplateImportOutcome {
    /// Imported, and the hole was found in the alpha channel.
    case measured(PrintTemplate)
    /// Imported, but nothing could be called a hole — the client draws the
    /// rectangle. The slot comes back as the middle of the canvas so there is
    /// something to drag rather than nothing to see.
    case needsRectangle(PrintTemplate, reason: String)
    case failed(reason: String)
}

enum TemplateImporter {

    /// A slot to hand the client when the drawing did not say where the hole
    /// is: the middle 80 %, the same shape as the canvas.
    static let fallbackSlot = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    /// Read a PNG the client chose, measure it, and put it in the store.
    ///
    /// ⚠️ The print size is a GUESS off the proportions and the caller must be
    /// able to overrule it — `size:` is there for the picker in step 2. An 8×10
    /// filed as an 8×6 prints at the wrong size on the client's paper.
    static func importArt(at url: URL,
                          name: String? = nil,
                          size: PrintSize? = nil,
                          artOverPhoto: Bool = true) -> TemplateImportOutcome {
        guard let data = try? Data(contentsOf: url) else {
            return .failed(reason: "The file could not be read.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failed(reason: "That file is not an image BriefShow can read.")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return .failed(reason: "That image has no pixels.")
        }
        guard let ref = TemplateStore.writeArt(data) else {
            return .failed(reason: "The template could not be saved to Application Support.")
        }

        let orientation = briefShowTemplateOrientation(width: width, height: height)
        let resolved = size ?? briefShowPrintSize(forPixelWidth: width, height: height)
            ?? (orientation == .square ? PrintSize.eightByTen : PrintSize.eightBySix)
        let title = name ?? url.deletingPathExtension().lastPathComponent

        let hole = briefShowAlphaChannel(of: image).flatMap {
            briefShowTemplateHole(alpha: $0, width: width, height: height)
        }

        var template = PrintTemplate(
            name: title,
            size: resolved,
            orientation: orientation,
            slot: TemplateSlot(rect: hole?.rect ?? fallbackSlot, detection: hole?.detection),
            artOverPhoto: artOverPhoto,
            artRef: ref,
            artPixelWidth: width,
            artPixelHeight: height)

        guard let hole else {
            template.slot.rect = fallbackSlot
            return .needsRectangle(template,
                reason: "No transparent opening was found in this drawing. Drag the rectangle "
                      + "over the place the photograph should land.")
        }
        if hole.detection.rectangularity < TemplateHoleDetection.rectangularThreshold {
            return .needsRectangle(template,
                reason: "The opening in this drawing is not a rectangle. The rectangle below is "
                      + "its outline — check it, or drag your own.")
        }
        return .measured(template)
    }
}

// MARK: - Reading a photograph's orientation without decoding it

/// Which way up a photograph is, from its metadata alone.
///
/// ⚠️ THE EXIF TAG DECIDES, not the pixel counts. A camera held upright writes
/// the sensor's own landscape pixels and a tag saying "turn this"; tags 5…8
/// are the quarter turns. Reading width against height and stopping there
/// would file every portrait frame from this client's Nikon as a landscape,
/// and the sync would then print them all sideways — quietly, which is the
/// part that matters.
func briefShowOrientationFromMetadata(pixelWidth: Int, pixelHeight: Int,
                                      exifOrientation: Int?) -> TemplateOrientation {
    var width = pixelWidth
    var height = pixelHeight
    if let exifOrientation, (5...8).contains(exifOrientation) {
        swap(&width, &height)
    }
    return TemplateOrientation.ofPhoto(width: width, height: height)
}

/// The same, read off a file — properties only, no decode. A sync across a
/// hundred photographs asks this a hundred times, and decoding a hundred RAWs
/// to learn which way up they are is the kind of thing that turns a click into
/// a minute.
func briefShowPhotoOrientation(at url: URL) -> TemplateOrientation? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return briefShowOrientationFromMetadata(pixelWidth: width, pixelHeight: height,
                                            exifOrientation: properties[kCGImagePropertyOrientation] as? Int)
}

/// The template a SYNC should write onto one target photograph.
///
/// ⚠️ This is where the pair earns its keep. A click on a tile uses exactly
/// what was clicked (see applyTemplate); a sync has nobody clicking, so an
/// upright photograph in a run of landscapes has to be given the other half of
/// the pair — or nothing at all. `nil` means "this one cannot take it", and the
/// caller has to SAY so rather than print a portrait sideways.
func briefShowSyncedTemplate(_ template: PrintTemplate,
                             forPhotoOrientation orientation: TemplateOrientation,
                             catalogue: [PrintTemplate]) -> PrintTemplate? {
    if template.orientation == orientation || template.orientation == .square { return template }
    guard let pairID = template.pairID,
          let partner = catalogue.first(where: { $0.id == pairID }),
          partner.orientation == orientation || partner.orientation == .square else { return nil }
    return partner
}

// MARK: - Pairing

/// Join a horizontal and a vertical drawing of the same format, so step 4's
/// sync can hand a portrait photograph a portrait template without asking.
///
/// ⚠️ Refuses a pair of the same orientation. Two horizontals joined would
/// leave sync believing it had a vertical to give and printing one sideways —
/// silently, on every portrait in the selection.
func briefShowCanPairTemplates(_ a: PrintTemplate, _ b: PrintTemplate) -> Bool {
    a.id != b.id &&
    a.orientation != b.orientation &&
    a.orientation != .square && b.orientation != .square &&
    a.size == b.size
}

/// The pair is stored on BOTH sides, each pointing at the other, so either one
/// found first leads to the other without a search through the catalogue.
func briefShowPairTemplates(_ a: PrintTemplate, _ b: PrintTemplate,
                            in templates: [PrintTemplate]) -> [PrintTemplate] {
    guard briefShowCanPairTemplates(a, b) else { return templates }
    var updated = templates
    for index in updated.indices {
        if updated[index].id == a.id {
            updated[index].pairID = b.id
        } else if updated[index].id == b.id {
            updated[index].pairID = a.id
        } else if updated[index].pairID == a.id || updated[index].pairID == b.id {
            // Anything that used to point at either of these is no longer
            // paired — a template belongs to one pair, and a stale pointer is
            // a template claiming a partner the other side has forgotten.
            updated[index].pairID = nil
        }
    }
    return updated
}

/// The template to use for a photograph of this shape, following the pair.
///
/// Returns nil when the chosen template is the wrong way round and has no
/// partner — which is the case step 4 has to SAY out loud rather than print
/// the photograph into a template it does not fit.
func briefShowTemplateForPhoto(width: Int, height: Int,
                               chosen: PrintTemplate,
                               catalogue: [PrintTemplate]) -> PrintTemplate? {
    let wanted = TemplateOrientation.ofPhoto(width: width, height: height)
    if chosen.orientation == wanted || chosen.orientation == .square { return chosen }
    guard let pairID = chosen.pairID,
          let partner = catalogue.first(where: { $0.id == pairID }),
          partner.orientation == wanted else { return nil }
    return partner
}

/// How much bigger than the print the canvas has to be drawn so the
/// photograph keeps its OWN pixels when a flatten bakes it in.
///
/// ⚠️ This is the locked resolution rule meeting the bake. The print canvas is
/// 2,400 × 1,800 at 300 dpi; a 6,000 px photograph laid into a 2,112 px
/// opening would be resampled down to 35 % on the way into the flattened file,
/// and nothing afterwards could get that back except Unflatten. So the bake is
/// drawn at the scale that keeps the picture's own pixels, and the export at
/// 300 dpi does the resizing — once, at the end, where it belongs.
///
/// ⚠️ CAPPED, because this machine has 8 GB. A canvas is four bytes a pixel
/// while it is being written, so the ceiling is expressed in megapixels rather
/// than in a scale factor: 60 MP is about 240 MB, which the flatten already
/// spends on a full-size render, and 6,000 px of photograph in this template
/// lands around 35 MP.
func briefShowBakeCanvasScale(photoWidth: Double, photoHeight: Double,
                              template: PrintTemplate,
                              placement: SlotPlacement,
                              megapixelCeiling: Double = 60) -> Double {
    let canvas = template.canvasPixels
    guard photoWidth > 0, photoHeight > 0, canvas.width > 0, canvas.height > 0 else { return 1 }
    let rect = briefShowPhotoRectOnCanvas(photoWidth: photoWidth, photoHeight: photoHeight,
                                          slot: template.slot.rect,
                                          canvasWidth: Double(canvas.width),
                                          canvasHeight: Double(canvas.height),
                                          placement: placement)
    guard rect.width > 1 else { return 1 }

    let wanted = max(1, photoWidth / Double(rect.width))
    let ceiling = (megapixelCeiling * 1_000_000 / (Double(canvas.width) * Double(canvas.height))).squareRoot()
    return min(wanted, max(1, ceiling))
}

// MARK: - The catalogue the app holds while it runs

/// The imported templates, in memory, with the disk behind them.
///
/// One shared instance, because two of them would be two catalogues writing
/// over each other's `templates.json` — the panel adds, the renderer reads,
/// and both have to be looking at the same list.
final class TemplateLibrary: ObservableObject {

    static let shared = TemplateLibrary()

    @Published private(set) var templates: [PrintTemplate] = []

    private init() {
        templates = TemplateStore.loadCatalogue()
    }

    func template(id: UUID?) -> PrintTemplate? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    /// Import a drawing the client chose, and keep it.
    ///
    /// ⚠️ It returns the outcome rather than swallowing it: `needsRectangle`
    /// carries a template that IS in the catalogue but whose slot is a guess,
    /// and the panel has to say so. An import that quietly filed a wrong
    /// rectangle would print the photograph in the wrong place.
    @discardableResult
    func importArt(at url: URL, name: String? = nil, size: PrintSize? = nil) -> TemplateImportOutcome {
        let outcome = TemplateImporter.importArt(at: url, name: name, size: size)
        switch outcome {
        case .measured(let template), .needsRectangle(let template, _):
            templates.append(template)
            // A drawing usually arrives with its other half, and the pair is
            // what lets a mixed selection sync without asking. Joining happens
            // here, on import, rather than as a gesture the client has to
            // remember: same paper, opposite orientation, neither already
            // spoken for.
            if let partner = templates.first(where: {
                $0.id != template.id && $0.pairID == nil && briefShowCanPairTemplates(template, $0)
            }) {
                templates = briefShowPairTemplates(template, partner, in: templates)
            }
            save()
        case .failed:
            break
        }
        return outcome
    }

    /// ⚠️ The pair is checked here, not at the call sites. Changing a
    /// template's paper or its orientation can make an existing pair illegal —
    /// two verticals joined would leave the sync believing it had a horizontal
    /// to give and printing portraits sideways — and a partner left pointing
    /// at a template that has forgotten it is the same fault seen from the
    /// other end. Both sides are cleared together or not at all.
    func update(_ template: PrintTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template

        if let pairID = template.pairID,
           let partnerIndex = templates.firstIndex(where: { $0.id == pairID }),
           !briefShowCanPairTemplates(templates[index], templates[partnerIndex]) {
            templates[index].pairID = nil
            templates[partnerIndex].pairID = nil
        }
        save()
    }

    func remove(_ template: PrintTemplate) {
        templates = TemplateStore.remove(template, from: templates)
        save()
    }

    func pair(_ a: PrintTemplate, _ b: PrintTemplate) {
        templates = briefShowPairTemplates(a, b, in: templates)
        save()
    }

    private func save() { TemplateStore.saveCatalogue(templates) }
}

// MARK: - Drawing the canvas

/// The drawings, decoded once. A template is redrawn on every slider the
/// client touches, and reading and decoding the same PNG each time is the kind
/// of cost that shows up as lag rather than as an error.
enum TemplateArtCache {

    private static let cache = NSCache<NSString, CIImage>()

    static func image(for ref: String) -> CIImage? {
        if let held = cache.object(forKey: ref as NSString) { return held }
        guard let url = TemplateStore.artURL(for: ref),
              let image = CIImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: ref as NSString)
        return image
    }
}

/// The finished print: the photograph in its slot, the drawing over it or
/// under it, on a canvas of the print's own proportions.
///
/// ⚠️ THE PHOTOGRAPH IS NEVER PRE-SHRUNK. It arrives here at whatever
/// resolution the caller rendered it — the full file, per the locked rule at
/// the top of this document — and is placed into the slot by a transform. Core
/// Image does the scaling when it draws, once, at the size being drawn.
///
/// ⚠️ Core Image counts rows from the BOTTOM and the slot is stored from the
/// top, which is why the slot is asked for flipped here. It is the only place
/// in the app that turns it over.
func briefShowComposeTemplate(photo: CIImage,
                              template: PrintTemplate,
                              placement: SlotPlacement,
                              artOverPhoto: Bool,
                              texts: [TemplateText] = [],
                              canvasScale: Double = 1) -> CIImage {
    briefShowComposeTemplate(photo: photo,
                             template: template,
                             art: TemplateArtCache.image(for: template.artRef),
                             placement: placement,
                             artOverPhoto: artOverPhoto,
                             texts: texts,
                             canvasScale: canvasScale)
}

/// The same composition with the drawing handed in.
///
/// ⚠️ The split is what makes this measurable. The wrapper above reaches into
/// Application Support for the client's PNG, and a test that did the same
/// would be writing into his own catalogue to ask a question about geometry.
func briefShowComposeTemplate(photo: CIImage,
                              template: PrintTemplate,
                              art: CIImage?,
                              placement: SlotPlacement,
                              artOverPhoto: Bool,
                              texts: [TemplateText] = [],
                              canvasScale: Double = 1) -> CIImage {
    let printed = template.canvasPixels
    let canvas = CGRect(x: 0, y: 0,
                        width: (printed.width * canvasScale).rounded(),
                        height: (printed.height * canvasScale).rounded())
    guard canvas.width > 1, canvas.height > 1 else { return photo }

    // The paper. Anything the photograph does not cover and the drawing does
    // not paint is white, not transparent: a PNG with a hole in it exported
    // over nothing is a picture with a hole in it.
    let paper = CIImage(color: CIColor.white).cropped(to: canvas)

    let extent = photo.extent
    var placed = photo
    if extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite {
        // Worked out the way the screen sees it — the same call the selection
        // outline makes — and turned over only here, because Core Image counts
        // its rows from the bottom.
        let onCanvas = briefShowPhotoRectOnCanvas(photoWidth: Double(extent.width),
                                                  photoHeight: Double(extent.height),
                                                  slot: template.slot.rect,
                                                  canvasWidth: Double(canvas.width),
                                                  canvasHeight: Double(canvas.height),
                                                  placement: placement)
        let target = CGRect(x: onCanvas.minX,
                            y: canvas.height - onCanvas.maxY,
                            width: onCanvas.width,
                            height: onCanvas.height)
        var transform = CGAffineTransform(translationX: target.midX, y: target.midY)
        if placement.rotationDegrees != 0 {
            // ⚠️ MINUS, and it is the difference between the knob and the
            // picture turning the same way. `rotationDegrees` is CLOCKWISE,
            // because that is what the rotate knob on the canvas reads and
            // what the layer knob beside it has always meant. Core Image
            // counts its rows from the bottom, so a positive angle there comes
            // out anti-clockwise on screen.
            transform = transform.rotated(by: CGFloat(-placement.rotationDegrees * .pi / 180))
        }
        transform = transform
            .scaledBy(x: target.width / extent.width, y: target.height / extent.height)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        placed = photo.transformed(by: transform)
    }

    // ⚠️ Clipped to the PAPER, not to the hole — changed 20.09 on the client's
    // word: *„da mogu bukvalno da je pomeram dragujem po celom templetu da
    // izabere ja lokaciju"*. The slot is where the photograph LANDS, not a
    // cage it has to stay in.
    //
    // With the drawing on top, a mat still shows the picture only through its
    // own opening, which is what a mat is. With the photograph on top it can
    // now sit anywhere on the print. Either way nothing spills off the paper.
    placed = placed.cropped(to: canvas)

    // ⚠️ ONE way out, and the texts are laid on it. Three separate `return`s
    // here would be three places a later change could forget the text — and
    // the two short ones are exactly the paths a template without art takes.
    func finished(_ print: CIImage) -> CIImage {
        texts.isEmpty ? print
            : briefShowComposeTemplateTexts(texts, over: print, template: template, canvas: canvas)
    }

    guard let art else {
        return finished(placed.composited(over: paper))
    }
    let artExtent = art.extent
    guard artExtent.width > 0, artExtent.height > 0 else {
        return finished(placed.composited(over: paper))
    }
    let drawn = art
        .transformed(by: CGAffineTransform(translationX: -artExtent.minX, y: -artExtent.minY))
        .transformed(by: CGAffineTransform(scaleX: canvas.width / artExtent.width,
                                           y: canvas.height / artExtent.height))

    // The client's switch, and the whole reason the template is a canvas: one
    // order of two images, not two different mechanisms.
    return finished(artOverPhoto
        ? drawn.composited(over: placed.composited(over: paper))
        : placed.composited(over: drawn.composited(over: paper)))
}

// MARK: - Text on the print
//
// KORAK 198, step 5. The client's words, 20.09: *„isto da moze da se doda Text
// na templateu, i da koristi sva free google fonta"*. The fonts themselves are
// step 6; this is the text, and it is drawn with whatever fonts the machine
// already has.

/// Which way a line sits inside its own box.
enum TemplateTextAlignment: String, Codable, Equatable, CaseIterable {
    case left, center, right

    var label: String {
        switch self {
        case .left: return "Left"
        case .center: return "Centre"
        case .right: return "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

/// A colour that survives a trip through JSON.
///
/// ⚠️ NOT `NSColor`. The whole record is one JSON blob (see the locked rule at
/// the top of this file); an archived `NSColor` in it is a blob inside a blob
/// that a later macOS is free to stop unarchiving. Four numbers cannot rot.
struct TemplateTextColor: Codable, Equatable {
    var red: Double = 0
    var green: Double = 0
    var blue: Double = 0
    var alpha: Double = 1

    static let black = TemplateTextColor()
    static let white = TemplateTextColor(red: 1, green: 1, blue: 1)

    var ciColor: CIColor {
        CIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// A piece of text laid on the print.
///
/// ⚠️ EVERYTHING HERE IS MEASURED AGAINST THE PAPER, NOT AGAINST PIXELS, and
/// that is the one rule this type exists to keep. The size is in INCHES of
/// print and the box is a fraction of the canvas, so the same record draws the
/// same text in the same place on the 900 px preview and on the 3000 px
/// export. A size in pixels would have been a size that means one thing on
/// screen and another on paper — which is the class of fault KORAK 198.4 had
/// to unpick once already with the selection outline.
struct TemplateText: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String = "Text"

    /// The font FAMILY as the system names it ("Helvetica Neue"), and the FACE
    /// within it ("Regular", "Bold", "Italic"). Two fields rather than one
    /// PostScript name because that is the shape step 6 needs: the Google
    /// catalogue is a list of families, each with the styles it has.
    var fontFamily: String = "Helvetica Neue"
    var fontFace: String = "Regular"

    /// Cap-to-descender size in INCHES OF PRINT. 0.25 in is about 18 pt.
    var sizeInches: Double = 0.25

    var color: TemplateTextColor = .black
    var alignment: TemplateTextAlignment = .center
    var opacity: Double = 1

    /// The box the text is laid out in, as a fraction of the canvas, measured
    /// from the TOP left — the same convention `TemplateSlot.rect` uses, and
    /// turned over in exactly one place (see `briefShowSlotPixelRect`).
    ///
    /// The width is the wrapping width. The height is what the box is drawn
    /// as on screen and what the text is centred in vertically; text taller
    /// than its box overflows it rather than being cut, because a client who
    /// has typed a third line should see the third line.
    var box: NormalizedRect = NormalizedRect(x: 0.1, y: 0.82, width: 0.8, height: 0.1)

    static let minimumSizeInches = 0.05
    static let maximumSizeInches = 3.0
}

/// How many pixels of this canvas one inch of print is.
///
/// ⚠️ Read off the CANVAS, not off `PrintOutput.dpi`, and that is what makes a
/// text the same size on the preview as on the export: the preview canvas is
/// the same paper drawn smaller, so an inch there is simply fewer pixels.
func briefShowPixelsPerInch(template: PrintTemplate, canvasWidth: Double) -> Double {
    let printed = template.canvasPixels
    guard printed.width > 0, canvasWidth > 0 else { return PrintOutput.dpi }
    return PrintOutput.dpi * canvasWidth / Double(printed.width)
}

/// How long the long edge of a photograph with NO template is taken to be, in
/// inches of print.
///
/// ⚠️ A PHOTOGRAPH HAS NO PAPER, and a text still has to be the same size on
/// the preview as in the export. The size in the record is inches, so the
/// picture is given a length: its long edge is read as an 8-inch print. That
/// makes a 0.25 in line one thirty-second of the long edge — the same fraction
/// on a 900 px preview and on a 6000 px export — and the same physical size it
/// would have on an 8-inch print of that photograph.
///
/// The alternative was a size in pixels of the preview, which is the exact
/// fault the whole of step 5 was written to avoid.
let briefShowPhotoLongEdgeInches: Double = 8

/// How many pixels of THIS canvas one inch is, for a picture that is not a
/// print.
func briefShowPhotoPixelsPerInch(canvasWidth: Double, canvasHeight: Double) -> Double {
    let longEdge = max(canvasWidth, canvasHeight)
    guard longEdge > 0 else { return PrintOutput.dpi }
    return longEdge / briefShowPhotoLongEdgeInches
}

/// Every line written on a photograph that is not a print.
///
/// ⚠️ Topmost, exactly as on a print, and for the same reason: the writing is
/// ON the picture. Nothing below it is touched, so an export of a photo with no
/// text is byte for byte what it was before this existed.
func briefShowComposeTextsOnPhoto(_ texts: [TemplateText], over photo: CIImage) -> CIImage {
    let canvas = photo.extent
    guard !texts.isEmpty, canvas.width > 1, canvas.height > 1,
          canvas.width.isFinite, canvas.height.isFinite else {
        return photo
    }
    let pixelsPerInch = briefShowPhotoPixelsPerInch(canvasWidth: Double(canvas.width),
                                                    canvasHeight: Double(canvas.height))
    var output = photo
    for text in texts {
        // ⚠️ Drawn in the canvas's OWN coordinates: a cropped photograph's
        // extent does not start at zero, and a text laid out as if it did
        // would sit off the picture by however far the crop moved it.
        guard let drawn = briefShowDrawText(text,
                                            canvas: CGRect(origin: .zero, size: canvas.size),
                                            pixelsPerInch: pixelsPerInch) else { continue }
        output = drawn
            .transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
            .composited(over: output)
    }
    return output
}

/// The box in pixels of the canvas, top-left measured — the screen's way up.
func briefShowTextPixelRect(_ text: TemplateText,
                            canvasWidth: Double,
                            canvasHeight: Double) -> CGRect {
    briefShowSlotPixelRect(text.box, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
}

/// The box moved by a drag, kept on the paper.
///
/// ⚠️ Clamped to the CANVAS, not to the mat: text belongs wherever the client
/// puts it, including over the photograph — the same answer KORAK 198.6 gave
/// for the photograph itself. What it may not do is walk off the paper, where
/// it would be a text nobody can find and nobody can print.
func briefShowTextBoxAfterDrag(_ start: NormalizedRect,
                               translation: CGSize,
                               canvasWidth: Double,
                               canvasHeight: Double) -> NormalizedRect {
    guard canvasWidth > 0, canvasHeight > 0 else { return start }
    var moved = start
    moved.x += Double(translation.width) / canvasWidth
    moved.y += Double(translation.height) / canvasHeight
    // Half the box may hang off, never all of it.
    moved.x = min(max(moved.x, -moved.width / 2), 1 - moved.width / 2)
    moved.y = min(max(moved.y, -moved.height / 2), 1 - moved.height / 2)
    return moved
}

/// The font a record asks for, or the nearest thing this machine has.
///
/// ⚠️ It never returns nil, and that is deliberate. A print that silently
/// loses its text because a font was uninstalled is worse than a print in
/// another face — and step 6 hands this exactly the same two strings for a
/// downloaded Google family, so nothing here changes when they arrive.
func briefShowTemplateTextFont(family: String, face: String, sizePixels: Double) -> CTFont {
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontFamilyNameAttribute: family as CFString,
        kCTFontStyleNameAttribute: face as CFString
    ] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, CGFloat(max(1, sizePixels)), nil)
}

/// One piece of text, drawn at the size the canvas makes it.
///
/// Returns the text as a CIImage already placed in canvas coordinates — Core
/// Image's way up, counted from the bottom — so the caller only composites.
///
/// ⚠️ The surface is the BOX, grown downward to hold as many lines as there
/// are. Text taller than its box overflows rather than being clipped: a client
/// who has typed a third line must see the third line, on screen and on paper
/// alike.
func briefShowDrawTemplateText(_ text: TemplateText,
                               template: PrintTemplate,
                               canvas: CGRect) -> CIImage? {
    briefShowDrawText(text, canvas: canvas,
                      pixelsPerInch: briefShowPixelsPerInch(template: template,
                                                            canvasWidth: Double(canvas.width)))
}

/// The same drawing, told how big an inch is here.
///
/// ⚠️ The split is what lets a line of text live on a PHOTOGRAPH as well as on
/// a print — asked for 20.09: *„dodaj da text moze bilo gde da se stavi cak i
/// na normalnu sliku ne samo na template"*. A print knows its paper; a
/// photograph is given one (see `briefShowPhotoPixelsPerInch`), and everything
/// below is the same code either way.
func briefShowDrawText(_ text: TemplateText,
                       canvas: CGRect,
                       pixelsPerInch: Double) -> CIImage? {
    let content = text.text
    guard !content.isEmpty, text.opacity > 0, canvas.width > 1, canvas.height > 1 else {
        return nil
    }

    let box = briefShowTextPixelRect(text, canvasWidth: Double(canvas.width),
                                     canvasHeight: Double(canvas.height))
    guard box.width >= 1 else { return nil }

    let font = briefShowTemplateTextFont(family: text.fontFamily,
                                         face: text.fontFace,
                                         sizePixels: text.sizeInches * pixelsPerInch)

    // ⚠️ CoreText's own paragraph style, not AppKit's. This file draws the
    // print and knows nothing about views, and it stays that way — the batch
    // flatten and the export run it with no window anywhere.
    var alignment: CTTextAlignment
    switch text.alignment {
    case .left: alignment = .left
    case .center: alignment = .center
    case .right: alignment = .right
    }
    // Wrapping, not truncation: the box is a width to wrap at, not a cage.
    var lineBreak = CTLineBreakMode.byWordWrapping
    let paragraph: CTParagraphStyle = withUnsafeBytes(of: &alignment) { alignBytes in
        withUnsafeBytes(of: &lineBreak) { breakBytes in
            var settings = [
                CTParagraphStyleSetting(spec: .alignment,
                                        valueSize: MemoryLayout<CTTextAlignment>.size,
                                        value: alignBytes.baseAddress!),
                CTParagraphStyleSetting(spec: .lineBreakMode,
                                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                                        value: breakBytes.baseAddress!)
            ]
            return CTParagraphStyleCreate(&settings, settings.count)
        }
    }

    let colour = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                         components: [CGFloat(text.color.red), CGFloat(text.color.green),
                                      CGFloat(text.color.blue), CGFloat(text.color.alpha)])
    let attributed = NSAttributedString(string: content, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour as Any
    ])

    let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    let constraint = CGSize(width: box.width, height: .greatestFiniteMagnitude)
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)

    let surfaceWidth = Int(box.width.rounded(.up))
    let surfaceHeight = Int(max(suggested.height, box.height).rounded(.up))
    guard surfaceWidth >= 1, surfaceHeight >= 1,
          let context = CGContext(data: nil,
                                  width: surfaceWidth,
                                  height: surfaceHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }

    let surface = CGRect(x: 0, y: 0, width: CGFloat(surfaceWidth), height: CGFloat(surfaceHeight))
    let path = CGPath(rect: surface, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)

    guard let drawn = context.makeImage() else { return nil }
    var image = CIImage(cgImage: drawn)

    if text.opacity < 1 {
        let filter = CIFilter(name: "CIColorMatrix")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(text.opacity)), forKey: "inputAVector")
        if let faded = filter?.outputImage {
            image = faded
        }
    }

    // The surface is centred on the box vertically, so growing a second line
    // pushes the text outward from where the client placed it rather than
    // dropping it downward from the top edge.
    let topY = box.midY - CGFloat(surfaceHeight) / 2
    // ⚠️ Turned over HERE, and only here: the box is stored from the top and
    // Core Image counts its rows from the bottom.
    let originY = canvas.height - (topY + CGFloat(surfaceHeight))
    return image.transformed(by: CGAffineTransform(translationX: box.minX, y: originY))
}

/// Every piece of text on the print, over whatever is already there.
///
/// ⚠️ TEXT IS ALWAYS TOPMOST, above the art AND above the photograph, and it
/// is not a switch. With the photograph on top of the art (the client's
/// „Photo Over"), text under it would be a text that vanishes with nothing on
/// screen to say why — and the thing being typed is a name or a studio mark,
/// which is written ON a print, not inside it.
func briefShowComposeTemplateTexts(_ texts: [TemplateText],
                                   over base: CIImage,
                                   template: PrintTemplate,
                                   canvas: CGRect) -> CIImage {
    var output = base
    for text in texts {
        guard let drawn = briefShowDrawTemplateText(text, template: template, canvas: canvas) else {
            continue
        }
        output = drawn.composited(over: output)
    }
    return output
}

// MARK: - The fonts this machine has
//
// ⚠️ THIS IS NOT STEP 6. The Google catalogue, the Download button and the
// permanent cache are their own step; these two read what is already
// installed, which is what the text can be set in today. When step 6 registers
// a downloaded family with CoreText it appears here with no change to either
// of these — which is the reason the record carries a FAMILY and a FACE rather
// than a PostScript name.

private let briefShowInstalledFamilyLock = NSLock()
private var briefShowInstalledFamilyCache: [String]?

/// Every font family on the machine, named the way a human names them.
///
/// ⚠️ CACHED, NOT CONSTANT. It is read on every rebuild of the panel, and a
/// font match walks the whole registry — but the list DOES change while the
/// app runs, because step 6 downloads families into it. Whoever adds one calls
/// `briefShowRefreshInstalledFontFamilies()`; a constant here would mean a
/// font the client just downloaded is missing from the list he downloaded it
/// from, until the next launch.
func briefShowInstalledFontFamilies() -> [String] {
    briefShowInstalledFamilyLock.lock()
    defer { briefShowInstalledFamilyLock.unlock() }
    if let held = briefShowInstalledFamilyCache { return held }
    let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
    // The dot-prefixed ones are the system's own private faces (".SF NS" and
    // friends). They are not the client's to choose and they do not survive a
    // trip through a font name.
    let families = names.filter { !$0.hasPrefix(".") }.sorted()
    briefShowInstalledFamilyCache = families
    return families
}

/// A family has been added to the machine — read the registry again, and drop
/// the faces cached for it.
func briefShowRefreshInstalledFontFamilies() {
    briefShowInstalledFamilyLock.lock()
    briefShowInstalledFamilyCache = nil
    briefShowInstalledFamilyLock.unlock()
    briefShowFontFaceCache.removeAllObjects()
}

private let briefShowFontFaceCache = NSCache<NSString, NSArray>()

/// The styles a family has — "Regular", "Bold", "Italic"…
///
/// ⚠️ Cached, because this is asked on every rebuild of the panel and a font
/// match walks the whole registry.
func briefShowFontFaces(in family: String) -> [String] {
    if let held = briefShowFontFaceCache.object(forKey: family as NSString) as? [String] {
        return held
    }
    let descriptor = CTFontDescriptorCreateWithAttributes(
        [kCTFontFamilyNameAttribute: family as CFString] as CFDictionary)
    // nil: nothing is mandatory beyond the family already in the descriptor.
    let matched = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil)
        as? [CTFontDescriptor] ?? []

    var seen = Set<String>()
    var faces: [String] = []
    for candidate in matched {
        guard let face = CTFontDescriptorCopyAttribute(candidate, kCTFontStyleNameAttribute) as? String,
              !seen.contains(face) else { continue }
        seen.insert(face)
        faces.append(face)
    }
    if faces.isEmpty {
        faces = ["Regular"]
    } else if let plain = faces.firstIndex(of: "Regular"), plain != 0 {
        // Regular first, whatever order the registry hands them back in: it is
        // what a new piece of text is set in, and a list that opens on
        // "Condensed Black" reads as the wrong font having been chosen.
        faces.insert(faces.remove(at: plain), at: 0)
    }
    briefShowFontFaceCache.setObject(faces as NSArray, forKey: family as NSString)
    return faces
}

// MARK: - The print, on its paper

/// The finished print, landed exactly on its own paper.
///
/// ⚠️ A SCALE, never a crop and never a stretch. Both sides come from the same
/// template and therefore have the same proportions; what differs is how many
/// pixels the bake needed in order to keep the photograph at its own
/// resolution (see `briefShowBakeCanvasScale`). Without this, the SAME
/// template exported one size from a live record and another from a baked one
/// — which is what step 7 of the plan means by aligning the two.
///
/// The crop at the end takes a rounded half-pixel off the edge: an extent of
/// 3000.0001 writes a 3001-pixel file otherwise.
func briefShowFitToPrintCanvas(_ image: CIImage, canvas: CGSize) -> CIImage {
    let extent = image.extent
    guard extent.width > 1, extent.height > 1,
          canvas.width > 1, canvas.height > 1,
          extent.width.isFinite, extent.height.isFinite else {
        return image
    }
    let scale = min(canvas.width / extent.width, canvas.height / extent.height)
    let placed = abs(scale - 1) < 1e-9
        ? image
        : image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let origin = placed.extent.origin
    return placed.cropped(to: CGRect(x: origin.x, y: origin.y,
                                     width: canvas.width, height: canvas.height))
}
