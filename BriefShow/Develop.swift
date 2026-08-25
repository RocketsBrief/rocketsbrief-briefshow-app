//
//  Develop.swift
//  BriefShow
//
//  "Develop" — a standalone, Lightroom-style non-destructive photo editor,
//  opened from ShowGrid's own "Develop" header button (see ContentView.swift).
//  Deliberately kept separate from PhotoShowSheet (ShowGrid's grid/loupe/
//  rating screen) and from the Kousei/Kirigami/Origami slideshow pipeline —
//  editing a photo here never touches the original file on disk and never
//  affects a slideshow export. It only writes a small per-photo settings
//  record (see PhotoEditStore) that this screen reads back on reopen, and
//  "Export Edited Copy" writes a brand-new file alongside the original.
//

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - Edit model

// Every field here is a delta around 0 = "untouched" (never an absolute
// filter parameter), so a fresh PhotoEditSettings() is trivially "no edit
// at all" (see isNeutral) and each slider can be reset independently just
// by setting it back to 0.
struct PhotoEditSettings: Codable, Equatable {
    var exposure: Double = 0        // EV, roughly -3...3
    var contrast: Double = 0        // -1...1
    var highlights: Double = 0      // -1 (recover blown highlights) ...1
    var shadows: Double = 0         // -1 (darken) ...1 (lift)
    var whites: Double = 0          // -1 (dull white point) ...1 (brighter/clips more)
    var blacks: Double = 0          // -1 (crush black point) ...1 (lift/brighter)
    var saturation: Double = 0      // -1...1
    var vibrance: Double = 0        // -1...1
    var temperature: Double = 0     // -1 (cooler) ...1 (warmer)
    var tint: Double = 0            // -1 (green) ...1 (magenta)
    var sharpness: Double = 0       // 0...1
    var texture: Double = 0         // -1 (smooth/soften mid-frequency detail — "younger, softer" portrait skin) ...1 (bring skin/fabric/hair texture out), see PhotoEditRenderer.render.
    var clarity: Double = 0         // 0...1 — Lightroom-style local (midtone) contrast boost, see PhotoEditRenderer.render. Positive only for now — no softening/negative range yet.
    var dehaze: Double = 0          // 0...1 — contrast/saturation/black-point APPROXIMATION of Lightroom's Dehaze, not a real dark-channel-prior algorithm, see PhotoEditRenderer.render.
    var softGlow: Double = 0        // 0...1 — diffusion/"soft focus" glow (blurred copy screen-blended back over the original), see PhotoEditRenderer.render.
    var vignette: Double = 0        // 0...1
    var rotationQuarterTurns: Int = 0   // 0...3, applied in 90° steps
    var straightenDegrees: Double = 0   // -45...45, fine rotation
    var crop: EditCropRect?             // nil = uncropped
    var localAdjustments: [LocalAdjustment] = []   // masks — see LocalAdjustment
    var layers: [ImageLayer] = []        // pasted cut/copied pieces — see ImageLayer

    init() {}

    // Written by hand (instead of relying on synthesized Decodable) so that
    // settings saved by an older build — before `whites`/`blacks` existed —
    // still decode instead of throwing and silently wiping out a user's
    // saved edit (see PhotoEditStore.allSettings, which drops anything that
    // fails to decode).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        softGlow = try c.decodeIfPresent(Double.self, forKey: .softGlow) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        rotationQuarterTurns = try c.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
        straightenDegrees = try c.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        crop = try c.decodeIfPresent(EditCropRect.self, forKey: .crop)
        localAdjustments = try c.decodeIfPresent([LocalAdjustment].self, forKey: .localAdjustments) ?? []
        layers = try c.decodeIfPresent([ImageLayer].self, forKey: .layers) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, saturation, vibrance
        case temperature, tint, sharpness, texture, clarity, dehaze, softGlow, vignette
        case rotationQuarterTurns, straightenDegrees, crop
        case localAdjustments, layers
    }

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && whites == 0 && blacks == 0
            && saturation == 0 && vibrance == 0 && temperature == 0 && tint == 0
            && sharpness == 0 && texture == 0 && clarity == 0 && dehaze == 0 && softGlow == 0
            && vignette == 0 && rotationQuarterTurns == 0
            && straightenDegrees == 0 && crop == nil && localAdjustments.isEmpty
            && layers.isEmpty
    }
}

// Which groups of PhotoEditSettings a "Synchronize Settings" sync should
// touch on each target photo — mirrors Lightroom's own Sync Settings dialog
// (a checklist of categories, all checked by default, "Synchronize" applies
// only the checked ones and leaves everything else on the target untouched).
// Grouped the same way Develop's own right-hand panel sections are (Crop &
// Rotate / Light / Color / Detail & Effects / Masks) so the dialog reads as
// "the same panel, but as checkboxes" rather than inventing a new taxonomy.
// `layers` (pasted cut/copy pieces) is deliberately NOT offered here — a
// layer is pixel content extracted from one specific photo, copying it onto
// an unrelated photo isn't a "setting" the way exposure or crop is, and
// Lightroom has no equivalent concept to model it after.
struct SyncCategory: OptionSet {
    let rawValue: Int

    static let cropRotate = SyncCategory(rawValue: 1 << 0)
    static let light = SyncCategory(rawValue: 1 << 1)
    static let color = SyncCategory(rawValue: 1 << 2)
    static let detail = SyncCategory(rawValue: 1 << 3)
    static let masks = SyncCategory(rawValue: 1 << 4)

    static let all: SyncCategory = [.cropRotate, .light, .color, .detail, .masks]

    // (title, SF Symbol) for each category's checkbox row, in the order the
    // sync dialog lists them — same top-to-bottom order as the adjustment
    // panel itself (Crop & Rotate first, Masks last).
    static let displayOrder: [(category: SyncCategory, title: String, icon: String)] = [
        (.cropRotate, "Crop & Rotate", "crop"),
        (.light, "Light", "sun.max"),
        (.color, "Color", "paintpalette"),
        (.detail, "Detail & Effects", "wand.and.stars"),
        (.masks, "Masks", "circle.lefthalf.filled"),
    ]
}

// What "Export" writes. Until now every export path hardcoded JPEG, and not
// even the same JPEG: the panel's own button used quality 0.92 while the
// filmstrip's right-click export used 1.0, so which button you happened to
// press changed the file you got. One setting now feeds all four paths.
enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg, png, tiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tif"
        }
    }

    var contentType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        }
    }

    /// Only JPEG is lossy, so only JPEG has anything to trade.
    var isLossy: Bool { self == .jpeg }

    func encode(_ representation: NSBitmapImageRep, quality: Double) -> Data? {
        switch self {
        case .jpeg:
            return representation.representation(
                using: .jpeg, properties: [.compressionFactor: min(max(quality, 0.1), 1.0)])
        case .png:
            return representation.representation(using: .png, properties: [:])
        case .tiff:
            // LZW rather than none: lossless either way, and a 45MP export is
            // a very large file to leave uncompressed for no gain.
            return representation.representation(
                using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])
        }
    }
}

// A crop rectangle in the unit square (0...1 on each axis) of the image
// AFTER rotation/straighten — so it stays valid across preview resolutions,
// and applying rotation before crop in PhotoEditRenderer.render always
// lines it up with what the crop overlay showed on screen.
struct EditCropRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = EditCropRect(x: 0, y: 0, width: 1, height: 1)
}

// Quick aspect-ratio presets offered on the crop tool's own row of
// buttons — not persisted anywhere (EditCropRect itself has no notion of
// "locked to a ratio"), just a one-shot starting point applied via
// PhotoEditRenderer... see DevelopView.applyCropAspectRatio.
private enum CropAspectRatioOption: CaseIterable, Identifiable {
    case free, square, fourThree, threeFour, sixteenNine, nineSixteen

    var id: Self { self }

    var label: String {
        switch self {
        case .free: return "Free"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    // width / height, nil = unconstrained (leaves whatever crop is
    // already there alone).
    var ratio: Double? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}

// MARK: - Local adjustments (masks)

enum LocalMaskType: String, Codable {
    case radial
    case graduated
    case brush
    case patch
}

// The three destination-outline shapes offered for the Patch (clone/heal)
// tool — mirrors the "circle / square / free cut" request directly: Circle
// and Square are drag-to-resize like RadialMaskGeometry, Free is a
// hand-drawn closed polygon like a lasso selection.
enum PatchShape: String, Codable, CaseIterable {
    case circle
    case square
    case free
}

// The subset of PhotoEditSettings that makes sense applied to a masked
// region rather than the whole photo: tonal/color sliders only. No crop/
// rotate/straighten (geometry is always global) and no Vignette (a
// "vignette" masked to an arbitrary local region isn't a vignette anymore).
struct LocalAdjustmentSettings: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && whites == 0 && blacks == 0 && saturation == 0 && vibrance == 0
            && temperature == 0 && tint == 0 && sharpness == 0
    }
}

// An elliptical mask in the same post-rotation unit-square coordinate space
// as EditCropRect (0...1 on each axis, y measured top-down). `invert` swaps
// which side gets the adjustment — false = inside the ellipse, true =
// everywhere outside it (feathering in toward the edge).
struct RadialMaskGeometry: Codable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radiusX: Double = 0.25
    var radiusY: Double = 0.25
    var feather: Double = 0.5   // 0 = hard edge, 1 = very soft falloff
    var invert: Bool = false
}

// A linear (Lightroom-style "graduated filter") mask: full effect at
// (startX, startY), fading to none by (endX, endY), constant along the
// perpendicular direction and clamped (not repeating) beyond both ends.
// Same unit-square coordinate space as RadialMaskGeometry.
struct GraduatedMaskGeometry: Codable, Equatable {
    var startX: Double = 0.5
    var startY: Double = 0.2
    var endX: Double = 0.5
    var endY: Double = 0.6
    var invert: Bool = false
}

// One continuous freehand brush drag, recorded as unit-square points (so it
// stays valid across preview/full-res renders like every other mask
// geometry here) plus the brush size/hardness in effect when it was drawn
// — each stroke keeps its OWN size/hardness rather than sharing one for the
// whole mask, so changing the brush size for a new stroke never reshapes
// strokes already painted. `isErase` strokes subtract from the accumulated
// mask instead of adding to it (see PhotoEditRenderer.brushMask).
struct BrushStroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var points: [CGPoint] = []   // unit space, in drag order
    var size: Double = 0.05      // brush diameter, as a fraction of the image's long edge
    var hardness: Double = 0.5   // 0 = very soft edge, 1 = hard edge
    var isErase: Bool = false
}

struct BrushMaskGeometry: Codable, Equatable {
    var strokes: [BrushStroke] = []
}

// A clone/heal "patch": a destination outline (Circle/Square use the same
// center+radius convention as RadialMaskGeometry; Free is a hand-drawn
// closed polygon, `points` in unit space, in draw order) plus a
// `sourceOffsetX/Y` vector — the displacement (in the SAME unit space, so
// still top-down Y) from the destination's own center to wherever the user
// has dragged the source marker. Unlike the other three mask types, a patch
// carries no tonal/color settings at all (LocalAdjustment.settings stays
// permanently neutral for it) — its only "effect" is showing sampled pixels
// from the source location inside the destination outline, feathered at the
// edge like a soft clone-stamp paste. Defaults to a small rightward offset
// (not (0,0)) so a freshly-added Circle/Square patch immediately shows a
// visibly distinct source marker instead of a degenerate identity clone
// that looks like it does nothing.
//
// `.circle` is a real continuous clone-stamp BRUSH (as of the 15. avgust
// 2026 rework, see BRIEFSHOW_DEVELOP_NOTES.md): `strokes` holds every
// painted drag, Photoshop-style — ⌥-click sets the source point, then
// dragging paints a `PatchStroke` whose `sourceOffsetX/Y` stays FIXED for
// that whole stroke (and carries over "aligned" into the next stroke too,
// until the user ⌥-clicks again), sampling from source+offset continuously
// as the cursor moves rather than repositioning one fixed shape. `.free`
// keeps the ORIGINAL single-hand-drawn-outline mechanic below (`points`/
// `centerX/Y`/`radiusX/Y`/`sourceOffsetX/Y`/`feather`) unchanged — it isn't
// painted incrementally. `.square` is kept only so old saved data still
// decodes/renders; it's no longer offered in the UI (Patch is Circle-brush
// or Free only — Square remains a Selection-tool-only shape).
struct PatchGeometry: Codable, Equatable {
    var shape: PatchShape = .circle
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radiusX: Double = 0.12
    var radiusY: Double = 0.12
    var feather: Double = 0.3
    var points: [CGPoint] = []   // unit space, Free shape only, empty until drawn
    var sourceOffsetX: Double = 0.2
    var sourceOffsetY: Double = 0
    var opacity: Double = 1.0    // 0...1, applies to the whole patch (brush strokes AND legacy Free outline)
    var strokes: [PatchStroke] = []   // Circle-brush mode only, see doc comment above

    init(
        shape: PatchShape = .circle, centerX: Double = 0.5, centerY: Double = 0.5,
        radiusX: Double = 0.12, radiusY: Double = 0.12, feather: Double = 0.3,
        points: [CGPoint] = [], sourceOffsetX: Double = 0.2, sourceOffsetY: Double = 0,
        opacity: Double = 1.0, strokes: [PatchStroke] = []
    ) {
        self.shape = shape
        self.centerX = centerX
        self.centerY = centerY
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.feather = feather
        self.points = points
        self.sourceOffsetX = sourceOffsetX
        self.sourceOffsetY = sourceOffsetY
        self.opacity = opacity
        self.strokes = strokes
    }

    // Written by hand, same reasoning/idiom as PhotoEditSettings' own
    // custom init(from:) — a plain synthesized Decodable does NOT fall
    // back to a property's default value for a key that's simply missing
    // from older saved JSON (confirmed with a standalone decode test
    // before relying on it here, see BRIEFSHOW_DEVELOP_NOTES.md); it
    // throws instead. Without this, adding `opacity`/`strokes` today would
    // make any Patch adjustment saved by a build before this rework fail
    // to decode — and since PhotoEditSettings.localAdjustments decodes the
    // WHOLE array at once, ONE bad element throws the whole photo's saved
    // edit away (see PhotoEditStore.allSettings), not just that one mask.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(PatchShape.self, forKey: .shape) ?? .circle
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        radiusX = try c.decodeIfPresent(Double.self, forKey: .radiusX) ?? 0.12
        radiusY = try c.decodeIfPresent(Double.self, forKey: .radiusY) ?? 0.12
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.3
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        sourceOffsetX = try c.decodeIfPresent(Double.self, forKey: .sourceOffsetX) ?? 0.2
        sourceOffsetY = try c.decodeIfPresent(Double.self, forKey: .sourceOffsetY) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        strokes = try c.decodeIfPresent([PatchStroke].self, forKey: .strokes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case shape, centerX, centerY, radiusX, radiusY, feather, points
        case sourceOffsetX, sourceOffsetY, opacity, strokes
    }
}

// One continuous clone-stamp brush drag for a Circle-mode Patch — same
// "each stroke keeps its own size/feather" reasoning as BrushStroke (so
// nudging the Feather/Brush Size sliders for the NEXT stroke never
// reshapes strokes already painted), plus a `sourceOffsetX/Y` fixed at the
// moment this stroke started (Photoshop's "Aligned" clone-stamp behavior —
// see PatchGeometry's doc comment).
struct PatchStroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var points: [CGPoint] = []        // unit space, destination path painted, in drag order
    var sourceOffsetX: Double = 0.2   // fixed for this stroke's whole drag, same convention as PatchGeometry.sourceOffsetX
    var sourceOffsetY: Double = 0
    var size: Double = 0.08           // brush diameter, fraction of the image's long edge — same convention as BrushStroke.size
    var feather: Double = 0.35        // patchMinimumFeather...1 — edges are ALWAYS at least a little feathered, per explicit request; never a hard 0 edge like a raw brush dab would give
}

// One local adjustment: a mask (exactly one of radial/graduated/brush/patch
// is non-nil, matching `type`) plus its own tonal/color settings (unused —
// always neutral — for `.patch`, see PatchGeometry's doc comment).
// `isEnabled` lets the user preview with a mask temporarily switched off
// without losing/deleting it.
struct LocalAdjustment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var type: LocalMaskType
    var radial: RadialMaskGeometry?
    var graduated: GraduatedMaskGeometry?
    var brush: BrushMaskGeometry?
    var patch: PatchGeometry?
    var settings = LocalAdjustmentSettings()
    var isEnabled: Bool = true

    static func radial(name: String) -> LocalAdjustment {
        LocalAdjustment(name: name, type: .radial, radial: RadialMaskGeometry())
    }

    static func graduated(name: String) -> LocalAdjustment {
        LocalAdjustment(name: name, type: .graduated, graduated: GraduatedMaskGeometry())
    }

    static func brush(name: String) -> LocalAdjustment {
        LocalAdjustment(name: name, type: .brush, brush: BrushMaskGeometry())
    }

    static func patch(name: String, shape: PatchShape) -> LocalAdjustment {
        LocalAdjustment(name: name, type: .patch, patch: PatchGeometry(shape: shape))
    }

    // Whether this adjustment currently changes anything, used by
    // applyLocalAdjustments to skip rendering work. Tonal mask types
    // (radial/graduated/brush) are neutral exactly when their settings are
    // — the existing check. A patch has no tonal settings to be neutral or
    // not; instead it "does nothing" until there's actually something to
    // render: a Circle-brush patch needs at least one painted stroke, a
    // Free patch needs a drawn outline, a (legacy) Square always had a
    // valid default outline the moment it was added.
    var hasEffect: Bool {
        if type == .patch {
            guard let patch else { return false }
            switch patch.shape {
            case .circle: return !patch.strokes.isEmpty
            case .free: return !patch.points.isEmpty
            case .square: return true
            }
        }
        return !settings.isNeutral
    }
}

// MARK: - Selection tool (Cut / Copy / Deselect -> layer)

// The Selection tool's current outline while the client is defining/
// adjusting it. Deliberately NOT Codable/part of PhotoEditSettings — a
// selection is pure ephemeral tool state (like isCropping's pendingCrop),
// consumed by Cut/Copy/Deselect and never itself saved. Shares its shape
// math with PatchGeometry's destination outline (Circle/Square use center+
// radius, Free uses a hand-drawn point list, `feather` softens the cut
// edge) via PhotoEditRenderer.selectionMask, which just re-packages this
// into a PatchGeometry to reuse patchMask/squareMask/freeMask rather than
// duplicating that geometry code a third time — but it deliberately has NO
// source-offset fields, which mean nothing for a plain selection.
struct SelectionGeometry: Equatable {
    var shape: PatchShape = .circle
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radiusX: Double = 0.15
    var radiusY: Double = 0.15
    var feather: Double = 0
    var points: [CGPoint] = []   // unit space, Free shape only
}

// MARK: - Image layers (pasted cut/copied pieces)

enum LayerBlendMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        }
    }
}

// A pasted cut/copied piece of a photo (from this photo or a DIFFERENT
// one, via DevelopView's in-memory layerClipboard) composited as its own
// positioned, resizable layer — the actual start of Photoshop-style image
// layers (see BRIEFSHOW_DEVELOP_NOTES.md #12), reached here via the
// Selection tool's Cut/Copy rather than importing a file.
//
// `imageData` is a PNG, never JPEG — a cut circle/free-lasso piece is
// mostly transparent outside its own outline, and JPEG has no alpha
// channel to hold that. x/y is the layer's TOP-LEFT corner (not center,
// unlike the mask geometries above) in the same unit-square (0...1,
// top-down Y) space as EditCropRect — a layer is dragged/resized from its
// bounding box like the crop tool, not from a radius around a center.
struct ImageLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var imageData: Data
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var opacity: Double = 1     // 0...1
    var blendMode: LayerBlendMode = .normal
    var isEnabled: Bool = true
}

// DevelopView's in-memory Cut/Copy clipboard (see its `layerClipboard`
// @State) — not Codable, never persisted, exists purely to hand a Paste
// action everything it needs to build a fresh ImageLayer.
struct LayerClipboardData {
    var imageData: Data
    // Where it was cut/copied FROM, in the source photo's own unit-square
    // (0...1, top-down Y) space — Paste drops it back at this exact
    // fraction of whatever photo is open when Paste happens, same photo or
    // a different one, "paste in place" rather than always centering.
    // Since these are FRACTIONS (not pixels), the same box is well-defined
    // and visually reasonable on a differently-sized/shaped destination
    // photo too, not just the source one.
    var boundsUnit: CGRect
}

// MARK: - Persistence

// Mirrors PhotoLabelStore's name+size keying (see ContentView.swift) — an
// edit follows a photo through a move/rename inside BriefShow, but not
// through changes to the file's actual bytes made outside it.
enum PhotoEditStore {
    private static let defaultsKey = "com.rocketsbrief.briefshow.photoEditSettings"

    private static func key(for url: URL) -> String {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        return "\(url.lastPathComponent)|\(fileSize)"
    }

    static func settings(for url: URL) -> PhotoEditSettings {
        allSettings[key(for: url)] ?? PhotoEditSettings()
    }

    static func setSettings(_ settings: PhotoEditSettings, for url: URL) {
        var all = allSettings
        if settings.isNeutral {
            all.removeValue(forKey: key(for: url))
        } else {
            all[key(for: url)] = settings
        }
        allSettings = all
    }

    // Powers the small "has edits" badge on a filmstrip thumbnail.
    static func hasEdits(_ url: URL) -> Bool {
        allSettings[key(for: url)] != nil
    }

    private static var allSettings: [String: PhotoEditSettings] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
                return [:]
            }
            return (try? JSONDecoder().decode([String: PhotoEditSettings].self, from: data)) ?? [:]
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }
}

// A named, reusable snapshot of the *entire* PhotoEditSettings (light/color/
// detail sliders AND crop/rotate/straighten) that the user saved once and
// can reapply to any photo — separate from PhotoEditStore, which holds only
// the one "current" edit per photo. Applying a preset to a photo with a
// different aspect ratio than the one it was saved from can produce an odd
// crop; that's an accepted tradeoff of including geometry in the snapshot
// (see BRIEFSHOW_DEVELOP_NOTES.md #5) rather than something this screen
// tries to detect or warn about.
struct PhotoEditPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var settings: PhotoEditSettings
}

// Global (not per-photo) library of presets. Order in the array is display
// order in the Presets list, oldest-saved-first.
enum PhotoEditPresetStore {
    private static let defaultsKey = "com.rocketsbrief.briefshow.photoEditPresets"

    static func loadAll() -> [PhotoEditPreset] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([PhotoEditPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [PhotoEditPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: defaultsKey)
    }
}

// MARK: - Render pipeline

// The once-per-photo decoded image handed to PhotoEditRenderer.render.
// RAW files keep the live CIRAWFilter around (not just its .outputImage) so
// render() can push Exposure/Temperature/Tint into the filter's own native
// RAW-domain controls — applied during demosaic, with the sensor's full
// headroom, instead of as generic CIFilters bolted onto an
// already-demosaiced/tone-mapped image (better highlight recovery and
// color accuracy). Non-RAW formats have no such native controls, so they
// just carry a plain decoded CIImage through the same generic pipeline as
// before.
//
// asShotTemperature/asShotTint are the camera's as-shot white balance,
// captured once right after decode (before anything mutates the filter).
// render() always computes neutralTemperature/neutralTint as this baseline
// plus the current slider delta — it never reads the filter's own
// neutralTemperature/neutralTint back as a starting point, because those
// properties were themselves SET by this same render() function on a
// previous call; treating them as the source of truth would let repeated
// renders (one per slider drag, all sharing this one filter instance)
// compound the same delta on top of itself instead of reapplying it fresh
// each time.
enum PhotoBaseImage {
    case standard(CIImage)
    case raw(filter: CIRAWFilter, asShotTemperature: Float, asShotTint: Float)

    var extent: CGRect {
        switch self {
        case .standard(let image):
            return image.extent
        case .raw(let filter, _, _):
            return filter.outputImage?.extent ?? .zero
        }
    }
}

enum PhotoEditRenderer {
    // RAW formats decode through CIRAWFilter instead of a plain CIImage
    // decode — a real demosaic with highlight-recovery headroom a JPEG/
    // HEIC preview embedded in the RAW file wouldn't have, rather than
    // just editing the camera's baked-in preview.
    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw", "raw"
    ]

    static func isRAW(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    // The largest axis-aligned rectangle (centered, as a fraction of the
    // post-rotation bounding box — i.e. directly usable as an EditCropRect)
    // that fits entirely inside a `w`×`h` rectangle once it's rotated by
    // `angleDegrees` around its own center. Used to auto-fit the crop right
    // after Straighten so the transparent "empty corner" triangles a plain
    // rotation leaves never show by default.
    //
    // Closed-form solution to "largest inscribed axis-aligned rectangle in
    // a rotated rectangle": with a = w/2, b = h/2 and θ = |angle|, the
    // inscribed rectangle's corner (p, q) touches either just the a-edge,
    // just the b-edge, or both at once, depending on how θ compares with
    // the rectangle's aspect ratio (verified numerically against a
    // brute-force point-containment/tightness check across landscape,
    // portrait, square, and extreme aspect ratios before wiring this in).
    static func autoStraightenCrop(imageWidth w: Double, imageHeight h: Double, angleDegrees: Double) -> EditCropRect {
        let theta = abs(angleDegrees) * .pi / 180
        guard theta > 0, w > 0, h > 0 else {
            return .full
        }

        let sinT = sin(theta), cosT = cos(theta)
        let a = w / 2, b = h / 2
        let sin2T = sin(2 * theta)

        let p: Double
        let q: Double
        if sin2T > 0, a <= b * sin2T {
            // Only the a (width) edge binds.
            p = a / (2 * cosT)
            q = a / (2 * sinT)
        } else if sin2T > 0, b <= a * sin2T {
            // Only the b (height) edge binds.
            p = b / (2 * sinT)
            q = b / (2 * cosT)
        } else {
            // Both edges bind at once (shallow angle / near-square image).
            let cos2T = cos(2 * theta)
            guard cos2T > 0 else {
                return .full
            }
            p = (a * cosT - b * sinT) / cos2T
            q = (b * cosT - a * sinT) / cos2T
        }

        guard p > 0, q > 0 else {
            return .full
        }

        let boundingW = w * cosT + h * sinT
        let boundingH = w * sinT + h * cosT
        let cropW = min(1, (2 * p) / boundingW)
        let cropH = min(1, (2 * q) / boundingH)

        return EditCropRect(x: (1 - cropW) / 2, y: (1 - cropH) / 2, width: cropW, height: cropH)
    }

    // The full-resolution decode, with no edits applied yet — loaded once
    // per photo by DevelopView and reused for the full-resolution export.
    // See loadPreviewBaseImage for the separate, independently-scaled
    // instance used by the live preview.
    static func loadBaseImage(from url: URL) -> PhotoBaseImage? {
        if isRAW(url), let rawFilter = CIRAWFilter(imageURL: url) {
            // Full quality, not the fast/lossy draft decode — this is for
            // an actual edit session, not a filmstrip thumbnail.
            rawFilter.isDraftModeEnabled = false
            return .raw(
                filter: rawFilter,
                asShotTemperature: rawFilter.neutralTemperature,
                asShotTint: rawFilter.neutralTint
            )
        }

        var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        if #available(macOS 14.0, *) {
            options[.expandToHDR] = false
        }
        guard let image = CIImage(contentsOf: url, options: options) else {
            return nil
        }
        return .standard(image)
    }

