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
    var rotationDegrees: Double = 0

    static let centred = SlotPlacement()

    /// How far in and how far out the photograph may be taken inside its
    /// opening. Below 1 in Fill it starts showing paper, which is the client's
    /// business, not the app's — but a zoom of 0 is a photograph that is not
    /// there, and 20× is a single pixel blown across a print.
    static let minimumZoom = 0.5
    static let maximumZoom = 5.0
}

/// How far the placement may travel before the photograph leaves its opening.
///
/// In Fill the photograph is bigger than the opening, so it may slide by half
/// the overhang and no further — one step past that and a white sliver appears
/// down one edge, which on paper is a reprint. In Fit it is smaller, and the
/// same arithmetic keeps it INSIDE instead: |photo − slot| ÷ 2, either way
/// round, in slot widths.
func briefShowPlacementLimits(photoWidth: Double, photoHeight: Double,
                              slotWidth: Double, slotHeight: Double,
                              placement: SlotPlacement) -> (x: Double, y: Double) {
    guard photoWidth > 0, photoHeight > 0, slotWidth > 0, slotHeight > 0 else { return (0, 0) }
    let scaleX = slotWidth / photoWidth
    let scaleY = slotHeight / photoHeight
    let base = placement.mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
    let zoom = max(SlotPlacement.minimumZoom, min(placement.zoom, SlotPlacement.maximumZoom))
    let width = photoWidth * base * zoom
    let height = photoHeight * base * zoom
    return (abs(width - slotWidth) / (2 * slotWidth),
            abs(height - slotHeight) / (2 * slotHeight))
}

/// The placement, kept inside what the opening allows.
func briefShowClampedPlacement(_ placement: SlotPlacement,
                               photoWidth: Double, photoHeight: Double,
                               slotWidth: Double, slotHeight: Double) -> SlotPlacement {
    var next = placement
    next.zoom = max(SlotPlacement.minimumZoom, min(placement.zoom, SlotPlacement.maximumZoom))
    let limits = briefShowPlacementLimits(photoWidth: photoWidth, photoHeight: photoHeight,
                                          slotWidth: slotWidth, slotHeight: slotHeight,
                                          placement: next)
    next.offsetX = min(max(next.offsetX, -limits.x), limits.x)
    next.offsetY = min(max(next.offsetY, -limits.y), limits.y)
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
                                 photoWidth: Double, photoHeight: Double) -> SlotPlacement {
    guard slotWidthOnScreen > 0, slotHeightOnScreen > 0 else { return start }
    var next = start
    next.offsetX = start.offsetX + translationX / slotWidthOnScreen
    next.offsetY = start.offsetY + translationY / slotHeightOnScreen
    return briefShowClampedPlacement(next,
                                     photoWidth: photoWidth, photoHeight: photoHeight,
                                     slotWidth: slotWidthOnScreen, slotHeight: slotHeightOnScreen)
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

    func update(_ template: PrintTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
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
                              canvasScale: Double = 1) -> CIImage {
    briefShowComposeTemplate(photo: photo,
                             template: template,
                             art: TemplateArtCache.image(for: template.artRef),
                             placement: placement,
                             artOverPhoto: artOverPhoto,
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
                              canvasScale: Double = 1) -> CIImage {
    let printed = template.canvasPixels
    let canvas = CGRect(x: 0, y: 0,
                        width: (printed.width * canvasScale).rounded(),
                        height: (printed.height * canvasScale).rounded())
    guard canvas.width > 1, canvas.height > 1 else { return photo }

    let slot = briefShowSlotPixelRect(template.slot.rect,
                                      canvasWidth: canvas.width,
                                      canvasHeight: canvas.height,
                                      flipped: true)

    // The paper. Anything the photograph does not cover and the drawing does
    // not paint is white, not transparent: a PNG with a hole in it exported
    // over nothing is a picture with a hole in it.
    let paper = CIImage(color: CIColor.white).cropped(to: canvas)

    let extent = photo.extent
    var placed = photo
    if extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite {
        let target = briefShowPhotoRectInSlot(photoWidth: extent.width,
                                              photoHeight: extent.height,
                                              slot: slot,
                                              placement: placement)
        var transform = CGAffineTransform(translationX: target.midX, y: target.midY)
        if placement.rotationDegrees != 0 {
            transform = transform.rotated(by: CGFloat(placement.rotationDegrees * .pi / 180))
        }
        transform = transform
            .scaledBy(x: target.width / extent.width, y: target.height / extent.height)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        placed = photo.transformed(by: transform)
    }

    // ⚠️ Clipped to the SLOT, always — including when the drawing sits on top
    // of it. The hole in a client's PNG is his drawing's business, and a
    // photograph wider than the slot would otherwise run out under the mat and
    // reappear wherever else the drawing happens to be transparent.
    placed = placed.cropped(to: slot)

    guard let art else {
        return placed.composited(over: paper)
    }
    let artExtent = art.extent
    guard artExtent.width > 0, artExtent.height > 0 else {
        return placed.composited(over: paper)
    }
    let drawn = art
        .transformed(by: CGAffineTransform(translationX: -artExtent.minX, y: -artExtent.minY))
        .transformed(by: CGAffineTransform(scaleX: canvas.width / artExtent.width,
                                           y: canvas.height / artExtent.height))

    // The client's switch, and the whole reason the template is a canvas: one
    // order of two images, not two different mechanisms.
    return artOverPhoto
        ? drawn.composited(over: placed.composited(over: paper))
        : placed.composited(over: drawn.composited(over: paper))
}
