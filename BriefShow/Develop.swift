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
    var vignette: Double = 0        // 0...1
    var rotationQuarterTurns: Int = 0   // 0...3, applied in 90° steps
    var straightenDegrees: Double = 0   // -45...45, fine rotation
    var crop: EditCropRect?             // nil = uncropped
    var localAdjustments: [LocalAdjustment] = []   // masks — see LocalAdjustment

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
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        rotationQuarterTurns = try c.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
        straightenDegrees = try c.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        crop = try c.decodeIfPresent(EditCropRect.self, forKey: .crop)
        localAdjustments = try c.decodeIfPresent([LocalAdjustment].self, forKey: .localAdjustments) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, saturation, vibrance
        case temperature, tint, sharpness, vignette, rotationQuarterTurns, straightenDegrees, crop
        case localAdjustments
    }

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && whites == 0 && blacks == 0
            && saturation == 0 && vibrance == 0 && temperature == 0 && tint == 0
            && sharpness == 0 && vignette == 0 && rotationQuarterTurns == 0
            && straightenDegrees == 0 && crop == nil && localAdjustments.isEmpty
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

// One local adjustment: a mask (exactly one of radial/graduated/brush is
// non-nil, matching `type`) plus its own tonal/color settings. `isEnabled`
// lets the user preview with a mask temporarily switched off without
// losing/deleting it.
struct LocalAdjustment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var type: LocalMaskType
    var radial: RadialMaskGeometry?
    var graduated: GraduatedMaskGeometry?
    var brush: BrushMaskGeometry?
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
            previewFilter.isDraftModeEnabled = false
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

        if settings.vignette > 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = output
            filter.radius = 1.6
            filter.intensity = Float(settings.vignette)
            output = filter.outputImage ?? output
        }

        if !settings.localAdjustments.isEmpty {
            output = applyLocalAdjustments(settings.localAdjustments, to: output)
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
            guard adjustment.isEnabled, !adjustment.settings.isNeutral else {
                continue
            }
            guard let mask = maskImage(for: adjustment, extent: extent) else {
                continue
            }

            let adjusted = applyLocalToneColorDetail(adjustment.settings, to: output)

            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = output
            blend.maskImage = mask
            output = blend.outputImage ?? output
        }

        return output
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

        window.contentView = NSHostingView(
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

// MARK: - Main view

struct DevelopView: View {
    let photoURLs: [URL]
    let initialSelection: URL?
    let onClose: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var selectedURL: URL?
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

    // Presets: a global, persisted library of full-settings snapshots (see
    // PhotoEditPresetStore). Copy/paste: a lightweight in-memory clipboard
    // that only lives for this Develop window session — deliberately not
    // persisted, since it's meant for "copy from A, paste onto B" within
    // one sitting, not a saved look (that's what a preset is for).
    @State private var presets: [PhotoEditPreset] = PhotoEditPresetStore.loadAll()
    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var settingsClipboard: PhotoEditSettings?

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
    // Drag-start snapshots for the radial/graduated on-canvas handles —
    // same pattern as dragStartCrop: captured on the first onChanged of a
    // drag, cleared on onEnded, so each drag computes its delta against a
    // stable baseline instead of the (already-mutated) live value.
    @State private var radialDragStart: RadialMaskGeometry?
    @State private var graduatedDragStart: GraduatedMaskGeometry?

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
        HStack(spacing: 0) {
            filmstrip

            Divider()

            VStack(spacing: 0) {
                topBar

                Divider()

                centerPreview
            }
            .frame(maxWidth: .infinity)

            Divider()

            adjustmentPanel
        }
        .background(AppColors.background)
        .onAppear {
            if selectedURL == nil, let initial = initialSelection ?? photoURLs.first {
                selectPhoto(initial)
            }
        }
        .onChange(of: settings) { _ in scheduleRender() }
        .onChange(of: pendingCrop) { _ in
            if isCropping {
                scheduleRender()
            }
        }
        .onChange(of: showOriginal) { _ in renderNow() }
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(photoURLs, id: \.self) { url in
                    filmstripThumbnail(for: url)
                }
            }
            .padding(10)
        }
        .frame(width: 120)
        .background(AppColors.panel)
    }

    private func filmstripThumbnail(for url: URL) -> some View {
        let isSelected = selectedURL == url
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
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? accentColor : Color.clear, lineWidth: 2.5)
            )

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
            selectPhoto(url)
        }
        .onAppear {
            loadFilmstripThumbnail(for: url)
        }
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

                    Image(nsImage: displayedImage)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                    if isCropping {
                        cropOverlay(frame: fitted, containerSize: proxy.size)
                    } else if let index = selectedAdjustmentIndex {
                        localAdjustmentOverlay(settings.localAdjustments[index], frame: fitted)
                    }
                } else if isLoadingPreview {
                    ProgressView()
                } else {
                    Text("Select a photo from the filmstrip")
                        .font(.custom("Figtree", size: 13))
                        .foregroundColor(AppColors.muted)
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

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (containerSize.width - width) / 2, y: (containerSize.height - height) / 2, width: width, height: height)
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
                .stroke(Color.white, lineWidth: 1.5)
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
                .stroke(accentColor, lineWidth: 1.5)
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
            .stroke(accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
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
        ZStack {
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
                    style: StrokeStyle(lineWidth: max(brushSize * frame.width, 2), lineCap: .round, lineJoin: .round)
                )
                .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in paintBrush(at: value.location, frame: frame) }
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

                copyPasteRow
                resetButton
                exportButton
                exportAllButton
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

            editSlider("Straighten", value: straightenBinding, range: -45...45) {
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
            editSlider("Exposure", value: $settings.exposure, range: -3...3) { String(format: "%+.2f", $0) }
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
            editSlider("Temperature", value: $settings.temperature, range: -1...1)
            editSlider("Tint", value: $settings.tint, range: -1...1)
            editSlider("Saturation", value: $settings.saturation, range: -1...1)
            editSlider("Vibrance", value: $settings.vibrance, range: -1...1)
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Detail & Effects")
            editSlider("Sharpness", value: $settings.sharpness, range: 0...1) { String(format: "%.0f", $0 * 100) }
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
        }
        // NOT EditToolButtonStyle — that style hard-codes a 30×30 frame
        // sized for a single icon glyph (Rotate/Crop), which would clip
        // "Graduated"'s two-line icon+label content. This sizes to the
        // available width instead (three equal-width buttons in an HStack).
        .buttonStyle(MaskAddButtonStyle())
    }

    private func maskTypeIcon(_ type: LocalMaskType) -> String {
        switch type {
        case .radial: return "circle.dashed"
        case .graduated: return "rectangle.lefthalf.filled"
        case .brush: return "paintbrush.pointed"
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
                editSlider("Feather", value: radialFeatherBinding, range: 0...1) { String(format: "%.0f", $0 * 100) }

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
                editSlider("Brush Size", value: $brushSize, range: 0.01...0.3) { String(format: "%.0f", $0 * 100) }
                editSlider("Hardness", value: $brushHardness, range: 0...1) { String(format: "%.0f", $0 * 100) }
                if !(adjustment.brush?.strokes.isEmpty ?? true) {
                    Button("Clear Strokes") {
                        clearBrushStrokes(at: index)
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                }
            }

            Divider()

            editSlider("Exposure", value: localAdjustmentBinding(\.exposure), range: -3...3) { String(format: "%+.2f", $0) }
            editSlider("Contrast", value: localAdjustmentBinding(\.contrast), range: -1...1)
            editSlider("Highlights", value: localAdjustmentBinding(\.highlights), range: -1...1)
            editSlider("Shadows", value: localAdjustmentBinding(\.shadows), range: -1...1)
            editSlider("Whites", value: localAdjustmentBinding(\.whites), range: -1...1)
            editSlider("Blacks", value: localAdjustmentBinding(\.blacks), range: -1...1)
            editSlider("Temperature", value: localAdjustmentBinding(\.temperature), range: -1...1)
            editSlider("Tint", value: localAdjustmentBinding(\.tint), range: -1...1)
            editSlider("Saturation", value: localAdjustmentBinding(\.saturation), range: -1...1)
            editSlider("Vibrance", value: localAdjustmentBinding(\.vibrance), range: -1...1)
            editSlider("Sharpness", value: localAdjustmentBinding(\.sharpness), range: 0...1) { String(format: "%.0f", $0 * 100) }
        }
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
                case .brush: return false
                }
            },
            set: { newValue in
                guard let index = selectedAdjustmentIndex else {
                    return
                }
                switch settings.localAdjustments[index].type {
                case .radial: settings.localAdjustments[index].radial?.invert = newValue
                case .graduated: settings.localAdjustments[index].graduated?.invert = newValue
                case .brush: break
                }
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

    private func editSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String = { String(format: "%+.0f", $0 * 100) }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.ink)

                Spacer()

                Text(format(value.wrappedValue))
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .monospacedDigit()
            }

            Slider(value: value, in: range)
        }
    }

    // Copy the current photo's full settings into an in-memory clipboard
    // (see settingsClipboard) and paste them onto whichever photo is
    // selected when Paste is pressed — deliberately one photo at a time,
    // no multi-select (see BRIEFSHOW_DEVELOP_NOTES.md #5).
    private var copyPasteRow: some View {
        HStack(spacing: 10) {
            Button {
                settingsClipboard = settings
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text("Copy Settings")
                }
            }
            .buttonStyle(ShowHeaderButtonStyle())
            .opacity(settings.isNeutral ? 0.4 : 1)
            .disabled(settings.isNeutral)

            Button {
                pasteSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Paste Settings")
                }
            }
            .buttonStyle(ShowHeaderButtonStyle())
            .opacity(settingsClipboard == nil ? 0.4 : 1)
            .disabled(settingsClipboard == nil)
        }
    }

    private var resetButton: some View {
        Button("Reset All") {
            settings = PhotoEditSettings()
            pendingCrop = .full
            cropIsAutoFitted = false
            selectedLocalAdjustmentID = nil
        }
        .buttonStyle(ShowHeaderButtonStyle())
        .opacity(settings.isNeutral ? 0.4 : 1)
        .disabled(settings.isNeutral)
    }

    private var exportButton: some View {
        Button {
            exportEditedCopy()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text("Export Edited Copy")
            }
        }
        .buttonStyle(ShowHeaderButtonStyle())
        .opacity(fullBaseImage == nil ? 0.4 : 1)
        .disabled(fullBaseImage == nil)
    }

    // Exports every photo in this folder (photoURLs — the same list the
    // filmstrip shows, not just the current selection) that has a saved
    // edit, skipping untouched ones — one destination-folder picker
    // instead of Save-panel-per-photo. Count is read fresh on every body
    // re-render (not cached), so it stays accurate as edits are made/reset
    // while this panel is open.
    private var exportAllButton: some View {
        let editedCount = photoURLs.filter { PhotoEditStore.hasEdits($0) }.count

        return Button {
            exportAllEditedPhotos()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up.on.square")
                Text("Export All Edited (\(editedCount))")
            }
        }
        .buttonStyle(ShowHeaderButtonStyle())
        .opacity(editedCount == 0 ? 0.4 : 1)
        .disabled(editedCount == 0)
    }

    // MARK: Actions

    private func selectPhoto(_ url: URL) {
        guard url != selectedURL else {
            return
        }

        selectedURL = url
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
    }

    // Tapping the already-selected mask's row deselects it (back to
    // editing global sliders) — same "tap again to close" affordance as
    // the crop tool's own icon button.
    private func selectLocalAdjustment(_ id: UUID) {
        selectedLocalAdjustmentID = (selectedLocalAdjustmentID == id) ? nil : id
        if selectedLocalAdjustmentID != nil {
            isCropping = false
        }
        activeBrushStrokePoints = []
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

    // A short debounce so dragging a slider re-renders once it settles
    // rather than on every intermediate value.
    private func scheduleRender() {
        renderWorkItem?.cancel()
        let workItem = DispatchWorkItem { renderNow() }
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

        let effectiveSettings = showOriginal ? PhotoEditSettings() : settings
        let cropEnabled = !isCropping
        let source = previewBaseImage
        let photoAtRenderTime = selectedURL

        developRenderQueue.async(qos: .userInteractive) {
            let rendered = PhotoEditRenderer.render(effectiveSettings, on: source, applyCrop: cropEnabled)
            guard let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent) else {
                return
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let bins = PhotoEditRenderer.luminanceHistogram(of: rendered)

            DispatchQueue.main.async {
                guard selectedURL == photoAtRenderTime else {
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = selectedURL.deletingPathExtension().lastPathComponent + " Edited.jpg"
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
                if let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
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
                        if let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                            // Same "<name> Edited.jpg" naming as the
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
                                .appendingPathExtension("jpg")
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
    }
}