    // A second, independent decode used for the live-editing preview.
    // Non-RAW just downsamples the already-decoded full image with a CI
    // transform, same as before. RAW gets its OWN CIRAWFilter instance —
    // never shared with the full-res one reserved for export — so its
    // native Exposure/Temperature/Tint controls can be pushed in on every
    // slider drag without disturbing the full-res filter, and so its
    // scaleFactor can decode directly at the reduced size (cheaper and
    // higher quality than demosaicing full-res then downsampling with a CI
    // transform).
    static func loadPreviewBaseImage(from url: URL, full: PhotoBaseImage, previewMax: CGFloat = 1600) -> PhotoBaseImage {
        let extent = full.extent
        let longEdge = max(extent.width, extent.height)
        let scale = (longEdge.isFinite && longEdge > previewMax) ? previewMax / longEdge : 1

        switch full {
        case .standard(let image):
            guard scale < 1 else {
                return full
            }
            return .standard(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))

        case .raw:
            guard let previewFilter = CIRAWFilter(imageURL: url) else {
                return full
            }
            // Draft mode ON here — unlike the full-res filter above (which
            // MUST stay full-quality, it's what export uses), this is the
            // filter re-demosaiced on every slider tick while dragging.
            // Full-quality RAW demosaic is expensive enough that on an
            // actual .NEF it was the real bottleneck behind "moving any
            // slider on a RAW photo feels choppy" (reported directly,
            // isolated by benchmarking the non-RAW filter chain separately
            // at ~13ms — fast — which pointed straight at RAW decode being
            // the one path left at full quality on every interactive
            // render). Draft mode trades some quality for a much faster
            // decode — an acceptable tradeoff for a downsampled (`scale`
            // below), live-dragging preview; the export render() call
            // above never touches this filter, so the final exported file
            // is completely unaffected.
            previewFilter.isDraftModeEnabled = true
            if scale < 1 {
                previewFilter.scaleFactor = Float(scale)
            }
            return .raw(
                filter: previewFilter,
                asShotTemperature: previewFilter.neutralTemperature,
                asShotTint: previewFilter.neutralTint
            )
        }
    }

    // Rotate/straighten, then adjust, then crop last — in that order so
    // the crop rect (defined in the post-rotation coordinate space, see
    // EditCropRect) always lines up with the image it was drawn against.
    // `applyCrop` is false while the crop tool itself is open, so the
    // overlay draws against the full, uncropped frame.
    //
    // For a RAW source, Exposure/Temperature/Tint are pushed into the
    // CIRAWFilter's own native controls (applied during demosaic) instead
    // of the generic CIFilter.exposureAdjust/temperatureAndTint below —
    // better highlight recovery and color accuracy than running the same
    // generic pipeline JPEG gets on top of an already-demosaiced image.
    // Everything else (tone curve, contrast, vibrance, sharpen, vignette,
    // crop) runs identically for RAW and non-RAW, since Core Image has no
    // native-RAW equivalent for those. boostAmount/boostShadowAmount (the
    // RAW converter's own global tone curve) are deliberately left at
    // their defaults rather than wired to Highlights/Shadows/Whites/Blacks
    // — those already bend one CIToneCurve below, and doubling them up
    // with a second, differently-shaped native curve would make the same
    // slider value look different on RAW vs. JPEG for no clear benefit.
    static func render(_ settings: PhotoEditSettings, on base: PhotoBaseImage, applyCrop: Bool = true) -> CIImage {
        var output: CIImage
        let isRAWSource: Bool

        switch base {
        case .standard(let image):
            output = image
            isRAWSource = false

        case .raw(let filter, let asShotTemperature, let asShotTint):
            // Absolute sets against the captured as-shot baseline, never
            // relative to the filter's own current value — see
            // PhotoBaseImage's doc comment for why (this filter instance
            // is shared across repeated renders of the same photo).
            //
            // Raising CIRAWFilter.neutralTemperature warms the render (it's
            // the "assumed source light temperature to correct for" — the
            // same role CITemperatureAndTint's `neutral.x` plays below), so
            // a plain addition matches PhotoEditSettings.temperature's
            // documented "+1 = warmer" — same sign the non-RAW path below
            // now uses too (see its own comment for the sign-bug fix this
            // matches).
            filter.exposure = Float(settings.exposure)
            filter.neutralTemperature = min(max(asShotTemperature + Float(settings.temperature) * 3000, 2000), 50000)
            filter.neutralTint = min(max(asShotTint + Float(settings.tint) * 100, -150), 150)
            output = filter.outputImage ?? CIImage.empty()
            isRAWSource = true
        }

        if settings.rotationQuarterTurns != 0 {
            let turns = ((settings.rotationQuarterTurns % 4) + 4) % 4
            let angle = CGFloat(turns) * (.pi / 2)
            output = output.transformed(by: CGAffineTransform(rotationAngle: angle))
        }

        if settings.straightenDegrees != 0 {
            let radians = settings.straightenDegrees * .pi / 180
            output = output.transformed(by: CGAffineTransform(rotationAngle: -radians))
        }

        if !isRAWSource, settings.temperature != 0 || settings.tint != 0 {
            // `neutral` is the assumed source white point CITemperatureAndTint
            // corrects FROM, back to `targetNeutral` — so telling it the
            // source was WARMER (lower Kelvin, neutral.x < 6500) makes it
            // correct more aggressively, which COOLS the rendered image,
            // and vice versa. Was `6500 - settings.temperature * 3000` —
            // the exact opposite of PhotoEditSettings.temperature's
            // documented "+1 = warmer" (confirmed empirically on a
            // synthetic gray swatch: the old sign measurably shifted the
            // image cooler for +1). Fixed to `+` so +1 now genuinely warms
            // the image, matching both the doc comment and the RAW path's
            // own neutralTemperature handling above. This does change how
            // an already-saved edit with a non-zero Temperature renders —
            // accepted tradeoff, the old sign was simply backwards.
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 6500 + settings.temperature * 3000, y: settings.tint * 100)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            output = filter.outputImage ?? output
        }

        if !isRAWSource, settings.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(settings.exposure)
            output = filter.outputImage ?? output
        }

        if settings.blacks != 0 || settings.shadows != 0 || settings.highlights != 0 || settings.whites != 0 {
            // Blacks/Shadows/Highlights/Whites all bend one CIToneCurve
            // instead of stacking separate filters. point2 (x = 0.5, the
            // midtone) is left fixed as the pivot, so every slider rotates
            // or bends the curve around a constant middle gray rather than
            // shifting overall brightness. point0/point4 (the endpoints)
            // are deliberately allowed past 0...1 — that's what lets Whites/
            // Blacks push tones into clipping instead of just flattening
            // toward it, which a curve clamped to 0...1 at the ends can't
            // do. Highlights keeps the "positive = recover/darken" sign it
            // had under the old CIHighlightShadowAdjust-based version (so a
            // photo edited before this change still reads the same
            // direction); Shadows/Whites/Blacks use the more familiar
            // Lightroom convention where positive means brighter.
            let strength = 0.3
            let filter = CIFilter.toneCurve()
            filter.inputImage = output
            filter.point0 = CGPoint(x: 0, y: settings.blacks * strength)
            filter.point1 = CGPoint(x: 0.25, y: min(max(0.25 + settings.shadows * strength, 0), 1))
            filter.point2 = CGPoint(x: 0.5, y: 0.5)
            filter.point3 = CGPoint(x: 0.75, y: min(max(0.75 - settings.highlights * strength, 0), 1))
            filter.point4 = CGPoint(x: 1, y: 1 + settings.whites * strength)
            output = filter.outputImage ?? output
        }

        if settings.contrast != 0 || settings.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.contrast = Float(1 + settings.contrast)
            filter.saturation = Float(1 + settings.saturation)
            filter.brightness = 0
            output = filter.outputImage ?? output
        }

        if settings.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(settings.vibrance)
            output = filter.outputImage ?? output
        }

        if settings.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = output
            filter.sharpness = Float(settings.sharpness * 2.2)
            output = filter.outputImage ?? output
        }

        // Texture — Lightroom's mid-frequency detail dial, and the only
        // slider in this section that runs BOTH ways. Positive brings skin/
        // fabric/hair detail OUT (a small-radius unsharp mask — finer than
        // Clarity's large-radius midtone "punch" below, coarser than
        // Sharpness' edge-only pass above; that middle frequency band is
        // exactly what reads as "texture" rather than "sharper" or
        // "punchier"). Negative pushes that same band back DOWN so a face
        // reads softer/younger, the way a portrait retouch does.
        //
        // The negative side is a frequency-separation MIX, not a plain blur
        // of everything: `blurred` is the low-frequency copy, and
        // CIBlendWithMask against a flat gray mask cross-fades toward it by
        // |texture| (the same "flat gray mask as an opacity dial" trick Soft
        // Glow and Patch's Opacity already use). The mix is capped at 0.85
        // so even -100 keeps some of the original's detail — a full 1.0
        // would hand back a straight blur, which reads as "out of focus",
        // not "smooth skin". This is an APPROXIMATION of Lightroom's
        // edge-preserving version (which leaves eyes/lips/edges crisp while
        // smoothing only flat areas) — same kind of documented shortcut as
        // Dehaze below.
        //
        // Both radii are a FRACTION of the image's long edge, not a fixed
        // pixel count — render() runs at both preview and full-export
        // resolution and a radius picked for one would look wrong at the
        // other (see Clarity's own radius comment right below for the full
        // reasoning, and the brush/patch tools for the same convention).
        if settings.texture != 0 {
            let extent = output.extent
            let longEdge = max(extent.width, extent.height)
            if longEdge.isFinite, longEdge > 0 {
                if settings.texture > 0 {
                    let filter = CIFilter.unsharpMask()
                    filter.inputImage = output
                    filter.radius = Float(min(max(longEdge * 0.006, 2), 40))
                    filter.intensity = Float(settings.texture * 1.1)
                    output = filter.outputImage ?? output
                } else {
                    let blurred = output
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(max(longEdge * 0.003, 1.5), 24)])
                        .cropped(to: extent)

                    // Edge guard. Cross-fading the whole frame toward
                    // `blurred` by a FLAT mask was the first version of
                    // this and it read as "out of focus", not "smooth
                    // skin" — eyes, lashes and hair went soft right along
                    // with the pores. |original - blurred| is exactly the
                    // mid-frequency band this slider owns, so amplified
                    // (x10) and clamped to 0...1 it doubles as a "there is
                    // real structure here" map: flat skin scores ~0, an
                    // eyelash or a lip edge saturates to 1. Inverting that
                    // and scaling it by |texture| gives a per-pixel mix
                    // that smooths the flat areas hard while leaving edges
                    // essentially untouched.
                    //
                    // CIBlendWithMask reads the mask's RGB level (not its
                    // alpha) — the same thing Soft Glow above and Patch's
                    // Opacity rely on, confirmed by a standalone render
                    // test, which is why a fully opaque mask image can
                    // still act as a per-pixel strength dial.
                    let detailBoost = 10.0
                    let detail = output
                        .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blurred])
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 0.333 * detailBoost, y: 0.333 * detailBoost, z: 0.333 * detailBoost, w: 0),
                            "inputGVector": CIVector(x: 0.333 * detailBoost, y: 0.333 * detailBoost, z: 0.333 * detailBoost, w: 0),
                            "inputBVector": CIVector(x: 0.333 * detailBoost, y: 0.333 * detailBoost, z: 0.333 * detailBoost, w: 0),
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                        ])
                        .applyingFilter("CIColorClamp", parameters: [
                            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                        ])

                    let amount = CGFloat(min(max(-settings.texture, 0), 1) * 0.9)
                    let mixMask = detail
                        .applyingFilter("CIColorInvert")
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                        ])
                        .cropped(to: extent)

                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = blurred
                    blend.backgroundImage = output
                    blend.maskImage = mixMask
                    output = blend.outputImage ?? output
                }
            }
        }

        // Clarity — Lightroom's "local/midtone contrast" — is a LARGE-radius
        // unsharp mask, as distinct from Sharpness' small-radius edge
        // sharpening above (CISharpenLuminance has no radius knob at all;
        // CIUnsharpMask's `radius` is what makes this read as "punch" in
        // the midtones rather than "crisper edges"). The radius is a
        // FRACTION of the image's long edge, not a fixed pixel count —
        // render() runs at both preview and full-export resolution, and a
        // radius picked for one would look wrong (too small or too smeared)
        // at the other; the brush/patch tools above already use the same
        // "size as a fraction of the long edge" convention for the same
        // reason. Positive-only for now (no negative/softening range) —
        // CIUnsharpMask's `intensity` isn't documented for negative values,
        // and a properly signed "reduce local contrast" would need its own
        // subtract-based blend rather than reusing this filter — deferred,
        // see BRIEFSHOW_DEVELOP_NOTES.md.
        if settings.clarity > 0 {
            let longEdge = max(output.extent.width, output.extent.height)
            if longEdge.isFinite, longEdge > 0 {
                let filter = CIFilter.unsharpMask()
                filter.inputImage = output
                filter.radius = Float(min(max(longEdge * 0.02, 8), 100))
                filter.intensity = Float(settings.clarity * 0.8)
                output = filter.outputImage ?? output
            }
        }

        // Dehaze — an APPROXIMATION, not Lightroom's real algorithm (which
        // uses a dark-channel-prior atmospheric-scattering model — a much
        // bigger undertaking, explicitly deferred, see
        // BRIEFSHOW_DEVELOP_NOTES.md). Haze visually reads as two things:
        // flattened contrast/color (light scattered by atmospheric
        // particles washes everything toward gray) and a lifted black
        // point (true blacks never quite reach black through the haze) —
        // so this fakes the "haze removed" look by boosting contrast and
        // saturation, THEN crushing the black point back down and pulling
        // the lower-midtones with it via a tone curve (same point0...
        // point4 curve-bending technique the Blacks/Shadows/Highlights/
        // Whites sliders above use, just dehaze-specific coefficients).
        // Reads as "punchier and clearer" on a real hazy photo without
        // needing the full atmospheric-scattering math.
        if settings.dehaze > 0 {
            let d = Float(settings.dehaze)

            let colorFilter = CIFilter.colorControls()
            colorFilter.inputImage = output
            colorFilter.contrast = 1 + d * 0.35
            colorFilter.saturation = 1 + d * 0.25
            colorFilter.brightness = 0
            output = colorFilter.outputImage ?? output

            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            curve.point0 = CGPoint(x: 0, y: CGFloat(-0.08 * d))
            curve.point1 = CGPoint(x: 0.25, y: CGFloat(0.25 - 0.05 * d))
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.75)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
        }

        // Soft Glow — a classic diffusion/"soft focus" portrait look: blur
        // a copy of the image and screen-blend it back over the sharp
        // original (screen only ever LIGHTENS, so this reads as a soft
        // glow/bloom rather than a plain blur), then mix between the crisp
        // original and the fully-glowed version by `softGlow` via
        // CIBlendWithMask against a flat gray mask — same "scale a mask's
        // blend strength for an opacity dial" trick Patch's own Opacity
        // slider uses. `.clampedToExtent()` before the blur (undone by the
        // final `.cropped(to:)`) is the standard Core Image pattern for
        // blurring without the transparent/undefined edge outside the
        // image bleeding black into the result.
        if settings.softGlow > 0 {
            let extent = output.extent
            let longEdge = max(extent.width, extent.height)
            if longEdge.isFinite, longEdge > 0 {
                let blurred = output
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: longEdge * 0.025])
                    .cropped(to: extent)

                let screen = CIFilter.screenBlendMode()
                screen.inputImage = blurred
                screen.backgroundImage = output
                let glowed = screen.outputImage ?? output

                let amount = CGFloat(min(max(settings.softGlow, 0), 1))
                let mixMask = CIImage(color: CIColor(red: amount, green: amount, blue: amount)).cropped(to: extent)
                let blend = CIFilter.blendWithMask()
                blend.inputImage = glowed
                blend.backgroundImage = output
                blend.maskImage = mixMask
                output = blend.outputImage ?? output
            }
        }

        // Vignette moved to AFTER crop (see the end of this function) — it
        // needs to darken the CROPPED image's own corners, not the
        // original full-frame's, see its doc comment down there.

        if !settings.localAdjustments.isEmpty {
            output = applyLocalAdjustments(settings.localAdjustments, to: output)
        }

        // Layers always composite ON TOP of the base photo AND every local
        // adjustment below them — a pasted piece is new content sitting
        // above the stack, not something a mask underneath it should be
        // able to reach up and tint. Runs before crop for the same reason
        // local adjustments do: a layer's x/y/width/height are defined in
        // this same pre-crop unit space, so cropping the photo afterward
        // naturally clips whatever part of a layer falls outside the kept
        // area too, instead of needing separate clipping logic.
        if !settings.layers.isEmpty {
            output = compositeLayers(settings.layers, onto: output)
        }

        if applyCrop, let crop = settings.crop {
            let extent = output.extent
            guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
                return output
            }
            let rect = CGRect(
                x: extent.origin.x + crop.x * extent.width,
                y: extent.origin.y + (1 - crop.y - crop.height) * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            ).integral
            output = output.cropped(to: rect)
        }

        // Custom corner-only vignette, applied LAST (after crop) — CIVignette
        // (the built-in filter this used to call) has no way to confine its
        // falloff to just the corners; even at its own default radius, the
        // darkening visibly crept in along the top/bottom/left/right edges
        // too, not just the four corners. Deliberately placed AFTER crop
        // (not back where the other Detail & Effects sliders run, before
        // local adjustments/layers/crop): a vignette needs to darken the
        // image's OWN actual corners — if it were computed against the
        // pre-crop extent instead, cropping in tight could leave the dark
        // corners entirely outside the kept area (no visible vignette left
        // at all) or cut across the middle of the cropped frame as a
        // visible edge, neither of which is "corners of the photo you're
        // looking at" — reported directly (a visible vignette "line" after
        // cropping, wanting the vignette to re-fill the CROPPED image's own
        // corners). Built as a radial gradient DARKENING MASK, multiplied
        // onto the image — an ELLIPSE (not a circle), same non-uniform-
        // scale-of-a-unit-gradient technique radialMask uses for the Radial
        // local adjustment: a plain CIRCULAR inscribed/circumscribed pair
        // was tried first and rejected after a pixel-sampling test script
        // caught it leaving a non-square (e.g. landscape) photo's LEFT/
        // RIGHT edge midpoints partially darkened too — a circle can only
        // be tangent to the SHORTER pair of edges, not both pairs at once.
        // Building the gradient in unit space (radius0 = 1, the ellipse
        // that — once scaled by halfW/halfH below — touches ALL FOUR edge
        // midpoints simultaneously; radius1 = √2, the unit-space distance
        // that scales to reach the actual corners) and only THEN applying
        // the (halfW, halfH) non-uniform scale fixes this: verified with a
        // standalone pixel-sampling script (see BRIEFSHOW_DEVELOP_NOTES.md)
        // — all four edge midpoints read full brightness, only the four
        // corner wedges outside the ellipse are darkened.
        //
        // The mask is then BLURRED (not the photo — just this gradient)
        // before use: the crisp geometric ellipse boundary above read as a
        // visible "vignette line" even though the underlying gradient IS
        // continuous with no value jump at that boundary — the RATE of
        // change jumps there (flat right up to radius0, then suddenly
        // sloped), a classic Mach-band effect the eye is very sensitive to.
        // Blurring the mask itself removes that slope discontinuity, giving
        // a soft, organic falloff instead of a geometric edge — also
        // directly the "more feather" ask. Blur radius is a fraction of the
        // (now-final, post-crop) image's shorter edge, same "size scales
        // with the actual image, not a fixed pixel count" convention as
        // Clarity/Soft Glow/the Patch brush above.
        if settings.vignette > 0 {
            let extent = output.extent
            if extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 {
                let halfW = extent.width / 2
                let halfH = extent.height / 2
                let darkAmount = CGFloat(min(max(settings.vignette, 0), 1))

                let gradient = CIFilter.radialGradient()
                gradient.center = .zero
                gradient.radius0 = 1
                gradient.radius1 = Float(2.0.squareRoot())
                gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
                gradient.color1 = CIColor(red: 1 - darkAmount, green: 1 - darkAmount, blue: 1 - darkAmount, alpha: 1)

                if let unitGradient = gradient.outputImage {
                    let transform = CGAffineTransform(a: halfW, b: 0, c: 0, d: halfH, tx: extent.midX, ty: extent.midY)
                    let featherRadius = min(extent.width, extent.height) * 0.06
                    let mask = unitGradient
                        .transformed(by: transform)
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius])
                        .cropped(to: extent)

                    let multiply = CIFilter.multiplyCompositing()
                    multiply.inputImage = mask
                    multiply.backgroundImage = output
                    output = multiply.outputImage ?? output
                }
            }
        }

        return output
    }

    // MARK: Local adjustments (masks)

    // Composites every enabled local adjustment onto `image` in order: for
    // each one, the SAME tonal/color chain the global sliders use
    // (applyLocalToneColorDetail) runs on the current accumulated image,
    // then the result is blended back in only where that adjustment's mask
    // is bright, via CIBlendWithMask. Adjustments are applied sequentially
    // (not all against the original `image`), so a later mask's "before"
    // state already includes any earlier masks' effect — matches how
    // Lightroom's own local adjustments stack.
    private static func applyLocalAdjustments(_ adjustments: [LocalAdjustment], to image: CIImage) -> CIImage {
        var output = image
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            return output
        }

        for adjustment in adjustments {
            guard adjustment.isEnabled, adjustment.hasEffect else {
                continue
            }

            // A Circle-mode patch is a whole SEQUENCE of independently-
            // sourced brush strokes (see PatchGeometry's doc comment), not
            // one mask+one sample the way every other adjustment type (and
            // a legacy Square/Free patch) is — routed to its own compositor
            // rather than forced through the generic single-mask path below.
            if adjustment.type == .patch, let patch = adjustment.patch, patch.shape == .circle {
                output = applyPatchBrushStrokes(patch, to: output, extent: extent)
                continue
            }

            guard let mask = maskImage(for: adjustment, extent: extent) else {
                continue
            }

            let adjusted: CIImage
            if adjustment.type == .patch, let patch = adjustment.patch {
                adjusted = patchSampledImage(patch, source: output, extent: extent)
            } else {
                adjusted = applyLocalToneColorDetail(adjustment.settings, to: output)
            }

            let scaledMask = adjustment.type == .patch
                ? scaleMaskOpacity(mask, by: adjustment.patch?.opacity ?? 1)
                : mask

            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = output
            blend.maskImage = scaledMask
            output = blend.outputImage ?? output
        }

        return output
    }

    // Paints every recorded PatchStroke in order, each with its OWN fixed
    // source offset (see PatchStroke's doc comment) — a soft brush-dab mask
    // built the same way brushStrokeDabs builds a Brush tool stroke, blended
    // against a copy of `output` shifted by that stroke's offset. Strokes
    // are applied sequentially against the running `output` (not all
    // against the original `image`), so painting one stroke's source
    // OVER an area an earlier stroke already patched samples the already-
    // patched result, matching a real clone stamp / how every other local
    // adjustment here already stacks.
    private static func applyPatchBrushStrokes(_ geo: PatchGeometry, to image: CIImage, extent: CGRect) -> CIImage {
        var output = image
        let opacity = min(max(geo.opacity, 0), 1)

        for stroke in geo.strokes {
            guard let dabs = patchStrokeDabs(stroke, extent: extent) else {
                continue
            }
            let mask = scaleMaskOpacity(dabs, by: opacity)
            let sampled = patchSampledImage(
                PatchGeometry(sourceOffsetX: stroke.sourceOffsetX, sourceOffsetY: stroke.sourceOffsetY),
                source: output, extent: extent
            )

            let blend = CIFilter.blendWithMask()
            blend.inputImage = sampled
            blend.backgroundImage = output
            blend.maskImage = mask
            output = blend.outputImage ?? output
        }

        return output
    }

    // Reuses brushStrokeDabs' exact dab-interpolation/stamping math (see its
    // own doc comment) by re-packaging a PatchStroke as a BrushStroke —
    // `feather` (0 = hard edge, 1 = very soft, same convention as every
    // other mask here) maps to `hardness` inverted, since brushStrokeDabs'
    // "hardness" and a patch's "feather" describe the same radius0/radius1
    // gap from opposite ends.
    private static func patchStrokeDabs(_ stroke: PatchStroke, extent: CGRect) -> CIImage? {
        let feather = min(max(stroke.feather, patchMinimumFeather), 1)
        let brushStroke = BrushStroke(points: stroke.points, size: stroke.size, hardness: 1 - feather, isErase: false)
        return brushStrokeDabs(brushStroke, extent: extent)
    }

    // Edges are ALWAYS at least a little feathered per explicit request —
    // this is the floor the Patch UI's Feather sliders clamp to (both the
    // Circle-brush's per-stroke slider and the legacy Free outline's
    // slider), so a client can never accidentally leave a hard, visibly
    // "pasted" edge the way a bare brush dab (hardness 1) would.
    fileprivate static let patchMinimumFeather = 0.05

    // Scales a grayscale mask's brightness by `factor` (CIColorMatrix,
    // RGB channels multiplied, alpha left at 1) — used to implement a
    // patch's Opacity: blendWithMask treats the mask's brightness as the
    // blend strength, so dimming it uniformly weakens the whole patch
    // (strokes or outline alike) without needing a second blend pass.
    private static func scaleMaskOpacity(_ mask: CIImage, by factor: Double) -> CIImage {
        guard factor < 1 else {
            return mask
        }
        let f = CGFloat(min(max(factor, 0), 1))
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = mask
        matrix.rVector = CIVector(x: f, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: f, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: f, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? mask
    }

    // Shifts the ENTIRE current image by the vector from the patch's
    // destination center to its source marker, so that whatever content
    // currently sits at the source location lands exactly on top of the
    // destination location — the mask built by maskImage (at the
    // DESTINATION outline, not the source) is what actually limits the
    // visible effect to just that shape, same blend-with-mask compositing
    // every other local adjustment uses. Deliberately shifts `source`
    // (the already-accumulated `output` from applyLocalAdjustments, i.e.
    // any earlier masks in the stack) rather than the pristine original —
    // if a patch is layered after another local adjustment, cloning should
    // pick up that earlier adjustment's effect too, same as Lightroom/
    // Photoshop layer order.
    //
    // Unit space is top-down (+Y = down the image) but Core Image's own
    // coordinate space is bottom-up (+Y = up) — same mismatch every other
    // mask here (radialMask/graduatedMask/etc.) already accounts for with a
    // `1 - y` flip. A translation only (no flip needed) works out to
    // dx = -offsetX * width, dy = +offsetY * height; verified against a
    // synthetic four-quadrant test image with a standalone script before
    // wiring in (confirms both axes sample from the intended quadrant, not
    // just "some" offset in roughly the right direction) — see
    // BRIEFSHOW_DEVELOP_NOTES.md.
    private static func patchSampledImage(_ patch: PatchGeometry, source: CIImage, extent: CGRect) -> CIImage {
        let dx = -patch.sourceOffsetX * extent.width
        let dy = patch.sourceOffsetY * extent.height
        return source.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    // Mirrors the main render() pipeline's own temperature/exposure/tone-
    // curve/contrast/vibrance/sharpen blocks almost line for line — kept as
    // a deliberate near-duplicate (not a shared helper the global pipeline
    // also calls) so this change can never alter the already
    // pixel-verified global pipeline's behavior. Local adjustments always
    // run as generic CIFilters regardless of whether the SOURCE photo was
    // RAW — by the time a mask is applied, RAW's native exposure/WB
    // controls have already been baked into `image` (see render()), and a
    // masked region has no equivalent native RAW control to push into.
    private static func applyLocalToneColorDetail(_ local: LocalAdjustmentSettings, to image: CIImage) -> CIImage {
        var output = image

        if local.temperature != 0 || local.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 6500 + local.temperature * 3000, y: local.tint * 100)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            output = filter.outputImage ?? output
        }

        if local.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(local.exposure)
            output = filter.outputImage ?? output
        }

        if local.blacks != 0 || local.shadows != 0 || local.highlights != 0 || local.whites != 0 {
            let strength = 0.3
            let filter = CIFilter.toneCurve()
            filter.inputImage = output
            filter.point0 = CGPoint(x: 0, y: local.blacks * strength)
            filter.point1 = CGPoint(x: 0.25, y: min(max(0.25 + local.shadows * strength, 0), 1))
            filter.point2 = CGPoint(x: 0.5, y: 0.5)
            filter.point3 = CGPoint(x: 0.75, y: min(max(0.75 - local.highlights * strength, 0), 1))
            filter.point4 = CGPoint(x: 1, y: 1 + local.whites * strength)
            output = filter.outputImage ?? output
        }

        if local.contrast != 0 || local.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.contrast = Float(1 + local.contrast)
            filter.saturation = Float(1 + local.saturation)
            filter.brightness = 0
            output = filter.outputImage ?? output
        }

        if local.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(local.vibrance)
            output = filter.outputImage ?? output
        }

        if local.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = output
            filter.sharpness = Float(local.sharpness * 2.2)
            output = filter.outputImage ?? output
        }

        return output
    }

    // Builds the grayscale (white = full effect, black = none) mask for one
    // LocalAdjustment, sized to `extent`. Math for all three (center/radius
    // mapping, ellipse via non-uniform scale, feather via the gradient's
    // radius0/radius1 gap, invert via swapped colors) verified with
    // standalone pixel-sampling scripts before wiring in — same approach as
    // the auto-fit crop and histogram work earlier (see
    // BRIEFSHOW_DEVELOP_NOTES.md #4/#3).
    private static func maskImage(for adjustment: LocalAdjustment, extent: CGRect) -> CIImage? {
        switch adjustment.type {
        case .radial:
            guard let geo = adjustment.radial else { return nil }
            return radialMask(geo, extent: extent)
        case .graduated:
            guard let geo = adjustment.graduated else { return nil }
            return graduatedMask(geo, extent: extent)
        case .brush:
            guard let geo = adjustment.brush else { return nil }
            return brushMask(geo, extent: extent)
        case .patch:
            guard let geo = adjustment.patch else { return nil }
            return patchMask(geo, extent: extent)
        }
    }

    private static let maskWhite = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static let maskBlack = CIColor(red: 0, green: 0, blue: 0, alpha: 1)

    // Builds a circular CIRadialGradient in an unrotated, unscaled "unit"
    // space centered at the origin (radius 1), then maps it directly onto
    // the image with ONE explicit affine matrix — CGAffineTransform(a: rx,
    // b: 0, c: 0, d: ry, tx: cx, ty: cy) — rather than composing translate/
    // scale/translate calls, to avoid any ambiguity about which order
    // SwiftUI/Core Graphics's transform-builder methods apply in (verified
    // directly against this exact matrix with a pixel-sampling script:
    // center, ellipse aspect ratio, and feather all land where expected).
    // CIRadialGradient is an infinite generator, so the area outside
    // radius1 is already a solid color (color1) — .cropped(to:) just bounds
    // it to the frame.
    private static func radialMask(_ geo: RadialMaskGeometry, extent: CGRect) -> CIImage {
        let feather = min(max(geo.feather, 0), 1)

        let gradient = CIFilter.radialGradient()
        gradient.center = .zero
        gradient.radius0 = Float(max(1 - feather, 0.001))
        gradient.radius1 = 1
        gradient.color0 = geo.invert ? maskBlack : maskWhite
        gradient.color1 = geo.invert ? maskWhite : maskBlack

        guard let unitGradient = gradient.outputImage else {
            return CIImage(color: maskBlack).cropped(to: extent)
        }

        let cx = extent.origin.x + geo.centerX * extent.width
        let cy = extent.origin.y + (1 - geo.centerY) * extent.height
        let rx = max(geo.radiusX * extent.width, 1)
        let ry = max(geo.radiusY * extent.height, 1)

        let transform = CGAffineTransform(a: rx, b: 0, c: 0, d: ry, tx: cx, ty: cy)
        return unitGradient.transformed(by: transform).cropped(to: extent)
    }

    // CILinearGradient already clamps to a solid color before point0 and
    // after point1 and is constant along the perpendicular direction — the
    // exact behavior a Lightroom-style graduated filter needs, no transform
    // required.
    private static func graduatedMask(_ geo: GraduatedMaskGeometry, extent: CGRect) -> CIImage {
        let start = CGPoint(x: extent.origin.x + geo.startX * extent.width, y: extent.origin.y + (1 - geo.startY) * extent.height)
        let end = CGPoint(x: extent.origin.x + geo.endX * extent.width, y: extent.origin.y + (1 - geo.endY) * extent.height)

        let gradient = CIFilter.linearGradient()
        gradient.point0 = start
        gradient.point1 = end
        gradient.color0 = geo.invert ? maskBlack : maskWhite
        gradient.color1 = geo.invert ? maskWhite : maskBlack

        guard let image = gradient.outputImage else {
            return CIImage(color: maskBlack).cropped(to: extent)
        }
        return image.cropped(to: extent)
    }

    // Unions every stroke's own dab-union in order — paint strokes brighten
    // the running mask (CIMaximumCompositing), erase strokes darken it
    // (multiply by 1-minus-that-stroke's-dabs, via CIColorInvert +
    // CIMultiplyCompositing) — so later strokes always take precedence over
    // earlier ones at the same point, same as a real paint tool.
    //
    // Known limitation: this rebuilds the ENTIRE mask from every stroke's
    // dabs on every render() call, including one triggered by an unrelated
    // slider elsewhere in the photo's settings — there's no caching of a
    // mask that hasn't geometrically changed. Fine for a modest number of
    // strokes (the debounced render + preview-resolution rendering keep it
    // interactive in practice), but a heavily-painted photo could get slow.
    // A real fix would cache each LocalAdjustment's rendered mask keyed to
    // its own Equatable value and only rebuild the ones that changed —
    // deferred for now, see BRIEFSHOW_DEVELOP_NOTES.md #7.
    // Same stroke-to-mask renderer the Brush local adjustment uses, reached
    // from outside PhotoEditRenderer — the Remove tool paints its own
    // strokes and needs exactly this, with no reason for a second
    // implementation of dab stamping.
    static func strokeMask(_ strokes: [BrushStroke], extent: CGRect) -> CIImage {
        brushMask(BrushMaskGeometry(strokes: strokes), extent: extent)
    }

    private static func brushMask(_ geo: BrushMaskGeometry, extent: CGRect) -> CIImage {
        var mask = CIImage(color: maskBlack).cropped(to: extent)
        guard !geo.strokes.isEmpty else {
            return mask
        }

        for stroke in geo.strokes {
            guard let dabs = brushStrokeDabs(stroke, extent: extent) else {
                continue
            }
            if stroke.isErase {
                let invert = CIFilter.colorInvert()
                invert.inputImage = dabs
                let invertedDabs = invert.outputImage ?? dabs
                let multiply = CIFilter.multiplyCompositing()
                multiply.inputImage = mask
                multiply.backgroundImage = invertedDabs
                mask = multiply.outputImage ?? mask
            } else {
                let maxFilter = CIFilter.maximumCompositing()
                maxFilter.inputImage = dabs
                maxFilter.backgroundImage = mask
                mask = maxFilter.outputImage ?? mask
            }
        }

        return mask.cropped(to: extent)
    }

    // Renders one stroke as the union (CIMaximumCompositing) of soft
    // circular CIRadialGradient "dabs" stamped along the stroke's recorded
    // points — interpolating extra dabs between consecutive points (capped
    // at 40 per segment) so a fast drag with sparse recorded points still
    // paints a continuous line rather than a dotted one. `hardness` widens/
    // narrows the gradient's radius0...radius1 gap exactly like a radial
    // mask's feather.
    private static func brushStrokeDabs(_ stroke: BrushStroke, extent: CGRect) -> CIImage? {
        guard !stroke.points.isEmpty else {
            return nil
        }

        let longEdge = max(extent.width, extent.height)
        let radius = max(stroke.size / 2 * longEdge, 1)
        let hardness = min(max(stroke.hardness, 0), 1)
        let radius0 = radius * hardness
        let spacing = max(radius * 0.35, 1)

        var centers: [CGPoint] = []
        if stroke.points.count == 1 {
            centers = [stroke.points[0]]
        } else {
            for i in 0..<(stroke.points.count - 1) {
                let p0 = stroke.points[i]
                let p1 = stroke.points[i + 1]
                let dx = (p1.x - p0.x) * extent.width
                let dy = (p1.y - p0.y) * extent.height
                let dist = (dx * dx + dy * dy).squareRoot()
                let steps = min(max(Int(dist / spacing), 1), 40)
                for s in 0..<steps {
                    let t = Double(s) / Double(steps)
                    centers.append(CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
                }
            }
            centers.append(stroke.points[stroke.points.count - 1])
        }

        var dabsUnion: CIImage?
        for center in centers {
            let cx = extent.origin.x + center.x * extent.width
            let cy = extent.origin.y + (1 - center.y) * extent.height

            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: cx, y: cy)
            gradient.radius0 = Float(radius0)
            gradient.radius1 = Float(radius)
            gradient.color0 = maskWhite
            gradient.color1 = maskBlack

            guard let dab = gradient.outputImage?.cropped(to: extent) else {
                continue
            }
            if let existing = dabsUnion {
                let maxFilter = CIFilter.maximumCompositing()
                maxFilter.inputImage = dab
                maxFilter.backgroundImage = existing
                dabsUnion = maxFilter.outputImage
            } else {
                dabsUnion = dab
            }
        }
        return dabsUnion
    }

    // Builds the destination-outline mask for a Patch adjustment, dispatched
    // by shape. Circle reuses radialMask directly (identical center+radius+
    // feather math, just re-packaged into a RadialMaskGeometry with
    // invert always false — a patch destination is never "everywhere
    // outside" the shape) rather than duplicating the ellipse gradient
    // code a second time.
    private static func patchMask(_ geo: PatchGeometry, extent: CGRect) -> CIImage {
        switch geo.shape {
        case .circle:
            let radial = RadialMaskGeometry(
                centerX: geo.centerX, centerY: geo.centerY,
                radiusX: geo.radiusX, radiusY: geo.radiusY,
                feather: geo.feather, invert: false
            )
            return radialMask(radial, extent: extent)
        case .square:
            return squareMask(geo, extent: extent)
        case .free:
            return freeMask(geo, extent: extent)
        }
    }

    // A hard-edged axis-aligned rectangle, softened by a Gaussian blur
    // proportional to `feather` and the rectangle's own half-size.
    // clampedToExtent() before the blur keeps the Gaussian from sampling
    // (and darkening the edge with) transparent pixels outside the working
    // image, the standard CI pattern for blurring near an edge. The blur
    // itself would normally bleed OUTWARD past the drawn rectangle too
    // (Gaussian blur softens both directions around a boundary) — clipped
    // back with darkenBlendMode against the unblurred `hard` mask (a
    // per-pixel minimum) so the feathered result can only ever be DIMMER
    // than the hard edge, never brighter/wider than it. This matters most
    // for the Selection tool's Cut, which drops this exact mask's shape in
    // as a same-sized fill layer — a client cutting a precise selection
    // expects the hole to match what they drew, not visibly balloon past
    // it at high feather values (unlike radialMask, which was already
    // "inward only" by construction via its radius0/radius1 gap).
    private static func squareMask(_ geo: PatchGeometry, extent: CGRect) -> CIImage {
        let feather = min(max(geo.feather, 0), 1)
        let cx = extent.origin.x + geo.centerX * extent.width
        let cy = extent.origin.y + (1 - geo.centerY) * extent.height
        let halfW = max(geo.radiusX * extent.width, 1)
        let halfH = max(geo.radiusY * extent.height, 1)
        let rect = CGRect(x: cx - halfW, y: cy - halfH, width: halfW * 2, height: halfH * 2)

        let hard = CIImage(color: maskWhite).cropped(to: rect)
            .composited(over: CIImage(color: maskBlack).cropped(to: extent))

        guard feather > 0 else {
            return hard.cropped(to: extent)
        }

        let blurRadius = feather * min(halfW, halfH)
        let blurred = hard.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
        return clipToHardEdge(blurred, hard: hard, extent: extent)
    }

    // Per-pixel minimum of a feathered mask and its own unblurred hard
    // edge — the standard trick for turning a symmetric blur into an
    // "inward only" feather (soften toward the inside, never brighten/grow
    // past the original boundary). Shared by squareMask and freeMask,
    // which both start from a hard edge and blur it; radialMask needs no
    // equivalent since its radius0/radius1 gap is already inward-only by
    // construction.
    private static func clipToHardEdge(_ blurred: CIImage, hard: CIImage, extent: CGRect) -> CIImage {
        let clip = CIFilter.darkenBlendMode()
        clip.inputImage = blurred
        clip.backgroundImage = hard
        return (clip.outputImage ?? blurred).cropped(to: extent)
    }

    // Rasterizes the hand-drawn closed polygon (`geo.points`, unit space,
    // top-down Y like every other mask geometry) into a grayscale bitmap via
    // CGContext — Core Image has no built-in "fill this arbitrary polygon"
    // generator the way it does gradients, so this is the one mask type that
    // goes through Core Graphics instead of a CIFilter chain. CGContext's
    // own coordinate space is bottom-up like Core Image's (not top-down like
    // SwiftUI's), so points get the same `1 - y` flip radialMask/graduatedMask
    // already use, not an extra one. Feather blur radius is scaled to the
    // polygon's own bounding box (not a fixed pixel count) so it feels
    // proportionate whether the user drew a tiny or a huge outline.
    private static func freeMask(_ geo: PatchGeometry, extent: CGRect) -> CIImage {
        guard geo.points.count > 2 else {
            return CIImage(color: maskBlack).cropped(to: extent)
        }
        let width = max(Int(extent.width.rounded()), 1)
        let height = max(Int(extent.height.rounded()), 1)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage(color: maskBlack).cropped(to: extent)
        }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let path = CGMutablePath()
        let first = geo.points[0]
        path.move(to: CGPoint(x: first.x * Double(width), y: (1 - first.y) * Double(height)))
        for point in geo.points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * Double(width), y: (1 - point.y) * Double(height)))
        }
        path.closeSubpath()

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(path)
        ctx.fillPath()

        guard let cgImage = ctx.makeImage() else {
            return CIImage(color: maskBlack).cropped(to: extent)
        }

        var mask = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))

        let feather = min(max(geo.feather, 0), 1)
        guard feather > 0 else {
            return mask.cropped(to: extent)
        }
        let hard = mask
        let bounds = path.boundingBoxOfPath
        let blurRadius = feather * min(bounds.width, bounds.height) * 0.5
        mask = mask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
        // Same inward-only clip as squareMask — see clipToHardEdge's doc
        // comment for why.
        return clipToHardEdge(mask, hard: hard, extent: extent)
    }

    // MARK: Image layers

    // Composites every enabled ImageLayer on top of `image` in order (later
    // entries in the array paint over earlier ones, same "list order is
    // stack order" convention as Lightroom/Photoshop's own layer panels).
    private static func compositeLayers(_ layers: [ImageLayer], onto image: CIImage) -> CIImage {
        var output = image
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            return output
        }

        for layer in layers {
            guard layer.isEnabled, layer.width > 0, layer.height > 0 else {
                continue
            }
            guard let source = CIImage(data: layer.imageData), source.extent.width > 0, source.extent.height > 0 else {
                continue
            }

            // Scaled fresh against THIS image's own extent, never assumed
            // to match the piece's native resolution — the same cut/copied
            // piece can be pasted onto a photo with entirely different
            // pixel dimensions than the one it was cut from, and
            // width/height are fractions of THIS photo either way.
            let targetWidthPx = layer.width * extent.width
            let targetHeightPx = layer.height * extent.height
            let scaleX = targetWidthPx / source.extent.width
            let scaleY = targetHeightPx / source.extent.height
            let originX = extent.origin.x + layer.x * extent.width
            // Unit Y is top-down (layer.y is the TOP edge); CI Y is
            // bottom-up, so the piece's bottom-left corner in CI space
            // sits at extent.height minus the distance down to that
            // bottom edge — same `1 - y - height` shape as every other
            // top-down-to-CI conversion in this file that deals with an
            // extent rather than a single point.
            let originY = extent.origin.y + (1 - layer.y - layer.height) * extent.height

            var positioned = source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            positioned = positioned.transformed(by: CGAffineTransform(translationX: originX, y: originY))

            if layer.opacity < 1 {
                let alphaScale = CIFilter.colorMatrix()
                alphaScale.inputImage = positioned
                alphaScale.aVector = CIVector(x: 0, y: 0, z: 0, w: max(layer.opacity, 0))
                positioned = alphaScale.outputImage ?? positioned
            }

            output = blendLayer(positioned, over: output, mode: layer.blendMode, extent: extent)
        }

        return output
    }

    private static func blendLayer(_ top: CIImage, over bottom: CIImage, mode: LayerBlendMode, extent: CGRect) -> CIImage {
        let filter: CIFilter
        switch mode {
        case .normal: filter = CIFilter.sourceOverCompositing()
        case .multiply: filter = CIFilter.multiplyBlendMode()
        case .screen: filter = CIFilter.screenBlendMode()
        case .overlay: filter = CIFilter.overlayBlendMode()
        }
        filter.setValue(top, forKey: kCIInputImageKey)
        filter.setValue(bottom, forKey: kCIInputBackgroundImageKey)
        return (filter.outputImage ?? bottom).cropped(to: extent)
    }

    // MARK: Selection tool (Cut / Copy -> layer clipboard)

    // Re-packages a SelectionGeometry into a PatchGeometry purely to reuse
    // patchMask/radialMask/squareMask/freeMask's already-verified shape
    // math — a selection's "which pixels" question is geometrically
    // identical to a patch's "where do I sample/blend" question, just
    // without any source-offset concept.
    static func selectionMask(_ selection: SelectionGeometry, extent: CGRect) -> CIImage {
        let geo = PatchGeometry(
            shape: selection.shape, centerX: selection.centerX, centerY: selection.centerY,
            radiusX: selection.radiusX, radiusY: selection.radiusY, feather: selection.feather,
            points: selection.points
        )
        return patchMask(geo, extent: extent)
    }

    // The selection's own bounding box in unit space (0...1, top-down Y),
    // clamped to the image — shared by both extraction functions below so
    // a cut/copied piece's PNG only covers the area it actually needs, not
    // the whole photo (mask math itself doesn't naturally shrink to just
    // this shape's box, since e.g. radialMask fills any Core Image extent
    // it's given).
    private static func selectionBoundsUnit(_ selection: SelectionGeometry) -> CGRect? {
        let raw: CGRect
        switch selection.shape {
        case .circle, .square:
            raw = CGRect(
                x: selection.centerX - selection.radiusX, y: selection.centerY - selection.radiusY,
                width: selection.radiusX * 2, height: selection.radiusY * 2
            )
        case .free:
            guard !selection.points.isEmpty else {
                return nil
            }
            let xs = selection.points.map(\.x), ys = selection.points.map(\.y)
            raw = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let clamped = raw.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clamped.isEmpty ? nil : clamped
    }

    private static func selectionBoundsPixels(_ selection: SelectionGeometry, extent: CGRect) -> (unit: CGRect, pixels: CGRect)? {
        guard let boundsUnit = selectionBoundsUnit(selection) else {
            return nil
        }
        let pixelRect = CGRect(
            x: extent.origin.x + boundsUnit.minX * extent.width,
            y: extent.origin.y + (1 - boundsUnit.minY - boundsUnit.height) * extent.height,
            width: boundsUnit.width * extent.width,
            height: boundsUnit.height * extent.height
        ).integral
        guard pixelRect.width > 0, pixelRect.height > 0 else {
            return nil
        }
        return (boundsUnit, pixelRect)
    }

    private static let sharedExtractionContext = CIContext()

    // Cuts/copies the pixels under a Selection's outline out of `image`
    // (expected to be the FULL-resolution, already-edited-and-cropped
    // render a client is looking at — same image Export Edited Copy would
    // write) into a PNG cropped to just the selection's own bounding box —
    // PNG specifically to preserve the alpha the selection shape cut with,
    // which a JPEG has no channel for. Returns nil for an empty/invalid
    // selection (e.g. a Free selection with fewer than 3 points, or a box
    // that doesn't intersect the image at all).
    static func extractSelectionPNG(_ selection: SelectionGeometry, from image: CIImage) -> (data: Data, boundsUnit: CGRect)? {
        guard let masked = maskedSelectionImage(selection, source: image, extent: image.extent) else {
            return nil
        }
        guard let bounds = selectionBoundsPixels(selection, extent: image.extent) else {
            return nil
        }
        guard let png = pngData(for: masked, pixelRect: bounds.pixels) else {
            return nil
        }
        return (png, bounds.unit)
    }

    // The "hole" a Cut leaves behind: a solid-color, same-shaped-as-the-
    // selection PNG (same mask, filled with `color` instead of sampled
    // pixels) meant to be dropped straight into a new ImageLayer at the
    // selection's own position — reuses the exact same layer-compositing
    // path as any pasted piece, so "cut" needs no separate render-time
    // concept of its own.
    static func solidFillPNG(_ selection: SelectionGeometry, color: CIColor, extent: CGRect) -> (data: Data, boundsUnit: CGRect)? {
        let solid = CIImage(color: color).cropped(to: extent)
        guard let masked = maskedSelectionImage(selection, source: solid, extent: extent) else {
            return nil
        }
        guard let bounds = selectionBoundsPixels(selection, extent: extent) else {
            return nil
        }
        guard let png = pngData(for: masked, pixelRect: bounds.pixels) else {
            return nil
        }
        return (png, bounds.unit)
    }

    private static func maskedSelectionImage(_ selection: SelectionGeometry, source: CIImage, extent: CGRect) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }
        if selection.shape == .free && selection.points.count < 3 {
            return nil
        }
        let mask = selectionMask(selection, extent: extent)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = clear
        blend.maskImage = mask
        return blend.outputImage
    }

    private static func pngData(for image: CIImage, pixelRect: CGRect) -> Data? {
        let cropped = image.cropped(to: pixelRect)
        guard let cgImage = sharedExtractionContext.createCGImage(cropped, from: pixelRect) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    // A single-channel (luminance) histogram of the already-rendered image,
    // as `bucketCount` bars normalized so the tallest bar is 1.0 — read by
    // the adjustment panel's histogram strip. Desaturating first (rather
    // than reading, say, just the green channel) keeps it representative of
    // overall tonal distribution the way a photo editor's histogram usually
    // reads, not one color channel's alone.
    static func luminanceHistogram(of image: CIImage, bucketCount: Int = 48) -> [CGFloat] {
        // CIColorMatrix computes each OUTPUT channel as a dot product of
        // (r, g, b, a) with the corresponding vector — so to get R=G=B=
        // luminance out, r/g/bVector all need to be the *same* Rec. 709
        // luma weights (not each channel's own weight in isolation, which
        // would compute outputRed = 0.2126*(r+g+b) instead of luminance).
        let lumaWeights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let grayFilter = CIFilter.colorMatrix()
        grayFilter.inputImage = image
        grayFilter.rVector = lumaWeights
        grayFilter.gVector = lumaWeights
        grayFilter.bVector = lumaWeights
        grayFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let gray = grayFilter.outputImage else {
            return []
        }

        let histogramFilter = CIFilter.areaHistogram()
        histogramFilter.inputImage = gray
        histogramFilter.extent = gray.extent
        histogramFilter.count = bucketCount
        histogramFilter.scale = 1
        guard let histogramImage = histogramFilter.outputImage else {
            return []
        }

        // Render straight to a float buffer (not through a CGImage) — an
        // 8-bit intermediate would clip any bucket whose pixel count
        // exceeds 255, which a several-hundred-thousand-pixel preview
        // hits immediately.
        var pixels = [Float](repeating: 0, count: bucketCount * 4)
        briefEditsCIContext.render(
            histogramImage,
            toBitmap: &pixels,
            rowBytes: bucketCount * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: bucketCount, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        // R/G/B all carry the same value post-desaturation, so any one
        // channel (here R) is the luminance bucket count.
        var bins = (0..<bucketCount).map { CGFloat(pixels[$0 * 4]) }
        if let peak = bins.max(), peak > 0 {
            bins = bins.map { $0 / peak }
        }
        return bins
    }
}

private let briefEditsSRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

// One shared, Metal-backed context for both the live (downsampled) preview
// and the full-resolution export — CIContext is safe to reuse across many
// renders of different sizes.
private let briefEditsCIContext = CIContext(options: [
    .workingColorSpace: briefEditsSRGBColorSpace,
    .outputColorSpace: briefEditsSRGBColorSpace,
    .cacheIntermediates: false
])

// Serial (not concurrent) — PhotoEditRenderer.render() mutates a RAW
// photo's shared CIRAWFilter in place (see PhotoBaseImage.raw's own doc
// comment), so two renders for the same photo must never run at once, or
// their concurrent writes to the same filter's exposure/neutralTemperature/
// neutralTint properties would race. A serial queue also naturally finishes
// slider-drag renders in the order they were scheduled, so a stale result
// can never briefly flash on screen after a newer one — a small
// correctness improvement for the non-RAW path too, not just RAW.
private let developRenderQueue = DispatchQueue(label: "com.rocketsbrief.briefshow.develop.render")

// MARK: - Window lifecycle

// Mirrors ShowGridWindowController/BriefShowWindowController exactly — its
// own standalone, resizable window (not an overlay inside ShowGrid, which
// is sized to its own content and would clip a Lightroom-style layout).
// Same simplification those two make too: if a Develop window is already
// open, this just refocuses it rather than swapping in a new photo set —
// re-opening Develop while a session is already in progress there
// shouldn't interrupt it.
// A view's `acceptsFirstMouse(for:)` defaults to false — the very FIRST
// click after this window becomes key (right after opening, or after
// clicking back into it from another window/app) is consumed just to
// activate/focus the window, never reaching whatever control is under the
// cursor. That's exactly the "clicking Brush/Radial does nothing the
// moment Develop opens, works after I click something else first" bug
// report: that "something else" click was silently eaten by activation,
// and everything after it worked normally because the window was already
// key by then. Overriding this to true on the hosting view (this is an
// NSView method, NOT NSWindow — there's no window-level equivalent) makes
// the very first click count everywhere inside it.
//
// Concrete (NSHostingView<DevelopView>) rather than generic over its
// content: Swift 6.3.3's optimizer crashes — a hard compiler crash, not a
// diagnostic — while inlining into the SYNTHESIZED deinit of a generic
// NSHostingView subclass, which made every Release build of this app fail
// (Debug, which doesn't run that pass, was fine, so it stayed hidden until
// the first Release build). This class only ever wraps DevelopView anyway,
// so naming that type costs nothing and sidesteps the bug. If a second
// content type ever needs it, re-check whether the toolchain still crashes
// before making it generic again.
private final class ClickThroughHostingView: NSHostingView<DevelopView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class DevelopWindowController {
    static let shared = DevelopWindowController()

    private var windowController: NSWindowController?

    private init() {}

    func open(photoURLs: [URL], initialSelection: URL?) {
        if let controller = windowController {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Develop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 640)
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller

        window.contentView = ClickThroughHostingView(
            rootView: DevelopView(
                photoURLs: photoURLs,
                initialSelection: initialSelection,
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        windowController?.close()
        windowController = nil
    }
}

// MARK: - Keyboard-nudgeable sliders

// Which slider the ← / → keys currently act on, plus the transient card
// that announces the pick — Lightroom's own behaviour, where clicking a
// slider's NAME arms it and the arrow keys then step it up/down without
// ever touching the mouse again.
//
// The nudge itself can't be resolved from a key alone: every editSlider is
// built with its own Binding (a plain `$settings.exposure` for the global
// ones, but a computed get/set pair for masks, patch and layer opacity),
// and there's no single keypath that reaches all of them. So each slider
// REGISTERS a closure over its own binding here, keyed by its slider key,
// and the key monitor just looks that closure up and calls it. Registration
// happens on every body pass (not in .onAppear) so the closure always holds
// the most recent render's binding, and the registry is a plain class — NOT
// ObservableObject — precisely so writing to it during a body pass can't
// invalidate the view it was written from.
//
// Entries for sliders that have since scrolled away or belong to a
// deselected mask are harmless: those bindings' own setters already guard
// on "is anything selected" and no-op, and only the ONE key in
// selectedSliderKey is ever invoked anyway.
final class SliderNudgeRegistry {
    private var entries: [String: (Bool, Double) -> Void] = [:]

    func register(_ key: String, apply: @escaping (_ increase: Bool, _ multiplier: Double) -> Void) {
        entries[key] = apply
    }

    // Returns false when the key isn't registered (slider not currently
    // built) so the caller can leave the keypress alone instead of
    // swallowing an arrow key that did nothing.
    @discardableResult
    func nudge(_ key: String, increase: Bool, multiplier: Double) -> Bool {
        guard let apply = entries[key] else {
            return false
        }
        apply(increase, multiplier)
        return true
    }
}

// The "Exposure selected — ← / → to adjust" card. Identifiable (fresh id per
// pick) so re-clicking a DIFFERENT slider while the card is still up
// re-triggers its transition instead of silently swapping the text.
struct SliderSelectionToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
}

// MARK: - Main view

struct DevelopView: View {
    let photoURLs: [URL]
    let initialSelection: URL?
    let onClose: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var selectedURL: URL?
    // Filmstrip multi-select (Cmd toggles one photo in/out, Shift selects
    // the whole range from selectionAnchor to the clicked photo) — separate
    // from selectedURL, which is "the photo currently open in the editor"
    // and keeps working exactly as before on a plain click. Used for the
    // right-click "Export…" context menu (exports the whole set when more
    // than one photo is selected) — see handleFilmstripClick/exportSinglePhoto.
    @State private var multiSelectedURLs: Set<URL> = []
    // The photo a Shift-click range is measured from — set on every plain
    // or Cmd click, left untouched by Shift-clicks themselves (so repeated
    // Shift-clicks keep extending/shrinking from the same anchor, matching
    // Finder/Photos convention rather than re-anchoring on every click).
    @State private var selectionAnchor: URL?
    @State private var settings = PhotoEditSettings()
    @State private var fullBaseImage: PhotoBaseImage?
    @State private var previewBaseImage: PhotoBaseImage?
    @State private var displayedImage: NSImage?
    @State private var histogramBins: [CGFloat] = []
    @State private var filmstripThumbnails: [URL: NSImage] = [:]
    @State private var isLoadingPreview = false
    @State private var showOriginal = false
    @State private var isCropping = false
    @State private var pendingCrop: EditCropRect = .full
    @State private var dragStartCrop: EditCropRect?
    // Which aspect-ratio button (if any) is highlighted on the crop tool's
    // own row — purely a UI highlight, not enforced during handle drags
    // (see moveCrop/resizeCrop, which reset it back to .free since a
    // manual drag breaks whatever ratio a button last snapped to).
    @State private var selectedCropAspectRatio: CropAspectRatioOption = .free
    // True while `settings.crop` was last set by auto-fitting after a
    // Straighten drag (rather than by the user's own crop tool) — lets
    // further straighten drags keep re-fitting it, without ever clobbering
    // a crop the user deliberately made with the crop tool. See
    // applyAutoFitCropIfNeeded / straightenBinding / commitCrop.
    @State private var cropIsAutoFitted = false
    @State private var exportStatusText: String?
    @State private var renderWorkItem: DispatchWorkItem?
    // Bumped once per renderNow() call, read live (cross-thread, same
    // pattern as `selectedURL`/`photoAtRenderTime` below) from inside the
    // background render — lets a render that's been superseded by a NEWER
    // one bail out immediately, before or during the expensive CIImage
    // work, instead of finishing anyway. Without this, dragging a slider
    // fast enough to outrun a single render's cost queues up a growing
    // backlog on `developRenderQueue` (a plain serial queue) — each stale
    // render still runs to completion before the next one even starts, so
    // the displayed image visibly lags/jumps through a chain of stale
    // in-between values instead of tracking the live slider smoothly.
    @State private var renderGeneration = 0

    // Presets: a global, persisted library of full-settings snapshots (see
    // PhotoEditPresetStore). Copy/paste: a lightweight in-memory clipboard
    // that only lives for this Develop window session — deliberately not
    // persisted, since it's meant for "copy from A, paste onto B" within
    // one sitting, not a saved look (that's what a preset is for).
    @State private var presets: [PhotoEditPreset] = PhotoEditPresetStore.loadAll()
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var settingsClipboard: PhotoEditSettings?
    // Lightroom-style "Synchronize Settings" — showSyncDialog presents a
    // sheet (syncDialogView) where the user picks WHICH categories to sync
    // (syncCategories, all checked by default like Lightroom's own dialog)
    // before syncSettingsToSelection actually writes anything. See
    // handleFilmstripClick/selectAllPhotos for how multiSelectedURLs (the
    // sync targets) gets populated.
    // App-wide, like every other preference here: what to write and how hard
    // to squeeze it. Stored as the raw string so the enum can gain cases
    // without invalidating what someone already picked.
    @AppStorage("develop.export.format") private var exportFormatRaw: String = ExportFormat.jpeg.rawValue
    @AppStorage("develop.export.quality") private var exportQuality: Double = 0.92
    private var exportFormat: ExportFormat {
        ExportFormat(rawValue: exportFormatRaw) ?? .jpeg
    }

    @State private var showSyncDialog = false
    @State private var syncCategories: SyncCategory = .all

    // Local adjustments (masks). `selectedLocalAdjustmentID` nil = editing
    // the global sliders as usual; non-nil = the on-canvas overlay shows
    // that mask's handles (or paint surface, for brush) and the panel shows
    // its own mini adjustment sliders instead of nothing extra. Mutually
    // exclusive with crop mode (see toggleCropMode/selectLocalAdjustment).
    @State private var selectedLocalAdjustmentID: UUID?
    // The in-progress brush stroke's points (unit space), live while the
    // user is dragging — committed into settings.localAdjustments on
    // mouse-up (see commitBrushStroke), not stored anywhere persisted
    // before that so a canceled/interrupted drag never leaves a partial
    // stroke behind.
    @State private var activeBrushStrokePoints: [CGPoint] = []
    // Tool state for the NEXT brush stroke — not per-adjustment, since it's
    // meant to persist as the user paints multiple strokes into the same
    // mask (each committed BrushStroke still keeps its own copy, see its
    // doc comment, so changing these later never reshapes past strokes).
    @State private var brushSize: Double = 0.08
    @State private var brushHardness: Double = 0.4
    @State private var brushIsErasing = false
    // Live mouse position (frame/view space, not unit space) while hovering
    // the brush's paint surface, purely for drawing a "you are about to
    // paint this big" cursor-size ring — nil whenever the mouse isn't over
    // the surface. Cleared on hover-exit and while a stroke is actively
    // being painted (the in-progress stroke's own preview already shows
    // where the brush is in that case).
    @State private var brushHoverLocation: CGPoint?
    // Drag-start snapshots for the radial/graduated on-canvas handles —
    // same pattern as dragStartCrop: captured on the first onChanged of a
    // drag, cleared on onEnded, so each drag computes its delta against a
    // stable baseline instead of the (already-mutated) live value.
    @State private var radialDragStart: RadialMaskGeometry?
    @State private var graduatedDragStart: GraduatedMaskGeometry?
    @State private var patchDragStart: PatchGeometry?
    // Points of an in-progress Free-shape patch outline (unit space), live
    // while the user is drawing it — same "don't touch the real model until
    // mouse-up" reasoning as activeBrushStrokePoints, so a canceled/
    // interrupted drag never leaves a stray half-drawn outline behind.
    @State private var activePatchDrawPoints: [CGPoint] = []
    // Live mouse position (frame/view space) while hovering a patch's
    // canvas with ⌥ held — purely a "this is where the source will land if
    // you click now" preview ring, nil whenever the mouse isn't over the
    // canvas OR ⌥ isn't currently held. Mirrors brushHoverLocation's
    // pattern/reasoning.
    @State private var patchSourceHoverLocation: CGPoint?

    // Circle-mode Patch (clone-stamp brush) state — same "don't touch the
    // real model until mouse-up" pattern as activeBrushStrokePoints/
    // activePatchDrawPoints above. `pendingPatchSource` is the unit-space
    // point an ⌥-click just landed on, consumed (and cleared) by the FIRST
    // dab of the next painted stroke, which turns it into `patchStrokeOffset`
    // — a fixed destination→source vector that then stays in effect across
    // MULTIPLE stroke drags ("Aligned" clone-stamp behavior, matching
    // Photoshop) until the user ⌥-clicks again to pick a new source.
    // `patchBrushSize`/`patchBrushFeather` are shared UI state read when a
    // stroke is committed (see commitPatchStroke) — exactly how brushSize/
    // brushHardness work for the Brush tool — so each already-painted
    // stroke keeps whatever size/feather was in effect when IT was drawn.
    @State private var activePatchStrokePoints: [CGPoint] = []
    @State private var pendingPatchSource: CGPoint?
    @State private var patchStrokeOffset: CGSize?
    @State private var patchBrushSize: Double = 0.08
    @State private var patchBrushFeather: Double = 0.35
    // Cursor-size ring preview while hovering (not dragging, not ⌥-held) —
    // mirrors brushHoverLocation exactly, just a separate var since the two
    // tools' hover state can't be conflated (different rings/sizes).
    @State private var patchBrushHoverLocation: CGPoint?

    // Selection tool (Cut/Copy/Deselect -> layer clipboard). `activeSelection`
    // nil = tool not in use; non-nil = its outline is shown/editable on
    // canvas. Ephemeral like isCropping's pendingCrop — never written into
    // PhotoEditSettings itself, only consumed by Cut/Copy into a new/
    // modified ImageLayer.
    @State private var activeSelection: SelectionGeometry?
    @State private var selectionDragStart: SelectionGeometry?
    @State private var activeSelectionDrawPoints: [CGPoint] = []
    @State private var isExtractingSelection = false

    // The most recently Cut/Copy'd piece, in-memory only (like
    // settingsClipboard) — survives switching photos in the filmstrip
    // while this Develop window stays open, but not closing the window or
    // restarting the app. `aspectRatio` lets Paste size the new layer
    // sensibly without having to decode the full image just to ask its
    // dimensions.
    @State private var layerClipboard: LayerClipboardData?

    // Image layers (pasted cut/copied pieces). Same UUID-not-index
    // selection tracking as selectedLocalAdjustmentID, same reasoning
    // (the array can shrink/reorder out from under a cached index).
    @State private var selectedLayerID: UUID?
    @State private var layerDragStart: ImageLayer?
    // Token for the Cmd+C/X/V local key monitor — see installClipboardKeyMonitor.
    @State private var editingKeyMonitor: Any?
    // Undo/redo — see scheduleUndoCommit's doc comment for the
    // debounce/coalescing reasoning.
    @State private var undoStack: [PhotoEditSettings] = []
    @State private var redoStack: [PhotoEditSettings] = []
    @State private var pendingUndoBaseline: PhotoEditSettings?
    @State private var undoCommitWorkItem: DispatchWorkItem?
    @State private var lastCommittedSettings = PhotoEditSettings()

    // Arrow-key slider nudging (see SliderNudgeRegistry). selectedSliderKey
    // is the armed slider (nil = arrows are left alone entirely, so they
    // still reach text fields and anything else that wants them);
    // sliderToast is the transient card announcing the pick, cleared by
    // sliderToastDismissWork after a couple of seconds or immediately when
    // another slider is picked.
    @State private var sliderRegistry = SliderNudgeRegistry()
    @State private var selectedSliderKey: String?
    @State private var sliderToast: SliderSelectionToast?
    @State private var sliderToastDismissWork: DispatchWorkItem?

    // "Remove" tool — Vision picks the people out, ExemplarInpainter fills
    // the hole (see DevelopInpaint.swift). Both are ephemeral, like
    // activeSelection: the mask lives only until it is erased or the photo
    // changes, and what PERSISTS is the ImageLayer the erase produces.
    // `removalMask` is in the FULL, pre-crop image's space, the same space
    // ImageLayer coordinates are interpreted in.
    @State private var removalMask: CIImage?
    @State private var removalOverlay: NSImage?
    @State private var isFindingPeople = false
    @State private var isRemoving = false
    // Only the AI erase reports progress: it is thirty UNet passes, not the
    // second or two the exemplar fill takes, so a bare "Erasing…" would read
    // as a hang. nil means no AI erase is running.
    @State private var aiEraseProgress: Double?
    // The AI erase is the one half of Remove that can fail for a reason the
    // user can act on (weights not installed yet), so unlike the exemplar
    // path it has somewhere to say so.
    @State private var removeErrorMessage: String?
    // App-wide, not per-photo: this is a preference about how AI Clean Up
    // behaves, not part of any one picture's edit. Empty string is allowed and
    // meaningful — it means "no prompt at all" — so the reset button restores
    // the default rather than an empty field standing in for it.
    //
    // The defaults keys keep the old "aiRemove" name on purpose: renaming them
    // to match the button would silently throw away a prompt someone had
    // already written.
    @AppStorage("develop.aiRemove.prompt")
    private var aiRemovePrompt: String = SDInpaintPipeline.defaultPrompt
    @State private var showsAIPromptEditor = false
    // 1 means "fit the window", which is where every photo starts. Zoom and
    // pan live in fittedImageFrame, so every overlay that derives its screen
    // position from that frame — crop, masks, layers, the removal brush —
    // follows the zoom without knowing it exists.
    @State private var zoomLevel: Double = 1
    @State private var panOffset: CGSize = .zero
    @State private var panStart: CGSize?
    @AppStorage("develop.aiRemove.feather")
    private var aiRemoveFeather: Double = SDInpaintPipeline.defaultFeather
    // Hand-painted half of the Remove tool: paint over anything (a bin, a
    // sign, a stranger Vision didn't call a person) and erase that instead.
    // Strokes live in the FULL, pre-crop image's unit space, same as
    // removalMask, and are only turned into a real CIImage mask at Erase
    // time — while painting, the red ink on screen is a plain vector Path,
    // the same trick brushPaintOverlay uses to stay interactive.
    @State private var isRemoveBrushActive = false
    @State private var removalStrokes: [BrushStroke] = []
    @State private var activeRemovalStrokePoints: [CGPoint] = []
    @State private var removalBrushSize: Double = 0.06
    @State private var removalBrushHoverLocation: CGPoint?

    // Same soft-yellow-in-Dark, mid-gray-elsewhere accent PhotoShowSheet
    // uses for its own selection border, kept consistent here for the
    // filmstrip's selection ring and the "has edits" badge.
    private var accentColor: Color {
        themeManager.current == .dark
            ? Color(red: 1.0, green: 0.94, blue: 0.62)
            : Color(red: 0.56, green: 0.56, blue: 0.58)
    }

    private let histogramHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    topBar

                    Divider()

                    centerPreview
                }
                .frame(maxWidth: .infinity)

                Divider()

                adjustmentPanel
            }

            Divider()

            filmstrip
        }
        .background(AppColors.background)
        .onAppear {
            if selectedURL == nil, let initial = initialSelection ?? photoURLs.first {
                selectPhoto(initial)
            }
            // Eat the model load here rather than on the first AI Clean Up: it is
            // ~18 seconds of Neural Engine compilation, and opening Develop is
            // the one moment the user is not already waiting for a result.
            SDInpaintPipeline.shared.warmUp()
            LaMaInpaintPipeline.shared.warmUp()
        }
        .onChange(of: settings) { _ in
            scheduleRender()
            scheduleUndoCommit()
        }
        .onChange(of: pendingCrop) { _ in
            if isCropping {
                scheduleRender()
            }
        }
        .onChange(of: showOriginal) { _ in renderNow() }
        .onAppear { installEditingKeyMonitor() }
        .onDisappear { removeEditingKeyMonitor() }
        .sheet(isPresented: $showSyncDialog) {
            syncDialogView
        }
    }

    // Every Develop keyboard shortcut that isn't a plain SwiftUI Button's
    // own `.keyboardShortcut` goes through this ONE local NSEvent monitor
    // — Cmd+C/X/V (clipboard), Cmd+Z / Cmd+⇧+Z (undo/redo), bare [ / ]
    // (brush/patch/radial/selection size, Photoshop's own convention), and
    // bare Backspace/Delete (delete the selected layer or mask). A single
    // shared monitor rather than one per shortcut, since they all need the
    // identical "only while Develop is key" scoping and it keeps the
    // isARepeat reasoning (see below) in one place instead of repeated
    // per-shortcut. Scoped to only fire while THIS window is key (by
    // title, since window is otherwise anonymous/untyped here) — local
    // monitors are app-wide, not per-window, so without this check these
    // shortcuts pressed while some OTHER window (e.g. the main ShowGrid
    // window) is frontmost would incorrectly act on whatever photo Develop
    // last had open.
    //
    // event.isARepeat is checked for Cmd+C/X/V specifically — a previous
    // version of this monitor omitted it there and shipped a real, serious
    // bug: holding Cmd+V for even a fraction of a second past the OS's
    // key-repeat threshold fired pasteLayer() on every repeated keyDown
    // (tens of times a second), piling up dozens of layers in an instant.
    // Each additional layer makes every subsequent render (PNG decode +
    // composite, once per layer, on every settings change) a little
    // slower, and that slowdown compounds with more repeats arriving
    // faster than renders can finish — a runaway feedback loop that pegged
    // the app at ~76% CPU and stopped responding to window activation
    // entirely, observed firsthand this session (had to `kill -9` it).
    // Undo/redo and [ / ] deliberately DO allow repeat — holding Cmd+Z to
    // step back several states, or holding ] to smoothly grow a brush,
    // are both the normal expected feel — but neither carries the same
    // risk: each step is one cheap, bounded array-pop or clamped-arithmetic
    // update, nothing accumulates the way an unbounded paste-per-repeat
    // did.
    private func installEditingKeyMonitor() {
        guard editingKeyMonitor == nil else {
            return
        }
        editingKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow?.title == "Develop" else {
                return event
            }
            // Masked down to JUST the modifiers these shortcuts actually
            // care about (command/shift/control/option), not the full
            // `.deviceIndependentFlagsMask` (which also includes capsLock/
            // numericPad/help/function). Those extra bits can legitimately
            // be set alongside a plain Cmd+X/Cmd+C/Cmd+V — e.g. Caps Lock
            // physically on, or a numeric-pad-adjacent key involved in how
            // some keyboards/input sources report the event — and every
            // comparison below is exact equality (`flags == .command`), so
            // ANY stray incidental bit silently broke the match and made
            // the shortcut do nothing with zero feedback. Narrowing to only
            // the modifiers that actually distinguish one shortcut from
            // another (command alone vs command+shift) fixes that without
            // losing the ability to tell them apart.
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let key = event.charactersIgnoringModifiers?.lowercased()

            // Each case only fires when there's actually something for it
            // to DO (a populated clipboard / a non-empty undo stack / an
            // active Selection outline / a selected mask or layer) —
            // otherwise falls through to the final `return event`, so
            // these keys still reach normal text-field editing (e.g.
            // typing/backspacing a preset name) whenever the relevant tool
            // isn't in active use. Without these guards, every one of
            // these keys anywhere in Develop — including inside a plain
            // text field — would be swallowed by this monitor.
            if flags == .command, !event.isARepeat {
                switch key {
                case "v" where layerClipboard != nil: pasteLayer(); return nil
                case "c" where activeSelection != nil: copySelection(); return nil
                case "x" where activeSelection != nil: cutSelection(); return nil
                default: break
                }
            }
            // Cmd +/- zoom, Cmd 0 back to fit. Repeat is allowed on purpose —
            // holding Cmd+= to zoom in is the expected feel — and each press
            // is one clamped multiply, so nothing accumulates the way the
            // Cmd+V paste-per-repeat bug did. Both "=" and "+" are matched
            // because the same physical key reports as "=" unshifted and "+"
            // with shift, and people press it either way.
            if flags == .command || flags == [.command, .shift] {
                switch key {
                case "=", "+": stepZoom(1); return nil
                case "-", "_": stepZoom(-1); return nil
                // Cmd+0 only. Cmd+Space was tried and dropped: Spotlight owns
                // it system-wide, so it never reaches the app.
                case "0" where flags == .command: resetZoom(); return nil
                default: break
                }
            }
            if flags == .command, key == "z", !undoStack.isEmpty {
                undo()
                return nil
            }
            if flags == [.command, .shift], key == "z", !redoStack.isEmpty {
                redo()
                return nil
            }
            if flags.isEmpty, key == "[" || key == "]", activeToolHasAdjustableSize {
                adjustActiveToolSize(increase: key == "]")
                return nil
            }
            // ← / → step whichever slider is currently armed (clicking a
            // slider's name arms it, see selectSlider), Shift+arrow steps it
            // 5x — Lightroom's own fine/coarse pairing. Repeat is allowed on
            // purpose: holding an arrow to ramp a value up is the whole
            // point, and each press is one clamped add on a single Double,
            // nothing that can pile up the way the Cmd+V bug above did.
            //
            // Guarded three ways so these keys stay untouched everywhere
            // else in Develop: nothing armed → fall through; a field editor
            // (the preset-name text field) has focus → fall through, so
            // arrows still move the caret; and nudgeSelectedSlider itself
            // returns false when the armed slider isn't on screen right now
            // (e.g. its mask got deselected) rather than swallowing the key
            // for nothing. Escape disarms.
            if flags.isEmpty, event.keyCode == 53, selectedSliderKey != nil {
                clearSelectedSlider()
                return nil
            }
            if flags.isEmpty || flags == .shift,
               event.keyCode == 123 || event.keyCode == 124,
               selectedSliderKey != nil,
               !((NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor ?? false),
               nudgeSelectedSlider(increase: event.keyCode == 124, coarse: flags == .shift) {
                return nil
            }
            if flags.isEmpty, (event.keyCode == 51 || event.keyCode == 117),
               selectedLayerID != nil || selectedLocalAdjustmentID != nil {
                deleteSelectedItem()
                return nil
            }

            return event
        }
    }

    private func removeEditingKeyMonitor() {
        if let editingKeyMonitor {
            NSEvent.removeMonitor(editingKeyMonitor)
        }
        editingKeyMonitor = nil
    }

    private func deleteSelectedItem() {
        if let id = selectedLayerID {
            deleteLayer(id)
        } else if let id = selectedLocalAdjustmentID {
            deleteLocalAdjustment(id)
        }
    }

    // Whether [ / ] currently have a "size" to act on — a Brush/Radial
    // mask (brush diameter / radial radius), a Circle or Square Patch
    // (its radius — Free has no single "size" to speak of), or an active
    // Circle/Square Selection outline. Graduated and Free-shape
    // Patch/Selection are excluded for the same reason: no single scalar
    // "size" describes them.
    private var activeToolHasAdjustableSize: Bool {
        if isRemoveBrushActive {
            return true
        }
        if let index = selectedAdjustmentIndex {
            switch settings.localAdjustments[index].type {
            case .brush, .radial: return true
            case .patch: return settings.localAdjustments[index].patch?.shape != .free
            case .graduated: return false
            }
        }
        if let activeSelection {
            return activeSelection.shape != .free
        }
        return false
    }

    // Multiplicative step (±10%) rather than a fixed absolute amount —
    // feels proportionate whether the current size is tiny or huge, and
    // means the SAME step works for brush (0.01...0.3 range) and a
    // radial/patch/selection radius (0.02...1 range) without needing a
    // different magic number per tool.
    private func adjustActiveToolSize(increase: Bool) {
        let factor = increase ? 1.1 : (1 / 1.1)

        // Checked before any mask/selection so the bracket keys follow the
        // tool the client is actually painting with right now.
        if isRemoveBrushActive {
            removalBrushSize = min(max(removalBrushSize * factor, 0.01), 0.3)
            return
        }

        if let index = selectedAdjustmentIndex {
            switch settings.localAdjustments[index].type {
            case .brush:
                brushSize = min(max(brushSize * factor, 0.01), 0.3)
            case .radial:
                guard var geo = settings.localAdjustments[index].radial else { return }
                geo.radiusX = min(max(geo.radiusX * factor, 0.02), 1)
                geo.radiusY = min(max(geo.radiusY * factor, 0.02), 1)
                settings.localAdjustments[index].radial = geo
            case .patch:
                guard let shape = settings.localAdjustments[index].patch?.shape, shape != .free else { return }
                if shape == .circle {
                    // Adjusts the brush for the NEXT stroke, same as
                    // brushSize above — strokes already painted keep
                    // whatever size they were drawn with.
                    patchBrushSize = min(max(patchBrushSize * factor, 0.02), 0.3)
                } else if var geo = settings.localAdjustments[index].patch {
                    // Legacy Square data only.
                    geo.radiusX = min(max(geo.radiusX * factor, 0.02), 1)
                    geo.radiusY = min(max(geo.radiusY * factor, 0.02), 1)
                    settings.localAdjustments[index].patch = geo
                }
            case .graduated:
                break
            }
            return
        }

        if var selection = activeSelection, selection.shape != .free {
            selection.radiusX = min(max(selection.radiusX * factor, 0.02), 1)
            selection.radiusY = min(max(selection.radiusY * factor, 0.02), 1)
            activeSelection = selection
        }
    }

    // MARK: Undo / redo

    // Coalesced, debounced undo — NOT one entry per slider-drag tick.
    // scheduleUndoCommit is called on every `settings` change (see body's
    // `.onChange`); the FIRST change in a burst captures `lastCommittedSettings`
    // (the state before this burst started) into `pendingUndoBaseline` and
    // starts a timer, and every subsequent change in the same burst just
    // restarts the timer without touching the baseline. Only once changes
    // STOP for 0.5s does commitUndoIfNeeded push that one baseline onto
    // undoStack — so dragging a slider for 3 seconds produces ONE undo
    // step (back to before the drag started), not hundreds.
    private func scheduleUndoCommit() {
        if pendingUndoBaseline == nil {
            pendingUndoBaseline = lastCommittedSettings
        }
        undoCommitWorkItem?.cancel()
        let workItem = DispatchWorkItem { commitUndoIfNeeded() }
        undoCommitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func commitUndoIfNeeded() {
        defer { pendingUndoBaseline = nil }
        guard let baseline = pendingUndoBaseline, baseline != settings else {
            return
        }
        undoStack.append(baseline)
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
        redoStack = []
        lastCommittedSettings = settings
    }

    // Undo/redo restore the WHOLE PhotoEditSettings snapshot (crop/masks/
    // layers/tonal sliders together), same "one struct is the source of
    // truth" approach Presets/Copy-Paste Settings already use — simpler
    // and more predictable than trying to undo individual fields
    // independently, at the cost of a coarser step than some editors'
    // per-field undo.
    private func undo() {
        guard let previous = undoStack.popLast() else {
            return
        }
        undoCommitWorkItem?.cancel()
        pendingUndoBaseline = nil
        redoStack.append(settings)
        applyUndoRedoSnapshot(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else {
            return
        }
        undoCommitWorkItem?.cancel()
        pendingUndoBaseline = nil
        undoStack.append(settings)
        applyUndoRedoSnapshot(next)
    }

    private func applyUndoRedoSnapshot(_ snapshot: PhotoEditSettings) {
        settings = snapshot
        lastCommittedSettings = snapshot
        pendingCrop = snapshot.crop ?? .full
        cropIsAutoFitted = false
        selectedLocalAdjustmentID = nil
        selectedLayerID = nil
        activeSelection = nil
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(photoURLs, id: \.self) { url in
                        filmstripThumbnail(for: url)
                    }
                }
                .padding(10)
            }

            Divider()

            // Kept OUTSIDE the horizontal ScrollView (not scrolled away with
            // the thumbnails) so it's always reachable regardless of scroll
            // position — a "Select All" that required first scrolling to
            // find it would defeat its own purpose on a long filmstrip.
            VStack(spacing: 8) {
                Button {
                    selectAllPhotos()
                } label: {
                    Text("Select All")
                }
                .buttonStyle(ShowHeaderButtonStyle())

                Button {
                    deselectAllPhotos()
                } label: {
                    Text("Deselect")
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .opacity(multiSelectedURLs.isEmpty ? 0.4 : 1)
                .disabled(multiSelectedURLs.isEmpty)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 120)
        .background(AppColors.panel)
    }

    private func filmstripThumbnail(for url: URL) -> some View {
        let isOpen = selectedURL == url
        let isMultiSelected = multiSelectedURLs.contains(url)
        let hasEdits = PhotoEditStore.hasEdits(url)

        return ZStack(alignment: .topTrailing) {
            Group {
                if let image = filmstripThumbnails[url] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(AppColors.panelAlt)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                // The open-in-editor photo keeps the original full-opacity
                // accent ring; a photo that's only part of the multi-select
                // (Cmd/Shift) but not the one currently open gets the same
                // ring at lower opacity — visually distinct from "open" while
                // still readable as "selected" at a glance in a horizontal
                // strip.
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isOpen ? accentColor : (isMultiSelected ? accentColor.opacity(0.5) : Color.clear),
                        lineWidth: 2.5
                    )
            )

            if isMultiSelected {
                // A previous version painted the WHOLE "checkmark.circle.fill"
                // glyph (circle AND checkmark together) in a single flat
                // color via .foregroundColor — with that color being the
                // pale-yellow accentColor, the result was a low-contrast
                // near-white blob on light thumbnails, exactly what wasn't
                // visible. `.palette` rendering mode colors the checkmark
                // and circle separately so they read as two contrasting
                // layers regardless of accentColor/theme; a fixed, saturated
                // blue (independent of accentColor, which stays reserved for
                // the selection RING) matches the standard macOS "item is
                // selected" affordance (Finder/Photos) rather than blending
                // into either theme's own accent.
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 0.13, green: 0.47, blue: 0.98))
                    .font(.system(size: 15))
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if hasEdits {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Circle().fill(accentColor))
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleFilmstripClick(url)
        }
        .onAppear {
            loadFilmstripThumbnail(for: url)
        }
        .contextMenu {
            // Right-clicking a photo that's part of a larger multi-select
            // exports the WHOLE selection (one destination-folder picker,
            // like "Export All Edited"); right-clicking a photo outside the
            // current selection, or when only one photo is selected, exports
            // just that one photo (Save panel) — see exportSinglePhoto's
            // comment for why the boundary is drawn there.
            if isMultiSelected && multiSelectedURLs.count > 1 {
                Button("Export \(multiSelectedURLs.count) Selected…") {
                    exportSelectedPhotos(Array(multiSelectedURLs))
                }
                // Sync's source is always whichever photo is open in the
                // editor (selectedURL), same as the panel's "Syncing"
                // button below — right-clicking a DIFFERENT thumbnail
                // within the same selection still syncs FROM the open
                // photo, not from the one under the cursor, so this reads
                // the same regardless of which selected thumbnail you
                // happen to right-click.
                Button("Syncing…") {
                    showSyncDialog = true
                }
            } else {
                Button("Export…") {
                    exportSinglePhoto(url)
                }
            }
        }
    }

    // Cmd toggles `url` in/out of the multi-select set without touching
    // which photo is open in the editor's main preview (matches Finder/
    // Photos: Cmd-click adds to a selection, it doesn't necessarily "view"
    // the newly-added item) — except we DO also open it here, since Develop
    // only has one preview pane and leaving it on some other photo while
    // the filmstrip shows a freshly-toggled selection would be confusing.
    // Shift selects the whole run between `selectionAnchor` (wherever the
    // last plain or Cmd click landed) and `url`, inclusive, replacing
    // whatever the multi-select set held before — same behavior as Finder
    // icon view and Photos' thumbnail grid. Unlike Cmd/plain click, Shift
    // deliberately does NOT call selectPhoto: the anchor (the first photo
    // you plain-clicked before shift-extending) stays open as the Sync
    // SOURCE the whole range is compared/copied FROM (see selectAllPhotos'
    // identical reasoning below). Jumping the open preview to whichever
    // photo happens to be under the shift-click — i.e. usually the LAST
    // one in the range — would silently swap the sync source out from
    // under the user mid-selection.
    private func handleFilmstripClick(_ url: URL) {
        let flags = NSEvent.modifierFlags

        if flags.contains(.command) {
            if multiSelectedURLs.contains(url) {
                multiSelectedURLs.remove(url)
            } else {
                multiSelectedURLs.insert(url)
            }
            selectionAnchor = url
            selectPhoto(url)
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor,
                  let anchorIndex = photoURLs.firstIndex(of: anchor),
                  let clickedIndex = photoURLs.firstIndex(of: url) {
            let range = anchorIndex < clickedIndex ? anchorIndex...clickedIndex : clickedIndex...anchorIndex
            multiSelectedURLs = Set(photoURLs[range])
        } else {
            multiSelectedURLs = [url]
            selectionAnchor = url
            selectPhoto(url)
        }
    }

    // Deliberately does NOT call selectPhoto or touch selectedURL —
    // "Select All" is for setting up a Sync/bulk-export TARGET SET while
    // still looking at whichever photo you were just editing (the sync
    // SOURCE); jumping the editor's view to some other photo (e.g. the
    // last one in the list, the way a Shift-click range-select would) the
    // moment you select everything would lose the very reference photo the
    // whole action is being taken from.
    private func selectAllPhotos() {
        multiSelectedURLs = Set(photoURLs)
    }

    private func deselectAllPhotos() {
        multiSelectedURLs = []
    }

    private func loadFilmstripThumbnail(for url: URL) {
        guard filmstripThumbnails[url] == nil else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let image = makeShowGridThumbnail(from: url, maxPixelSize: 240)

            DispatchQueue.main.async {
                if let image {
                    filmstripThumbnails[url] = image
                }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            if let selectedURL {
                Text(selectedURL.lastPathComponent)
                    .font(.custom("Figtree", size: 13).weight(.semibold))
                    .foregroundColor(AppColors.ink)
                    .lineLimit(1)

                if PhotoEditRenderer.isRAW(selectedURL) {
                    rawBadge
                }
            }

            Spacer()

            if let exportStatusText {
                Text(exportStatusText)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.muted)
            }

            beforeAfterButton

            Button("Done") {
                onClose()
            }
            .buttonStyle(ShowHeaderButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var rawBadge: some View {
        Text("RAW")
            .font(.custom("Figtree", size: 9).weight(.bold))
            .foregroundColor(AppColors.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.border, lineWidth: 1)
            )
    }

    // Press-and-hold (rather than a toggle) so comparing back to the
    // original is a quick glance, not an extra click to undo — the same
    // interaction Lightroom's own "\\" before/after key gives you, just on
    // a button since this has no keyboard shortcut plumbing yet.
    private var beforeAfterButton: some View {
        Text(showOriginal ? "Original" : "Before / After")
            .font(.custom("Figtree", size: 12).weight(.semibold))
            .foregroundColor(showOriginal ? AppColors.hoverInk : AppColors.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(showOriginal ? AppColors.panelAlt : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in showOriginal = true }
                    .onEnded { _ in showOriginal = false }
            )
    }

    // MARK: Center preview + crop overlay

    private var centerPreview: some View {
        GeometryReader { proxy in
            ZStack {
                AppColors.panelAlt.opacity(0.4)

                if let displayedImage {
                    let fitted = fittedImageFrame(imageSize: displayedImage.size, in: proxy.size)

                    // Clipped on its own rather than by clipping the whole
                    // ZStack: zoomed in, the picture has to stop at the edge
                    // of the preview, but the crop tool's corner handles sit
                    // right on the image edge and a container-level clip would
                    // shave them off.
                    Image(nsImage: displayedImage)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    // Drag to pan, but ONLY when zoomed in and no tool owns
                    // the canvas — every tool below claims the same drag, and
                    // a pan layer that outranked them would quietly break
                    // painting, cropping and mask dragging. At fit there is
                    // nothing to pan, so the layer is not there at all.
                    if zoomLevel > 1, !isCropping, !isRemoveBrushActive,
                       selectedAdjustmentIndex == nil, activeSelection == nil,
                       selectedLayerIndex == nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let start = panStart ?? panOffset
                                        panStart = start
                                        // Clamped here, not just where the frame
                                        // is placed: letting the stored offset run
                                        // past the edge would mean dragging back
                                        // does nothing until it unwinds the slack.
                                        let limitX = max((fitted.width - proxy.size.width) / 2, 0)
                                        let limitY = max((fitted.height - proxy.size.height) / 2, 0)
                                        panOffset = CGSize(
                                            width: min(max(start.width + value.translation.width, -limitX), limitX),
                                            height: min(max(start.height + value.translation.height, -limitY), limitY))
                                    }
                                    .onEnded { _ in panStart = nil }
                            )
                    }

                    if isCropping {
                        cropOverlay(frame: fitted, containerSize: proxy.size)
                    } else if isRemoveBrushActive {
                        removalPaintOverlay(frame: fullImageFrame(from: fitted))
                    } else if let index = selectedAdjustmentIndex {
                        localAdjustmentOverlay(settings.localAdjustments[index], frame: fullImageFrame(from: fitted))
                    } else if let activeSelection {
                        selectionOverlay(activeSelection, frame: fullImageFrame(from: fitted))
                    } else if let index = selectedLayerIndex {
                        layerOverlay(settings.layers[index], frame: fullImageFrame(from: fitted))
                    }

                    // What the Remove tool is about to erase, painted red
                    // over the photo. Drawn on the FULL (pre-crop) frame
                    // because that is the space the mask itself is in, and
                    // clipped to the preview area so a tight crop — whose
                    // full frame is far bigger than what's on screen —
                    // can't paint outside the picture.
                    if let removalOverlay {
                        let fullFrame = fullImageFrame(from: fitted)
                        ZStack {
                            Image(nsImage: removalOverlay)
                                .resizable()
                                .frame(width: fullFrame.width, height: fullFrame.height)
                                .position(x: fullFrame.midX, y: fullFrame.midY)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                    }
                } else if isLoadingPreview {
                    ProgressView()
                } else {
                    Text("Select a photo from the filmstrip")
                        .font(.custom("Figtree", size: 13))
                        .foregroundColor(AppColors.muted)
                }

                // "Exposure selected — ← / → to adjust", over the bottom of
                // the preview. Hit-testing off so it never steals a click
                // from the crop/mask/layer overlays it floats above, and it
                // slides up on the way in / fades on the way out (see
                // selectSlider for the timing).
                if let sliderToast {
                    VStack {
                        Spacer()
                        sliderToastCard(sliderToast)
                            .padding(.bottom, 18)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                    // Scale-from-the-bottom + fade rather than a slide up
                    // from off-screen: no clipping needed on the container
                    // (which would cut the crop tool's corner handles where
                    // they sit right on the image edge), and it still reads
                    // as the card "arriving" rather than blinking on.
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(24)
    }

    private func fittedImageFrame(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height) * zoomLevel
        let width = imageSize.width * scale
        let height = imageSize.height * scale

        // Panning only means anything along an axis the image overflows on;
        // along the other one it stays centred, so a zoomed-in portrait photo
        // cannot be dragged sideways into empty space.
        func placed(container: CGFloat, content: CGFloat, offset: CGFloat) -> CGFloat {
            let centred = (container - content) / 2
            guard content > container else { return centred }
            return min(max(centred + offset, container - content), 0)
        }

        return CGRect(
            x: placed(container: containerSize.width, content: width, offset: panOffset.width),
            y: placed(container: containerSize.height, content: height, offset: panOffset.height),
            width: width, height: height)
    }

    // Steps rather than a continuous gesture, because Cmd +/- is a keyboard
    // shortcut: 1.25x a press reaches 4x in six presses, which is about the
    // range that matters for checking an erase.
    private func stepZoom(_ direction: Double) {
        let next = min(max(zoomLevel * (direction > 0 ? 1.25 : 1 / 1.25), 1), 8)
        // Back at fit there is nothing to pan, and leaving a stale offset
        // behind would make the next zoom-in start off-centre for no reason.
        if next == 1 {
            panOffset = .zero
        } else if zoomLevel > 0 {
            // Keep whatever is in the middle of the view in the middle of it.
            let ratio = next / zoomLevel
            panOffset = CGSize(width: panOffset.width * ratio, height: panOffset.height * ratio)
        }
        zoomLevel = next
    }

    private func resetZoom() {
        zoomLevel = 1
        panOffset = .zero
    }

    // Mask/Selection/Layer geometry (unlike the crop rect itself) is
    // always defined in the FULL, PRE-crop image's unit space — render()
    // applies applyLocalAdjustments/compositeLayers BEFORE crop, so a
    // mask keeps its position/size if the crop is later changed or
    // removed, same as Lightroom's own local adjustments. But whenever a
    // crop IS set and the client isn't actively in the crop tool
    // (cropEnabled == true in that state, see renderNow), `displayedImage`
    // — and therefore `fitted`, the on-screen frame everything else
    // computes screen positions from — shows the CROPPED image, not the
    // full one. Passing `fitted` straight to a mask/selection/layer
    // overlay in that state was a real bug: the overlay would land
    // wherever that fraction maps to on the SMALLER cropped frame, not
    // where it actually renders in the full image the geometry describes
    // — visibly offset from the actual masked/pasted content
    // (reported as "square isn't precisely on it").
    //
    // This reconstructs the frame the FULL pre-crop image would occupy on
    // screen at the SAME scale `fitted` is already using, by inverting
    // `settings.crop`'s own x/y/width/height fractions — algebraically the
    // exact inverse of how render() turns a crop fraction into a pixel
    // rect. The result is typically BIGGER than `fitted` and extends
    // beyond it (partly off in centerPreview's own letterboxing margin) —
    // expected, since a mask positioned outside the current crop genuinely
    // isn't visible in the cropped photo either. Not used for the crop
    // overlay itself, which already gets a correct, uncropped `fitted`
    // for a different reason (cropEnabled is false while isCropping).
    private func fullImageFrame(from fitted: CGRect) -> CGRect {
        guard let crop = settings.crop, crop.width > 0, crop.height > 0 else {
            return fitted
        }
        let fullWidth = fitted.width / crop.width
        let fullHeight = fitted.height / crop.height
        let originX = fitted.minX - crop.x * fullWidth
        let originY = fitted.minY - crop.y * fullHeight
        return CGRect(x: originX, y: originY, width: fullWidth, height: fullHeight)
    }

    private enum CropHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func cropOverlay(frame: CGRect, containerSize: CGSize) -> some View {
        let rect = CGRect(
            x: frame.minX + pendingCrop.x * frame.width,
            y: frame.minY + pendingCrop.y * frame.height,
            width: pendingCrop.width * frame.width,
            height: pendingCrop.height * frame.height
        )

        return ZStack {
            // Even-odd fill of [full canvas, crop rect] darkens everything
            // outside the crop rect while leaving the rect itself clear.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: containerSize))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 1.0)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in moveCrop(by: value.translation, frame: frame) }
                        .onEnded { _ in dragStartCrop = nil }
                )

            ForEach(CropHandle.allCases, id: \.self) { handle in
                cropHandleView(handle, rect: rect, frame: frame)
            }
        }
    }

    private func cropHandleView(_ handle: CropHandle, rect: CGRect, frame: CGRect) -> some View {
        let position: CGPoint
        switch handle {
        case .topLeft: position = CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: position = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: position = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: position = CGPoint(x: rect.maxX, y: rect.maxY)
        }

        return Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(radius: 1)
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in resizeCrop(handle, by: value.translation, frame: frame) }
                    .onEnded { _ in dragStartCrop = nil }
            )
    }

    private func moveCrop(by translation: CGSize, frame: CGRect) {
        if dragStartCrop == nil {
            dragStartCrop = pendingCrop
        }
        guard let start = dragStartCrop, frame.width > 0, frame.height > 0 else {
            return
        }

        let dx = translation.width / frame.width
        let dy = translation.height / frame.height

        var next = start
        next.x = min(max(0, start.x + dx), 1 - start.width)
        next.y = min(max(0, start.y + dy), 1 - start.height)
        pendingCrop = next
    }

    // The image's own pixel width/height ratio (post-rotation) — needed to
    // convert a target width:height ratio (e.g. 4:3) into the right
    // width/height FRACTIONS for EditCropRect, since fraction space isn't
    // the same shape as pixel space unless the image itself is square.
    private var currentImagePixelRatio: Double? {
        guard let base = previewBaseImage else {
            return nil
        }
        var width = base.extent.width
        var height = base.extent.height
        if settings.rotationQuarterTurns % 2 != 0 {
            swap(&width, &height)
        }
        guard width > 0, height > 0 else {
            return nil
        }
        return Double(width / height)
    }

    // Corner-handle resize. When selectedCropAspectRatio is locked (not
    // .free), the dragged corner's OPPOSITE corner stays anchored in place
    // and width/height are reconciled to hold that exact ratio — dragging
    // a handle in shrinks/grows the crop without ever snapping back to
    // Free (previously every manual resize reset the ratio row to Free;
    // now only a NEW aspect-ratio button tap or Reset Crop does). Free-form
    // (.free) behaves exactly as before this ratio-lock support existed —
    // verified via a standalone regression script against the original
    // per-handle code before wiring this in.
    private func resizeCrop(_ handle: CropHandle, by translation: CGSize, frame: CGRect) {
        if dragStartCrop == nil {
            dragStartCrop = pendingCrop
        }
        guard let start = dragStartCrop, frame.width > 0, frame.height > 0 else {
            return
        }

        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        let minSize = 0.05

        // The corner that stays fixed while the dragged one moves.
        let anchorX: Double
        let anchorY: Double
        switch handle {
        case .topLeft: anchorX = start.x + start.width; anchorY = start.y + start.height
        case .topRight: anchorX = start.x; anchorY = start.y + start.height
        case .bottomLeft: anchorX = start.x + start.width; anchorY = start.y
        case .bottomRight: anchorX = start.x; anchorY = start.y
        }

        // Raw, independent-axis proposed size — same math the old
        // free-form-only code used, just factored out so the ratio-lock
        // branch below can reconcile it before the final bounds clamp.
        var rawWidth: Double
        var rawHeight: Double
        switch handle {
        case .topLeft: rawWidth = start.width - dx; rawHeight = start.height - dy
        case .topRight: rawWidth = start.width + dx; rawHeight = start.height - dy
        case .bottomLeft: rawWidth = start.width - dx; rawHeight = start.height + dy
        case .bottomRight: rawWidth = start.width + dx; rawHeight = start.height + dy
        }
        rawWidth = max(rawWidth, minSize)
        rawHeight = max(rawHeight, minSize)

        let maxWidthAllowed: Double
        switch handle {
        case .topLeft, .bottomLeft: maxWidthAllowed = anchorX
        case .topRight, .bottomRight: maxWidthAllowed = 1 - anchorX
        }
        let maxHeightAllowed: Double
        switch handle {
        case .topLeft, .topRight: maxHeightAllowed = anchorY
        case .bottomLeft, .bottomRight: maxHeightAllowed = 1 - anchorY
        }

        var finalWidth: Double
        var finalHeight: Double

        if let ratio = selectedCropAspectRatio.ratio, let imagePixelRatio = currentImagePixelRatio, imagePixelRatio > 0 {
            // Target ratio expressed in fraction space.
            let k = ratio / imagePixelRatio
            let widthFromWidth = rawWidth
            let heightFromWidth = rawWidth / k
            let widthFromHeight = rawHeight * k
            let heightFromHeight = rawHeight

            // Whichever axis the drag moved further (in the resulting
            // implied box) wins — the box grows to cover the larger of
            // the two, matching how Shift-drag corner resize normally
            // feels in other editors.
            var w: Double
            var h: Double
            if widthFromWidth >= widthFromHeight {
                w = widthFromWidth
                h = heightFromWidth
            } else {
                w = widthFromHeight
                h = heightFromHeight
            }

            // Scale both dimensions down together (never just one) so the
            // ratio still holds exactly even after clamping to the image
            // bounds at the anchor.
            let scale = min(1, maxWidthAllowed / max(w, 0.0001), maxHeightAllowed / max(h, 0.0001))
            finalWidth = max(w * scale, minSize)
            finalHeight = max(h * scale, minSize)
        } else {
            finalWidth = max(min(rawWidth, maxWidthAllowed), minSize)
            finalHeight = max(min(rawHeight, maxHeightAllowed), minSize)
        }

        var next = EditCropRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
        switch handle {
        case .topLeft: next.x = anchorX - finalWidth; next.y = anchorY - finalHeight
        case .topRight: next.x = anchorX; next.y = anchorY - finalHeight
        case .bottomLeft: next.x = anchorX - finalWidth; next.y = anchorY
        case .bottomRight: next.x = anchorX; next.y = anchorY
        }
        pendingCrop = next
    }

    // MARK: Mask overlays (local adjustments)

    @ViewBuilder
    private func localAdjustmentOverlay(_ adjustment: LocalAdjustment, frame: CGRect) -> some View {
        switch adjustment.type {
        case .radial:
            if let geo = adjustment.radial {
                radialOverlay(geo, frame: frame)
            }
        case .graduated:
            if let geo = adjustment.graduated {
                graduatedOverlay(geo, frame: frame)
            }
        case .brush:
            brushPaintOverlay(adjustment.brush, frame: frame)
        case .patch:
            if let geo = adjustment.patch {
                patchOverlay(geo, frame: frame)
            }
        }
    }

    // Move handle (accent-filled, at the center) plus two white radius
    // handles — one purely horizontal, one purely vertical — so each drag
    // resizes only that one axis around the fixed center, rather than a
    // crop-style corner drag that would couple both axes together. Simpler
    // to reason about for an ellipse, where there's no natural "corner".
    private func radialOverlay(_ geo: RadialMaskGeometry, frame: CGRect) -> some View {
        let center = CGPoint(x: frame.minX + geo.centerX * frame.width, y: frame.minY + geo.centerY * frame.height)
        let rx = geo.radiusX * frame.width
        let ry = geo.radiusY * frame.height

        return ZStack {
            Ellipse()
                .stroke(accentColor, lineWidth: 1.0)
                .frame(width: rx * 2, height: ry * 2)
                .position(center)
                .allowsHitTesting(false)

            Circle()
                .fill(accentColor)
                .frame(width: 11, height: 11)
                .shadow(radius: 1)
                .position(center)
                .gesture(
                    DragGesture()
                        .onChanged { value in moveRadialCenter(by: value.translation, frame: frame) }
                        .onEnded { _ in radialDragStart = nil }
                )

            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(radius: 1)
                .position(x: center.x + rx, y: center.y)
                .gesture(
                    DragGesture()
                        .onChanged { value in resizeRadiusX(by: value.translation, frame: frame) }
                        .onEnded { _ in radialDragStart = nil }
                )

            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(radius: 1)
                .position(x: center.x, y: center.y + ry)
                .gesture(
                    DragGesture()
                        .onChanged { value in resizeRadiusY(by: value.translation, frame: frame) }
                        .onEnded { _ in radialDragStart = nil }
                )
        }
    }

    private func moveRadialCenter(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if radialDragStart == nil {
            radialDragStart = settings.localAdjustments[index].radial
        }
        guard let start = radialDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        var geo = start
        geo.centerX = min(max(start.centerX + translation.width / frame.width, 0), 1)
        geo.centerY = min(max(start.centerY + translation.height / frame.height, 0), 1)
        settings.localAdjustments[index].radial = geo
    }

    private func resizeRadiusX(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if radialDragStart == nil {
            radialDragStart = settings.localAdjustments[index].radial
        }
        guard let start = radialDragStart, frame.width > 0 else {
            return
        }
        var geo = start
        geo.radiusX = min(max(start.radiusX + translation.width / frame.width, 0.02), 1)
        settings.localAdjustments[index].radial = geo
    }

    private func resizeRadiusY(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if radialDragStart == nil {
            radialDragStart = settings.localAdjustments[index].radial
        }
        guard let start = radialDragStart, frame.height > 0 else {
            return
        }
        var geo = start
        geo.radiusY = min(max(start.radiusY + translation.height / frame.height, 0.02), 1)
        settings.localAdjustments[index].radial = geo
    }

    // Accent-filled handle at the start point (full effect), white handle
    // at the end point (no effect), connected by a dashed line — dragging
    // either end moves just that point, same "drag start from a captured
    // baseline" pattern as the crop/radial handles above.
    private func graduatedOverlay(_ geo: GraduatedMaskGeometry, frame: CGRect) -> some View {
        let start = CGPoint(x: frame.minX + geo.startX * frame.width, y: frame.minY + geo.startY * frame.height)
        let end = CGPoint(x: frame.minX + geo.endX * frame.width, y: frame.minY + geo.endY * frame.height)

        return ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(accentColor, style: StrokeStyle(lineWidth: 1.0, dash: [5, 4]))
            .allowsHitTesting(false)

            Circle()
                .fill(accentColor)
                .frame(width: 12, height: 12)
                .shadow(radius: 1)
                .position(start)
                .gesture(
                    DragGesture()
                        .onChanged { value in moveGraduatedStart(by: value.translation, frame: frame) }
                        .onEnded { _ in graduatedDragStart = nil }
                )

            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .shadow(radius: 1)
                .position(end)
                .gesture(
                    DragGesture()
                        .onChanged { value in moveGraduatedEnd(by: value.translation, frame: frame) }
                        .onEnded { _ in graduatedDragStart = nil }
                )
        }
    }

    private func moveGraduatedStart(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if graduatedDragStart == nil {
            graduatedDragStart = settings.localAdjustments[index].graduated
        }
        guard let start = graduatedDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        var geo = start
        geo.startX = min(max(start.startX + translation.width / frame.width, 0), 1)
        geo.startY = min(max(start.startY + translation.height / frame.height, 0), 1)
        settings.localAdjustments[index].graduated = geo
    }

    private func moveGraduatedEnd(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if graduatedDragStart == nil {
            graduatedDragStart = settings.localAdjustments[index].graduated
        }
        guard let start = graduatedDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        var geo = start
        geo.endX = min(max(start.endX + translation.width / frame.width, 0), 1)
        geo.endY = min(max(start.endY + translation.height / frame.height, 0), 1)
        settings.localAdjustments[index].graduated = geo
    }

    // Dispatches a Patch mask's on-canvas overlay by shape/draw-state: a
    // Free shape with no outline drawn yet shows the drawing surface
    // instead of handles (nothing to grab a handle ON before it exists).
    // Circle is the clone-stamp BRUSH (patchBrushOverlay) — .square is kept
    // only so old saved data still has SOMETHING to render (patchShapeOverlay),
    // it's no longer reachable from the UI.
    @ViewBuilder
    private func patchOverlay(_ geo: PatchGeometry, frame: CGRect) -> some View {
        switch geo.shape {
        case .circle:
            patchBrushOverlay(geo, frame: frame)
        case .square:
            patchShapeOverlay(geo, frame: frame)
        case .free:
            if geo.points.isEmpty {
                patchFreeDrawOverlay(frame: frame)
            } else {
                patchFreeShapeOverlay(geo, frame: frame)
            }
        }
    }

    // The clone-stamp BRUSH overlay for a Circle-mode patch — paints
    // continuously as the user drags, exactly like Photoshop/Lightroom's
    // own clone stamp (see PatchGeometry's doc comment and
    // paintPatchStroke/commitPatchStroke for the gesture logic).
    //
    // Deliberately shows NOTHING persistent for already-committed strokes
    // (unlike brushPaintOverlay's brushMaskCanvas, which stays visible on
    // purpose — a Brush mask's tonal effect is otherwise invisible, so it
    // NEEDS a permanent coverage indicator). A Patch's effect is the
    // cloned pixels themselves, already visible in the real rendered
    // image — an earlier version of this overlay also painted a
    // translucent accentColor tint over every committed stroke "for
    // visibility", which back-fired badly: sampling from a similarly-toned
    // nearby area (the common case) makes the real clone subtle, so the
    // filled tint circles were the ONLY thing visibly showing, reading as
    // stuck yellow stickers doing nothing rather than an edit (reported
    // directly against a real screenshot, 15. avgust 2026 evening). Real
    // Photoshop shows no such overlay after painting either. Layered:
    // a live vector preview of the IN-PROGRESS stroke, then source/size
    // cursor previews, then the transparent hit area last so its
    // gesture/hover modifiers stay on top.
    private func patchBrushOverlay(_ geo: PatchGeometry, frame: CGRect) -> some View {
        let brushDiameter = max(patchBrushSize * max(frame.width, frame.height), 2)

        return ZStack {
            if activePatchStrokePoints.count > 1 {
                Path { path in
                    let scaled = activePatchStrokePoints.map {
                        CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
                    }
                    path.move(to: scaled[0])
                    for point in scaled.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(accentColor.opacity(0.8), style: StrokeStyle(lineWidth: brushDiameter, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }

            // While actively painting, a second yellow "twin cursor" tracks
            // where content is being sampled FROM (last painted point plus
            // this stroke's fixed offset) — the same live feedback a real
            // clone stamp gives, so the user sees what's about to land
            // before it does.
            if let last = activePatchStrokePoints.last, let offset = patchStrokeOffset {
                let sourcePoint = CGPoint(
                    x: frame.minX + (last.x + offset.width) * frame.width,
                    y: frame.minY + (last.y + offset.height) * frame.height
                )
                Image(systemName: "viewfinder")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.yellow)
                    .shadow(radius: 1)
                    .position(sourcePoint)
                    .allowsHitTesting(false)
            }

            // "Source will land here if you ⌥-click now" preview — only
            // while ⌥ is held and nothing's mid-paint, same reasoning as
            // the legacy patchCanvasClickArea's identical preview below.
            if let patchSourceHoverLocation, activePatchStrokePoints.isEmpty {
                Image(systemName: "viewfinder")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.yellow.opacity(0.7))
                    .shadow(radius: 1)
                    .position(patchSourceHoverLocation)
                    .allowsHitTesting(false)
            }

            // Cursor-size ring — shows the brush diameter before painting.
            // Hidden the instant ⌥ is held (the source-preview ring above
            // takes over) or a stroke is actively in progress (the stroke
            // itself already shows the true width). Mirrors
            // brushPaintOverlay's identical ring.
            if let patchBrushHoverLocation, patchSourceHoverLocation == nil, activePatchStrokePoints.isEmpty {
                Circle()
                    .stroke(accentColor.opacity(0.9), lineWidth: 1.5)
                    .frame(width: brushDiameter, height: brushDiameter)
                    .position(patchBrushHoverLocation)
                    .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if NSEvent.modifierFlags.contains(.option) {
                            patchSourceHoverLocation = location
                            patchBrushHoverLocation = nil
                        } else {
                            patchBrushHoverLocation = location
                            patchSourceHoverLocation = nil
                        }
                    case .ended:
                        patchSourceHoverLocation = nil
                        patchBrushHoverLocation = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Nothing painted yet in THIS gesture and ⌥ is
                            // held: this drag is setting the source, not
                            // painting — just track the preview ring,
                            // don't touch activePatchStrokePoints. Once a
                            // point HAS been recorded, ⌥ being pressed
                            // transiently mid-stroke can never flip modes
                            // (a real clone stamp never reinterprets an
                            // in-progress stroke either).
                            if activePatchStrokePoints.isEmpty && NSEvent.modifierFlags.contains(.option) {
                                patchSourceHoverLocation = value.location
                                return
                            }
                            paintPatchStroke(at: value.location, frame: frame)
                        }
                        .onEnded { value in
                            if activePatchStrokePoints.isEmpty {
                                if NSEvent.modifierFlags.contains(.option), let unit = unitPoint(from: value.location, frame: frame) {
                                    pendingPatchSource = unit
                                }
                                patchSourceHoverLocation = nil
                            } else {
                                commitPatchStroke()
                            }
                        }
                )
        }
    }

    // Circle/Square share this overlay — same center+radiusX/radiusY
    // geometry, same move+2-axis-resize handle scheme as radialOverlay,
    // differing only in which shape gets stroked (Ellipse vs Rectangle).
    // Also draws the source marker (a draggable "viewfinder" glyph, styled
    // distinctly in yellow rather than the accent color so it never reads
    // as just another resize handle), a dashed line connecting destination
    // to source, and a dashed MIRROR of the destination outline at the
    // source location — purely a visual reference so the user can see
    // exactly what region will be sampled, not interactive itself.
    // (Circle no longer reaches here from the UI — see patchBrushOverlay —
    // this stays only so old saved Square/Circle data still renders.)
    private func patchShapeOverlay(_ geo: PatchGeometry, frame: CGRect) -> some View {
        let center = CGPoint(x: frame.minX + geo.centerX * frame.width, y: frame.minY + geo.centerY * frame.height)
        let rx = geo.radiusX * frame.width
        let ry = geo.radiusY * frame.height
        let sourceCenter = CGPoint(x: center.x + geo.sourceOffsetX * frame.width, y: center.y + geo.sourceOffsetY * frame.height)

        return ZStack {
            patchCanvasClickArea(frame: frame)

            Path { path in
                path.move(to: center)
                path.addLine(to: sourceCenter)
            }
            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
            .allowsHitTesting(false)

            patchShapeStroke(geo.shape, color: Color.yellow.opacity(0.7), lineWidth: 0.8, dash: [3, 3])
                .frame(width: rx * 2, height: ry * 2)
                .position(sourceCenter)
                .allowsHitTesting(false)

            patchShapeStroke(geo.shape, color: accentColor, lineWidth: 1.0, dash: [])
                .frame(width: rx * 2, height: ry * 2)
                .position(center)
                .allowsHitTesting(false)

            Circle()
                .fill(accentColor)
                .frame(width: 11, height: 11)
                .shadow(radius: 1)
                .position(center)
                .gesture(
                    DragGesture()
                        .onChanged { value in movePatchCenter(by: value.translation, frame: frame) }
                        .onEnded { _ in patchDragStart = nil }
                )

            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(radius: 1)
                .position(x: center.x + rx, y: center.y)
                .gesture(
                    DragGesture()
                        .onChanged { value in resizePatchRadiusX(by: value.translation, frame: frame) }
                        .onEnded { _ in patchDragStart = nil }
                )

            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(radius: 1)
                .position(x: center.x, y: center.y + ry)
                .gesture(
                    DragGesture()
                        .onChanged { value in resizePatchRadiusY(by: value.translation, frame: frame) }
                        .onEnded { _ in patchDragStart = nil }
                )

            Image(systemName: "viewfinder")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.yellow)
                .shadow(radius: 1)
                .position(sourceCenter)
                .gesture(
                    DragGesture()
                        .onChanged { value in movePatchSource(by: value.translation, frame: frame) }
                        .onEnded { _ in patchDragStart = nil }
                )
        }
    }

    @ViewBuilder
    private func patchShapeStroke(_ shape: PatchShape, color: Color, lineWidth: CGFloat, dash: [CGFloat]) -> some View {
        if shape == .circle {
            Ellipse().stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: dash))
        } else {
            Rectangle().stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: dash))
        }
    }

    // A transparent, full-canvas layer shared by patchShapeOverlay and
    // patchFreeShapeOverlay — placed FIRST in their ZStacks (so it sits
    // BEHIND the move/resize/source handles, which still get hit-test
    // priority for their own small areas) so clicking anywhere else on the
    // photo acts on the patch directly: real clone-stamp UX, same gesture
    // Photoshop/Lightroom's own Healing/Clone tools use. NSEvent.modifierFlags
    // (not a SwiftUI modifier-key API — macOS 13's SDK has none) is read
    // synchronously both on hover (to preview) and at tap time (to decide
    // what the tap means), so no separate event-monitor bookkeeping is
    // needed for ⌥'s current state.
    private func patchCanvasClickArea(frame: CGRect) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        patchSourceHoverLocation = NSEvent.modifierFlags.contains(.option) ? location : nil
                    case .ended:
                        patchSourceHoverLocation = nil
                    }
                }
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handlePatchCanvasTap(at: value.location, frame: frame)
                        }
                )

            // "Source will land here if you click now" preview — only
            // shown while ⌥ is actually held (patchSourceHoverLocation is
            // nil otherwise), a cheap ring rather than a live pixel
            // preview of the source content itself (which would mean
            // re-rendering a cropped thumbnail on every hover event —
            // too much for interactive hover, same tradeoff the brush
            // cursor preview already made).
            if let patchSourceHoverLocation {
                Image(systemName: "viewfinder")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.yellow.opacity(0.7))
                    .shadow(radius: 1)
                    .position(patchSourceHoverLocation)
                    .allowsHitTesting(false)
            }
        }
    }

    // ⌥-click sets the SOURCE under the cursor (keeping the destination
    // exactly where it is) — expressed as this patch's existing
    // sourceOffsetX/Y (a vector from destination to source), the same
    // value dragging the yellow marker already writes to, just reached by
    // a single click instead of a drag. A plain click instead moves the
    // DESTINATION under the cursor and patches there — the source comes
    // along for free since sourceOffset is relative (same math
    // movePatchCenter/movePatchFreeShape use for a drag).
    private func handlePatchCanvasTap(at location: CGPoint, frame: CGRect) {
        guard let index = selectedAdjustmentIndex, let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        guard var geo = settings.localAdjustments[index].patch else {
            return
        }

        if NSEvent.modifierFlags.contains(.option) {
            geo.sourceOffsetX = unit.x - geo.centerX
            geo.sourceOffsetY = unit.y - geo.centerY
        } else if geo.shape == .free {
            // Unclamped, same reasoning as movePatchFreeShape — points and
            // centerX/Y must move by the identical delta or they'd desync,
            // since freeMask draws directly from `points`, not the center.
            let dx = unit.x - geo.centerX
            let dy = unit.y - geo.centerY
            geo.centerX += dx
            geo.centerY += dy
            geo.points = geo.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        } else {
            geo.centerX = min(max(unit.x, 0), 1)
            geo.centerY = min(max(unit.y, 0), 1)
        }

        settings.localAdjustments[index].patch = geo
        patchDragStart = nil
    }

    private func movePatchCenter(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if patchDragStart == nil {
            patchDragStart = settings.localAdjustments[index].patch
        }
        guard let start = patchDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        var geo = start
        geo.centerX = min(max(start.centerX + translation.width / frame.width, 0), 1)
        geo.centerY = min(max(start.centerY + translation.height / frame.height, 0), 1)
        settings.localAdjustments[index].patch = geo
    }

    private func resizePatchRadiusX(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if patchDragStart == nil {
            patchDragStart = settings.localAdjustments[index].patch
        }
        guard let start = patchDragStart, frame.width > 0 else {
            return
        }
        var geo = start
        geo.radiusX = min(max(start.radiusX + translation.width / frame.width, 0.02), 1)
        settings.localAdjustments[index].patch = geo
    }

    private func resizePatchRadiusY(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if patchDragStart == nil {
            patchDragStart = settings.localAdjustments[index].patch
        }
        guard let start = patchDragStart, frame.height > 0 else {
            return
        }
        var geo = start
        geo.radiusY = min(max(start.radiusY + translation.height / frame.height, 0.02), 1)
        settings.localAdjustments[index].patch = geo
    }

    // No clamping to 0...1 here, unlike centerX/Y above — the source point
    // is just "wherever the user is currently sampling from" and there's no
    // reason it can't sit near an edge or even slightly off it; it isn't
    // where anything gets DRAWN the way the destination outline is.
    private func movePatchSource(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if patchDragStart == nil {
            patchDragStart = settings.localAdjustments[index].patch
        }
        guard let start = patchDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        var geo = start
        geo.sourceOffsetX = start.sourceOffsetX + translation.width / frame.width
        geo.sourceOffsetY = start.sourceOffsetY + translation.height / frame.height
        settings.localAdjustments[index].patch = geo
    }

    // A Free-shape patch that already has a drawn outline: same move-handle
    // + source-marker scheme as patchShapeOverlay, but the move handle
    // shifts every polygon point together with centerX/Y (kept in sync as
    // the shape's centroid) rather than adjusting a radius, since a
    // freehand polygon has no "radius" to speak of.
    private func patchFreeShapeOverlay(_ geo: PatchGeometry, frame: CGRect) -> some View {
        let scaledPoints = geo.points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
        let center = CGPoint(x: frame.minX + geo.centerX * frame.width, y: frame.minY + geo.centerY * frame.height)
        let sourceOffset = CGSize(width: geo.sourceOffsetX * frame.width, height: geo.sourceOffsetY * frame.height)
        let sourceCenter = CGPoint(x: center.x + sourceOffset.width, y: center.y + sourceOffset.height)
        let sourcePoints = scaledPoints.map { CGPoint(x: $0.x + sourceOffset.width, y: $0.y + sourceOffset.height) }

        return ZStack {
            patchCanvasClickArea(frame: frame)

            Path { path in
                path.move(to: center)
                path.addLine(to: sourceCenter)
            }
            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
            .allowsHitTesting(false)

            closedPolygonPath(sourcePoints)
                .stroke(Color.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .allowsHitTesting(false)

            closedPolygonPath(scaledPoints)
                .stroke(accentColor, lineWidth: 1.0)
                .allowsHitTesting(false)

            Circle()
                .fill(accentColor)
                .frame(width: 11, height: 11)
                .shadow(radius: 1)
                .position(center)
                .gesture(
                    DragGesture()
                        .onChanged { value in movePatchFreeShape(by: value.translation, frame: frame) }
                        .onEnded { _ in patchDragStart = nil }
                )

            Image(systemName: "viewfinder")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.yellow)
                .shadow(radius: 1)
                .position(sourceCenter)
                .gesture(
                    DragGesture()
                        .onChanged { value in movePatchSource(by: value.translation, frame: frame) }
                        .onEnded { _ in patchDragStart = nil }
                )
        }
    }

    private func closedPolygonPath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else {
                return
            }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
    }

    // Shifts every drawn point AND centerX/Y by the same delta, unclamped
    // (matching movePatchSource's reasoning) — clamping centerX/Y alone
    // while leaving points unclamped would desync the two, since the
    // points array is what maskImage/freeMask actually draws from and
    // centerX/Y is only a derived handle-position/source-anchor
    // convenience, not source-of-truth geometry.
    private func movePatchFreeShape(by translation: CGSize, frame: CGRect) {
        guard let index = selectedAdjustmentIndex else {
            return
        }
        if patchDragStart == nil {
            patchDragStart = settings.localAdjustments[index].patch
        }
        guard let start = patchDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        var geo = start
        geo.centerX = start.centerX + dx
        geo.centerY = start.centerY + dy
        geo.points = start.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        settings.localAdjustments[index].patch = geo
    }

    // A transparent, full-frame hit area for drawing a Free-shape patch's
    // outline — same cheap-vector-preview-until-mouse-up pattern as
    // brushPaintOverlay (see its own doc comment for why), closing the path
    // back to its start point so the in-progress preview already reads as
    // the closed outline it will become on commit.
    private func patchFreeDrawOverlay(frame: CGRect) -> some View {
        ZStack {
            if activePatchDrawPoints.count > 1 {
                closedPolygonPath(activePatchDrawPoints.map {
                    CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
                })
                .stroke(accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.0, dash: [5, 3]))
                .allowsHitTesting(false)
            } else {
                Text("Drag to draw the patch outline")
                    .font(.custom("Figtree", size: 11).weight(.medium))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in paintPatchOutline(at: value.location, frame: frame) }
                        .onEnded { _ in commitPatchOutline() }
                )
        }
    }

    private func paintPatchOutline(at location: CGPoint, frame: CGRect) {
        guard let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        if let last = activePatchDrawPoints.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activePatchDrawPoints.append(unit)
    }

    // Requires at least 3 points (a real polygon, not a line/dot) to commit
    // — mirrors commitBrushStroke's `count > 1` guard, just a higher bar
    // since a 2-point "outline" wouldn't enclose any area for freeMask to
    // fill. The outline's own centroid becomes centerX/Y, so the move
    // handle and source marker both start from somewhere sensible on the
    // shape the user actually drew, not the (0.5, 0.5) default.
    private func commitPatchOutline() {
        defer { activePatchDrawPoints = [] }
        guard let index = selectedAdjustmentIndex, activePatchDrawPoints.count > 2 else {
            return
        }
        let count = Double(activePatchDrawPoints.count)
        let centroidX = activePatchDrawPoints.reduce(0) { $0 + $1.x } / count
        let centroidY = activePatchDrawPoints.reduce(0) { $0 + $1.y } / count
        settings.localAdjustments[index].patch?.points = activePatchDrawPoints
        settings.localAdjustments[index].patch?.centerX = centroidX
        settings.localAdjustments[index].patch?.centerY = centroidY
    }

    // MARK: Selection tool overlay (Cut/Copy/Deselect)

    // Same shape/dispatch structure as patchOverlay, minus everything
    // source-related (no marker, no dashed mirror, no drag-start snapshot
    // needed beyond `selectionDragStart`) — a plain selection only ever
    // has ONE outline to show.
    @ViewBuilder
    private func selectionOverlay(_ selection: SelectionGeometry, frame: CGRect) -> some View {
        switch selection.shape {
        case .circle, .square:
            selectionShapeOverlay(selection, frame: frame)
        case .free:
            if selection.points.isEmpty {
                selectionFreeDrawOverlay(frame: frame)
            } else {
                selectionFreeShapeOverlay(selection, frame: frame)
            }
        }
    }

    private func selectionShapeOverlay(_ selection: SelectionGeometry, frame: CGRect) -> some View {
        let center = CGPoint(x: frame.minX + selection.centerX * frame.width, y: frame.minY + selection.centerY * frame.height)
        let rx = selection.radiusX * frame.width
        let ry = selection.radiusY * frame.height

        return ZStack {
            patchShapeStroke(selection.shape, color: accentColor, lineWidth: 1.0, dash: [5, 3])
                .frame(width: rx * 2, height: ry * 2)
                .position(center)
                .allowsHitTesting(false)

            Circle()
                .fill(accentColor)
                .frame(width: 11, height: 11)
                .shadow(radius: 1)
                .position(center)
                .gesture(
                    DragGesture()
                        .onChanged { value in moveSelectionCenter(by: value.translation, frame: frame) }
                        .onEnded { _ in selectionDragStart = nil }
                )

            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(radius: 1)
                .position(x: center.x + rx, y: center.y)
                .gesture(
                    DragGesture()
                        .onChanged { value in resizeSelectionRadiusX(by: value.translation, frame: frame) }
                        .onEnded { _ in selectionDragStart = nil }
                )

            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(radius: 1)
                .position(x: center.x, y: center.y + ry)
                .gesture(
                    DragGesture()
                        .onChanged { value in resizeSelectionRadiusY(by: value.translation, frame: frame) }
                        .onEnded { _ in selectionDragStart = nil }
                )
        }
    }

    private func moveSelectionCenter(by translation: CGSize, frame: CGRect) {
        if selectionDragStart == nil {
            selectionDragStart = activeSelection
        }
        guard let start = selectionDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        var geo = start
        geo.centerX = min(max(start.centerX + translation.width / frame.width, 0), 1)
        geo.centerY = min(max(start.centerY + translation.height / frame.height, 0), 1)
        activeSelection = geo
    }

    private func resizeSelectionRadiusX(by translation: CGSize, frame: CGRect) {
        if selectionDragStart == nil {
            selectionDragStart = activeSelection
        }
        guard let start = selectionDragStart, frame.width > 0 else {
            return
        }
        var geo = start
        geo.radiusX = min(max(start.radiusX + translation.width / frame.width, 0.02), 1)
        activeSelection = geo
    }

    private func resizeSelectionRadiusY(by translation: CGSize, frame: CGRect) {
        if selectionDragStart == nil {
            selectionDragStart = activeSelection
        }
        guard let start = selectionDragStart, frame.height > 0 else {
            return
        }
        var geo = start
        geo.radiusY = min(max(start.radiusY + translation.height / frame.height, 0.02), 1)
        activeSelection = geo
    }

    private func selectionFreeShapeOverlay(_ selection: SelectionGeometry, frame: CGRect) -> some View {
        let scaledPoints = selection.points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
        let center = CGPoint(x: frame.minX + selection.centerX * frame.width, y: frame.minY + selection.centerY * frame.height)

        return ZStack {
            closedPolygonPath(scaledPoints)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 1.0, dash: [5, 3]))
                .allowsHitTesting(false)

            Circle()
                .fill(accentColor)
                .frame(width: 11, height: 11)
                .shadow(radius: 1)
                .position(center)
                .gesture(
                    DragGesture()
                        .onChanged { value in moveSelectionFreeShape(by: value.translation, frame: frame) }
                        .onEnded { _ in selectionDragStart = nil }
                )
        }
    }

    private func moveSelectionFreeShape(by translation: CGSize, frame: CGRect) {
        if selectionDragStart == nil {
            selectionDragStart = activeSelection
        }
        guard let start = selectionDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        var geo = start
        geo.centerX = start.centerX + dx
        geo.centerY = start.centerY + dy
        geo.points = start.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        activeSelection = geo
    }

    // Same cheap-vector-preview-until-mouse-up drawing surface as
    // patchFreeDrawOverlay.
    private func selectionFreeDrawOverlay(frame: CGRect) -> some View {
        ZStack {
            if activeSelectionDrawPoints.count > 1 {
                closedPolygonPath(activeSelectionDrawPoints.map {
                    CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
                })
                .stroke(accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.0, dash: [5, 3]))
                .allowsHitTesting(false)
            } else {
                Text("Drag to draw the selection outline")
                    .font(.custom("Figtree", size: 11).weight(.medium))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in paintSelectionOutline(at: value.location, frame: frame) }
                        .onEnded { _ in commitSelectionOutline() }
                )
        }
    }

    private func paintSelectionOutline(at location: CGPoint, frame: CGRect) {
        guard let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        if let last = activeSelectionDrawPoints.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activeSelectionDrawPoints.append(unit)
    }

    private func commitSelectionOutline() {
        defer { activeSelectionDrawPoints = [] }
        guard activeSelectionDrawPoints.count > 2 else {
            return
        }
        let count = Double(activeSelectionDrawPoints.count)
        let centroidX = activeSelectionDrawPoints.reduce(0) { $0 + $1.x } / count
        let centroidY = activeSelectionDrawPoints.reduce(0) { $0 + $1.y } / count
        activeSelection?.points = activeSelectionDrawPoints
        activeSelection?.centerX = centroidX
        activeSelection?.centerY = centroidY
    }

    // MARK: Layer overlay (move/resize)

    private enum LayerCorner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    // Move-by-dragging-the-body plus 4 independent-axis corner handles
    // (each anchors the OPPOSITE corner, same reasoning as the crop tool's
    // own corner handles) — no aspect-ratio lock, unlike crop's optional
    // one, since a pasted layer has no equivalent "aspect ratio buttons" UI
    // to lock to; keeping it simple for v1.
    private func layerOverlay(_ layer: ImageLayer, frame: CGRect) -> some View {
        let rect = CGRect(
            x: frame.minX + layer.x * frame.width,
            y: frame.minY + layer.y * frame.height,
            width: layer.width * frame.width,
            height: layer.height * frame.height
        )

        return ZStack {
            Rectangle()
                .stroke(accentColor, lineWidth: 1.0)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in moveLayer(by: value.translation, frame: frame) }
                        .onEnded { _ in layerDragStart = nil }
                )

            ForEach(LayerCorner.allCases, id: \.self) { corner in
                layerHandleView(corner, rect: rect, frame: frame)
            }
        }
    }

    private func layerHandleView(_ corner: LayerCorner, rect: CGRect, frame: CGRect) -> some View {
        let position: CGPoint
        switch corner {
        case .topLeft: position = CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: position = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: position = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: position = CGPoint(x: rect.maxX, y: rect.maxY)
        }

        return Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(radius: 1)
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in resizeLayer(corner, by: value.translation, frame: frame) }
                    .onEnded { _ in layerDragStart = nil }
            )
    }

    private func moveLayer(by translation: CGSize, frame: CGRect) {
        guard let index = selectedLayerIndex else {
            return
        }
        if layerDragStart == nil {
            layerDragStart = settings.layers[index]
        }
        guard let start = layerDragStart, frame.width > 0, frame.height > 0 else {
            return
        }
        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        var next = start
        next.x = min(max(0, start.x + dx), 1 - start.width)
        next.y = min(max(0, start.y + dy), 1 - start.height)
        settings.layers[index] = next
    }

    // Anchors the corner OPPOSITE the one being dragged (e.g. dragging
    // .bottomRight keeps .topLeft fixed), same as the crop tool's own
    // corner resize. LOCKED to the layer's own starting aspect ratio by
    // default — opposite of crop's own convention (crop is free unless a
    // ratio button is tapped) but matches what the client explicitly asked
    // for here: hold ⇧ (Shift) to resize free-form, otherwise the shape
    // stays proportional. Locking to `start.width/start.height` directly
    // (a fraction-space ratio) rather than converting through the photo's
    // pixel dimensions still preserves the PIXEL aspect ratio exactly: for
    // a fixed photo, pixelRatio = (widthFraction/heightFraction) *
    // imagePixelRatio, so holding widthFraction/heightFraction constant
    // holds pixelRatio constant too — the imagePixelRatio factor cancels
    // out, so there's no need to look it up here at all (unlike the crop
    // tool's ratio-lock, which targets an ARBITRARY externally-chosen
    // pixel ratio like 4:3 and does need that conversion).
    private func resizeLayer(_ corner: LayerCorner, by translation: CGSize, frame: CGRect) {
        guard let index = selectedLayerIndex else {
            return
        }
        if layerDragStart == nil {
            layerDragStart = settings.layers[index]
        }
        guard let start = layerDragStart, frame.width > 0, frame.height > 0, start.height > 0 else {
            return
        }

        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        let minSize = 0.02

        let anchorX: Double
        switch corner {
        case .topLeft, .bottomLeft: anchorX = start.x + start.width
        case .topRight, .bottomRight: anchorX = start.x
        }
        let anchorY: Double
        switch corner {
        case .topLeft, .topRight: anchorY = start.y + start.height
        case .bottomLeft, .bottomRight: anchorY = start.y
        }

        // Raw, independent-axis proposed size — what a free-form resize
        // would use directly; the ratio-lock branch below reconciles it.
        var rawWidth: Double
        var rawHeight: Double
        switch corner {
        case .topLeft: rawWidth = start.width - dx; rawHeight = start.height - dy
        case .topRight: rawWidth = start.width + dx; rawHeight = start.height - dy
        case .bottomLeft: rawWidth = start.width - dx; rawHeight = start.height + dy
        case .bottomRight: rawWidth = start.width + dx; rawHeight = start.height + dy
        }
        rawWidth = max(rawWidth, minSize)
        rawHeight = max(rawHeight, minSize)

        let maxWidthAllowed: Double
        switch corner {
        case .topLeft, .bottomLeft: maxWidthAllowed = anchorX
        case .topRight, .bottomRight: maxWidthAllowed = 1 - anchorX
        }
        let maxHeightAllowed: Double
        switch corner {
        case .topLeft, .topRight: maxHeightAllowed = anchorY
        case .bottomLeft, .bottomRight: maxHeightAllowed = 1 - anchorY
        }

        var finalWidth: Double
        var finalHeight: Double

        if NSEvent.modifierFlags.contains(.shift) {
            finalWidth = max(min(rawWidth, maxWidthAllowed), minSize)
            finalHeight = max(min(rawHeight, maxHeightAllowed), minSize)
        } else {
            let k = start.width / start.height
            let widthFromWidth = rawWidth
            let heightFromWidth = rawWidth / k
            let widthFromHeight = rawHeight * k
            let heightFromHeight = rawHeight

            // Whichever axis the drag moved further (in the resulting
            // implied box) wins — the box grows/shrinks to follow
            // whichever direction the client is actually dragging in,
            // same feel as a Shift-drag corner resize in other editors
            // (here inverted: this is the DEFAULT, not the modifier).
            var w: Double
            var h: Double
            if widthFromWidth >= widthFromHeight {
                w = widthFromWidth
                h = heightFromWidth
            } else {
                w = widthFromHeight
                h = heightFromHeight
            }

            // Scale both dimensions down together (never just one) so the
            // ratio still holds exactly even after clamping to the anchor
            // corner's on-image bounds.
            let scale = min(1, maxWidthAllowed / max(w, 0.0001), maxHeightAllowed / max(h, 0.0001))
            finalWidth = max(w * scale, minSize)
            finalHeight = max(h * scale, minSize)
        }

        var next = start
        switch corner {
        case .topLeft: next.x = anchorX - finalWidth; next.y = anchorY - finalHeight
        case .topRight: next.x = anchorX; next.y = anchorY - finalHeight
        case .bottomLeft: next.x = anchorX - finalWidth; next.y = anchorY
        case .bottomRight: next.x = anchorX; next.y = anchorY
        }
        next.width = finalWidth
        next.height = finalHeight
        settings.layers[index] = next
    }

    // A transparent, full-frame hit area that records the drag as
    // `activeBrushStrokePoints` (unit space) and shows a cheap, purely
    // vector Path preview of the in-progress stroke — no CIImage re-render
    // happens until mouse-up (see commitBrushStroke), both because
    // rebuilding the whole brush mask through Core Image on every drag
    // point would be too slow to feel interactive, and because a live Path
    // is exactly what a paint tool's own on-screen ink normally looks like
    // anyway. Layered on top of brushMaskCanvas, which is what makes
    // ALREADY-painted strokes stay visible once the drag ends (previously
    // nothing showed the mask at all outside of an active drag).
    private func brushPaintOverlay(_ brush: BrushMaskGeometry?, frame: CGRect) -> some View {
        // Diameter in view space: `brushSize` is a fraction of the image's
        // LONG edge (see BrushStroke.size doc comment), and since `frame` is
        // an aspect-preserving fit of the image, frame's long edge scales
        // proportionally to the image's regardless of zoom — so the same
        // formula (size * longEdge) used at render time in
        // PhotoEditRenderer.brushStrokeDabs applies here unchanged.
        let brushDiameter = max(brushSize * max(frame.width, frame.height), 2)

        return ZStack {
            if let brush {
                brushMaskCanvas(brush, frame: frame)
            }

            if activeBrushStrokePoints.count > 1 {
                Path { path in
                    let scaled = activeBrushStrokePoints.map {
                        CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
                    }
                    path.move(to: scaled[0])
                    for point in scaled.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(
                    brushIsErasing ? Color.red.opacity(0.7) : accentColor.opacity(0.8),
                    style: StrokeStyle(lineWidth: brushDiameter, lineCap: .round, lineJoin: .round)
                )
                .allowsHitTesting(false)
            }

            // Cursor-size ring: shows exactly how big the next dab will be
            // BEFORE the user commits to painting, tracking the mouse while
            // it's merely hovering (not dragging) over the paint surface.
            // Hidden during an active drag since the in-progress stroke
            // above already shows the brush at its true width there.
            if let hover = brushHoverLocation, activeBrushStrokePoints.isEmpty {
                Circle()
                    .stroke(brushIsErasing ? Color.red.opacity(0.9) : accentColor.opacity(0.9), lineWidth: 1.5)
                    .frame(width: brushDiameter, height: brushDiameter)
                    .position(hover)
                    .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        brushHoverLocation = location
                    case .ended:
                        brushHoverLocation = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            brushHoverLocation = value.location
                            paintBrush(at: value.location, frame: frame)
                        }
                        .onEnded { _ in commitBrushStroke() }
                )
        }
    }

    // Persistent, translucent overlay of every ALREADY-PAINTED stroke —
    // what makes a brush mask's coverage visible once you let go of the
    // mouse, not just while actively dragging (the active-drag Path above
    // this in brushPaintOverlay is separate and only covers the
    // in-progress stroke). Drawn with Canvas (not a plain Path/ZStack)
    // specifically so an erase stroke can use `.destinationOut` to
    // genuinely punch a hole in the strokes painted before it, rather than
    // just drawing another translucent shape on top that wouldn't visually
    // "remove" anything — this reads as the actual mask shape, including
    // erased regions, not just a stack of independent strokes.
    private func brushMaskCanvas(_ brush: BrushMaskGeometry, frame: CGRect) -> some View {
        Canvas { context, size in
            for stroke in brush.strokes {
                guard stroke.points.count > 1 else {
                    continue
                }
                var path = Path()
                let scaled = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                path.move(to: scaled[0])
                for point in scaled.dropFirst() {
                    path.addLine(to: point)
                }
                let lineWidth = max(stroke.size * size.width, 2)
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

                if stroke.isErase {
                    context.blendMode = .destinationOut
                    context.stroke(path, with: .color(.white), style: style)
                } else {
                    context.blendMode = .normal
                    context.stroke(path, with: .color(accentColor.opacity(0.4)), style: style)
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }

    // The Remove brush's canvas. Committed strokes and the in-progress one
    // are drawn as plain red Paths rather than by rendering the real mask
    // through Core Image — the same reason brushPaintOverlay does it (a
    // CIImage re-render per drag point can't keep up), and here it doubles
    // as the "red translucent paint" the tool is supposed to look like.
    // The real mask is only built at Erase time (see eraseMaskedArea).
    private func removalPaintOverlay(frame: CGRect) -> some View {
        let longEdge = max(frame.width, frame.height)
        let brushDiameter = max(removalBrushSize * longEdge, 2)
        let ink = Color(red: 0.90, green: 0.25, blue: 0.22)

        return ZStack {
            // Every stroke is painted OPAQUE into one group, and the group is
            // made translucent afterwards. Painting each stroke at 45% instead
            // — which is what this did — meant two strokes crossing showed a
            // darker patch where they overlapped, so going back over an area
            // already covered looked like it was doing something when it was
            // not. The mask never worked that way (it takes the maximum), so
            // this only ever misrepresented what was selected.
            ZStack {
                ForEach(removalStrokes) { stroke in
                    strokePath(stroke.points, frame: frame)
                        .stroke(
                            ink,
                            style: StrokeStyle(
                                lineWidth: max(stroke.size * longEdge, 2),
                                lineCap: .round, lineJoin: .round
                            )
                        )
                }

                if !activeRemovalStrokePoints.isEmpty {
                    strokePath(activeRemovalStrokePoints, frame: frame)
                        .stroke(
                            ink,
                            style: StrokeStyle(lineWidth: brushDiameter, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            .compositingGroup()
            .opacity(0.45)
            .allowsHitTesting(false)

            if let hover = removalBrushHoverLocation, activeRemovalStrokePoints.isEmpty {
                Circle()
                    .stroke(ink.opacity(0.9), lineWidth: 1.5)
                    .frame(width: brushDiameter, height: brushDiameter)
                    .position(hover)
                    .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        removalBrushHoverLocation = location
                    case .ended:
                        removalBrushHoverLocation = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            removalBrushHoverLocation = value.location
                            paintRemovalBrush(at: value.location, frame: frame)
                        }
                        .onEnded { _ in commitRemovalStroke() }
                )
        }
    }

    private func strokePath(_ points: [CGPoint], frame: CGRect) -> Path {
        Path { path in
            let scaled = points.map {
                CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
            }
            guard let first = scaled.first else {
                return
            }
            path.move(to: first)
            // A lone point needs a zero-length line, not just a move: with a
            // round cap that draws the dab, while a bare move draws nothing.
            if scaled.count == 1 {
                path.addLine(to: first)
            }
            for point in scaled.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func unitPoint(from location: CGPoint, frame: CGRect) -> CGPoint? {
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }
        let x = (location.x - frame.minX) / frame.width
        let y = (location.y - frame.minY) / frame.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private func paintBrush(at location: CGPoint, frame: CGRect) {
        guard let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        // Skip points too close to the last recorded one — keeps the
        // stored array (and the render-time dab interpolation built from
        // it, see PhotoEditRenderer.brushStrokeDabs) from ballooning on a
        // slow drag without visibly changing the painted line.
        if let last = activeBrushStrokePoints.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activeBrushStrokePoints.append(unit)
    }

    private func commitBrushStroke() {
        defer { activeBrushStrokePoints = [] }
        guard let index = selectedAdjustmentIndex, activeBrushStrokePoints.count > 1 else {
            return
        }
        let stroke = BrushStroke(points: activeBrushStrokePoints, size: brushSize, hardness: brushHardness, isErase: brushIsErasing)
        if settings.localAdjustments[index].brush == nil {
            settings.localAdjustments[index].brush = BrushMaskGeometry()
        }
        settings.localAdjustments[index].brush?.strokes.append(stroke)
    }

    // Records one dab of an in-progress clone-stamp stroke. The FIRST dab
    // of a fresh stroke (activePatchStrokePoints still empty) is where a
    // pending ⌥-click source (if any) gets turned into this stroke's fixed
    // offset — see patchStrokeOffset's doc comment for why that offset then
    // carries over to later strokes too. If no source has EVER been set
    // (patchStrokeOffset is still nil), painting is a no-op: there's
    // nothing to clone from yet.
    private func paintPatchStroke(at location: CGPoint, frame: CGRect) {
        guard let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        if activePatchStrokePoints.isEmpty {
            if let source = pendingPatchSource {
                patchStrokeOffset = CGSize(width: source.x - unit.x, height: source.y - unit.y)
                pendingPatchSource = nil
            }
            guard patchStrokeOffset != nil else {
                return
            }
        }
        if let last = activePatchStrokePoints.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activePatchStrokePoints.append(unit)
    }

    // Unlike commitBrushStroke, a single-point "stroke" (a plain click, no
    // drag) IS committed — a one-dab clone stamp is a normal, common use
    // (spot-heal a single blemish), and brushStrokeDabs already renders a
    // 1-point stroke correctly (see its own doc comment).
    private func commitPatchStroke() {
        defer { activePatchStrokePoints = [] }
        guard let index = selectedAdjustmentIndex, !activePatchStrokePoints.isEmpty, let offset = patchStrokeOffset else {
            return
        }
        let stroke = PatchStroke(
            points: activePatchStrokePoints,
            sourceOffsetX: offset.width, sourceOffsetY: offset.height,
            size: patchBrushSize,
            feather: max(patchBrushFeather, PhotoEditRenderer.patchMinimumFeather)
        )
        settings.localAdjustments[index].patch?.strokes.append(stroke)
    }

    private func clearPatchStrokes(at index: Int) {
        guard settings.localAdjustments.indices.contains(index) else {
            return
        }
        settings.localAdjustments[index].patch?.strokes.removeAll()
    }

    // MARK: Adjustment panel

    private var adjustmentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                histogramView

                Divider()

                presetsSection

                Divider()

                cropRotateSection

                Divider()

                lightSection

                Divider()

                colorSection

                Divider()

                detailSection

                Divider()

                masksSection

                Divider()

                selectionSection

                Divider()

                removeSection

                Divider()

                layersSection

                Divider()

                settingsActionsSection

                Divider()

                resetButton

                Divider()

                exportActionsSection
            }
            .padding(18)
        }
        .frame(width: 300)
        .background(AppColors.panel)
    }

    // A plain luminance histogram — one bar per bucket, tallest bucket
    // normalized to full height — recomputed each render alongside the
    // preview image itself (see renderNow). Reads whatever is actually on
    // screen right now, including a held Before/After original and an
    // in-progress (not yet committed) crop.
    private var histogramView: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Histogram")

            HStack(alignment: .bottom, spacing: 1.5) {
                if histogramBins.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    ForEach(histogramBins.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AppColors.muted.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(1.5, histogramBins[index] * histogramHeight))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: histogramHeight, alignment: .bottom)
            .padding(8)
            .background(AppColors.panelAlt.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom("Figtree", size: 10).weight(.bold))
            .tracking(1)
            .foregroundColor(AppColors.muted.opacity(0.7))
    }

    private var cropRotateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Crop & Rotate")

            HStack(spacing: 10) {
                Button {
                    rotateQuarterTurn(-1)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .buttonStyle(EditToolButtonStyle())

                Button {
                    rotateQuarterTurn(1)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(EditToolButtonStyle())

                Button {
                    toggleCropMode()
                } label: {
                    Image(systemName: "crop")
                }
                .buttonStyle(EditToolButtonStyle(isActive: isCropping))

                Spacer()
            }

            editSlider("Straighten", value: straightenBinding, range: -45...45, step: 0.1) {
                String(format: "%+.1f°", $0)
            }

            if isCropping {
                aspectRatioRow

                HStack {
                    Button("Reset Crop") {
                        pendingCrop = .full
                        selectedCropAspectRatio = .free
                    }
                    .buttonStyle(ShowHeaderButtonStyle())

                    Spacer()

                    Button("Done") {
                        commitCrop()
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                    // Enter/Return commits the crop — SwiftUI attaches the
                    // shortcut to whichever button carries it, active only
                    // while this button actually exists in the tree (i.e.
                    // only while isCropping is true), so it never fires
                    // Return anywhere else in Develop. modifiers: [] is
                    // required — keyboardShortcut's own default modifier is
                    // Command, which would otherwise make this ⌘-Return
                    // instead of plain Return.
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
    }

    // Quick aspect-ratio presets for the crop tool. Tapping one snaps
    // pendingCrop to the largest centered rect of that ratio that fits the
    // (post-rotation) image — see applyCropAspectRatio. Once picked, the
    // ratio STAYS LOCKED through further handle drags too (see
    // resizeCrop) — shrinking/growing the crop keeps this exact ratio
    // instead of going free-form. Only tapping a different ratio button,
    // "Reset Crop", or opening the crop tool fresh on a different photo
    // clears it back to Free.
    private var aspectRatioRow: some View {
        HStack(spacing: 6) {
            ForEach(CropAspectRatioOption.allCases) { option in
                Button(option.label) {
                    applyCropAspectRatio(option)
                }
                .buttonStyle(AspectRatioButtonStyle(isActive: selectedCropAspectRatio == option))
            }
        }
    }

    // A saved, named PhotoEditSettings snapshot (full settings, including
    // crop/rotate/straighten) the user can reapply to any photo. See
    // PhotoEditPreset/PhotoEditPresetStore for why geometry is included.
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Presets")

            if presets.isEmpty && !isAddingPreset {
                Text("No presets saved yet")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
            }

            ForEach(presets) { preset in
                presetRow(preset)
            }

            if isAddingPreset {
                HStack(spacing: 6) {
                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.custom("Figtree", size: 12))
                        .onSubmit { saveCurrentAsPreset() }

                    Button("Save") {
                        saveCurrentAsPreset()
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") {
                        isAddingPreset = false
                        newPresetName = ""
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                }
            } else {
                Button {
                    newPresetName = ""
                    isAddingPreset = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Save Current as Preset")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .opacity(settings.isNeutral ? 0.4 : 1)
                .disabled(settings.isNeutral)
            }
        }
    }

    private func presetRow(_ preset: PhotoEditPreset) -> some View {
        HStack(spacing: 8) {
            Button {
                applyPreset(preset)
            } label: {
                Text(preset.name)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                deletePreset(preset)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppColors.panelAlt.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var lightSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Light")
            editSlider("Exposure", value: $settings.exposure, range: -3...3, step: 0.05) { String(format: "%+.2f", $0) }
            editSlider("Contrast", value: $settings.contrast, range: -1...1)
            editSlider("Highlights", value: $settings.highlights, range: -1...1)
            editSlider("Shadows", value: $settings.shadows, range: -1...1)
            editSlider("Whites", value: $settings.whites, range: -1...1)
            editSlider("Blacks", value: $settings.blacks, range: -1...1)
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Color")
            editSlider("Temperature", value: $settings.temperature, range: -1...1,
                       trackGradient: DevelopView.temperatureTrack)
            editSlider("Tint", value: $settings.tint, range: -1...1,
                       trackGradient: DevelopView.tintTrack)
            editSlider("Saturation", value: $settings.saturation, range: -1...1,
                       trackGradient: DevelopView.saturationTrack)
            editSlider("Vibrance", value: $settings.vibrance, range: -1...1,
                       trackGradient: DevelopView.vibranceTrack)
        }
    }

    // The four Color-panel track gradients. Each one shows what its own
    // ENDS do to the photo, so the control reads the same way Lightroom's
    // does: push Temperature right and the photo warms, and the track's
    // right end is already amber.
    //
    // Temperature/Tint pass through a near-neutral middle stop rather than
    // interpolating one end straight into the other — a direct blue→amber
    // ramp crosses through muddy green on the way and would put a false
    // "green here" cue at the slider's zero point, which is exactly where
    // the photo is untouched.
    private static let temperatureTrack = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.47, blue: 0.90),
            Color(red: 0.88, green: 0.88, blue: 0.88),
            Color(red: 0.99, green: 0.76, blue: 0.18)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    private static let tintTrack = LinearGradient(
        colors: [
            Color(red: 0.30, green: 0.74, blue: 0.35),
            Color(red: 0.88, green: 0.88, blue: 0.88),
            Color(red: 0.85, green: 0.28, blue: 0.78)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    // Saturation/Vibrance: a hue sweep whose SATURATION ramps with the
    // slider's own position — flat gray at the far left (where -100 takes
    // the photo), fully saturated at the right. The hue only runs to 0.85
    // instead of wrapping the full circle, so the two ends don't both come
    // back around to red and read as the same value. Vibrance gets the
    // same sweep at a lower ceiling, matching what it actually does: the
    // gentler, already-saturated-colors-protected version of Saturation.
    private static func colorfulTrack(maxSaturation: Double) -> LinearGradient {
        let steps = 12
        let colors: [Color] = (0...steps).map { index in
            let fraction = Double(index) / Double(steps)
            return Color(
                hue: fraction * 0.85,
                saturation: fraction * maxSaturation,
                // Slightly darker than the colored stops so the far-left
                // end lands on a readable mid-gray rather than washing out
                // into the panel's own light background.
                brightness: 0.86
            )
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private static let saturationTrack = colorfulTrack(maxSaturation: 1.0)
    private static let vibranceTrack = colorfulTrack(maxSaturation: 0.62)

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Detail & Effects")
            editSlider("Sharpness", value: $settings.sharpness, range: 0...1) { String(format: "%.0f", $0 * 100) }
            editSlider("Texture", value: $settings.texture, range: -1...1)
            editSlider("Clarity", value: $settings.clarity, range: 0...1) { String(format: "%.0f", $0 * 100) }
            editSlider("Dehaze", value: $settings.dehaze, range: 0...1) { String(format: "%.0f", $0 * 100) }
            editSlider("Soft Glow", value: $settings.softGlow, range: 0...1) { String(format: "%.0f", $0 * 100) }
            editSlider("Vignette", value: $settings.vignette, range: 0...1) { String(format: "%.0f", $0 * 100) }
        }
    }

    // MARK: Masks (local adjustments)

    // Index into settings.localAdjustments for the currently-selected mask,
    // re-derived from its stable UUID every time rather than cached — the
    // array can reorder/shrink (delete) out from under a cached index, and
    // this is cheap (the array is never more than a handful of masks long).
    private var selectedAdjustmentIndex: Int? {
        guard let id = selectedLocalAdjustmentID else {
            return nil
        }
        return settings.localAdjustments.firstIndex { $0.id == id }
    }

    private var masksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Masks")

            HStack(spacing: 8) {
                maskAddButton("Radial", systemImage: "circle.dashed") {
                    addLocalAdjustment(.radial(name: nextMaskName("Radial")))
                }
                maskAddButton("Graduated", systemImage: "rectangle.lefthalf.filled") {
                    addLocalAdjustment(.graduated(name: nextMaskName("Graduated")))
                }
                maskAddButton("Brush", systemImage: "paintbrush.pointed") {
                    addLocalAdjustment(.brush(name: nextMaskName("Brush")))
                }
            }

            // Square dropped per explicit request — Patch is Circle
            // (clone-stamp brush) or Free only now; Square remains a
            // Selection-tool-only shape (see addSelection below).
            HStack(spacing: 8) {
                maskAddButton("Patch Circle", systemImage: "circle") {
                    addLocalAdjustment(.patch(name: nextMaskName("Patch"), shape: .circle))
                }
                maskAddButton("Patch Free", systemImage: "lasso") {
                    addLocalAdjustment(.patch(name: nextMaskName("Patch"), shape: .free))
                }
            }

            if settings.localAdjustments.isEmpty {
                Text("No masks yet")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
            }

            ForEach(settings.localAdjustments) { adjustment in
                maskRow(adjustment)
            }

            if let index = selectedAdjustmentIndex {
                selectedMaskEditor(index: index)
            }
        }
    }

    private func maskAddButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                Text(title)
                    .font(.custom("Figtree", size: 9).weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            // Explicit hit-test shape covering the FULL frame (including
            // the padding/whitespace around the icon+text, which has no
            // rendered pixels of its own) — without this, SwiftUI can fall
            // back to hit-testing only the actual glyph content on some
            // layout passes, especially right after this section's height
            // changes (e.g. selectedMaskEditor appearing/disappearing below
            // as a mask gets added/selected). Reported directly: "Patch"/
            // "Radial"/any mask-add button intermittently not responding
            // to the first click right after opening Develop or selecting
            // a photo, working again only after some UNRELATED interaction
            // — this is the standard, known fix for exactly that class of
            // intermittent-miss bug in a SwiftUI ScrollView (this whole
            // panel is one, see adjustmentPanel), not a guess specific to
            // Patch — added to every mask-add button since Radial/Graduated/
            // Brush share this same function.
            .contentShape(Rectangle())
        }
        // NOT EditToolButtonStyle — that style hard-codes a 30×30 frame
        // sized for a single icon glyph (Rotate/Crop), which would clip
        // "Graduated"'s two-line icon+label content. This sizes to the
        // available width instead (three equal-width buttons in an HStack).
        .buttonStyle(MaskAddButtonStyle())
    }

    // Full-width, left-aligned icon+label row — every action button at the
    // bottom of the panel (Paste as Layer, Copy/Paste Settings, Syncing,
    // Reset All, both Export buttons) now goes through this ONE helper
    // instead of each independently building its own HStack and reaching
    // for `ShowHeaderButtonStyle()`. That style has no button "chrome" at
    // all (no border/fill — it was built for ShowGrid's HORIZONTAL header
    // bar, not this 264px-wide vertical sidebar) and let "Copy Settings"/
    // "Paste Settings" wrap onto two lines when squeezed side by side —
    // reported directly against a screenshot as looking cluttered/
    // unorganized. Bordered pill look matches maskAddButton's/
    // MaskAddButtonStyle's existing visual language above, just full-width
    // horizontal instead of a fixed-width icon-over-label square, so the
    // whole panel reads as one consistent system rather than two different
    // button languages stacked on top of each other.
    private func panelActionButton(_ title: String, systemImage: String, isProminent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(PanelActionButtonStyle(isProminent: isProminent))
    }

    private func maskTypeIcon(_ type: LocalMaskType) -> String {
        switch type {
        case .radial: return "circle.dashed"
        case .graduated: return "rectangle.lefthalf.filled"
        case .brush: return "paintbrush.pointed"
        case .patch: return "bandage"
        }
    }

    private func maskRow(_ adjustment: LocalAdjustment) -> some View {
        let isSelected = selectedLocalAdjustmentID == adjustment.id

        return HStack(spacing: 8) {
            Image(systemName: maskTypeIcon(adjustment.type))
                .font(.system(size: 11))
                .foregroundColor(AppColors.muted)
                .frame(width: 16)

            Button {
                selectLocalAdjustment(adjustment.id)
            } label: {
                Text(adjustment.name)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(adjustment.isEnabled ? AppColors.ink : AppColors.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleMaskEnabled(adjustment.id)
            } label: {
                Image(systemName: adjustment.isEnabled ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.muted)
            }
            .buttonStyle(.plain)

            Button {
                deleteLocalAdjustment(adjustment.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppColors.panelAlt.opacity(isSelected ? 1 : 0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? accentColor : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // The selected mask's own mini adjustment panel — type-specific controls
    // (Invert/Feather for radial & graduated, brush tool settings for
    // brush) plus the same tonal/color sliders as the global Light/Color/
    // Detail sections, bound through localAdjustmentBinding instead of
    // $settings directly.
    private func selectedMaskEditor(index: Int) -> some View {
        let adjustment = settings.localAdjustments[index]

        return VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack {
                Text("Editing: \(adjustment.name)")
                    .font(.custom("Figtree", size: 11).weight(.bold))
                    .foregroundColor(AppColors.ink)
                Spacer()
                Button("Done") {
                    selectedLocalAdjustmentID = nil
                }
                .buttonStyle(ShowHeaderButtonStyle())
            }

            switch adjustment.type {
            case .radial:
                Toggle("Invert", isOn: invertBinding)
                    .toggleStyle(.checkbox)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.ink)
                editSlider("Feather", key: "radial.feather", value: radialFeatherBinding, range: 0...1) { String(format: "%.0f", $0 * 100) }

            case .graduated:
                Toggle("Invert", isOn: invertBinding)
                    .toggleStyle(.checkbox)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.ink)

            case .brush:
                Toggle("Erase", isOn: $brushIsErasing)
                    .toggleStyle(.checkbox)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.ink)
                editSlider("Brush Size", key: "brush.size", value: $brushSize, range: 0.01...0.3) { String(format: "%.0f", $0 * 100) }
                editSlider("Hardness", key: "brush.hardness", value: $brushHardness, range: 0...1) { String(format: "%.0f", $0 * 100) }
                if !(adjustment.brush?.strokes.isEmpty ?? true) {
                    Button("Clear Strokes") {
                        clearBrushStrokes(at: index)
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                }

            case .patch:
                // Square dropped from the picker per explicit request —
                // still handled elsewhere purely so old saved data renders.
                Picker("Shape", selection: patchShapeBinding) {
                    Text("Circle").tag(PatchShape.circle)
                    Text("Free").tag(PatchShape.free)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if adjustment.patch?.shape == .free {
                    editSlider("Feather", key: "patch.feather", value: patchFeatherBinding, range: PhotoEditRenderer.patchMinimumFeather...1) { String(format: "%.0f", $0 * 100) }
                    editSlider("Opacity", key: "patch.opacity", value: patchOpacityBinding, range: 0...1) { String(format: "%.0f", $0 * 100) }
                    if adjustment.patch?.points.isEmpty ?? true {
                        Text("Drag on the photo to draw the patch outline.")
                            .font(.custom("Figtree", size: 11))
                            .foregroundColor(AppColors.muted)
                    } else {
                        Text("Drag the marker on the photo to choose where to sample from.")
                            .font(.custom("Figtree", size: 11))
                            .foregroundColor(AppColors.muted)
                        Button("Reset Source Offset") {
                            resetPatchSourceOffset(at: index)
                        }
                        .buttonStyle(ShowHeaderButtonStyle())
                        Button("Redraw Outline") {
                            clearPatchOutline(at: index)
                        }
                        .buttonStyle(ShowHeaderButtonStyle())
                    }
                } else {
                    // Circle = clone-stamp brush. Brush Size/Feather here
                    // are shared UI state (like the Brush tool's own
                    // brushSize/brushHardness) read when a NEW stroke is
                    // committed — nudging them never reshapes strokes
                    // already painted, same reasoning as the Brush tool.
                    editSlider("Brush Size", key: "patchBrush.size", value: $patchBrushSize, range: 0.02...0.3) { String(format: "%.0f", $0 * 100) }
                    editSlider("Feather", key: "patchBrush.feather", value: $patchBrushFeather, range: PhotoEditRenderer.patchMinimumFeather...1) { String(format: "%.0f", $0 * 100) }
                    editSlider("Opacity", key: "patchBrush.opacity", value: patchOpacityBinding, range: 0...1) { String(format: "%.0f", $0 * 100) }
                    Text("⌥-click to set the clone source, then drag on the photo to paint.")
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)
                    if !(adjustment.patch?.strokes.isEmpty ?? true) {
                        Button("Clear Strokes") {
                            clearPatchStrokes(at: index)
                        }
                        .buttonStyle(ShowHeaderButtonStyle())
                    }
                }
            }

            // A patch has no tonal/color settings of its own (see
            // PatchGeometry's doc comment) — it just samples pixels, so the
            // global-style Light/Color/Detail sliders below would be dead
            // controls for it and are skipped entirely.
            if adjustment.type != .patch {
                Divider()

                editSlider("Exposure", key: "mask.exposure", value: localAdjustmentBinding(\.exposure), range: -3...3, step: 0.05) { String(format: "%+.2f", $0) }
                editSlider("Contrast", key: "mask.contrast", value: localAdjustmentBinding(\.contrast), range: -1...1)
                editSlider("Highlights", key: "mask.highlights", value: localAdjustmentBinding(\.highlights), range: -1...1)
                editSlider("Shadows", key: "mask.shadows", value: localAdjustmentBinding(\.shadows), range: -1...1)
                editSlider("Whites", key: "mask.whites", value: localAdjustmentBinding(\.whites), range: -1...1)
                editSlider("Blacks", key: "mask.blacks", value: localAdjustmentBinding(\.blacks), range: -1...1)
                editSlider("Temperature", key: "mask.temperature", value: localAdjustmentBinding(\.temperature), range: -1...1)
                editSlider("Tint", key: "mask.tint", value: localAdjustmentBinding(\.tint), range: -1...1)
                editSlider("Saturation", key: "mask.saturation", value: localAdjustmentBinding(\.saturation), range: -1...1)
                editSlider("Vibrance", key: "mask.vibrance", value: localAdjustmentBinding(\.vibrance), range: -1...1)
                editSlider("Sharpness", key: "mask.sharpness", value: localAdjustmentBinding(\.sharpness), range: 0...1) { String(format: "%.0f", $0 * 100) }
            }
        }
    }

    // MARK: Selection tool (Cut/Copy/Deselect)

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Selection")

            HStack(spacing: 8) {
                maskAddButton("Circle", systemImage: "circle") {
                    addSelection(shape: .circle)
                }
                maskAddButton("Square", systemImage: "square") {
                    addSelection(shape: .square)
                }
                maskAddButton("Free", systemImage: "lasso") {
                    addSelection(shape: .free)
                }
            }

            if let activeSelection {
                let isFreeUndrawn = activeSelection.shape == .free && activeSelection.points.isEmpty

                if isFreeUndrawn {
                    Text("Drag on the photo to draw the selection outline.")
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)
                } else {
                    editSlider("Feather", key: "selection.feather", value: selectionFeatherBinding, range: 0...1) { String(format: "%.0f", $0 * 100) }
                }

                // .fixedSize() on each label — three icon+text buttons in a
                // 300pt-wide panel are tight enough that without it, SwiftUI
                // would rather wrap "Copy" onto two lines than let the
                // HStack overflow; fixedSize forces each label to keep its
                // natural single-line width instead (the row scrolls/
                // clips before it wraps mid-word, which reads much better).
                HStack(spacing: 10) {
                    Button {
                        cutSelection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "scissors")
                            Text("Cut")
                        }
                        .fixedSize()
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                    .disabled(isFreeUndrawn || isExtractingSelection)
                    .opacity((isFreeUndrawn || isExtractingSelection) ? 0.4 : 1)

                    Button {
                        copySelection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy")
                        }
                        .fixedSize()
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                    .disabled(isFreeUndrawn || isExtractingSelection)
                    .opacity((isFreeUndrawn || isExtractingSelection) ? 0.4 : 1)

                    Button("Deselect") {
                        deselectSelection()
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                    .disabled(isExtractingSelection)
                }

                if isExtractingSelection {
                    Text("Extracting…")
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)
                }
            } else {
                Text("No active selection")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
            }
        }
    }

    private var selectionFeatherBinding: Binding<Double> {
        Binding(
            get: { activeSelection?.feather ?? 0 },
            set: { activeSelection?.feather = $0 }
        )
    }

    // Lightroom's "remove this" in two explicit steps rather than one
    // magic button: FIND the people (so what is about to be erased is
    // visible on the canvas first — an erase is expensive and picking the
    // wrong subject is the likeliest way to waste that), then ERASE.
    //
    // If a Selection outline is already active, the search is confined to
    // it. That is the answer to the usual case — "remove the people in the
    // BACKGROUND, keep the one I photographed" — without needing a
    // per-person picker: rope off the area, then find people inside it.
    private var removeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Remove")

            panelActionButton("Select People", systemImage: "person.crop.rectangle") {
                findPeople()
            }
            .disabled(isFindingPeople || isRemoving || selectedURL == nil)
            .opacity((isFindingPeople || isRemoving || selectedURL == nil) ? 0.4 : 1)

            // The manual half: Vision only knows people, and plenty of what
            // anyone wants gone (a bin, a sign, a cable, a stranger too
            // small to register as a person) isn't one. Painting also
            // stacks WITH a found mask rather than replacing it, so the
            // usual flow — find the people, then brush in the two things
            // Vision missed — is one Erase, not two.
            panelActionButton(isRemoveBrushActive ? "Brush (painting)" : "Brush", systemImage: "paintbrush") {
                toggleRemoveBrush()
            }
            .disabled(isFindingPeople || isRemoving || selectedURL == nil)
            .opacity((isFindingPeople || isRemoving || selectedURL == nil) ? 0.4 : 1)

            if isRemoveBrushActive {
                editSlider("Brush Size", key: "removeBrush.size", value: $removalBrushSize, range: 0.01...0.3) {
                    String(format: "%.0f", $0 * 100)
                }
                Text("Paint over what should go. [ and ] resize the brush.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isFindingPeople {
                Text("Looking for people…")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
            } else if hasRemovalArea {
                Text(removalMask == nil
                     ? "Painted area ready. Quick is fast and matches the surroundings; AI Clean Up invents what belongs there."
                     : (activeSelection == nil
                        ? "People found. Quick is fast and matches the surroundings; AI Clean Up invents what belongs there."
                        : "People inside the selection. Quick is fast; AI Clean Up invents what belongs there."))
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)

                // LaMa: one forward pass, about a second, and it ships inside
                // the app — so this works on every Mac, including Intel
                // machines with no Neural Engine where the generative path
                // below takes minutes. Best at continuing texture and
                // background; it extends what is around the hole rather than
                // inventing something new.
                panelActionButton("Quick AI Clean Up", systemImage: "wand.and.rays") {
                    eraseMaskedArea(using: .quick)
                }
                .disabled(isRemoving)
                .opacity(isRemoving ? 0.4 : 1)

                // Same mask, same resulting ImageLayer — the only difference
                // is what invents the missing pixels. Kept as a separate
                // button rather than a mode toggle because the two have
                // completely different costs: instant is a second, AI is
                // thirty diffusion steps.
                //
                // The gear sits beside it rather than inside a Settings screen
                // because the prompt only makes sense next to the thing it
                // controls — and it stays closed by default, since the whole
                // point is that the tool is one button.
                HStack(spacing: 6) {
                    panelActionButton("AI Clean Up", systemImage: "wand.and.stars") {
                        eraseMaskedArea(using: .generative)
                    }
                    Button {
                        showsAIPromptEditor.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(showsAIPromptEditor ? AppColors.ink : AppColors.muted)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("What AI Clean Up should put in place of what you erased")
                }
                .disabled(isRemoving)
                .opacity(isRemoving ? 0.4 : 1)

                if showsAIPromptEditor {
                    aiPromptEditor
                }

                panelActionButton("Clear Selection", systemImage: "xmark.circle") {
                    clearRemovalMask()
                }
                .disabled(isRemoving)
                .opacity(isRemoving ? 0.4 : 1)
            } else if !isRemoveBrushActive {
                Text("Finds everyone in the photo — or only inside an active Selection. Brush paints any area by hand.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isRemoving {
                Text(aiEraseProgress.map { "Cleaning up… \(Int($0 * 100))%" } ?? "Erasing…")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
            }

            if let removeErrorMessage {
                Text(removeErrorMessage)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // The prompt AI Clean Up runs with. Hidden behind the gear because the tool
    // is meant to be one button: brush, click, done. It is here for the case
    // the model guesses wrong about what belongs behind the thing that was
    // removed, and naming it ("a wooden terrace", "sand") fixes it.
    private var aiPromptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Describe what should be there instead")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)

            TextEditor(text: $aiRemovePrompt)
                .font(.custom("Figtree", size: 11))
                .scrollContentBackground(.hidden)
                .background(AppColors.panelAlt)
                .frame(height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(AppColors.border, lineWidth: 1)
                )

            // The patch is generated, not copied, so its tone lands a hair off
            // the photo's and a hard edge shows as a rectangle. This is how
            // far it fades out — as a fraction of the repaired area, so the
            // setting means the same thing on a small object and a large one.
            editSlider("Edge Feather", key: "aiRemove.feather",
                       value: $aiRemoveFeather, range: 0...1) {
                String(format: "%.0f", $0 * 100)
            }

            HStack(spacing: 8) {
                Button("Reset") {
                    aiRemovePrompt = SDInpaintPipeline.defaultPrompt
                    aiRemoveFeather = SDInpaintPipeline.defaultFeather
                }
                .buttonStyle(.plain)
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)
                .disabled(aiRemovePrompt == SDInpaintPipeline.defaultPrompt
                          && aiRemoveFeather == SDInpaintPipeline.defaultFeather)
                .opacity(aiRemovePrompt == SDInpaintPipeline.defaultPrompt
                         && aiRemoveFeather == SDInpaintPipeline.defaultFeather ? 0.4 : 1)

                Spacer(minLength: 0)
            }

            // Worth saying plainly: this model reads a prompt as a list of
            // things to DEPICT, not as an instruction. "Remove the object and
            // match the lighting" makes it paint signs and stock textures —
            // measured, not guessed.
            Text("Name what belongs there, like \"a wooden terrace\" — not an instruction like \"remove the object\".")
                .font(.custom("Figtree", size: 10))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: Remove (Vision + inpainting) actions

    // Either half of the tool counts: a Vision mask, painted strokes, or
    // both at once (they are unioned at Erase time).
    private var hasRemovalArea: Bool {
        removalMask != nil || !removalStrokes.isEmpty
    }

    private func clearRemovalMask() {
        removalMask = nil
        removalOverlay = nil
        removalStrokes = []
        activeRemovalStrokePoints = []
    }

    // Turning the brush on takes over the canvas the same way picking a
    // mask or the Selection tool does — those overlays share one hit area,
    // so leaving another one active would mean two tools fighting over the
    // same drag.
    private func toggleRemoveBrush() {
        isRemoveBrushActive.toggle()
        guard isRemoveBrushActive else {
            activeRemovalStrokePoints = []
            return
        }
        selectedLocalAdjustmentID = nil
        activeSelection = nil
        activeSelectionDrawPoints = []
        selectedLayerID = nil
        isCropping = false
    }

    private func paintRemovalBrush(at location: CGPoint, frame: CGRect) {
        guard let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        // Same minimum-spacing filter as paintBrush — see its doc comment.
        if let last = activeRemovalStrokePoints.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activeRemovalStrokePoints.append(unit)
    }

    private func commitRemovalStroke() {
        defer { activeRemovalStrokePoints = [] }
        // One point counts: a single click should dab the brush where it was
        // clicked, rather than needing a drag before anything appears.
        // brushStrokeDabs already handles a one-point stroke, so the mask side
        // has always been ready for this.
        guard !activeRemovalStrokePoints.isEmpty else {
            return
        }
        // hardness 1: this is a SELECTION, not a soft adjustment — a feathered
        // edge would fall under the mask threshold and quietly shrink what
        // gets erased. The pipeline grows and softens the hole itself.
        removalStrokes.append(BrushStroke(
            points: activeRemovalStrokePoints,
            size: removalBrushSize,
            hardness: 1,
            isErase: false
        ))
    }

    // Runs on the FULL, PRE-CROP render — not the cropped one a Cut/Copy
    // works from — because that is the space compositeLayers interprets an
    // ImageLayer's coordinates in, and the erase's output is an
    // ImageLayer. Using the cropped render here would land every repair at
    // the wrong place on any photo that has a crop.
    private func findPeople() {
        guard let fullBaseImage, let selectedURL else {
            return
        }
        isFindingPeople = true
        let settingsSnapshot = settings
        let photoAtActionTime = selectedURL
        let confineTo = activeSelection

        developRenderQueue.async(qos: .userInitiated) {
            let full = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage, applyCrop: false)
            var mask = SubjectMasker.personMask(for: full)

            if let mask_ = mask, let confineTo, !(confineTo.shape == .free && confineTo.points.count < 3) {
                let shape = PhotoEditRenderer.selectionMask(confineTo, extent: full.extent)
                mask = mask_.applyingFilter("CIMultiplyBlendMode", parameters: [
                    kCIInputBackgroundImageKey: shape
                ]).cropped(to: full.extent)
            }

            let overlay = mask.flatMap {
                InpaintPipeline.overlayImage(for: $0, context: briefEditsCIContext)
            }

            DispatchQueue.main.async {
                isFindingPeople = false
                guard selectedURL == photoAtActionTime else {
                    return
                }
                removalMask = mask
                removalOverlay = overlay
            }
        }
    }

    // Which model fills the hole. Everything either side of it — the union of
    // the Vision mask and the painted strokes, the guard against the client
    // moving on mid-run, the ImageLayer that comes out — is shared, so the two
    // buttons stay genuinely interchangeable.
    private enum RemovalEngine {
        case quick        // LaMa, bundled, ~1s, every Mac
        case generative   // Stable Diffusion, downloaded, ~13s, Apple Silicon
    }

    private func eraseMaskedArea(using engine: RemovalEngine) {
        guard hasRemovalArea, let fullBaseImage, let selectedURL else {
            return
        }
        isRemoving = true
        removeErrorMessage = nil
        // Only the generative path is slow enough to need a percentage; LaMa
        // finishes before a progress bar would finish appearing.
        aiEraseProgress = engine == .generative ? 0 : nil
        let settingsSnapshot = settings
        let photoAtActionTime = selectedURL
        let visionMask = removalMask
        let strokes = removalStrokes
        let prompt = aiRemovePrompt
        let feather = aiRemoveFeather

        developRenderQueue.async(qos: .userInitiated) {
            let full = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage, applyCrop: false)

            // Union, so "find the people, then brush in what Vision missed"
            // is a single erase. Maximum (not addition) keeps the mask a
            // clean 0...1 decision where the two overlap.
            var mask = visionMask
            if !strokes.isEmpty {
                let painted = PhotoEditRenderer.strokeMask(strokes, extent: full.extent)
                mask = mask.map {
                    $0.applyingFilter("CIMaximumCompositing", parameters: [
                        kCIInputBackgroundImageKey: painted
                    ]).cropped(to: full.extent)
                } ?? painted
            }
            guard let mask else {
                DispatchQueue.main.async { isRemoving = false }
                return
            }
            let removal: InpaintPipeline.Removal?
            do {
                switch engine {
                case .quick:
                    removal = try InpaintPipeline.quickAIRemoval(
                        mask: mask, from: full, context: briefEditsCIContext, feather: feather)
                case .generative:
                    removal = try InpaintPipeline.aiRemoval(
                        mask: mask, from: full, context: briefEditsCIContext,
                        prompt: prompt, feather: feather,
                        progress: { done, total in
                            DispatchQueue.main.async {
                                aiEraseProgress = Double(done) / Double(max(total, 1))
                            }
                        }
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isRemoving = false
                    aiEraseProgress = nil
                    removeErrorMessage = error.localizedDescription
                }
                return
            }

            DispatchQueue.main.async {
                isRemoving = false
                aiEraseProgress = nil
                // Same guard as performSelectionExtraction: the repair is
                // pixels belonging to ONE photo, so it is dropped rather
                // than misapplied if the client moved on while it ran.
                guard let removal, selectedURL == photoAtActionTime else {
                    clearRemovalMask()
                    return
                }
                let layer = ImageLayer(
                    name: nextLayerName("Removed"), imageData: removal.pngData,
                    x: removal.boundsUnit.minX, y: removal.boundsUnit.minY,
                    width: removal.boundsUnit.width, height: removal.boundsUnit.height
                )
                settings.layers.append(layer)
                clearRemovalMask()
                activeSelection = nil
                isRemoveBrushActive = false
            }
        }
    }

    // MARK: Layers

    private var selectedLayerIndex: Int? {
        guard let id = selectedLayerID else {
            return nil
        }
        return settings.layers.firstIndex { $0.id == id }
    }

    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Layers")

            panelActionButton("Paste as Layer", systemImage: "doc.on.clipboard") {
                pasteLayer()
            }
            .disabled(layerClipboard == nil)
            .opacity(layerClipboard == nil ? 0.4 : 1)
            // Cmd+V pastes directly, same expectation as any other
            // clipboard in macOS — this button is always in the view tree
            // (not conditionally inserted), so the shortcut works no
            // matter where the Layers section has scrolled to, and
            // SwiftUI disables the shortcut itself whenever the button is
            // (i.e. whenever the clipboard is empty).
            .keyboardShortcut("v", modifiers: .command)

            if settings.layers.isEmpty {
                Text("No layers yet")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
            }

            ForEach(settings.layers) { layer in
                layerRow(layer)
            }

            if let index = selectedLayerIndex {
                selectedLayerEditor(index: index)
            }
        }
    }

    private func layerRow(_ layer: ImageLayer) -> some View {
        let isSelected = selectedLayerID == layer.id

        return HStack(spacing: 8) {
            Image(systemName: "square.2.layers.3d")
                .font(.system(size: 11))
                .foregroundColor(AppColors.muted)
                .frame(width: 16)

            Button {
                selectLayer(layer.id)
            } label: {
                Text(layer.name)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(layer.isEnabled ? AppColors.ink : AppColors.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleLayerEnabled(layer.id)
            } label: {
                Image(systemName: layer.isEnabled ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.muted)
            }
            .buttonStyle(.plain)

            Button {
                deleteLayer(layer.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppColors.panelAlt.opacity(isSelected ? 1 : 0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? accentColor : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func selectedLayerEditor(index: Int) -> some View {
        let layer = settings.layers[index]

        return VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack {
                Text("Editing: \(layer.name)")
                    .font(.custom("Figtree", size: 11).weight(.bold))
                    .foregroundColor(AppColors.ink)
                Spacer()
                Button("Done") {
                    selectedLayerID = nil
                }
                .buttonStyle(ShowHeaderButtonStyle())
            }

            editSlider("Opacity", key: "layer.opacity", value: layerOpacityBinding, range: 0...1) { String(format: "%.0f", $0 * 100) }

            Picker("Blend Mode", selection: layerBlendModeBinding) {
                ForEach(LayerBlendMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Drag the layer on the photo to move it; drag a corner to resize.")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)
        }
    }

    private var layerOpacityBinding: Binding<Double> {
        Binding(
            get: {
                guard let index = selectedLayerIndex else {
                    return 1
                }
                return settings.layers[index].opacity
            },
            set: { newValue in
                guard let index = selectedLayerIndex else {
                    return
                }
                settings.layers[index].opacity = newValue
            }
        )
    }

    private var layerBlendModeBinding: Binding<LayerBlendMode> {
        Binding(
            get: {
                guard let index = selectedLayerIndex else {
                    return .normal
                }
                return settings.layers[index].blendMode
            },
            set: { newValue in
                guard let index = selectedLayerIndex else {
                    return
                }
                settings.layers[index].blendMode = newValue
            }
        )
    }

    // Generic binding into the selected mask's own LocalAdjustmentSettings
    // — mirrors $settings.<field> for the global sliders, but resolved
    // through selectedAdjustmentIndex every get/set since which array slot
    // is "selected" is tracked by UUID, not by index (see that property's
    // own comment).
    private func localAdjustmentBinding(_ keyPath: WritableKeyPath<LocalAdjustmentSettings, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let index = selectedAdjustmentIndex else {
                    return 0
                }
                return settings.localAdjustments[index].settings[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = selectedAdjustmentIndex else {
                    return
                }
                settings.localAdjustments[index].settings[keyPath: keyPath] = newValue
            }
        )
    }

    private var invertBinding: Binding<Bool> {
        Binding(
            get: {
                guard let index = selectedAdjustmentIndex else {
                    return false
                }
                let adjustment = settings.localAdjustments[index]
                switch adjustment.type {
                case .radial: return adjustment.radial?.invert ?? false
                case .graduated: return adjustment.graduated?.invert ?? false
                case .brush, .patch: return false
                }
            },
            set: { newValue in
                guard let index = selectedAdjustmentIndex else {
                    return
                }
                switch settings.localAdjustments[index].type {
                case .radial: settings.localAdjustments[index].radial?.invert = newValue
                case .graduated: settings.localAdjustments[index].graduated?.invert = newValue
                case .brush, .patch: break
                }
            }
        )
    }

    private var patchShapeBinding: Binding<PatchShape> {
        Binding(
            get: {
                guard let index = selectedAdjustmentIndex else {
                    return .circle
                }
                return settings.localAdjustments[index].patch?.shape ?? .circle
            },
            set: { newValue in
                guard let index = selectedAdjustmentIndex else {
                    return
                }
                // Switching TO Free discards centerX/Y-derived state that
                // no longer means anything for a hand-drawn polygon;
                // switching Circle <-> Free otherwise just leaves both
                // representations (strokes vs points/center/radius) intact
                // side by side — whichever one the current shape doesn't
                // use is simply dormant, not deleted, so switching back
                // restores it.
                settings.localAdjustments[index].patch?.shape = newValue
                if newValue == .free {
                    settings.localAdjustments[index].patch?.points = []
                }
            }
        )
    }

    private var patchFeatherBinding: Binding<Double> {
        Binding(
            get: {
                guard let index = selectedAdjustmentIndex else {
                    return 0.3
                }
                return settings.localAdjustments[index].patch?.feather ?? 0.3
            },
            set: { newValue in
                guard let index = selectedAdjustmentIndex else {
                    return
                }
                // Floored, never a hard 0 edge — edges are ALWAYS at least
                // a little feathered, per explicit request (same floor
                // patchStrokeDabs applies for Circle-mode strokes).
                settings.localAdjustments[index].patch?.feather = max(newValue, PhotoEditRenderer.patchMinimumFeather)
            }
        )
    }

    private var patchOpacityBinding: Binding<Double> {
        Binding(
            get: {
                guard let index = selectedAdjustmentIndex else {
                    return 1.0
                }
                return settings.localAdjustments[index].patch?.opacity ?? 1.0
            },
            set: { newValue in
                guard let index = selectedAdjustmentIndex else {
                    return
                }
                settings.localAdjustments[index].patch?.opacity = min(max(newValue, 0), 1)
            }
        )
    }

    private var radialFeatherBinding: Binding<Double> {
        Binding(
            get: {
                guard let index = selectedAdjustmentIndex else {
                    return 0.5
                }
                return settings.localAdjustments[index].radial?.feather ?? 0.5
            },
            set: { newValue in
                guard let index = selectedAdjustmentIndex else {
                    return
                }
                settings.localAdjustments[index].radial?.feather = newValue
            }
        )
    }

    // One slider row: name on the left, live value on the right, track
    // below. Two things beyond the obvious:
    //
    // `key` — the identity used for arrow-key arming (see
    // SliderNudgeRegistry) and for drawing the "armed" highlight. Defaults
    // to the title, which is unique for the global Light/Color/Detail
    // sliders, but the mask/patch/brush/layer panels reuse names
    // ("Exposure", "Feather", "Opacity", "Brush Size" all appear more than
    // once), so those call sites pass an explicit namespaced key. Two
    // sliders sharing a key would fight over the same registry entry AND
    // both light up as selected.
    //
    // `step` — how far ONE arrow press moves it. Defaults to 0.01, which is
    // exactly one unit on the 0...100 scale nearly every slider here
    // displays (value * 100); the two that don't display that way
    // (Exposure in EV, Straighten in degrees) pass their own.
    //
    // Clicking the NAME arms the slider and shows the card; starting a
    // normal drag arms it too but stays silent (onEditingChanged) — the
    // card is an answer to "what did I just click", and firing it on every
    // drag would make it noise.
    // `trackGradient` — when a slider's direction has a COLOR meaning
    // (the whole Color section: blue↔amber, green↔magenta, gray↔saturated),
    // pass the gradient and the row draws a Lightroom-style colored track
    // instead of the platform's gray one. Everything else about the row is
    // identical either way; see GradientTrackSlider for why it can't just
    // be a background behind the real Slider.
    private func editSlider(
        _ title: String,
        key: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 0.01,
        trackGradient: LinearGradient? = nil,
        format: @escaping (Double) -> String = { String(format: "%+.0f", $0 * 100) }
    ) -> some View {
        let sliderKey = key ?? title
        let isSelected = selectedSliderKey == sliderKey

        // Deliberately re-registered on EVERY body pass rather than in
        // .onAppear — see SliderNudgeRegistry for why the freshest binding
        // matters and why this can't invalidate the view.
        sliderRegistry.register(sliderKey) { increase, multiplier in
            let delta = step * multiplier * (increase ? 1 : -1)
            // Snapped back onto the step's own grid after every press, the
            // way Lightroom's arrows land on whole increments. Two reasons
            // beyond tidiness: repeated adds accumulate binary-float dust
            // (ten +0.05 presses from -0.5 landed on -1.1e-16, which the
            // readout rendered as a baffling "-0" and which isNeutral —
            // an exact == 0 comparison — would have counted as "this photo
            // is edited" forever), and a value left mid-grid by a mouse
            // drag would otherwise keep every later arrow press off-grid
            // too.
            let raw = value.wrappedValue + delta
            let snapped = step > 0 ? (raw / step).rounded() * step : raw
            value.wrappedValue = min(max(snapped, range.lowerBound), range.upperBound)
        }

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    selectSlider(sliderKey, title: title)
                } label: {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.custom("Figtree", size: 12).weight(.medium))
                            .foregroundColor(isSelected ? AppColors.hoverInk : AppColors.ink)

                        if isSelected {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(accentColor)
                        }
                    }
                    // Without this the Button only hits on the glyphs
                    // themselves and the first click often lands on nothing
                    // — the same missing-contentShape bug already fixed on
                    // maskAddButton/EditToolButtonStyle/AspectRatioButtonStyle,
                    // see BRIEFSHOW_DEVELOP_NOTES.md.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to control \(title) with the ← / → keys")

                Spacer()

                Text(format(value.wrappedValue))
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(isSelected ? AppColors.ink : AppColors.muted)
                    .monospacedDigit()
            }

            if let trackGradient {
                GradientTrackSlider(value: value, range: range, gradient: trackGradient) { editing in
                    if editing, selectedSliderKey != sliderKey {
                        selectedSliderKey = sliderKey
                    }
                }
            } else {
                Slider(value: value, in: range) { editing in
                    if editing, selectedSliderKey != sliderKey {
                        selectedSliderKey = sliderKey
                    }
                }
            }
        }
        // padding(6) → highlight → padding(-6): the selected row's tint/
        // border bleeds 6pt outward past the row's own content, but the
        // negative padding hands the ORIGINAL footprint back to the
        // enclosing VStack, so arming a slider never shifts the panel's
        // layout by a pixel.
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .padding(-6)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    // Arm `key` for the ← / → keys and pop the card that says so. Any
    // previously-scheduled dismissal is cancelled first so clicking a
    // second slider gives the new card its own full dwell time instead of
    // inheriting the leftover of the old one's.
    private func selectSlider(_ key: String, title: String) {
        sliderToastDismissWork?.cancel()

        withAnimation(.easeOut(duration: 0.25)) {
            selectedSliderKey = key
            sliderToast = SliderSelectionToast(title: title)
        }

        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.3)) {
                sliderToast = nil
            }
        }
        sliderToastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    private func clearSelectedSlider() {
        sliderToastDismissWork?.cancel()
        withAnimation(.easeIn(duration: 0.2)) {
            selectedSliderKey = nil
            sliderToast = nil
        }
    }

    // Called by the key monitor for a bare (or Shift-held) ← / →. Shift
    // multiplies the step by 5, matching Lightroom's own "arrow for fine,
    // Shift+arrow for coarse" pairing. Returns false when nothing is armed
    // or the armed slider isn't currently on screen, so the caller can let
    // the keypress through untouched.
    private func nudgeSelectedSlider(increase: Bool, coarse: Bool) -> Bool {
        guard let key = selectedSliderKey else {
            return false
        }
        return sliderRegistry.nudge(key, increase: increase, multiplier: coarse ? 5 : 1)
    }

    // The card itself — sits over the bottom of the preview, never over the
    // panel, so it can't cover the slider the user just clicked. Purely
    // informational, so it takes no hits (see centerPreview's
    // allowsHitTesting) and the photo underneath stays fully interactive.
    private func sliderToastCard(_ toast: SliderSelectionToast) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(toast.title) selected")
                .font(.custom("Figtree", size: 12.5).weight(.semibold))
                .foregroundColor(AppColors.ink)

            Text("Press ← to lower, → to raise  ·  hold ⇧ for bigger steps")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppColors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accentColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 10, y: 3)
    }

    // Copy the current photo's full settings into an in-memory clipboard
    // (see settingsClipboard) and paste them onto whichever photo is
    // selected when Paste is pressed — deliberately one photo at a time,
    // no multi-select (see BRIEFSHOW_DEVELOP_NOTES.md #5). Stacked full-
    // width (not side by side) together with Sync, one consistent group —
    // see panelActionButton's own doc comment for why.
    private var settingsActionsSection: some View {
        let targetCount = selectedURL.map { multiSelectedURLs.subtracting([$0]).count } ?? 0

        return VStack(alignment: .leading, spacing: 8) {
            panelActionButton("Copy Settings", systemImage: "doc.on.doc") {
                settingsClipboard = settings
            }
            .opacity(settings.isNeutral ? 0.4 : 1)
            .disabled(settings.isNeutral)

            panelActionButton("Paste Settings", systemImage: "doc.on.clipboard") {
                pasteSettings()
            }
            .opacity(settingsClipboard == nil ? 0.4 : 1)
            .disabled(settingsClipboard == nil)

            // Lightroom-style "Sync Settings" — the CURRENTLY OPEN photo's
            // live `settings` (exactly what the sliders show right now,
            // not a separately copied snapshot the way the clipboard
            // above works) is written to every OTHER photo currently in
            // the filmstrip's multi-select (multiSelectedURLs, see
            // handleFilmstripClick). Named "Syncing" per explicit request
            // rather than "Synchronize"/"Sync Settings". Only enabled once
            // there's at least one OTHER photo selected alongside the open
            // one — syncing to an empty target set would be a no-op
            // button press with no feedback as to why nothing happened.
            panelActionButton("Syncing (\(targetCount))", systemImage: "arrow.triangle.2.circlepath") {
                showSyncDialog = true
            }
            .opacity(targetCount == 0 ? 0.4 : 1)
            .disabled(targetCount == 0)
        }
    }

    // Lightroom's own "Synchronize Settings" dialog, adapted: a checklist of
    // categories (all checked by default, same as Lightroom opens with),
    // "Check All"/"Uncheck All" for quickly flipping every row at once, and
    // a "Synchronize"/Cancel pair. Reads live off `syncCategories` — nothing
    // is written until the user presses "Synchronize" (syncSettingsToSelection).
    private var syncDialogView: some View {
        let targetCount = selectedURL.map { multiSelectedURLs.subtracting([$0]).count } ?? 0

        return VStack(alignment: .leading, spacing: 16) {
            Text("Synchronize Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppColors.ink)

            Text("Copy the open photo's settings to \(targetCount) other selected photo\(targetCount == 1 ? "" : "s").")
                .font(.system(size: 12))
                .foregroundColor(AppColors.ink.opacity(0.7))

            // Every Text/Image below explicitly takes AppColors.ink — same
            // as the rest of this file — rather than relying on the
            // platform's default label color. Left unset, that default
            // color follows the SYSTEM light/dark appearance, not this
            // app's own always-dark panel background, so it rendered as
            // near-black text/icons on a near-black background (invisible)
            // whenever the system happened to be in Light Mode.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SyncCategory.displayOrder, id: \.title) { entry in
                    let isChecked = syncCategories.contains(entry.category)

                    Button {
                        if isChecked {
                            syncCategories.remove(entry.category)
                        } else {
                            syncCategories.insert(entry.category)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .foregroundColor(isChecked ? accentColor : AppColors.ink.opacity(0.5))
                            Image(systemName: entry.icon)
                                .foregroundColor(AppColors.ink)
                                .frame(width: 16)
                            Text(entry.title)
                                .foregroundColor(AppColors.ink)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button("Check All") { syncCategories = .all }
                    .buttonStyle(ShowHeaderButtonStyle())
                Button("Uncheck All") { syncCategories = [] }
                    .buttonStyle(ShowHeaderButtonStyle())
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    showSyncDialog = false
                }
                .buttonStyle(ShowHeaderButtonStyle())

                Button("Synchronize") {
                    syncSettingsToSelection(categories: syncCategories)
                    showSyncDialog = false
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .opacity(syncCategories.isEmpty ? 0.4 : 1)
                .disabled(syncCategories.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
        .background(AppColors.panel)
    }

    private var resetButton: some View {
        panelActionButton("Reset All", systemImage: "arrow.counterclockwise") {
            settings = PhotoEditSettings()
            pendingCrop = .full
            cropIsAutoFitted = false
            selectedLocalAdjustmentID = nil
            activeSelection = nil
            activeSelectionDrawPoints = []
            selectedLayerID = nil
        }
        .opacity(settings.isNeutral ? 0.4 : 1)
        .disabled(settings.isNeutral)
    }

    // The two "final" actions of the panel — visually set apart as
    // prominent (solid fill, semibold) rather than the plain bordered rows
    // above, same "this is where you finish" emphasis Export already had
    // by virtue of being physically last, just made visible in the style
    // too now instead of looking identical to Reset All/Copy Settings/etc.
    private var exportActionsSection: some View {
        // Read fresh on every body re-render (not cached), so it stays
        // accurate as edits are made/reset while this panel is open.
        let editedCount = photoURLs.filter { PhotoEditStore.hasEdits($0) }.count

        return VStack(alignment: .leading, spacing: 8) {
            // Above the buttons rather than behind a gear, unlike the AI
            // prompt: format is something you decide before exporting, not a
            // setting you tune once and forget.
            Picker("", selection: $exportFormatRaw) {
                ForEach(ExportFormat.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if exportFormat.isLossy {
                editSlider("Quality", key: "export.quality",
                           value: $exportQuality, range: 0.4...1.0) {
                    String(format: "%.0f", $0 * 100)
                }
            } else {
                Text("\(exportFormat.title) is lossless — every export is full quality and a much larger file.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            panelActionButton("Export Edited Copy", systemImage: "square.and.arrow.up", isProminent: true) {
                exportEditedCopy()
            }
            .opacity(fullBaseImage == nil ? 0.4 : 1)
            .disabled(fullBaseImage == nil)

            // Exports every photo in this folder (photoURLs — the same
            // list the filmstrip shows, not just the current selection)
            // that has a saved edit, skipping untouched ones — one
            // destination-folder picker instead of Save-panel-per-photo.
            panelActionButton("Export All Edited (\(editedCount))", systemImage: "square.and.arrow.up.on.square", isProminent: true) {
                exportAllEditedPhotos()
            }
            .opacity(editedCount == 0 ? 0.4 : 1)
            .disabled(editedCount == 0)
        }
    }

    // MARK: Actions

    private func selectPhoto(_ url: URL) {
        guard url != selectedURL else {
            return
        }

        selectedURL = url
        resetZoom()
        isCropping = false
        dragStartCrop = nil
        showOriginal = false
        settings = PhotoEditStore.settings(for: url)
        pendingCrop = settings.crop ?? .full
        // Whatever crop (if any) came back with the saved settings is
        // treated as the user's own — this photo's Straighten shouldn't
        // start silently overwriting it just because it happens to be
        // non-nil. A fresh photo with no saved crop keeps auto-fitting.
        cropIsAutoFitted = false
        // The previous photo's mask (if any) was selected by UUID, and a
        // different photo's localAdjustments won't contain that UUID — but
        // clear explicitly anyway rather than rely on selectedAdjustmentIndex
        // quietly resolving to nil, and always drop any in-progress brush
        // drag so it can never bleed onto the newly-selected photo.
        selectedLocalAdjustmentID = nil
        activeBrushStrokePoints = []
        activePatchDrawPoints = []
        activePatchStrokePoints = []
        pendingPatchSource = nil
        patchStrokeOffset = nil
        // Same reasoning as selectedLocalAdjustmentID above — a Selection
        // outline or layer index from the PREVIOUS photo has no business
        // surviving onto this one. layerClipboard is deliberately left
        // alone: it's meant to survive a photo switch (that's the whole
        // point of "cut from one photo, paste onto another").
        activeSelection = nil
        activeSelectionDrawPoints = []
        selectedLayerID = nil
        // A Remove mask describes PIXELS of the previous photo — the one
        // piece of ephemeral state here that would be actively dangerous
        // to keep (erasing "the people" at coordinates taken from a
        // different image).
        clearRemovalMask()
        isRemoveBrushActive = false
        // Undo/redo history is per-photo, like Lightroom's own — a
        // previous photo's undo stack describing edits to a DIFFERENT
        // image has no meaning here.
        undoCommitWorkItem?.cancel()
        undoCommitWorkItem = nil
        pendingUndoBaseline = nil
        undoStack = []
        redoStack = []
        lastCommittedSettings = settings
        loadImages(for: url)
    }

    // Presets/paste both replace the *entire* settings struct, including
    // crop — mirror commitCrop's own reasoning and treat whatever crop
    // comes along with it as the user's deliberate choice, not something
    // auto-fit should keep re-computing on the next Straighten drag.
    private func applyPreset(_ preset: PhotoEditPreset) {
        settings = preset.settings
        pendingCrop = preset.settings.crop ?? .full
        cropIsAutoFitted = false
        selectedLocalAdjustmentID = nil
    }

    private func saveCurrentAsPreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let preset = PhotoEditPreset(id: UUID(), name: trimmed, settings: settings)
        presets.append(preset)
        PhotoEditPresetStore.save(presets)
        isAddingPreset = false
        newPresetName = ""
    }

    private func deletePreset(_ preset: PhotoEditPreset) {
        presets.removeAll { $0.id == preset.id }
        PhotoEditPresetStore.save(presets)
    }

    private func pasteSettings() {
        guard let settingsClipboard else {
            return
        }
        settings = settingsClipboard
        pendingCrop = settingsClipboard.crop ?? .full
        cropIsAutoFitted = false
        selectedLocalAdjustmentID = nil
    }

    // Writes the open photo's live `settings` straight into every OTHER
    // multi-selected photo's PhotoEditStore entry — no render/decode needed
    // (UserDefaults writes only), so this runs synchronously on the main
    // thread rather than developRenderQueue. Doesn't touch `settings`/
    // `selectedURL` themselves (the open photo's own store entry is already
    // kept current by renderNow on every change), and doesn't load or
    // re-render the target photos now — their filmstrip "has edits" badge
    // and histogram will simply reflect the synced settings next time each
    // is actually opened, same as any other out-of-editor PhotoEditStore
    // write (Presets, Export All Edited's own settings lookups, etc).
    private func syncSettingsToSelection(categories: SyncCategory) {
        guard let selectedURL, !categories.isEmpty else {
            return
        }
        let targets = multiSelectedURLs.subtracting([selectedURL])
        guard !targets.isEmpty else {
            return
        }

        for target in targets {
            let merged = Self.mergedSyncSettings(
                source: settings,
                target: PhotoEditStore.settings(for: target),
                categories: categories
            )
            PhotoEditStore.setSettings(merged, for: target)
        }

        exportStatusText = "Synced to \(targets.count)"
        let dismissWorkItem = DispatchWorkItem { exportStatusText = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: dismissWorkItem)
    }

    // Starts from the TARGET's own settings (so anything not in `categories`
    // is left exactly as that photo already had it) and overwrites only the
    // fields belonging to checked categories with the SOURCE's values — the
    // same "only touch what's checked" behavior as Lightroom's Sync Settings.
    // `static` + explicit params (no implicit access to `settings`/instance
    // state) so this is a pure, independently testable function — same
    // reasoning as PhotoEditRenderer's math helpers throughout this file.
    private static func mergedSyncSettings(
        source: PhotoEditSettings,
        target: PhotoEditSettings,
        categories: SyncCategory
    ) -> PhotoEditSettings {
        var result = target

        if categories.contains(.cropRotate) {
            result.rotationQuarterTurns = source.rotationQuarterTurns
            result.straightenDegrees = source.straightenDegrees
            result.crop = source.crop
        }
        if categories.contains(.light) {
            result.exposure = source.exposure
            result.contrast = source.contrast
            result.highlights = source.highlights
            result.shadows = source.shadows
            result.whites = source.whites
            result.blacks = source.blacks
        }
        if categories.contains(.color) {
            result.temperature = source.temperature
            result.tint = source.tint
            result.saturation = source.saturation
            result.vibrance = source.vibrance
        }
        if categories.contains(.detail) {
            result.sharpness = source.sharpness
            result.texture = source.texture
            result.clarity = source.clarity
            result.dehaze = source.dehaze
            result.softGlow = source.softGlow
            result.vignette = source.vignette
        }
        if categories.contains(.masks) {
            result.localAdjustments = source.localAdjustments
        }

        return result
    }

    // MARK: Masks (local adjustments) actions

    // "Radial 1", "Radial 2", ... — counts existing masks of the same base
    // name rather than the whole array's length, so deleting "Radial 1"
    // and adding a new radial mask doesn't produce a second "Radial 1".
    private func nextMaskName(_ base: String) -> String {
        let existingCount = settings.localAdjustments.filter { $0.name.hasPrefix(base) }.count
        return "\(base) \(existingCount + 1)"
    }

    private func addLocalAdjustment(_ adjustment: LocalAdjustment) {
        settings.localAdjustments.append(adjustment)
        selectedLocalAdjustmentID = adjustment.id
        isCropping = false
        activeSelection = nil
        selectedLayerID = nil
    }

    // Tapping the already-selected mask's row deselects it (back to
    // editing global sliders) — same "tap again to close" affordance as
    // the crop tool's own icon button.
    private func selectLocalAdjustment(_ id: UUID) {
        selectedLocalAdjustmentID = (selectedLocalAdjustmentID == id) ? nil : id
        if selectedLocalAdjustmentID != nil {
            isCropping = false
            activeSelection = nil
            selectedLayerID = nil
        }
        activeBrushStrokePoints = []
        activePatchDrawPoints = []
        activePatchStrokePoints = []
        pendingPatchSource = nil
        patchStrokeOffset = nil
    }

    private func toggleMaskEnabled(_ id: UUID) {
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == id }) else {
            return
        }
        settings.localAdjustments[index].isEnabled.toggle()
    }

    private func deleteLocalAdjustment(_ id: UUID) {
        settings.localAdjustments.removeAll { $0.id == id }
        if selectedLocalAdjustmentID == id {
            selectedLocalAdjustmentID = nil
        }
    }

    private func clearBrushStrokes(at index: Int) {
        guard settings.localAdjustments.indices.contains(index) else {
            return
        }
        settings.localAdjustments[index].brush?.strokes.removeAll()
    }

    private func resetPatchSourceOffset(at index: Int) {
        guard settings.localAdjustments.indices.contains(index) else {
            return
        }
        settings.localAdjustments[index].patch?.sourceOffsetX = 0.2
        settings.localAdjustments[index].patch?.sourceOffsetY = 0
    }

    // Clears a Free-shape patch's drawn outline so the user can redraw it
    // (e.g. after a mistake) without deleting and re-adding the whole mask
    // — keeps its feather/source-offset settings intact.
    private func clearPatchOutline(at index: Int) {
        guard settings.localAdjustments.indices.contains(index) else {
            return
        }
        settings.localAdjustments[index].patch?.points = []
    }

    // MARK: Selection tool actions

    private func addSelection(shape: PatchShape) {
        activeSelection = SelectionGeometry(shape: shape)
        selectionDragStart = nil
        activeSelectionDrawPoints = []
        selectedLocalAdjustmentID = nil
        selectedLayerID = nil
        isCropping = false
    }

    private func deselectSelection() {
        activeSelection = nil
        selectionDragStart = nil
        activeSelectionDrawPoints = []
    }

    private func copySelection() {
        performSelectionExtraction(cut: false)
    }

    private func cutSelection() {
        performSelectionExtraction(cut: true)
    }

    // Renders the CURRENT settings onto the FULL-resolution base image
    // (same starting point as Export Edited Copy) on developRenderQueue,
    // then extracts the selection's pixels from that — full quality, and
    // consistent with what's actually on screen (crop/masks/etc. already
    // applied) rather than the raw undeveloped file. `cut` additionally
    // builds a same-shaped solid-black fill and drops it in as a new layer
    // at the selection's own position, right where the cut piece used to
    // show through — see ImageLayer/PatchGeometry doc comments and
    // BRIEFSHOW_DEVELOP_NOTES.md #13 for why a "hole" is implemented this
    // way instead of as some new, one-off adjustment type.
    private func performSelectionExtraction(cut: Bool) {
        guard let selection = activeSelection, let fullBaseImage, let selectedURL else {
            return
        }
        if selection.shape == .free && selection.points.count < 3 {
            return
        }

        isExtractingSelection = true
        let settingsSnapshot = settings
        let photoAtActionTime = selectedURL

        developRenderQueue.async(qos: .userInitiated) {
            let rendered = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage)
            let extracted = PhotoEditRenderer.extractSelectionPNG(selection, from: rendered)
            // Neutral gray, not black — a black hole read as "broken"/
            // suspiciously like a bug at a glance; mid-gray reads more
            // clearly as a deliberate placeholder fill.
            let fillResult = cut
                ? PhotoEditRenderer.solidFillPNG(selection, color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1), extent: rendered.extent)
                : nil

            DispatchQueue.main.async {
                isExtractingSelection = false
                // The client may have switched to a different filmstrip
                // photo while this was still running — the extracted piece
                // is still good for the clipboard (that's meant to survive
                // a photo switch), but a Cut's fill layer belongs on the
                // SOURCE photo specifically, so bail on THAT part if the
                // selection no longer matches what's on screen.
                guard let extracted else {
                    return
                }
                layerClipboard = LayerClipboardData(imageData: extracted.data, boundsUnit: extracted.boundsUnit)

                if cut, selectedURL == photoAtActionTime, let fillResult {
                    let layer = ImageLayer(
                        name: nextLayerName("Cut Fill"), imageData: fillResult.data,
                        x: fillResult.boundsUnit.minX, y: fillResult.boundsUnit.minY,
                        width: fillResult.boundsUnit.width, height: fillResult.boundsUnit.height
                    )
                    settings.layers.append(layer)
                }

                activeSelection = nil
                activeSelectionDrawPoints = []
            }
        }
    }

    // MARK: Layer actions

    // "Layer 1", "Layer 2", ... / "Cut Fill 1", "Cut Fill 2", ... — same
    // per-base-name counting as nextMaskName, for the same reason (so
    // deleting "Layer 1" and pasting again doesn't produce a second
    // "Layer 1").
    private func nextLayerName(_ base: String) -> String {
        let existingCount = settings.layers.filter { $0.name.hasPrefix(base) }.count
        return "\(base) \(existingCount + 1)"
    }

    // Pastes the clipboard back at EXACTLY the fractional position/size it
    // was cut/copied from ("paste in place") — same spot on the same
    // photo if that's still open, or the same relative spot on a
    // different one. Deliberately NOT a fixed centered default: a Cut's
    // fill layer already sits at that exact same position (see
    // performSelectionExtraction), so pasting back there means the piece
    // reappears right on top of its own "hole" — the one place a client
    // cutting and immediately pasting back would actually be looking,
    // rather than a re-centered copy elsewhere on the photo they'd have to
    // go hunt for.
    private func pasteLayer() {
        guard let layerClipboard else {
            return
        }
        let bounds = layerClipboard.boundsUnit
        let width = min(max(bounds.width, 0.02), 1)
        let height = min(max(bounds.height, 0.02), 1)
        let layer = ImageLayer(
            name: nextLayerName("Layer"), imageData: layerClipboard.imageData,
            x: min(max(bounds.minX, 0), 1 - width), y: min(max(bounds.minY, 0), 1 - height),
            width: width, height: height
        )
        settings.layers.append(layer)
        selectedLayerID = layer.id
        selectedLocalAdjustmentID = nil
        activeSelection = nil
        isCropping = false
    }

    // Tapping the already-selected layer's row deselects it — same
    // "tap again to close" affordance as selectLocalAdjustment/the crop
    // tool's own icon button.
    private func selectLayer(_ id: UUID) {
        selectedLayerID = (selectedLayerID == id) ? nil : id
        if selectedLayerID != nil {
            isCropping = false
            selectedLocalAdjustmentID = nil
            activeSelection = nil
        }
    }

    private func toggleLayerEnabled(_ id: UUID) {
        guard let index = settings.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        settings.layers[index].isEnabled.toggle()
    }

    private func deleteLayer(_ id: UUID) {
        settings.layers.removeAll { $0.id == id }
        if selectedLayerID == id {
            selectedLayerID = nil
        }
    }

    private func rotateQuarterTurn(_ delta: Int) {
        settings.rotationQuarterTurns = ((settings.rotationQuarterTurns + delta) % 4 + 4) % 4
    }

    private func toggleCropMode() {
        if isCropping {
            commitCrop()
        } else {
            pendingCrop = settings.crop ?? .full
            isCropping = true
            selectedLocalAdjustmentID = nil
            activeSelection = nil
            selectedLayerID = nil
            selectedCropAspectRatio = .free
            scheduleRender()
        }
    }

    private func commitCrop() {
        settings.crop = (pendingCrop == .full) ? nil : pendingCrop
        // The user just went through the crop tool themselves — even if
        // they landed back on the auto-fitted rect, further Straighten
        // drags shouldn't override their choice anymore.
        cropIsAutoFitted = false
        isCropping = false
        scheduleRender()
    }

    // Binding used only by the Straighten slider — routes every drag
    // through applyAutoFitCropIfNeeded, rather than a blanket
    // `.onChange(of: settings.straightenDegrees)`, so the auto-fit only
    // ever runs for an actual straighten drag. A generic onChange would
    // also fire when selectPhoto assigns a whole new `settings` for a
    // different photo, at a point where `previewBaseImage` is still the
    // *previous* photo's — which would compute the crop against the wrong
    // image dimensions.
    private var straightenBinding: Binding<Double> {
        Binding(
            get: { settings.straightenDegrees },
            set: { newValue in
                settings.straightenDegrees = newValue
                applyAutoFitCropIfNeeded()
            }
        )
    }

    // Keeps the crop tight against the rotated image's own edges after a
    // Straighten drag, so the transparent corners a plain rotation leaves
    // never show by default — see PhotoEditRenderer.autoStraightenCrop.
    // No-op once the user has taken the crop tool into their own hands
    // (see cropIsAutoFitted).
    private func applyAutoFitCropIfNeeded() {
        guard settings.crop == nil || cropIsAutoFitted else {
            return
        }
        guard let base = previewBaseImage else {
            return
        }

        var width = base.extent.width
        var height = base.extent.height
        if settings.rotationQuarterTurns % 2 != 0 {
            swap(&width, &height)
        }

        let autoCrop = PhotoEditRenderer.autoStraightenCrop(
            imageWidth: Double(width),
            imageHeight: Double(height),
            angleDegrees: settings.straightenDegrees
        )
        settings.crop = (autoCrop == .full) ? nil : autoCrop
        cropIsAutoFitted = true

        if isCropping {
            pendingCrop = settings.crop ?? .full
        }
    }

    // Snaps pendingCrop to the largest centered rect matching `option`'s
    // ratio that fits inside the (post-rotation) image — a one-shot
    // starting point, not a constraint kept during later handle drags (see
    // moveCrop/resizeCrop). `.free` just un-highlights the row without
    // touching the current crop, since there's nothing to "apply".
    private func applyCropAspectRatio(_ option: CropAspectRatioOption) {
        selectedCropAspectRatio = option
        guard let ratio = option.ratio, ratio > 0 else {
            return
        }
        guard let base = previewBaseImage else {
            return
        }

        var width = base.extent.width
        var height = base.extent.height
        if settings.rotationQuarterTurns % 2 != 0 {
            swap(&width, &height)
        }
        guard width > 0, height > 0 else {
            return
        }

        let imagePixelRatio = Double(width / height)
        let cropWidthFraction: Double
        let cropHeightFraction: Double
        if ratio > imagePixelRatio {
            // Target is wider (relative to its height) than the image
            // itself — the crop's width is the constraint.
            cropWidthFraction = 1
            cropHeightFraction = imagePixelRatio / ratio
        } else {
            cropHeightFraction = 1
            cropWidthFraction = ratio / imagePixelRatio
        }

        pendingCrop = EditCropRect(
            x: (1 - cropWidthFraction) / 2,
            y: (1 - cropHeightFraction) / 2,
            width: cropWidthFraction,
            height: cropHeightFraction
        )
        cropIsAutoFitted = false
    }

    private func loadImages(for url: URL) {
        isLoadingPreview = true
        fullBaseImage = nil
        previewBaseImage = nil
        displayedImage = nil
        histogramBins = []

        DispatchQueue.global(qos: .userInitiated).async {
            guard let base = PhotoEditRenderer.loadBaseImage(from: url) else {
                DispatchQueue.main.async {
                    if url == selectedURL {
                        isLoadingPreview = false
                    }
                }
                return
            }

            let preview = PhotoEditRenderer.loadPreviewBaseImage(from: url, full: base)

            DispatchQueue.main.async {
                // The client may have already clicked another filmstrip
                // thumbnail while this decode was still running.
                guard url == selectedURL else {
                    return
                }
                fullBaseImage = base
                previewBaseImage = preview
                isLoadingPreview = false
                renderNow()
            }
        }
    }

    // A THROTTLE, not a debounce — this used to cancel+reschedule on every
    // single call, which means a value arriving faster than the 20ms delay
    // (exactly what a normal slider drag does, via SwiftUI's own .onChange
    // firing on essentially every frame) kept pushing the timer back
    // forever, so it never actually fired until the drag stopped — the
    // photo would visibly jump straight from its start value to wherever
    // the slider ended up, with nothing smooth shown in between (reported
    // directly: dragging 0...10 "shows immediately 10", no live in-between
    // frames at all). Fixed by only scheduling a NEW timer when none is
    // already pending — an in-flight timer is left alone to fire on its
    // original schedule instead of being pushed back, giving a steady
    // ~20ms cadence of renders throughout a drag (reads `settings` live
    // when it actually runs, via renderNow(), so it always picks up
    // whatever's current by then, never a stale value from scheduling
    // time). renderGeneration (see its own doc comment) is what keeps
    // this safe against pileup now that renders genuinely fire this often.
    private func scheduleRender() {
        guard renderWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem {
            renderWorkItem = nil
            renderNow()
        }
        renderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: workItem)
    }

    private func renderNow() {
        if let selectedURL {
            PhotoEditStore.setSettings(settings, for: selectedURL)
        }

        guard let previewBaseImage else {
            return
        }

        renderGeneration += 1
        let generation = renderGeneration
        let effectiveSettings = showOriginal ? PhotoEditSettings() : settings
        let cropEnabled = !isCropping
        let source = previewBaseImage
        let photoAtRenderTime = selectedURL

        developRenderQueue.async(qos: .userInteractive) {
            // A NEWER renderNow() already landed while this one was sitting
            // in the queue — skip the expensive render entirely rather than
            // computing a result nobody will see (see renderGeneration's
            // doc comment).
            guard generation == renderGeneration else {
                return
            }
            let rendered = PhotoEditRenderer.render(effectiveSettings, on: source, applyCrop: cropEnabled)
            // Superseded WHILE rendering — still worth checking before the
            // (also non-trivial) CGImage conversion below.
            guard generation == renderGeneration,
                  let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) else {
                return
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let bins = PhotoEditRenderer.luminanceHistogram(of: rendered)

            DispatchQueue.main.async {
                guard selectedURL == photoAtRenderTime, generation == renderGeneration else {
                    return
                }
                displayedImage = image
                histogramBins = bins
            }
        }
    }

    private func exportEditedCopy() {
        guard let selectedURL, let fullBaseImage else {
            return
        }

        // Captured before the background work starts, like the settings
        // snapshot beside it: changing the format mid-export must not change
        // the file being written.
        let format = exportFormat
        let quality = exportQuality

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = selectedURL.deletingPathExtension().lastPathComponent
            + " Edited." + format.fileExtension
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let settingsSnapshot = settings
        exportStatusText = "Exporting…"

        developRenderQueue.async(qos: .userInitiated) {
            let rendered = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage)
            var didWrite = false

            if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) {
                let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                if let data = format.encode(bitmapRep, quality: quality) {
                    didWrite = (try? data.write(to: destinationURL)) != nil
                }
            }

            DispatchQueue.main.async {
                exportStatusText = didWrite ? "Exported" : "Export Failed"
                let dismissWorkItem = DispatchWorkItem { exportStatusText = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: dismissWorkItem)
            }
        }
    }

    // Right-click "Export…" on a filmstrip thumbnail — exports THAT photo
    // (not necessarily the one currently open in the editor) at maximum
    // JPEG quality (compressionFactor 1.0, vs. 0.92 for the regular "Export
    // Edited Copy" button). Loads its own full-resolution base image fresh
    // from disk (same PhotoEditRenderer.loadBaseImage used by "Export All
    // Edited" below — full RAW demosaic for RAW files, not the downsampled
    // preview decode) and its own saved settings from PhotoEditStore, so
    // this works correctly even when right-clicking a DIFFERENT photo than
    // the one currently open (renderNow() keeps PhotoEditStore up to date
    // for the open photo on every change, see its comment).
    private func exportSinglePhoto(_ url: URL) {
        // Captured before the background work starts, like the settings
        // snapshot beside it: changing the format mid-export must not change
        // the file being written.
        let format = exportFormat
        let quality = exportQuality
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent
            + " Edited." + format.fileExtension
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let settingsForPhoto = PhotoEditStore.settings(for: url)
        exportStatusText = "Exporting…"

        developRenderQueue.async(qos: .userInitiated) {
            var didWrite = false

            if let base = PhotoEditRenderer.loadBaseImage(from: url) {
                let rendered = PhotoEditRenderer.render(settingsForPhoto, on: base)
                if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) {
                    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                    if let data = format.encode(bitmapRep, quality: quality) {
                        didWrite = (try? data.write(to: destinationURL)) != nil
                    }
                }
            }

            DispatchQueue.main.async {
                exportStatusText = didWrite ? "Exported" : "Export Failed"
                let dismissWorkItem = DispatchWorkItem { exportStatusText = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: dismissWorkItem)
            }
        }
    }

    // Right-click "Export N Selected…" when the right-clicked thumbnail is
    // part of a larger (Cmd/Shift) multi-select — same one-folder-picker
    // shape as exportAllEditedPhotos below, but for exactly the given set of
    // photos (regardless of whether they have edits) and at maximum JPEG
    // quality, matching exportSinglePhoto's quality rather than the 0.92
    // used by exportAllEditedPhotos/the main "Export Edited Copy" button.
    private func exportSelectedPhotos(_ urls: [URL]) {
        // Captured before the background work starts, like the settings
        // snapshot beside it: changing the format mid-export must not change
        // the file being written.
        let format = exportFormat
        let quality = exportQuality
        guard !urls.isEmpty else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for the \(urls.count) selected photo\(urls.count == 1 ? "" : "s")"

        guard panel.runModal() == .OK, let destinationFolder = panel.url else {
            return
        }

        exportStatusText = "Exporting 0/\(urls.count)…"

        developRenderQueue.async(qos: .userInitiated) {
            var successCount = 0

            for (index, url) in urls.enumerated() {
                let settingsForPhoto = PhotoEditStore.settings(for: url)
                if let base = PhotoEditRenderer.loadBaseImage(from: url) {
                    let rendered = PhotoEditRenderer.render(settingsForPhoto, on: base)
                    if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) {
                        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                        if let data = format.encode(bitmapRep, quality: quality) {
                            let destinationURL = destinationFolder
                                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " Edited")
                                .appendingPathExtension(format.fileExtension)
                            if (try? data.write(to: destinationURL)) != nil {
                                successCount += 1
                            }
                        }
                    }
                }

                let completed = index + 1
                DispatchQueue.main.async {
                    exportStatusText = "Exporting \(completed)/\(urls.count)…"
                }
            }

            DispatchQueue.main.async {
                exportStatusText = "Exported \(successCount)/\(urls.count)"
                let dismissWorkItem = DispatchWorkItem { exportStatusText = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: dismissWorkItem)
            }
        }
    }

    // Exports every edited photo in `photoURLs` to a single chosen
    // destination folder in one pass, instead of Save-panel-per-photo.
    // Each photo is loaded and rendered fresh from its OWN saved settings
    // (PhotoEditStore.settings(for:) — already kept up to date on every
    // render, including for the currently-open photo, see renderNow), not
    // from any in-memory state here, so this reflects exactly what's
    // saved regardless of which photo happens to be open in the editor
    // right now. Runs entirely on developRenderQueue, one photo at a time
    // (not in parallel) — full-resolution decodes of several photos at
    // once, especially RAW, would spike memory for no real speed benefit
    // once you're bottlenecked on disk/CPU anyway.
    private func exportAllEditedPhotos() {
        // Captured before the background work starts, like the settings
        // snapshot beside it: changing the format mid-export must not change
        // the file being written.
        let format = exportFormat
        let quality = exportQuality
        let editedURLs = photoURLs.filter { PhotoEditStore.hasEdits($0) }
        guard !editedURLs.isEmpty else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for the \(editedURLs.count) edited photo\(editedURLs.count == 1 ? "" : "s")"

        guard panel.runModal() == .OK, let destinationFolder = panel.url else {
            return
        }

        exportStatusText = "Exporting 0/\(editedURLs.count)…"

        developRenderQueue.async(qos: .userInitiated) {
            var successCount = 0

            for (index, url) in editedURLs.enumerated() {
                let settingsForPhoto = PhotoEditStore.settings(for: url)
                if let base = PhotoEditRenderer.loadBaseImage(from: url) {
                    let rendered = PhotoEditRenderer.render(settingsForPhoto, on: base)
                    if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) {
                        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                        if let data = format.encode(bitmapRep, quality: quality) {
                            // Same "<name> Edited.<ext>" naming as the
                            // single-photo export — re-running this into
                            // the same destination folder later (e.g.
                            // after further edits) overwrites its own
                            // previous output rather than piling up
                            // "Edited 2", "Edited 3", ... copies, which
                            // matches "export reflects the latest saved
                            // edit" better than silently accumulating
                            // stale exports.
                            let destinationURL = destinationFolder
                                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " Edited")
                                .appendingPathExtension(format.fileExtension)
                            if (try? data.write(to: destinationURL)) != nil {
                                successCount += 1
                            }
                        }
                    }
                }

                let completed = index + 1
                DispatchQueue.main.async {
                    exportStatusText = "Exporting \(completed)/\(editedURLs.count)…"
                }
            }

            DispatchQueue.main.async {
                exportStatusText = "Exported \(successCount)/\(editedURLs.count)"
                let dismissWorkItem = DispatchWorkItem { exportStatusText = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: dismissWorkItem)
            }
        }
    }
}

// MARK: - Small tool button style (rotate/crop icon buttons)

// A slider whose TRACK is a color gradient instead of the platform's plain
// gray bar — Lightroom's own Color panel look, where Temperature reads
// blue→amber and Tint green→magenta right on the control, so the direction
// each slider pushes the photo is visible before you touch it.
//
// It has to be hand-drawn: macOS SwiftUI's Slider paints its own opaque
// track and offers no hook to replace it, and nothing behind it shows
// through. So this reimplements just enough of a slider — a capsule track,
// a round thumb, and a drag/click gesture — while keeping the SAME
// Binding<Double>/range/onEditingChanged contract as the real thing, so
// editSlider can swap one for the other and everything built on top (the
// arrow-key registry, the armed highlight, the value readout) keeps
// working unchanged.
//
// DragGesture(minimumDistance: 0) rather than a drag-only gesture: it makes
// a plain CLICK anywhere on the track jump the thumb there, which is what
// the platform slider does and what the hand-drawn one would otherwise
// lose.
private struct GradientTrackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gradient: LinearGradient
    var onEditingChanged: (Bool) -> Void = { _ in }

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 16
    private let rowHeight: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            // The thumb's LEADING edge travels across (width - thumbSize),
            // so its CENTER stays inside the track at both ends instead of
            // hanging half-off — hence every conversion below goes through
            // `usable` and offsets by half a thumb.
            let usable = max(proxy.size.width - thumbSize, 1)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (value - range.lowerBound) / span : 0
            let clamped = min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(gradient)
                    .frame(height: trackHeight)
                    .overlay(
                        Capsule()
                            .stroke(AppColors.ink.opacity(0.18), lineWidth: 0.5)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle()
                            .stroke(AppColors.ink.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: usable * CGFloat(clamped))
            }
            .frame(width: proxy.size.width, height: rowHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onEditingChanged(true)
                        let x = min(max(drag.location.x - thumbSize / 2, 0), usable)
                        value = range.lowerBound + Double(x / usable) * span
                    }
                    .onEnded { _ in
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: rowHeight)
    }
}

private struct EditToolButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isActive ? AppColors.hoverInk : AppColors.ink)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? AppColors.panelAlt : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            // Same fix as maskAddButton/PanelActionButtonStyle above (see
            // their doc comments) — without an explicit content shape, a
            // Button's hit-test area can fall back to just its rendered
            // glyph's own ink bounds rather than this style's full 30×30
            // box, especially right after a layout pass elsewhere in the
            // panel changes this section's height (e.g. aspectRatioRow/
            // Reset Crop/Done appearing under Crop & Rotate when isCropping
            // flips). Reported directly: the Crop button not responding to
            // the first click, "waking up" only after clicking a DIFFERENT
            // button (Patch) that already had this fix — same bug class,
            // different button, not something specific to Crop. Fixed at
            // the STYLE level so it covers every button using
            // EditToolButtonStyle (Rotate Left/Right, Crop, and any other
            // fixed-size icon tool button), not just this one report.
            .contentShape(Rectangle())
    }
}

// Same visual language as EditToolButtonStyle (clear fill, subtle border,
// press scale-down) but sized to the available width instead of a fixed
// 30×30 — for the "+ Radial / Graduated / Brush" row, whose two-line
// icon+label content needs more room than a single glyph does.
private struct MaskAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(AppColors.ink)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// Full-width bordered row, used via panelActionButton for every action
// button at the bottom of the Develop panel. `isProminent` (Export Edited
// Copy/Export All Edited) gets a filled background + semibold weight so
// the panel's two "finishing" actions read as visually distinct from the
// plain utility rows above (Copy/Paste Settings, Syncing, Reset All) —
// same bordered-pill language as MaskAddButtonStyle just above, so the
// whole panel reads as one consistent system rather than mixing this with
// the borderless ShowHeaderButtonStyle it replaced here (that style is
// still correct/unchanged for its original job, ShowGrid's HORIZONTAL
// header bar — just wasn't a fit for a narrow vertical sidebar).
private struct PanelActionButtonStyle: ButtonStyle {
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Figtree", size: 12).weight(isProminent ? .semibold : .medium))
            .foregroundColor(AppColors.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isProminent ? AppColors.panelAlt : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppColors.border.opacity(isProminent ? 0.9 : 0.6), lineWidth: isProminent ? 1.4 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Rectangle())
    }
}

// Small text-pill style for the crop tool's aspect-ratio row — same
// language as EditToolButtonStyle's isActive highlight, just sized to a
// short label instead of a fixed icon square.
private struct AspectRatioButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Figtree", size: 11).weight(.medium))
            .foregroundColor(isActive ? AppColors.hoverInk : AppColors.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? AppColors.panelAlt : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            // Same fix as EditToolButtonStyle just above — see its doc
            // comment.
            .contentShape(Rectangle())
    }
}
