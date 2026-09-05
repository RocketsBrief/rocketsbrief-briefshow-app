//
//  Develop.swift
//  BriefShow
//
//  "Create" — a standalone, Lightroom-style non-destructive photo editor,
//  opened from ShowGrid's own "Create" header button (see ContentView.swift).
//  Everything in here is still named Develop: the window was renamed, the code
//  was not, and chasing the rename through nine thousand lines would be a large
//  diff that changes no behaviour.
//  Deliberately kept separate from PhotoShowSheet (ShowGrid's grid/loupe/
//  rating screen) and from the Kousei/Kirigami/Origami slideshow pipeline —
//  editing a photo here never touches the original file on disk and never
//  affects a slideshow export. It only writes a small per-photo settings
//  record (see PhotoEditStore) that this screen reads back on reopen, and
//  "Export Edited Copy" writes a brand-new file alongside the original.
//

import SwiftUI
import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

// MARK: - Edit model

// Every field here is a delta around 0 = "untouched" (never an absolute
// filter parameter), so a fresh PhotoEditSettings() is trivially "no edit
// at all" (see isNeutral) and each slider can be reset independently just
// by setting it back to 0.
/// The eight colour bands Lightroom's Colour Mixer works in, at Adobe's own
/// hue centres.
///
/// The centres are not evenly spaced and that is deliberate on Adobe's part:
/// the warm end of the wheel is where skin lives, so red/orange/yellow sit 30°
/// apart while green/aqua/blue sit 60° apart. Copying the spacing is what makes
/// an imported preset land on the same colours it did in Lightroom.
enum ColorBand: String, CaseIterable, Codable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }

    var centreDegrees: Double {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 60
        case .green: return 120
        case .aqua: return 180
        case .blue: return 240
        case .purple: return 285
        case .magenta: return 315
        }
    }

    /// The swatch on the band's own button — the band's hue at full saturation.
    var swatch: Color {
        Color(hue: centreDegrees / 360, saturation: 0.85, brightness: 0.95)
    }
}

/// What one band's three sliders hold. All -1...1, zero being untouched.
struct ColorMixerBand: Codable, Equatable {
    var hue: Double = 0         // -1...1 → ±30° of hue rotation
    var saturation: Double = 0  // -1 = grey, +1 = twice as saturated
    var luminance: Double = 0   // -1 = darker, +1 = brighter

    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

/// Lightroom's Colour Mixer / HSL panel.
///
/// Eight named fields rather than an array or a dictionary: this is stored in
/// every photo's settings record and in every preset, so its Codable shape is
/// something the app has to live with. A named field can be added or left
/// alone; an array's meaning depends on its length and on nobody ever
/// reordering it.
struct ColorMixer: Codable, Equatable {
    var red = ColorMixerBand()
    var orange = ColorMixerBand()
    var yellow = ColorMixerBand()
    var green = ColorMixerBand()
    var aqua = ColorMixerBand()
    var blue = ColorMixerBand()
    var purple = ColorMixerBand()
    var magenta = ColorMixerBand()

    var isNeutral: Bool {
        ColorBand.allCases.allSatisfy { self[$0].isNeutral }
    }

    subscript(band: ColorBand) -> ColorMixerBand {
        get {
            switch band {
            case .red: return red
            case .orange: return orange
            case .yellow: return yellow
            case .green: return green
            case .aqua: return aqua
            case .blue: return blue
            case .purple: return purple
            case .magenta: return magenta
            }
        }
        set {
            switch band {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .aqua: aqua = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }
}

struct PhotoEditSettings: Codable, Equatable {
    var exposure: Double = 0        // EV, roughly -3...3
    var contrast: Double = 0        // -1...1
    // ⚠️ LIGHTROOM'S SIGN since 05.09.2026: positive BRIGHTENS the highlights,
    // negative recovers them — the same direction the number on the slider now
    // means in Lightroom. It used to be inverted. Records written before the
    // flip carry no `schemaVersion` and are migrated on decode, so a photo
    // edited under an older build still renders exactly as it did.
    var highlights: Double = 0      // -1 (recover blown highlights) ...+1 (brighter)
    var shadows: Double = 0         // -1 (darken) ...1 (lift)
    var whites: Double = 0          // -1 (dull white point) ...1 (brighter/clips more)
    var blacks: Double = 0          // -1 (crush black point) ...1 (lift/brighter)
    var saturation: Double = 0      // -1...1
    var vibrance: Double = 0        // -1...1
    var temperature: Double = 0     // -1 (cooler) ...1 (warmer)
    var tint: Double = 0            // -1 (green) ...1 (magenta)
    var sharpness: Double = 0       // 0...1
    var texture: Double = 0         // -1 (smooth/soften mid-frequency detail — "younger, softer" portrait skin) ...1 (bring skin/fabric/hair texture out), see PhotoEditRenderer.render.
    var clarity: Double = 0         // -1...1 — Lightroom-style local (midtone) contrast: unsharp above zero, a mix toward a blur of the same radius below it. See PhotoEditRenderer.render.
    var dehaze: Double = 0          // -1...1 — contrast/saturation/black-point APPROXIMATION of Lightroom's Dehaze, not a real dark-channel-prior algorithm; negative adds haze rather than removing it. See PhotoEditRenderer.render.
    var softGlow: Double = 0        // 0...1 — diffusion/"soft focus" glow (blurred copy screen-blended back over the original), see PhotoEditRenderer.render.
    var vignette: Double = 0        // -1...1 — positive darkens the corners, negative lightens them.
    // The three shape controls Lightroom's Post-Crop Vignetting has beside its
    // Amount. Every default here reproduces EXACTLY the vignette this app drew
    // before they existed — 0.5 midpoint is the old radius of 1, 0.5 feather is
    // the old outer radius of √2, 0 roundness is the old frame-shaped ellipse —
    // so nothing already edited changes, and an imported preset now has
    // somewhere to put its shape. See PhotoEditRenderer.render.
    var vignetteMidpoint: Double = 0.5   // 0...1 — how far out the darkening starts
    var vignetteFeather: Double = 0.5    // 0...1 — 0 a hard edge, 1 very soft
    var vignetteRoundness: Double = 0    // -1 (squarer) ...1 (circular)
    // Lightroom's Sharpening Radius. 1 is Core Image's own default radius, so
    // the default leaves every existing photo rendering exactly as it did.
    var sharpenRadius: Double = 1        // 0.5...3 — Lightroom's own range
    var colorMixer = ColorMixer()   // Lightroom's HSL panel — see ColorMixer.
    var rotationQuarterTurns: Int = 0   // 0...3, applied in 90° steps
    var straightenDegrees: Double = 0   // -45...45, fine rotation
    var crop: EditCropRect?             // nil = uncropped
    // Which ratio the crop tool is LOCKED to, if any. Stored beside the crop
    // rather than kept as tool state, because the rectangle alone does not say
    // whether dragging a handle should hold 4:3 or go free — see
    // CropAspectRatioOption. Not part of isNeutral, for the same reason the
    // vignette's shape controls are not: on its own it changes no pixel.
    var cropAspect: CropAspectRatioOption = .free
    var localAdjustments: [LocalAdjustment] = []   // masks — see LocalAdjustment
    var layers: [ImageLayer] = []        // pasted cut/copied pieces — see ImageLayer

    /// Which meaning the numbers in this record carry.
    ///
    /// 1 (or absent) — everything written before 05.09.2026, where Highlights
    /// was inverted with respect to Lightroom. 2 — Highlights carries
    /// Lightroom's sign. Written on every encode, so a migrated record is
    /// migrated exactly once; without it the flip would apply again on every
    /// decode and the photo would oscillate.
    var schemaVersion: Int = PhotoEditSettings.currentSchemaVersion
    static let currentSchemaVersion = 2

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
        // Migration, and it must come with the version read below: a record
        // from before the sign flip means the OPPOSITE of what it says.
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
        // Absent in anything saved before these existed, and the fallbacks are
        // the values that reproduce the old drawing — so an old record decodes
        // to a photo that looks the same, not merely to a photo that decodes.
        vignetteMidpoint = try c.decodeIfPresent(Double.self, forKey: .vignetteMidpoint) ?? 0.5
        vignetteFeather = try c.decodeIfPresent(Double.self, forKey: .vignetteFeather) ?? 0.5
        vignetteRoundness = try c.decodeIfPresent(Double.self, forKey: .vignetteRoundness) ?? 0
        sharpenRadius = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? 1
        colorMixer = try c.decodeIfPresent(ColorMixer.self, forKey: .colorMixer) ?? ColorMixer()
        rotationQuarterTurns = try c.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
        straightenDegrees = try c.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        crop = try c.decodeIfPresent(EditCropRect.self, forKey: .crop)
        // Absent from every record written before 2.09. — and .free is what
        // those photos behaved as, so an old edit decodes to the same photo it
        // always was, not merely to a photo that decodes.
        cropAspect = try c.decodeIfPresent(CropAspectRatioOption.self, forKey: .cropAspect) ?? .free
        localAdjustments = try c.decodeIfPresent([LocalAdjustment].self, forKey: .localAdjustments) ?? []
        layers = try c.decodeIfPresent([ImageLayer].self, forKey: .layers) ?? []

        // ⚠️ The Highlights migration, and it is the reason `schemaVersion`
        // exists. Before 05.09.2026 a positive Highlights DARKENED, the
        // opposite of Lightroom and of the number the slider showed. A record
        // written then means the negative of what it says, so it is flipped
        // here — once. The version is written on every encode, so a record
        // that has already been migrated is left alone; without it the flip
        // would apply on every decode and the photo would oscillate between
        // two looks with nobody touching a slider.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if schemaVersion < 2 {
            highlights = -highlights
            // Masks and pasted layers carry their own copy of the same tone
            // controls through the same curve, so they migrate with it.
            for index in localAdjustments.indices {
                localAdjustments[index].settings.highlights = -localAdjustments[index].settings.highlights
            }
            for index in layers.indices {
                layers[index].adjustments.highlights = -layers[index].adjustments.highlights
            }
            schemaVersion = PhotoEditSettings.currentSchemaVersion
        }
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, saturation, vibrance
        case temperature, tint, sharpness, texture, clarity, dehaze, softGlow, vignette
        case vignetteMidpoint, vignetteFeather, vignetteRoundness, sharpenRadius
        case colorMixer
        case rotationQuarterTurns, straightenDegrees, crop, cropAspect
        case localAdjustments, layers
        case schemaVersion
    }

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && whites == 0 && blacks == 0
            && saturation == 0 && vibrance == 0 && temperature == 0 && tint == 0
            && sharpness == 0 && texture == 0 && clarity == 0 && dehaze == 0 && softGlow == 0
            // The vignette's shape and the sharpening radius are deliberately
            // NOT counted. They are the SHAPE of an effect, not the effect: a
            // photo with Vignette at 0 is unvignetted whatever its midpoint
            // says, and counting them would light up "this photo has edits" —
            // and with it Flatten, Reset and the export lists — for a slider
            // that is doing nothing.
            && vignette == 0 && colorMixer.isNeutral && rotationQuarterTurns == 0
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

    /// What the render that feeds the encoder should be done at.
    ///
    /// The panel tells the client that PNG and TIFF are "lossless — every
    /// export is full quality", and that was only half true: every export ran
    /// through `createCGImage(_:from:)`, whose default is 8 bits per component,
    /// so a 16-bit-capable format was handed 8-bit pixels to be lossless about.
    /// Measured on a 5176x3448 .NEF: TIFF 20 MB at depth 8 against 107 MB at
    /// depth 16, PNG 18 MB against 75 MB, for 0.07 s more render time. The
    /// dimensions were never the problem — they are native either way — but the
    /// tones a grade was pushed through were being rounded on the way out.
    ///
    /// JPEG stays 8-bit because JPEG IS 8-bit; asking for 16 there costs the
    /// render and changes nothing in the file.
    var renderFormat: CIFormat { isLossy ? .RGBA8 : .RGBA16 }

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
    // How far the crop FRAME itself is turned, in degrees, positive =
    // clockwise on screen. The photograph does NOT move: this turns the
    // rectangle over a still picture, which is what was asked for —
    // „da mogu da rotiram krop (ne sliku)" — and it is a different thing
    // from `PhotoEditSettings.straightenDegrees`, which turns the picture
    // and leaves the frame upright.
    //
    // The two are deliberately independent and may sit at different angles.
    // A photograph straightened by 2° and then framed at a 5° tilt is a
    // real thing a photographer asks for, and folding this into
    // straightenDegrees would have made the second impossible to express.
    //
    // x/y/width/height stay the UNROTATED box; the angle turns it about its
    // own centre. Every piece of code that only ever cared where the crop
    // roughly is therefore still reads right, and the rotation lives in one
    // place instead of being baked into four numbers.
    //
    // ⚠️ Turned in a space PROPORTIONAL TO PIXELS, never in fraction space.
    // x/y/width/height are fractions of width and of height, and those two
    // axes have different scales unless the photograph is square — a 45°
    // turn of a fraction rectangle is not a 45° turn of the picture. See
    // constrainedToImage and PhotoEditRenderer.render, both of which convert
    // first.
    var angle: Double = 0

    static let full = EditCropRect(x: 0, y: 0, width: 1, height: 1)

    // Written out by hand because declaring ANY initializer in a struct's body
    // takes the memberwise one away, and `EditCropRect(x:y:width:height:)` is
    // called in a dozen places that have no opinion about the angle. The
    // default on `angle:` is what keeps every one of them compiling unchanged.
    init(x: Double, y: Double, width: Double, height: Double, angle: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.angle = angle
    }

    // Spelled out rather than synthesized so `angle`'s key is written down
    // next to the decoder that has to survive its absence.
    private enum CodingKeys: String, CodingKey {
        case x, y, width, height, angle
    }

    // ⚠️ THIS IS THE MIGRATION, and it is the reason the client was asked
    // before any of this was written. Every crop already on the client's disk
    // was written without an `angle` key. Synthesized decoding THROWS on a
    // missing key, and `PhotoEditStore.allSettings` drops any record that
    // fails to decode — so the synthesized version would have silently
    // deleted every existing crop on the first launch of the new build.
    //
    // ⚠️ IT LIVES IN THE BODY, NOT IN AN EXTENSION, and that is not a style
    // choice. It was written in an extension first — where the memberwise
    // initializer survives on its own, which is tidier — and
    // `Tools/run-editsettings-decode-test.py` FAILED all 25 crops: that
    // harness pulls named declarations out of this file by brace balance and
    // never sees an extension. A decoder the test cannot reach is a decoder
    // nobody checks again, and what it is guarding against is "every edit in
    // the store is wiped". So it sits here, where the test reads it.
    //
    // Run that test after touching this. It decodes the client's own records,
    // and it exists because this exact class of change has already cost a
    // scare once (KORAK 69).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        // 0 is not just "a safe default" — it is what every old record MEANT.
        // An unrotated frame is exactly how those photographs have always
        // rendered, so an old edit decodes to the same picture it was, not
        // merely to a picture that decodes.
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
    }
}

// Quick aspect-ratio presets offered on the crop tool's own row of buttons.
//
// This USED to say "not persisted anywhere", and that was the whole of the
// 1.09. report: a client synced 4:3 across a shoot, opened one of those photos,
// dragged a crop handle, and got free-form — because the RECTANGLE travelled
// and the LOCK did not. It is stored on PhotoEditSettings now, so it survives
// closing the photo and it rides along with Sync's "Crop & Rotate" category.
//
// String raw values, not the synthesized Int ordinals: these end up in a JSON
// record on the client's disk, and ordinals would silently re-point every
// stored ratio the day a case is inserted in the middle of this list.
enum CropAspectRatioOption: String, CaseIterable, Identifiable, Codable {
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

// The part of PhotoEditSettings that makes sense applied to a LAYER or a
// masked region rather than to the whole photo. No crop/rotate/straighten —
// geometry is always global.
//
// ⚠️ This used to be tone and colour ONLY, and the client reported the gap in
// as many words: *„kada selektujem ljude… nemam iste opcije za edit kao
// celokupan edit, a treba da bude sve kao edit za sliku"*. Texture, Clarity,
// Dehaze, Soft Glow, the Colour Mixer, the sharpen radius and Vignette are all
// here now, and they run through the SAME functions `render` runs for the
// photo (applySharpen, applyTexture, … — extracted for exactly this, and proved
// pixel-identical to the code they came from by
// Tools/run-effect-extraction-test.py), in the same order, so a layer's +40
// Clarity means what the photo's +40 Clarity means.
//
// ⚠️ VIGNETTE, and the note this replaces. The old comment here said a
// vignette masked to an arbitrary region "isn't a vignette anymore", and for a
// MASK that is still true — a radial darkening confined to a brush stroke is
// not what anybody means by the word. On a LAYER it is a different matter: a
// layer has its own rectangle, and darkening ITS corners is a real thing to
// want on a cut-out. It is offered in the layer panel only; the mask panel
// does not show it.
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

    // Everything below arrived after records were already on the client's
    // disk. See init(from:) — it is what keeps those records readable.
    var sharpenRadius: Double = 1
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var softGlow: Double = 0
    var vignette: Double = 0
    var vignetteMidpoint: Double = 0.5
    var vignetteFeather: Double = 0.5
    var vignetteRoundness: Double = 0
    var colorMixer = ColorMixer()

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && whites == 0 && blacks == 0 && saturation == 0 && vibrance == 0
            && temperature == 0 && tint == 0 && sharpness == 0
            && texture == 0 && clarity == 0 && dehaze == 0 && softGlow == 0
            && vignette == 0 && colorMixer.isNeutral
            // sharpenRadius, and the three vignette shape dials, are NOT in
            // here on purpose: they are modifiers, not effects. At sharpness 0
            // a radius changes nothing, and with vignette 0 a midpoint changes
            // nothing — counting them would make a layer that looks untouched
            // report itself as edited.
    }

    init() {}

    /// ⚠️ WRITTEN BY HAND, and it has to stay that way.
    ///
    /// Swift's synthesised decoder does NOT fall back to a property's default
    /// when a key is missing — it throws. Every layer and every mask already
    /// on the client's disk was encoded before the fields above existed, so
    /// with the synthesised version the first added field would have made
    /// every one of those records fail to decode: not a wrong number, the
    /// whole record gone. `PhotoEditSettings` learned this already and decodes
    /// the same way; `Tools/run-editsettings-decode-test.py` is what watches it.
    ///
    /// So: decodeIfPresent for everything, old fields included. A record
    /// written by any version of this app, before or after today, reads back
    /// with the values it had and defaults for what it never knew about.
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
        sharpenRadius = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? 1
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        softGlow = try c.decodeIfPresent(Double.self, forKey: .softGlow) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        vignetteMidpoint = try c.decodeIfPresent(Double.self, forKey: .vignetteMidpoint) ?? 0.5
        vignetteFeather = try c.decodeIfPresent(Double.self, forKey: .vignetteFeather) ?? 0.5
        vignetteRoundness = try c.decodeIfPresent(Double.self, forKey: .vignetteRoundness) ?? 0
        colorMixer = try c.decodeIfPresent(ColorMixer.self, forKey: .colorMixer) ?? ColorMixer()
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
/// Where a layer's PIXELS live: files on disk, not inside the settings record.
///
/// ⚠️ Why this exists, measured before it was written. Every edit in this app
/// lives in one JSON blob in UserDefaults, re-encoded 0.5s after any change
/// (PhotoEditStore.flushNow) and decoded when the store is first read. On the
/// client's own machine, 125 photos:
///
/// | | |
/// |---|---|
/// | whole store | **32.4 MB** |
/// | of that, layer pixels | **31.5 MB — 97%** |
/// | every slider, mask and crop of all 125 photos | 932 KB |
/// | a record with no layers | ~1 KB |
/// | encoding the store, on the MAIN THREAD | **55 ms** |
/// | decoding it when the window opens | **35 ms** |
/// | the same store without layer pixels | **1.9 / 1.1 ms** |
///
/// Two photos alone accounted for 22 MB of it. That is already a hitch after
/// every pause in editing, but the reason it had to be fixed NOW is the
/// history feature: a history that snapshots settings is about 1 KB a step,
/// and one that drags a 12.8 MB layer along with every step is not a feature,
/// it is a fault.
///
/// ⚠️ NOTHING IN THE CLIENT'S OWN FOLDER IS TOUCHED BY ANY OF THIS. These
/// blobs are the app's own storage, beside the flattened copies. The imported
/// originals are not read, written, renamed or moved — layer pixels were never
/// in his folder to begin with.
enum LayerPixelStore {

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            return nil
        }
        // ⚠️ THE NAME ON DISK IS "BriefShow" AND IT STAYS THAT WAY.
        //
        // This is not the product's name, it is a PATH. The suite was renamed
        // to C4S Suite on 3.09 and a search-and-replace over string literals
        // rewrote this one too — which would have orphaned every blob already
        // written here, so the client's layers would sit in the list and show
        // nothing on the photo. The harness caught it; nothing else would have.
        // Same rule as the UserDefaults keys: what the client SEES is renamed,
        // what points at his data is not.
        let directory = base.appendingPathComponent("BriefShow/LayerPixels", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// CONTENT-ADDRESSED, and that is what makes this safe to call from
    /// `encode(to:)`.
    ///
    /// A name derived from the bytes means writing is idempotent: the second
    /// flush finds the file already there and does nothing. A name derived
    /// from, say, the layer's id would not — the same id can be handed new
    /// pixels (a bake, a fresh Select People), and the store would serve the
    /// old ones. The fingerprint is the same constant-time one the render
    /// cache uses, for the same reason: this runs per layer per flush, and
    /// hashing megabytes there would put back a smaller version of the cost
    /// being removed.
    static func name(for data: Data) -> String {
        "\(data.count)-\(fingerprint(data))"
    }

    private static func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        let count = data.count
        let starts = [0, count / 3, count / 2, max(0, count - 96)]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for start in starts {
                let end = min(start + 96, count)
                guard start < end else { continue }
                for i in start..<end {
                    hash = (hash ^ UInt64(raw[i])) &* 1099511628211
                }
            }
        }
        return hash
    }

    private static func fileURL(_ name: String) -> URL? {
        directory?.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_") + ".bin")
    }

    /// Writes the bytes once and hands back the name to store in their place.
    /// Returns nil if it could not be written — the caller then keeps the
    /// bytes inline, which is slower but never loses a layer.
    static func store(_ data: Data) -> String? {
        guard !data.isEmpty, let url = fileURL(name(for: data)) else {
            return nil
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Kept in memory once read: the same blob is asked for on every render of
    /// the photo it belongs to, and going back to the disk each time would
    /// trade one cost for another.
    private static var cache: [String: Data] = [:]
    private static let cacheLock = NSLock()

    static func data(for name: String) -> Data? {
        cacheLock.lock()
        if let hit = cache[name] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let url = fileURL(name), let data = try? Data(contentsOf: url) else {
            return nil
        }
        cacheLock.lock()
        cache[name] = data
        cacheLock.unlock()
        return data
    }
}

struct ImageLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String

    /// ⚠️ The pixels are NOT stored in this struct any more, and `imageData`
    /// below is a door to them rather than the thing itself. See
    /// LayerPixelStore for the measurements that forced it.
    ///
    /// Both halves are needed. `pixelRef` is the name of a blob on disk and is
    /// what gets encoded; `inlineImageData` holds bytes that have not been
    /// written yet — a layer just made by Select People, a paste, a cut fill —
    /// and is deliberately NOT encoded. Whichever is set, `imageData` answers.
    ///
    /// The win is on DECODE as much as on encode: a ref costs nothing to read,
    /// so opening the store no longer drags every layer of every photo into
    /// memory. The bytes arrive the first time something actually renders that
    /// layer.
    private var pixelRef: String?
    private var inlineImageData: Data?
    private var maskRef: String?
    private var inlineMaskData: Data?

    /// Reads and writes exactly as it always did, so every call site in the
    /// app is unchanged. Assigning marks the bytes as not-yet-written; the
    /// next encode stores them and records the ref.
    var imageData: Data {
        get {
            if let inlineImageData { return inlineImageData }
            if let pixelRef { return LayerPixelStore.data(for: pixelRef) ?? Data() }
            return Data()
        }
        set {
            inlineImageData = newValue
            pixelRef = nil
        }
    }
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var opacity: Double = 1     // 0...1
    var blendMode: LayerBlendMode = .normal
    var isEnabled: Bool = true

    /// This layer's OWN tone and colour, applied to its pixels before it is
    /// composited.
    ///
    /// The same struct the masks use, and for the same reason: it is
    /// exactly the subset of PhotoEditSettings that means anything applied
    /// to a region rather than to a whole photo — no geometry, no vignette.
    /// A second, near-identical struct for layers would be one more place
    /// for "which sliders are local" to drift.
    var adjustments = LocalAdjustmentSettings()

    /// Gaussian blur on this layer alone, 0...1, scaled to the picture
    /// rather than to pixels — see `PhotoEditRenderer.layerBlur`.
    var blur: Double = 0

    /// A soft alpha matte. When this is set the layer holds NO pixels of its
    /// own: it is a REGION of the photo underneath, and the renderer takes
    /// its pixels from there at render time.
    ///
    /// ⚠️ This exists because of where edits are stored. Every edit in this
    /// app lives in one JSON blob in UserDefaults, re-encoded on each flush
    /// (see PhotoEditStore.flushNow). A full-frame "Background" layer held
    /// as pixels would be tens of megabytes of PNG in there, rewritten
    /// every time any slider settles — which is not a heavy feature, it is
    /// a broken app. A mask is smooth and mostly flat, so a small one
    /// (`maskPNG` caps it at 1024px) upscales back with no visible
    /// difference and costs tens of KILObytes.
    ///
    /// It buys a second thing worth having: a derived layer is re-read from
    /// the photo on every render, so global sliders moved afterwards carry
    /// it along instead of leaving it behind as a frozen copy.
    /// The matte, through the same door as the pixels above and for the same
    /// reason — a full-frame matte is tens of KB, small next to a cut-out but
    /// not nothing once history multiplies it.
    var maskData: Data? {
        get {
            if let inlineMaskData { return inlineMaskData }
            if let maskRef { return LayerPixelStore.data(for: maskRef) }
            return nil
        }
        set {
            inlineMaskData = newValue
            maskRef = nil
        }
    }

    /// Rotation about the layer's own centre, in degrees.
    var rotationDegrees: Double = 0

    /// ⚠️ VESTIGIAL, and kept on purpose. Sky replacement was removed on
    /// 2.09.2026 (see SKY_ARCHIVE/BRIEFSHOW_SKY_NOTES.md), but this key is in
    /// records already on the client's disk. Decoding it and carrying it means
    /// a photo edited before the removal still round-trips unchanged instead of
    /// quietly losing a field — and if the feature ever comes back, the layers
    /// it made are still marked.
    var isSky: Bool = false

    /// Pixels of its own, or a region of the photo underneath.
    var isDerived: Bool { maskData != nil }

    init(id: UUID = UUID(), name: String, imageData: Data,
         x: Double, y: Double, width: Double, height: Double,
         opacity: Double = 1, blendMode: LayerBlendMode = .normal,
         isEnabled: Bool = true, adjustments: LocalAdjustmentSettings = LocalAdjustmentSettings(),
         blur: Double = 0, maskData: Data? = nil,
         isSky: Bool = false,
         rotationDegrees: Double = 0) {
        self.id = id
        self.name = name
        self.inlineImageData = imageData
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.opacity = opacity
        self.blendMode = blendMode
        self.isEnabled = isEnabled
        self.adjustments = adjustments
        self.blur = blur
        self.inlineMaskData = maskData
        self.isSky = isSky
        self.rotationDegrees = rotationDegrees
    }

    /// ⚠️ Hand-written for the same reason PhotoEditSettings' is, and the
    /// stakes here are higher.
    ///
    /// A layer saved before `adjustments` existed carries no key for it, and
    /// the SYNTHESIZED decoder throws on a missing key even when the
    /// property has a default. `PhotoEditStore.allSettings` DROPS anything
    /// that fails to decode — so relying on the synthesized one would have
    /// silently deleted every pasted layer anybody has ever saved, with no
    /// error anywhere. Every field added here from now on must be
    /// `decodeIfPresent` with a fallback.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        // ⚠️ MIGRATION, and it runs silently on the client's existing records.
        // A layer saved by any earlier build carries its pixels INLINE under
        // "imageData"; one saved from now on carries a "pixelRef" instead.
        // Both are read. An old record's bytes come in here and are written
        // out as a blob by the very next encode, so a store converts itself
        // the first time it is saved — no migration pass, no version flag, and
        // nothing lost if the app is killed halfway (the old key is still
        // there until the new one replaces it).
        if let ref = try c.decodeIfPresent(String.self, forKey: .pixelRef) {
            pixelRef = ref
            inlineImageData = nil
        } else {
            inlineImageData = try c.decodeIfPresent(Data.self, forKey: .imageData) ?? Data()
            pixelRef = nil
        }
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        blendMode = try c.decodeIfPresent(LayerBlendMode.self, forKey: .blendMode) ?? .normal
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        adjustments = try c.decodeIfPresent(LocalAdjustmentSettings.self, forKey: .adjustments)
            ?? LocalAdjustmentSettings()
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        if let ref = try c.decodeIfPresent(String.self, forKey: .maskRef) {
            maskRef = ref
            inlineMaskData = nil
        } else {
            inlineMaskData = try c.decodeIfPresent(Data.self, forKey: .maskData)
            maskRef = nil
        }
        isSky = try c.decodeIfPresent(Bool.self, forKey: .isSky) ?? false
        rotationDegrees = try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
    }

    /// ⚠️ Hand-written so the pixels go to disk instead of into the record.
    ///
    /// It WRITES as a side effect, which is unusual for an encoder and is the
    /// reason LayerPixelStore names blobs by their content: storing the same
    /// bytes twice is a `fileExists` check and nothing more, so the flush that
    /// runs after every edit does not touch the disk again for a layer that
    /// has not changed.
    ///
    /// If the write FAILS the bytes are encoded inline, exactly as before.
    /// That is slow and fat — and it is the right failure: a full disk must
    /// cost the client speed, never a layer.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)

        if let ref = pixelRef {
            try c.encode(ref, forKey: .pixelRef)
        } else if let bytes = inlineImageData, !bytes.isEmpty {
            if let ref = LayerPixelStore.store(bytes) {
                try c.encode(ref, forKey: .pixelRef)
            } else {
                try c.encode(bytes, forKey: .imageData)
            }
        }

        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(blendMode, forKey: .blendMode)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encode(blur, forKey: .blur)

        if let ref = maskRef {
            try c.encode(ref, forKey: .maskRef)
        } else if let bytes = inlineMaskData, !bytes.isEmpty {
            if let ref = LayerPixelStore.store(bytes) {
                try c.encode(ref, forKey: .maskRef)
            } else {
                try c.encode(bytes, forKey: .maskData)
            }
        }

        try c.encode(isSky, forKey: .isSky)
        try c.encode(rotationDegrees, forKey: .rotationDegrees)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, imageData, x, y, width, height, opacity, blendMode, isEnabled, adjustments
        case blur, maskData, isSky, rotationDegrees
        case pixelRef, maskRef
    }
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
        lock.lock()
        cachedSettings = all
        generation &+= 1
        pendingChangedURLs.insert(url)
        lock.unlock()
        scheduleFlush()
    }

    // MARK: Writing back

    // Writing is debounced; reading is not. Everything above reads
    // `cachedSettings`, which is updated synchronously, so nothing in the app
    // can observe a stale edit — the delay is only in how often the dictionary
    // is encoded and handed to UserDefaults.
    //
    // That matters because `setSettings` is called from `renderNow`, which
    // runs on a ~20ms throttle: dragging one slider for two seconds used to
    // JSON-encode the client's ENTIRE edit history, every photo of it, about a
    // hundred times. Same shape as the decode problem above — cost that grows
    // with how long the app has been used rather than with what is being done.
    //
    // Half a second, and flushed outright when the Create window closes, so
    // the window that owns the edits cannot go away with anything unwritten.
    private static let flushDelay: TimeInterval = 0.5
    private static var flushWorkItem: DispatchWorkItem?
    private static var pendingChangedURLs: Set<URL> = []

    private static func scheduleFlush() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { flushNow() }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay, execute: work)
    }

    /// Writes any pending changes out and tells the rest of the app which
    /// photos moved. Safe to call when nothing is pending.
    static func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil

        lock.lock()
        let snapshot = cachedSettings
        let changed = pendingChangedURLs
        pendingChangedURLs = []
        lock.unlock()

        guard let snapshot else {
            return
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: defaultsKey)

        guard !changed.isEmpty else {
            return
        }
        // Posted here rather than from setSettings so it is coalesced by the
        // same debounce: ShowGrid re-renders a thumbnail through the whole
        // edit pipeline when it hears this, which is not something to do a
        // hundred times during one slider drag.
        NotificationCenter.default.post(name: .photoEditsChanged, object: nil,
                                        userInfo: [photoEditsChangedURLsKey: changed])
    }

    // Powers the small "has edits" badge on a filmstrip thumbnail, and the
    // decision in ShowGrid about whether a photo's thumbnail has to be
    // re-rendered through the edit pipeline at all.
    static func hasEdits(_ url: URL) -> Bool {
        allSettings[key(for: url)] != nil
    }

    /// Bumped on every write. ShowGrid watches this to know its thumbnails are
    /// stale without having to diff the settings of every photo it is showing
    /// — see `refreshEditedGridThumbnailsIfNeeded`.
    private(set) static var generation: Int = 0

    // Decoded ONCE and held, rather than re-decoded on every read.
    //
    // This getter used to decode the entire JSON blob out of UserDefaults on
    // every single access, and the accesses are not rare: `hasEdits` is one,
    // and the panel ran `photoURLs.filter { hasEdits($0) }` inside a body
    // pass — so opening a folder of 300 photos meant 300 full decodes of a
    // dictionary holding every edit the client has ever made, before the
    // window could be shown. That was the four seconds of nothing between
    // double-clicking a photo and Create appearing. It grew with BOTH the
    // folder size and the client's edit history, so it got worse the longer
    // the app was used, which is the worst shape a slowdown can have.
    //
    // The cache is safe because this type is the only writer: `setSettings`
    // updates the dictionary and the store together, so nothing can go stale
    // underneath it within a run.
    private static var cachedSettings: [String: PhotoEditSettings]?

    // Guards `cachedSettings`. Before the cache existed this type was a pure
    // read of UserDefaults and needed no lock; caching turned it into shared
    // mutable state, and it is genuinely shared — ShowGrid renders its tiles
    // on one queue, the filmstrip decodes on another, and the editor reads on
    // the main thread, all of them asking this for a photo's settings. A Swift
    // Dictionary written on one thread while read on another is not a race
    // that shows up as a wrong answer; it shows up as a crash, eventually.
    private static let lock = NSLock()

    private static var allSettings: [String: PhotoEditSettings] {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let cachedSettings {
                return cachedSettings
            }
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
                cachedSettings = [:]
                return [:]
            }
            let decoded = (try? JSONDecoder().decode([String: PhotoEditSettings].self, from: data)) ?? [:]
            cachedSettings = decoded
            return decoded
        }
        set {
            lock.lock()
            cachedSettings = newValue
            generation &+= 1
            lock.unlock()
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }
}

/// Where a flattened photo lives, and how to get back.
///
/// Flattening bakes the CURRENT render — grade, masks, patches and the AI Clean
/// Up layers together — into one image, and that image becomes what the photo
/// renders from. The reason is a real defect it fixes: an AI Clean Up result is
/// stored as a layer of finished pixels, captured with whatever settings were
/// active at the time, and `render` composites layers AFTER the whole tonal
/// pipeline. So the repaired area keeps its old tone while the rest of the
/// photograph moves — most visibly when a grade is synced onto it from another
/// photo, which is how it was reported.
///
/// Nothing is written to the client's original file, ever. The flattened copy
/// is a private file in the app's container; the original stays untouched on
/// disk, and `unflatten` deletes the copy and puts the settings back exactly as
/// they were, so this is reversible in practice even though it is called
/// flattening.
///
/// 16-bit, not 8: the photo goes on being edited after this — that is the whole
/// point of it — and a grade pushed onto 8-bit baked pixels bands. Resolution
/// is native, per the lock at the top of BRIEFSHOW_DEVELOP_NOTES.md.
///
/// UNCOMPRESSED, and that is not a detail — it was the whole of "I flatten the
/// photo and then it will not show me the photo any more". Measured on the
/// client's own flattened .NEF (5176x3448, 16-bit):
///
///     LZW      126 MB   first render  9.9 s
///     none     142 MB   first render  1.5 s
///     none + downsampled decode for the preview   0.13 s
///
/// LZW is a serial, whole-file decompression that ImageIO cannot subsample
/// through, so every path that wanted a few megapixels had to inflate all 143
/// of them first — and it had to do it again on every return to the photo,
/// which is exactly what the client saw. Uncompressed costs 16 MB more in a
/// private cache directory and lets ImageIO read a reduced-size image straight
/// out of the file. See loadPreviewBaseImage.
enum FlattenedImageStore {

    private static let settingsKey = "com.rocketsbrief.briefshow.flattenedSettings"

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            return nil
        }
        // ⚠️ THE NAME ON DISK IS "BriefShow" AND IT STAYS THAT WAY.
        //
        // This is not the product's name, it is a PATH. The suite was renamed
        // to C4S Suite on 3.09 and a search-and-replace over string literals
        // rewrote this one too — which would have orphaned every blob already
        // written here, so the client's layers would sit in the list and show
        // nothing on the photo. The harness caught it; nothing else would have.
        // Same rule as the UserDefaults keys: what the client SEES is renamed,
        // what points at his data is not.
        let directory = base.appendingPathComponent("BriefShow/Flattened", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Keyed the same way PhotoEditStore keys its settings — name plus file
    /// size — so a different file that happens to share a name cannot pick up
    /// another photo's flattened copy.
    private static func key(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        return "\(url.lastPathComponent)|\(size)"
    }

    private static func fileURL(for photo: URL) -> URL? {
        guard let directory else { return nil }
        let safe = key(for: photo).replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe + ".tiff")
    }

    /// The flattened file for this photo, or nil.
    static func flattenedURL(for photo: URL) -> URL? {
        guard let candidate = fileURL(for: photo),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    static func isFlattened(_ photo: URL) -> Bool {
        flattenedURL(for: photo) != nil
    }

    /// What every decode in the app should actually open for this photo: the
    /// flattened copy when there is one, the original otherwise.
    static func sourceURL(for photo: URL) -> URL {
        flattenedURL(for: photo) ?? photo
    }

    enum Failure: LocalizedError {
        case noDirectory, renderFailed, encodeFailed
        var errorDescription: String? {
            switch self {
            case .noDirectory: return "Could not find a place to save the flattened photo."
            case .renderFailed: return "The photo could not be rendered."
            case .encodeFailed: return "The flattened photo could not be written."
            }
        }
    }

    /// Writes `image` as this photo's flattened copy and remembers the settings
    /// it was baked from, so `unflatten` can put them back.
    static func flatten(_ image: CIImage, settings: PhotoEditSettings,
                        for photo: URL, context: CIContext) throws {
        guard let destination = fileURL(for: photo) else { throw Failure.noDirectory }
        guard image.extent.width >= 1, image.extent.height >= 1,
              let cgImage = context.createCGImage(image, from: image.extent,
                                                  format: .RGBA16,
                                                  colorSpace: briefEditsSRGBColorSpace,
                                                  deferred: false) else {
            throw Failure.renderFailed
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        // No compression — see the type's own comment for the measurement.
        guard let data = rep.representation(using: .tiff, properties: [:]) else {
            throw Failure.encodeFailed
        }
        try data.write(to: destination, options: .atomic)

        // Only the FIRST flatten records a snapshot. Flattening a second time
        // (an AI Clean Up done after the first bake, which is the normal way to
        // reach this) must not overwrite it: those settings were measured
        // against the already-baked picture, so restoring them onto the
        // ORIGINAL file — which is what unflatten goes back to — would be
        // restoring a grade to a photo that never had it. Unflatten means "back
        // to before any of this", and one flatten or three, that is the same
        // place.
        var all = storedSettings
        if all[key(for: photo)] == nil {
            all[key(for: photo)] = settings
            storedSettings = all
        }
    }

    /// Rewrites a flattened file that was written by an older build with LZW
    /// compression, which cost ~10 s on every first render of the photo.
    ///
    /// Cheap to call on every open: it reads the TIFF header only (~1 ms) and
    /// returns immediately unless the compression tag says otherwise. Called
    /// off the main thread, from the decode that is about to open the file.
    static func upgradeLegacyCompressedFile(for photo: URL) {
        guard let url = flattenedURL(for: photo),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
              let compression = tiff[kCGImagePropertyTIFFCompression as String] as? Int,
              compression != 1 else {
            return
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            return
        }
        let rep = NSBitmapImageRep(cgImage: decoded)
        guard let data = rep.representation(using: .tiff, properties: [:]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes the flattened copy and returns the settings it was baked from,
    /// so the caller can restore them.
    @discardableResult
    static func unflatten(_ photo: URL) -> PhotoEditSettings? {
        if let existing = flattenedURL(for: photo) {
            try? FileManager.default.removeItem(at: existing)
        }
        var all = storedSettings
        let previous = all.removeValue(forKey: key(for: photo))
        storedSettings = all
        return previous
    }

    private static var storedSettings: [String: PhotoEditSettings] {
        get {
            guard let data = UserDefaults.standard.data(forKey: settingsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: PhotoEditSettings].self, from: data)) ?? [:]
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: settingsKey)
        }
    }
}

extension Notification.Name {
    /// Photos whose saved edits just changed, coalesced — see
    /// `PhotoEditStore.flushNow`. userInfo carries a `Set<URL>` under
    /// `photoEditsChangedURLsKey`.
    static let photoEditsChanged = Notification.Name("com.rocketsbrief.briefshow.photoEditsChanged")
}

let photoEditsChangedURLsKey = "urls"

/// A ShowGrid thumbnail with the client's Create edits applied.
///
/// The grid used to show the untouched file no matter how much work had been
/// done on a photo, so a folder looked identical before and after an editing
/// session — the edits existed but were only ever visible inside Create.
///
/// Edits are applied to the THUMBNAIL, not to a full decode that is then
/// shrunk. That is the whole reason this is affordable in a grid: the small
/// ImageIO decode is what the grid was already paying for, and the filter
/// chain then runs over a few hundred pixels instead of forty megapixels.
/// Every geometry in PhotoEditSettings — crops, masks, patches, layer bounds —
/// is stored in unit coordinates precisely so it can be resolved against
/// whatever extent it is handed, so the small render matches the big one.
///
/// A photo with no edits takes the plain path and costs exactly what it did
/// before.
func makeEditedShowGridThumbnail(from url: URL, maxPixelSize: CGFloat = 420) -> NSImage? {
    // The flattened copy, when there is one — otherwise a flattened photo would
    // still show its original in the grid and the filmstrip.
    let source = FlattenedImageStore.sourceURL(for: url)
    let settings = PhotoEditStore.settings(for: url)
    guard !settings.isNeutral else {
        return makeShowGridThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    guard let plain = makeShowGridThumbnail(from: source, maxPixelSize: maxPixelSize),
          let plainCG = plain.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }

    let rendered = PhotoEditRenderer.render(settings, on: .standard(CIImage(cgImage: plainCG)))
    guard rendered.extent.width >= 1, rendered.extent.height >= 1,
          let out = briefEditsDisplayCGImage(rendered, from: rendered.extent,
                                             context: briefEditsThumbnailCIContext) else {
        // Falls back to the unedited thumbnail rather than to nothing: a photo
        // that renders as a blank tile in the grid is worse than one that
        // renders as its original.
        return plain
    }
    return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
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


// MARK: - Colour Mixer

/// Turns a ColorMixer into the 3D lookup table CIColorCube renders through.
///
/// A LUT rather than a chain of per-band filters, and the difference is not
/// small: eight bands times three controls would be a couple of dozen masked
/// filter passes over a 45-megapixel frame on every slider tick. A cube is ONE
/// filter whatever the mixer holds, and building it touches 32³ = 32,768 table
/// entries — work that does not depend on the size of the photograph at all.
///
/// 32 per side is the size Adobe, Apple and every LUT format settle on for
/// colour work. The table is interpolated between entries, and hue/saturation
/// moves are smooth by construction, so the visible error at 32 is nil; 64
/// would be eight times the build for nothing to look at.
enum ColorMixerCube {

    static let dimension = 32

    // Rebuilt only when the mixer actually changes. render() runs at a ~20ms
    // cadence while a slider is dragged and every one of those passes asks for
    // the cube, so without this the table would be rebuilt fifty times a second
    // for a photo whose mixer had not moved at all.
    private static let lock = NSLock()
    private static var cachedMixer: ColorMixer?
    private static var cachedData: Data?

    static func data(for mixer: ColorMixer) -> Data {
        lock.lock()
        if let cachedData, cachedMixer == mixer {
            lock.unlock()
            return cachedData
        }
        lock.unlock()

        let built = build(mixer)

        lock.lock()
        cachedMixer = mixer
        cachedData = built
        lock.unlock()
        return built
    }

    /// How far the Hue slider swings, in degrees, at ±1.
    ///
    /// 30° is one whole step of the warm end of the wheel — red to orange,
    /// orange to yellow — which is the range Lightroom's own Hue slider covers
    /// and about as far as a hue can move before it stops reading as a shift of
    /// that colour and starts reading as a different colour.
    private static let hueSwingDegrees: Double = 30

    /// How hard the Luminance slider pushes at ±1.
    ///
    /// ⚠️ Was 0.6, chosen by feel and never measured. Against the client's
    /// Lightroom export it was the single largest colour error left after the
    /// tone curve: the preset's four negative Luminance bands (Red -21,
    /// Yellow -22, Green -21) darkened the frame far past Lightroom's, and
    /// dropping the swing to 0.2 brought all three channel means back within a
    /// few counts of the target. Measured with Tools/run-lightroom-calibration.py.
    private static let luminanceSwing: Double = 0.2

    private static func build(_ mixer: ColorMixer) -> Data {
        let n = dimension
        let bands = ColorBand.allCases
        let settings = bands.map { mixer[$0] }
        var table = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0

        for b in 0..<n {
            let blue = Double(b) / Double(n - 1)
            for g in 0..<n {
                let green = Double(g) / Double(n - 1)
                for r in 0..<n {
                    let red = Double(r) / Double(n - 1)

                    var (h, s, l) = Self.rgbToHSL(red, green, blue)

                    // A grey has no hue to belong to a band, so no band may
                    // touch it. Without this a neutral would drift with
                    // whichever band happened to win the weighting, and a
                    // photograph's greys drifting is the one thing a colour
                    // tool must never do.
                    if s > 0 {
                        let weights = Self.bandWeights(h)
                        var hueShift = 0.0, satAmount = 0.0, lumAmount = 0.0
                        for i in 0..<bands.count where weights[i] != 0 {
                            hueShift += weights[i] * settings[i].hue
                            satAmount += weights[i] * settings[i].saturation
                            lumAmount += weights[i] * settings[i].luminance
                        }

                        h += hueShift * hueSwingDegrees
                        // Negative takes it to grey at -1, positive doubles it
                        // at +1 — the two ends Lightroom's own slider has.
                        s = min(max(s * (1 + satAmount), 0), 1)
                        l = lumAmount >= 0
                            ? l + (1 - l) * lumAmount * luminanceSwing
                            : l * (1 + lumAmount * luminanceSwing)
                        l = min(max(l, 0), 1)
                    }

                    let (outR, outG, outB) = Self.hslToRGB(h, s, l)
                    // CIColorCube wants the table premultiplied. Everything
                    // here is opaque, so premultiplying by 1 is the identity —
                    // stated rather than assumed, because a cube written the
                    // other way looks right until it meets a transparent pixel.
                    table[index] = Float(min(max(outR, 0), 1))
                    table[index + 1] = Float(min(max(outG, 0), 1))
                    table[index + 2] = Float(min(max(outB, 0), 1))
                    table[index + 3] = 1
                    index += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Each hue sits between two of the eight centres and splits smoothly
    /// between them, so the weights always sum to exactly 1.
    ///
    /// That property is the whole design. Weighting each band independently —
    /// a bell curve per centre, say — makes the weights sum to something that
    /// varies with hue, so a mixer with all eight saturations at +20 would
    /// saturate some hues more than others rather than doing what it plainly
    /// says. A partition of unity cannot do that.
    ///
    /// Smoothstep rather than a straight line, so a colour crossing a centre
    /// has no kink in it — a gradient sky sliding from aqua to blue must not
    /// show a band edge.
    static func bandWeights(_ hue: Double) -> [Double] {
        var weights = [Double](repeating: 0, count: 8)
        let centres = ColorBand.allCases.map(\.centreDegrees)
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        let h = wrapped < 0 ? wrapped + 360 : wrapped

        for i in 0..<8 {
            let a = centres[i]
            let b = i == 7 ? centres[0] + 360 : centres[i + 1]
            // The last span wraps past 360 back to red.
            var x = h
            if i == 7 && h < centres[0] { x += 360 }
            guard x >= a, x <= b, b > a else { continue }
            let t = (x - a) / (b - a)
            let smooth = t * t * (3 - 2 * t)
            weights[i] = 1 - smooth
            weights[(i + 1) % 8] = smooth
            return weights
        }
        return weights
    }

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        guard high > low else { return (0, 0, l) }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        var h: Double
        if high == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if high == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h * 60, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let hk = (h / 360).truncatingRemainder(dividingBy: 1)
        let k = hk < 0 ? hk + 1 : hk
        return (channel(k + 1.0 / 3), channel(k), channel(k - 1.0 / 3))
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

    /// How far a control at full travel bends its own knot.
    ///
    /// Calibrated against Lightroom rather than chosen: Tools/run-lightroom-calibration.py
    /// renders the client's NEF through this very pipeline and scores it against
    /// the same photograph exported from Lightroom with the same preset.
    /// 0.30 was never measured — it scored **36.01**, WORSE than applying no
    /// preset at all (24.11). At 0.10, with the zone weights below, the same
    /// comparison scores **15.28**.
    ///
    /// ⚠️ 0.06 scores slightly better still (13.69) and was NOT taken: it buys
    /// 1.6 RMS on one photograph at the cost of every tone slider's authority,
    /// and one photograph cannot tell those apart. What settles it is a
    /// Lightroom export per slider — see the tool's own warning.
    static let toneControlStrength = 0.10

    /// The gentlest the curve is allowed to rise between two knots. Above zero
    /// on purpose: a flat segment is what let the old spline dip.
    static let toneMinimumSlope = 0.08

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
    static func loadBaseImage(from photoURL: URL) -> PhotoBaseImage? {
        // A flattened photo opens its baked copy instead of the original, and
        // it does so HERE so that every path — preview, refine, export, the
        // erases — sees the same picture. Flattening that only the preview
        // honoured would be a lie the export would then tell.
        let url = FlattenedImageStore.sourceURL(for: photoURL)
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

    /// A reduced-size decode straight out of the file, at most `maxPixelSize`
    /// on the long edge.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` is what makes this worth
    /// having: ImageIO reads the pixels it needs for the requested size instead
    /// of decoding the frame and shrinking it. The name is unfortunate — this
    /// is a full-quality reduced image, not the postage stamp the camera
    /// embedded, which is what `...FromImageIfAbsent` would have settled for.
    private static func downsampledImage(from url: URL, maxPixelSize: CGFloat) -> CIImage? {
        guard maxPixelSize.isFinite, maxPixelSize >= 1,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded()),
                  // Orientation applied here, to match the .applyOrientationProperty
                  // the full decode above opens with — otherwise a photo shot in
                  // portrait would preview on its side and render upright.
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
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
    /// `previewMax` is the long edge, in pixels, of the image the client is
    /// actually shown while editing.
    ///
    /// It was 1600, and 1600 is not enough. The preview area on a Retina
    /// display is roughly 2900 physical pixels wide, so a 1600px render was
    /// being enlarged nearly twice over — reported directly, with a crop of a
    /// .NEF that looked nothing like the file that came out of the camera.
    /// 2600 lands close to native for the screen without being the full frame.
    ///
    /// It is still the DRAFT decode for RAW (see below), and it is still
    /// replaced by the full-resolution render as soon as editing pauses. What
    /// changed is what the client looks at in between, which is most of the
    /// time they spend in this window.
    static func loadPreviewBaseImage(from photoURL: URL, full: PhotoBaseImage, previewMax: CGFloat = 2600) -> PhotoBaseImage {
        let url = FlattenedImageStore.sourceURL(for: photoURL)
        let extent = full.extent
        let longEdge = max(extent.width, extent.height)
        let scale = (longEdge.isFinite && longEdge > previewMax) ? previewMax / longEdge : 1

        switch full {
        case .standard(let image):
            guard scale < 1 else {
                return full
            }
            // A real reduced-size DECODE, not an affine transform over the
            // full-resolution one — and for the same reason the RAW branch
            // below builds its own filter rather than shrinking the export
            // filter's output: scaling a lazy CIImage does not make it cheaper,
            // it just puts a downsample at the end of a graph that still has to
            // inflate every pixel of the file first.
            //
            // That cost is invisible on a 4 MB JPEG and enormous on a flattened
            // photo, which is a 142 MB 16-bit TIFF at native resolution. It was
            // measured on the client's flattened .NEF: 1.5 s through the
            // transform, 0.13 s through this path, and the same saving is paid
            // back on every return to the photo, because each open decodes
            // afresh.
            if let reduced = downsampledImage(from: url, maxPixelSize: previewMax) {
                return .standard(reduced)
            }
            // A format ImageIO will not hand back a reduced image for still has
            // to show something, so the old path stays as the fallback.
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
    /// The five knots of the Blacks/Shadows/Highlights/Whites curve.
    ///
    /// ⚠️ Replaces a layout that could produce a NON-MONOTONIC curve — measured
    /// on a 0...255 ramp through the real renderer with the client's own
    /// "Classic Edits" preset (Highlights -77, Shadows +70, Whites +25,
    /// Blacks -28):
    ///
    ///     in   48 ->  59      the image got DARKER as the input got BRIGHTER,
    ///     in   64 ->  56      from 48 all the way to 112, and never recovered:
    ///     in   96 ->  50      240 came out at 192/197/108.
    ///     in  112 ->  50
    ///
    /// The old layout pinned the midtone knot at (0.5, 0.5) and moved only
    /// point3 for Highlights, so a strong Highlights setting left the segment
    /// between x=0.5 and x=0.75 almost flat (0.500 -> 0.519 here) and the
    /// spline through it dipped. On a high-key photograph — this one has half
    /// its pixels above 242 — that is most of the picture.
    ///
    /// Two things are different now. Each control moves EVERY knot, by a weight
    /// that falls off away from the zone it owns, which is how Lightroom's
    /// Blacks/Shadows/Highlights/Whites behave — they are zone-weighted, not
    /// single knots. And the result is forced non-decreasing with a minimum
    /// slope, so no combination of the four can invert the image again.
    ///
    /// **Highlights now carries LIGHTROOM'S SIGN: positive brightens.** It used
    /// to be the other way round. Records written before that flip are migrated
    /// on decode (see PhotoEditSettings.init(from:) and `schemaVersion`), so a
    /// photo edited under an older build still renders the way it did.
    static func toneCurvePoints(blacks: Double, shadows: Double,
                                highlights: Double, whites: Double) -> [CGPoint] {
        let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]
        // Rows: blacks, shadows, highlights, whites. Columns: the five knots.
        // Each control is 1.0 at home and fades outwards.
        //
        // ⚠️ Shadows and Highlights leak far LESS into the midtone knot than
        // Blacks and Whites do, and that asymmetry is measured rather than
        // chosen. With a wide leak the client's preset (Shadows +70,
        // Highlights -77) lifted and then crushed the whole middle of the
        // frame — which on a high-key photograph is most of the picture — and
        // NO value of toneControlStrength made that stop. Pinning the midtone
        // is what Lightroom's own Shadows does: on a 0...255 ramp, Shadows
        // +100 now reads 16 -> 29, 32 -> 42 and 128 -> 128.
        //
        // ⚠️ Blacks KEEPS its 0.45 on the quarter knot. That weight is the
        // whole reason Blacks does anything at all — narrowing it with the
        // others took the same ramp from "16 -> 11" back to "16 -> 15", which
        // is the dead Blacks slider the client already reported once.
        let weights: [[Double]] = [
            [1.00, 0.45, 0.06, 0.00, 0.00],
            [0.30, 1.00, 0.10, 0.00, 0.00],
            [0.00, 0.00, 0.10, 1.00, 0.30],
            [0.00, 0.00, 0.06, 0.45, 1.00],
        ]
        let amounts = [blacks, shadows, highlights, whites]

        var ys = xs
        for knot in 0..<5 {
            var delta = 0.0
            for control in 0..<4 { delta += amounts[control] * weights[control][knot] }
            ys[knot] = xs[knot] + delta * toneControlStrength
        }

        // Below black is not a place to go; above white is, because that is
        // what lets Whites push tones into clipping instead of flattening
        // toward it.
        ys[0] = max(ys[0], 0)

        // Monotonic by construction, not by hope. Without this the four
        // controls can still cross each other at the extremes.
        for knot in 1..<5 {
            let floor = ys[knot - 1] + toneMinimumSlope * (xs[knot] - xs[knot - 1])
            ys[knot] = max(ys[knot], floor)
        }

        return (0..<5).map { CGPoint(x: xs[$0], y: ys[$0]) }
    }

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
            // shifting overall brightness. point4 (the top endpoint) is
            // deliberately allowed past 1 — that's what lets Whites push tones
            // into clipping instead of just flattening toward it, which a
            // curve clamped at the end can't do. Highlights keeps the
            // "positive = recover/darken" sign it had under the old
            // CIHighlightShadowAdjust-based version (so a photo edited before
            // this change still reads the same direction); Shadows/Whites/
            // Blacks use the more familiar Lightroom convention where positive
            // means brighter.
            //
            // BLACKS ALSO BENDS point1, and without that it did nothing at all
            // — reported as "-100 to +100 and nothing happens", and measured
            // here on a 0...255 ramp:
            //
            //     blacks -1, point0 only:  16 -> 16,  32 -> 32   (no change)
            //     blacks +1, point0 only:   0 -> 19,  16 -> 15   (and inverted)
            //
            // Two structural reasons. A negative y at x = 0 has nowhere to go,
            // because the output there is already black — "crush the blacks" is
            // a move along x, not down past zero; the symmetry with point4 that
            // the paragraph above claimed simply is not there. And point1 is
            // pinned at x = 0.25, so whatever point0 does is spent by the time
            // the curve has travelled a quarter of the range — at +1 it even
            // came back DOWN in between, which is the inversion above.
            //
            // Carrying a fraction of Blacks onto point1 gives it somewhere to
            // act. Same ramp, with the weight below:
            //
            //     blacks -1:   16 ->  4,  32 -> 21,  128 -> 129
            //     blacks +1:   16 -> 35,  32 -> 42,  128 -> 128
            //
            // — a real crush and a real lift, monotonic in both directions,
            // and the midtone pivot at 0.5 left alone, which was the point of
            // the layout in the first place. Blacks and Shadows now share
            // point1, and that is honest: both are controls over the bottom of
            // the range, and they overlap in Lightroom too.
            let points = PhotoEditRenderer.toneCurvePoints(
                blacks: settings.blacks, shadows: settings.shadows,
                highlights: settings.highlights, whites: settings.whites)
            let filter = CIFilter.toneCurve()
            filter.inputImage = output
            filter.point0 = points[0]
            filter.point1 = points[1]
            filter.point2 = points[2]
            filter.point3 = points[3]
            filter.point4 = points[4]
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

        // The Colour Mixer sits here, after the basic tone and colour work and
        // before texture/clarity — the same place Lightroom's panel sits, so an
        // imported preset meets the picture in the state it expects.
        if !settings.colorMixer.isNeutral {
            output = applyColorMixer(settings.colorMixer, to: output)
        }

        output = PhotoEditRenderer.applySharpen(settings.sharpness, radius: settings.sharpenRadius, to: output)

        output = PhotoEditRenderer.applyTexture(settings.texture, to: output)

        output = PhotoEditRenderer.applyClarity(settings.clarity, to: output)

        output = PhotoEditRenderer.applyDehaze(settings.dehaze, to: output)

        output = PhotoEditRenderer.applySoftGlow(settings.softGlow, to: output)

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

            // A TURNED crop frame is rendered by turning the PICTURE the other
            // way about the frame's own centre, and then taking the ordinary
            // upright rectangle. The two are the same thing: what comes out is
            // the tilted frame's contents, upright, at exactly the frame's own
            // size. Doing it this way means `rect` below is untouched — the
            // centre is the one point a rotation about the centre leaves where
            // it is, and the size does not change.
            //
            // ⚠️ Sign checked against the straighten path twenty lines up, not
            // guessed. There, a POSITIVE straightenDegrees turns the picture
            // clockwise through `rotationAngle: -radians`; so `+radians` turns
            // it counter-clockwise, which is what stands the frame back up when
            // the frame itself is turned clockwise. A rotation that goes the
            // wrong way is the kind of thing that gets "fixed" twice.
            if crop.angle != 0 {
                let radians = CGFloat(crop.angle * .pi / 180)
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                let turn = CGAffineTransform(translationX: centre.x, y: centre.y)
                    .rotated(by: radians)
                    .translatedBy(x: -centre.x, y: -centre.y)
                output = output.transformed(by: turn)
            }

            output = output.cropped(to: rect)
        }

        output = PhotoEditRenderer.applyVignette(settings.vignette, midpoint: settings.vignetteMidpoint, feather: settings.vignetteFeather, roundness: settings.vignetteRoundness, to: output)

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
    /// Extracted verbatim from `render` so a LAYER can have the same
    /// effect as the whole photo — see applyLocalToneColorDetail. The call
    /// site in `render` is unchanged in behaviour; proved pixel-for-pixel
    /// against the pre-extraction code by Tools/run-effect-extraction-test.py.
    private static func applySharpen(_ sharpness: Double, radius: Double, to image: CIImage) -> CIImage {
        var output = image

    if sharpness > 0 {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = output
        filter.sharpness = Float(sharpness * 2.2)
        // Radius was never set here, so Core Image used its own default of
        // 1.69. `sharpenRadius` defaults to 1 and is multiplied by exactly
        // that, which is what makes this an addition rather than a change:
        // a photo that has never seen the new slider renders through the
        // identical filter it always did.
        filter.radius = Float(briefEditsDefaultSharpenRadius
                              * min(max(radius, 0.5), 3))
        output = filter.outputImage ?? output
    }

        return output
    }

    /// Extracted verbatim from `render` so a LAYER can have the same
    /// effect as the whole photo — see applyLocalToneColorDetail. The call
    /// site in `render` is unchanged in behaviour; proved pixel-for-pixel
    /// against the pre-extraction code by Tools/run-effect-extraction-test.py.
    private static func applyTexture(_ texture: Double, to image: CIImage) -> CIImage {
        var output = image

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
    if texture != 0 {
        let extent = output.extent
        let longEdge = max(extent.width, extent.height)
        if longEdge.isFinite, longEdge > 0 {
            if texture > 0 {
                let filter = CIFilter.unsharpMask()
                filter.inputImage = output
                filter.radius = Float(min(max(longEdge * 0.006, 2), 40))
                filter.intensity = Float(texture * 1.1)
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

                let amount = CGFloat(min(max(-texture, 0), 1) * 0.9)
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

        return output
    }

    /// Extracted verbatim from `render` so a LAYER can have the same
    /// effect as the whole photo — see applyLocalToneColorDetail. The call
    /// site in `render` is unchanged in behaviour; proved pixel-for-pixel
    /// against the pre-extraction code by Tools/run-effect-extraction-test.py.
    private static func applyClarity(_ clarity: Double, to image: CIImage) -> CIImage {
        var output = image

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
    // reason.
    //
    // Both directions, and NOT through the same filter: CIUnsharpMask's
    // `intensity` is undocumented for negative values, so the softening
    // half is what "reduce local contrast" actually means — a mix toward
    // a blurred copy at the SAME radius, which is the exact inverse of
    // what unsharp adds at that radius. (Positive: base + k x detail.
    // Negative: base - k x detail, i.e. mix(base, blurred, k).) It shares
    // the radius on purpose, so -40 undoes what +40 did rather than
    // softening at some unrelated scale.
    if clarity != 0 {
        let extent = output.extent
        let longEdge = max(extent.width, extent.height)
        if longEdge.isFinite, longEdge > 0 {
            let radius = min(max(longEdge * 0.02, 8), 100)
            if clarity > 0 {
                let filter = CIFilter.unsharpMask()
                filter.inputImage = output
                filter.radius = Float(radius)
                filter.intensity = Float(min(clarity, 1) * 0.8)
                output = filter.outputImage ?? output
            } else {
                let blurred = output
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: extent)

                // Same flat-grey-mask trick Soft Glow uses below for its
                // own opacity dial: CIBlendWithMask reads the mask's
                // level, so a constant colour is a constant mix.
                let amount = CGFloat(min(-clarity, 1) * 0.6)
                let mixMask = CIImage(color: CIColor(red: amount, green: amount, blue: amount)).cropped(to: extent)
                let blend = CIFilter.blendWithMask()
                blend.inputImage = blurred
                blend.backgroundImage = output
                blend.maskImage = mixMask
                output = blend.outputImage ?? output
            }
        }
    }

        return output
    }

    /// Extracted verbatim from `render` so a LAYER can have the same
    /// effect as the whole photo — see applyLocalToneColorDetail. The call
    /// site in `render` is unchanged in behaviour; proved pixel-for-pixel
    /// against the pre-extraction code by Tools/run-effect-extraction-test.py.
    private static func applyDehaze(_ dehaze: Double, to image: CIImage) -> CIImage {
        var output = image

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
    //
    // Runs in both directions from the SAME coefficients, with no
    // special-casing, because every one of them already reverses
    // correctly under a negative d: contrast and saturation drop below
    // 1, and the tone curve's black point lifts instead of crushing —
    // which is exactly what haze does to a photo. So the left half of
    // the slider ADDS atmosphere rather than being dead travel.
    if dehaze != 0 {
        let d = Float(min(max(dehaze, -1), 1))

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

        return output
    }

    /// Extracted verbatim from `render` so a LAYER can have the same
    /// effect as the whole photo — see applyLocalToneColorDetail. The call
    /// site in `render` is unchanged in behaviour; proved pixel-for-pixel
    /// against the pre-extraction code by Tools/run-effect-extraction-test.py.
    private static func applySoftGlow(_ softGlow: Double, to image: CIImage) -> CIImage {
        var output = image

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
    if softGlow > 0 {
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

            let amount = CGFloat(min(max(softGlow, 0), 1))
            let mixMask = CIImage(color: CIColor(red: amount, green: amount, blue: amount)).cropped(to: extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = glowed
            blend.backgroundImage = output
            blend.maskImage = mixMask
            output = blend.outputImage ?? output
        }
    }

        return output
    }

    /// Extracted verbatim from `render` so a LAYER can have the same
    /// effect as the whole photo — see applyLocalToneColorDetail. The call
    /// site in `render` is unchanged in behaviour; proved pixel-for-pixel
    /// against the pre-extraction code by Tools/run-effect-extraction-test.py.
    private static func applyVignette(_ vignette: Double, midpoint: Double, feather: Double, roundness: Double, to image: CIImage) -> CIImage {
        var output = image

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
    //
    // Both directions, like Lightroom's own post-crop vignette: negative
    // darkens the corners, positive lightens them. The two halves share
    // one gradient and differ only in which blend consumes it, and both
    // blends are chosen so the CENTRE is untouched at every amount —
    // multiply against white changes nothing, and screen against black
    // changes nothing. So the effect grows from the corners inward
    // instead of dimming or fogging the whole frame.
    if vignette != 0 {
        let extent = output.extent
        if extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 {
            let halfW = extent.width / 2
            let halfH = extent.height / 2
            let darkens = vignette > 0
            let amount = CGFloat(min(abs(vignette), 1))
            let centre: CGFloat = darkens ? 1 : 0
            let corner0: CGFloat = darkens ? 1 - amount : amount

            // Lightroom's three shape controls, added around the gradient
            // this always drew. Each default reproduces the old numbers
            // exactly — midpoint 0.5 gives radius0 = 1, feather 0.5 gives
            // radius1 = √2, roundness 0 leaves the ellipse matching the
            // frame — so a photo edited before these existed renders
            // identically. That is the whole reason the defaults are 0.5
            // rather than the 0 that would look tidier in a struct.
            let corner = 2.0.squareRoot()
            let inner = 2 * CGFloat(min(max(midpoint, 0), 1))
            let spread = CGFloat(min(max(feather, 0), 1)) * 2 * (corner - 1)
            // A floor on the spread: radius1 == radius0 is a gradient with
            // no distance to travel, which Core Image has no answer for.
            let outer = inner + max(spread, 0.02)

            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = Float(inner)
            gradient.radius1 = Float(outer)
            gradient.color0 = CIColor(red: centre, green: centre, blue: centre, alpha: 1)
            gradient.color1 = CIColor(red: corner0, green: corner0, blue: corner0, alpha: 1)

            if let unitGradient = gradient.outputImage {
                // Roundness, and it is honestly an APPROXIMATION of
                // Lightroom's. Lightroom's negative roundness bends the
                // shape toward a rounded RECTANGLE, which no ellipse can
                // be. Positive is exact — the axes are blended toward each
                // other until the ellipse is a circle. Negative is
                // approached by pushing the ellipse outward so its edge
                // hugs the corners the way a squarer shape would, which
                // reads as intended on a photograph even though it is not
                // the same curve.
                let roundness = CGFloat(min(max(roundness, -1), 1))
                var axisW = halfW
                var axisH = halfH
                if roundness > 0 {
                    let mean = (halfW + halfH) / 2
                    axisW = halfW + (mean - halfW) * roundness
                    axisH = halfH + (mean - halfH) * roundness
                } else if roundness < 0 {
                    let push = 1 + 0.35 * -roundness
                    axisW *= push
                    axisH *= push
                }
                let transform = CGAffineTransform(a: axisW, b: 0, c: 0, d: axisH, tx: extent.midX, ty: extent.midY)
                let featherRadius = min(extent.width, extent.height) * 0.06
                let mask = unitGradient
                    .transformed(by: transform)
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius])
                    .cropped(to: extent)

                if darkens {
                    let multiply = CIFilter.multiplyCompositing()
                    multiply.inputImage = mask
                    multiply.backgroundImage = output
                    output = multiply.outputImage ?? output
                } else {
                    let screen = CIFilter.screenBlendMode()
                    screen.inputImage = mask
                    screen.backgroundImage = output
                    output = screen.outputImage ?? output
                }
            }
        }
    }

        return output
    }

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
            // The same curve as the global one, and deliberately the same
            // FUNCTION: a mask that toned differently from the panel would be
            // a second thing to calibrate and a second thing to get wrong. It
            // carried the same non-monotonic Highlights defect until 05.09 —
            // the measurements are on toneCurvePoints.
            let points = PhotoEditRenderer.toneCurvePoints(
                blacks: local.blacks, shadows: local.shadows,
                highlights: local.highlights, whites: local.whites)
            let filter = CIFilter.toneCurve()
            filter.inputImage = output
            filter.point0 = points[0]
            filter.point1 = points[1]
            filter.point2 = points[2]
            filter.point3 = points[3]
            filter.point4 = points[4]
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

        // ⚠️ From here down, a layer runs THE SAME FUNCTIONS the photo runs,
        // in the SAME ORDER `render` runs them: colour mixer, sharpen, texture,
        // clarity, dehaze, soft glow, and vignette last. That order is not a
        // preference — it is what makes a layer's +40 Clarity mean the same
        // thing as the photo's +40 Clarity. If the order in `render` ever
        // changes, change it here too.
        //
        // The old inline sharpen that stood here is gone: it passed no radius,
        // so it could not honour the Radius dial. applySharpen is the photo's
        // own, and at radius 1 it is byte-for-byte the filter this used to run
        // (see the note inside it).
        if !local.colorMixer.isNeutral {
            output = applyColorMixer(local.colorMixer, to: output)
        }

        output = applySharpen(local.sharpness, radius: local.sharpenRadius, to: output)
        output = applyTexture(local.texture, to: output)
        output = applyClarity(local.clarity, to: output)
        output = applyDehaze(local.dehaze, to: output)
        output = applySoftGlow(local.softGlow, to: output)

        // Against the LAYER's own rectangle, which is the only frame a layer
        // has. On the photo this runs after the crop, for the same reason:
        // a vignette darkens the corners of what you are actually looking at.
        output = applyVignette(local.vignette, midpoint: local.vignetteMidpoint,
                               feather: local.vignetteFeather,
                               roundness: local.vignetteRoundness, to: output)

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
    /// Runs the image through the mixer's lookup table.
    ///
    /// Three things happen around the cube, and each one is there because the
    /// obvious version was measured and found wrong.
    ///
    /// **A grey must stay grey.** A cube is sampled with trilinear
    /// interpolation, so a true neutral at 0.5 lands exactly BETWEEN table
    /// entries and is mixed from eight corners — six of which are slightly
    /// coloured and have therefore been moved by whichever band claims them.
    /// Measured: with every band's Luminance at +100, a 0.5 grey came out at
    /// 0.725. Fading the effect out inside the cube barely helped (0.35 → 0.11
    /// at best) because the neighbours of a DARK grey are strongly saturated.
    /// What works is deciding outside the cube, at full precision, how far each
    /// pixel is from grey and blending the cube's answer in by that much: drift
    /// went to 0.0000, and a pale sky and a saturated blue came through
    /// completely unchanged. The mixer is a COLOUR tool; a photograph's greys
    /// drifting is the one thing it must never do.
    ///
    /// **The headroom above white must survive.** CIColorCube looks up over
    /// 0...1 and clamps past it, and measured on a .NEF through this very
    /// pipeline the image arrives here with components up to 1.33 — an IDENTITY
    /// cube brought them to 1.000. Everything downstream still reads those
    /// highlights: clarity, the vignette, a darkening mask. So the part above
    /// white is carried around the cube and added back.
    ///
    /// **Adding two images back together took three attempts**, all of them
    /// undone by premultiplied alpha, and the dead ends are written down
    /// because each one looked right:
    ///
    /// 1. Zero the excess image's alpha so the addition cannot double the
    ///    opacity. Core Image stores colour PREMULTIPLIED, so alpha 0 means
    ///    colour 0: the excess came out (0, 0, 0, 0) and the whole thing was a
    ///    silent no-op.
    /// 2. Keep the alpha and reset it to 1 afterwards with a colour matrix.
    ///    CIColorMatrix UNPREMULTIPLIES before it works, so with the addition's
    ///    alpha of 2 every channel was divided by 2 — the whole photograph came
    ///    out at exactly half brightness. Measured: an untouched orange went
    ///    from 0.90/0.50/0.20 to 0.4494/0.2500/0.0996.
    /// 3. CILinearDodgeBlendMode, which does keep alpha at 1 — and clamps the
    ///    sum to 1, which is the very thing being worked around.
    ///
    /// What works is to let the addition double the alpha and then undo exactly
    /// that: colour times two, alpha times a half. Measured exact for a sum
    /// under 1, a sum over 1, a zero excess (a true no-op), and — because the
    /// correction is algebraic rather than a special case for opaque pixels —
    /// for two images at alpha 0.5 as well.
    private static func applyColorMixer(_ mixer: ColorMixer, to image: CIImage) -> CIImage {
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(ColorMixerCube.dimension)
        cube.cubeData = ColorMixerCube.data(for: mixer)
        cube.colorSpace = briefEditsSRGBColorSpace
        guard var output = cube.outputImage else {
            return image
        }

        // Neutrals come from the original, colours from the cube, and the
        // crossover is smooth.
        if let mask = colourDistanceFromGrey(image) {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = output
            blend.backgroundImage = image
            blend.maskImage = mask
            output = blend.outputImage ?? output
        }

        // Everything above 1 and nothing else: clamp the bottom UP to 1, then
        // subtract that 1 away.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = image
        clamp.minComponents = CIVector(x: 1, y: 1, z: 1, w: 0)
        clamp.maxComponents = CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1)
        guard let clamped = clamp.outputImage else {
            return output.cropped(to: image.extent)
        }
        let excess = CIFilter.colorMatrix()
        excess.inputImage = clamped
        excess.biasVector = CIVector(x: -1, y: -1, z: -1, w: 0)
        guard let headroom = excess.outputImage else {
            return output.cropped(to: image.extent)
        }
        let add = CIFilter.additionCompositing()
        add.inputImage = headroom
        add.backgroundImage = output
        guard let summed = add.outputImage else {
            return output.cropped(to: image.extent)
        }
        // Undo what the addition did to alpha, and to the colour along with it:
        // both inputs carry the same alpha, so the sum carries twice it, and
        // the premultiplied colour is therefore twice as dark once anything
        // divides it back out. Colour times two, alpha times a half.
        let unwind = CIFilter.colorMatrix()
        unwind.inputImage = summed
        unwind.rVector = CIVector(x: 2, y: 0, z: 0, w: 0)
        unwind.gVector = CIVector(x: 0, y: 2, z: 0, w: 0)
        unwind.bVector = CIVector(x: 0, y: 0, z: 2, w: 0)
        unwind.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.5)
        return (unwind.outputImage ?? summed).cropped(to: image.extent)
    }

    /// How far each pixel is from grey, 0 at a true neutral and 1 by the time
    /// any channel is `fullyColoured` away from the pixel's own grey.
    ///
    /// 0.04 is generous to colour and strict about neutrals: a deviation of
    /// 0.04 is about a saturation of 0.08 at mid grey, which is far below any
    /// colour anybody points a mixer at, so real colours get the full effect
    /// while the neutral axis is pinned. Measured at 0.02, 0.04 and 0.08 — all
    /// three pin the greys exactly and none of them changed a pale sky or a
    /// saturated blue by a single count.
    private static let fullyColoured: Double = 0.04

    private static func colourDistanceFromGrey(_ image: CIImage) -> CIImage? {
        let grey = CIFilter.colorControls()
        grey.inputImage = image
        grey.saturation = 0
        guard let greyed = grey.outputImage else { return nil }

        let difference = CIFilter.colorAbsoluteDifference()
        difference.inputImage = image
        difference.inputImage2 = greyed
        guard let deviation = difference.outputImage,
              let peak = CIFilter(name: "CIMaximumComponent",
                                  parameters: [kCIInputImageKey: deviation])?.outputImage else {
            return nil
        }

        let gain = CIFilter.colorMatrix()
        gain.inputImage = peak
        let scale = 1 / fullyColoured
        gain.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        gain.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        gain.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        gain.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let scaled = gain.outputImage else { return nil }

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = scaled
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage
    }

    /// One derived layer: the photo underneath, graded and blurred on its
    /// own, blended back through its matte.
    ///
    /// The stored matte is small on purpose (see `ImageLayer.maskData`), so
    /// it is scaled up to whatever this render's extent is — preview or
    /// native, the same way every layer's own geometry is resolved against
    /// the current extent rather than assumed.
    ///
    /// `blendMode` is deliberately ignored here. It describes how a pasted
    /// piece meets what is behind it, and for a region OF the photo there
    /// is nothing behind it but itself — Multiply would just be a darker
    /// version of the same pixels pretending to be a composite. The panel
    /// hides the row for these layers to match.
    private static func compositeDerivedLayer(_ layer: ImageLayer, maskData: Data,
                                              onto image: CIImage, extent: CGRect) -> CIImage {
        guard let stored = CIImage(data: maskData),
              stored.extent.width > 0, stored.extent.height > 0 else {
            return image
        }

        let scaled = stored
            .transformed(by: CGAffineTransform(scaleX: extent.width / stored.extent.width,
                                               y: extent.height / stored.extent.height))
        let mask = scaled
            .transformed(by: CGAffineTransform(translationX: extent.origin.x - scaled.extent.origin.x,
                                               y: extent.origin.y - scaled.extent.origin.y))
            .cropped(to: extent)

        // A derived layer adjusts the photo under its own matte — it never
        // replaces it. Replacement existed once, for sky, and went with it
        // (see SKY_ARCHIVE/BRIEFSHOW_SKY_NOTES.md).
        let base = image

        var adjusted = layer.adjustments.isNeutral
            ? base
            : applyLocalToneColorDetail(layer.adjustments, to: base)
        if layer.blur > 0 {
            adjusted = layerBlur(adjusted, amount: layer.blur, extent: extent)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjusted
        blend.backgroundImage = image
        blend.maskImage = layer.opacity < 1 ? scaleMaskOpacity(mask, by: layer.opacity) : mask
        return blend.outputImage ?? image
    }
    /// Blur scaled to the PICTURE, not to pixels.
    ///
    /// ⚠️ A sigma in pixels would be wrong here and wrong invisibly: the
    /// preview renders at 2600px and the export at native resolution, so
    /// the same number would blur the two by visibly different amounts —
    /// the client would approve one picture and receive another. 0.02 of
    /// the short edge at full strength.
    private static func layerBlur(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let sigma = min(max(amount, 0), 1) * 0.02 * min(extent.width, extent.height)
        guard sigma > 0.3 else {
            return image
        }
        // Clamped before blurring, cropped after: without the clamp the
        // filter samples nothing outside the frame and darkens every edge.
        return image.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)
    }

    /// A soft matte, stored small on purpose.
    ///
    /// A mask is smooth and mostly flat, so a 1024px copy upscales back to
    /// a native-resolution frame with no visible difference — and it is the
    /// difference between tens of KILObytes and tens of MEGABYTES sitting
    /// in UserDefaults, which is where every edit in this app is kept.
    static func maskPNG(_ mask: CIImage, extent: CGRect, maxEdge: CGFloat = 1024) -> Data? {
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }
        let scale = min(1, maxEdge / max(extent.width, extent.height))
        let scaled = mask.cropped(to: extent)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = scaled.extent.integral
        guard rect.width >= 1, rect.height >= 1 else {
            return nil
        }
        return pngData(for: scaled, pixelRect: rect)
    }

    /// The layer's pixels, decoded ONCE and kept — never resampled, never
    /// reduced.
    ///
    /// ⚠️ This is a speed fix that must not become a quality one, and the
    /// client said so in as many words: *„nemoj da izgubi quality taj duplikat
    /// layer people ili background… quality maximum original i samo smooth drag
    /// movement"*. What is cached is the FULL-RESOLUTION decode of exactly the
    /// bytes that were stored. Nothing here may ever downscale, re-encode or
    /// approximate a layer to go faster — the same rule the top of
    /// BRIEFSHOW_DEVELOP_NOTES.md sets for the preview itself.
    ///
    /// Why it exists: `CIImage(data:)` was being built afresh inside the render
    /// loop, so every frame of a layer drag decoded the whole cut-out PNG
    /// again. Measured on a realistic 1800×2900 cut-out (738 KB) at preview
    /// size: **31.6 ms per frame decoding each time, 8.3 ms reusing the
    /// decode** — 23.3 ms of pure repeat work in a loop that gets 20 ms
    /// between frames. That is the reported *„drhti, nije smooth movement"*.
    /// Compositing itself costs 0.6 ms; it was never the compositing.
    ///
    /// Keyed by the layer's id AND the size and a fingerprint of its bytes, so
    /// a layer whose pixels are replaced (a bake, a flatten, a fresh Select
    /// People) cannot be served the old decode. NSCache because renders run on
    /// more than one queue and it evicts under memory pressure on its own.
    private static let decodedLayerCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        // A photo has a handful of layers, not hundreds.
        cache.countLimit = 12
        return cache
    }()

    private static func decodedLayerImage(_ layer: ImageLayer) -> CIImage? {
        let data = layer.imageData
        guard !data.isEmpty else {
            return nil
        }

        let key = "\(layer.id.uuidString)|\(data.count)|\(dataFingerprint(data))" as NSString
        if let cached = decodedLayerCache.object(forKey: key) {
            return cached
        }
        guard let decoded = CIImage(data: data) else {
            return nil
        }
        decodedLayerCache.setObject(decoded, forKey: key)
        return decoded
    }

    /// A constant-time fingerprint: three 64-byte samples, FNV-1a.
    ///
    /// Deliberately NOT a hash of the whole buffer. This is read on every
    /// render of every layer, and hashing megabytes each time would put back a
    /// smaller version of the cost this cache exists to remove. Paired with the
    /// layer's id and its exact byte count, sampling is enough to tell one
    /// cut-out from another.
    private static func dataFingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        let count = data.count
        let starts = [0, count / 2, max(0, count - 64)]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for start in starts {
                let end = min(start + 64, count)
                guard start < end else { continue }
                for i in start..<end {
                    hash = (hash ^ UInt64(raw[i])) &* 1099511628211
                }
            }
        }
        return hash
    }

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

            // A derived layer holds no pixels — it is a region of the photo
            // underneath, taken through its own matte. It gets its own
            // tone, colour and blur and is blended straight back through
            // that matte, which is the same shape applyLocalAdjustments
            // uses for a mask. No cutout, so no edge artefacts, and it
            // follows the photo when the global sliders move.
            if let maskData = layer.maskData {
                output = compositeDerivedLayer(layer, maskData: maskData, onto: output, extent: extent)
                continue
            }

            guard let source = decodedLayerImage(layer), source.extent.width > 0, source.extent.height > 0 else {
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

            // The layer's own tone and colour, applied to ITS pixels — this
            // is what makes "select a layer, then move a slider" mean that
            // layer and nothing else. Before the transform rather than
            // after: the piece is smaller than the photo, so it is cheaper
            // here, and the result is the same either way.
            var graded = layer.adjustments.isNeutral
                ? source
                : applyLocalToneColorDetail(layer.adjustments, to: source)
            if layer.blur > 0 {
                graded = layerBlur(graded, amount: layer.blur, extent: source.extent)
            }

            // Centre → scale → rotate → put the centre where it belongs.
            // Built in that order because a rotation is only meaningful
            // about a point, and the layer's own centre is the only point
            // a client dragging a rotate handle is thinking about.
            var positioned = graded.transformed(by: CGAffineTransform(
                translationX: -source.extent.midX, y: -source.extent.midY))
            positioned = positioned.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            if layer.rotationDegrees != 0 {
                // Negated: the handle turns clockwise on screen, where the
                // y axis points down, and Core Image's turns anticlockwise
                // in a y-up space. Without the sign the layer would spin
                // the opposite way from the cursor.
                positioned = positioned.transformed(by: CGAffineTransform(
                    rotationAngle: -layer.rotationDegrees * .pi / 180))
            }

            positioned = positioned.transformed(by: CGAffineTransform(
                translationX: originX + targetWidthPx / 2,
                y: originY + targetHeightPx / 2))

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

    /// ⚠️ THE SAME COLOUR SPACE THE CLIENT LOOKS THROUGH. Do not take these
    /// options away.
    ///
    /// This was a bare `CIContext()` and it cost a real bug: "Select People"
    /// gave back a cut-out that was a different colour from the photograph it
    /// had just been cut out of, reported as *„dobio sam kopiju totalno
    /// drugačiju, vidi oči recimo"*.
    ///
    /// Core Image applies tone and colour filters in the context's WORKING
    /// colour space, and a default context works in LINEAR sRGB while every
    /// context this app renders a picture through works in sRGB
    /// (makeBriefEditsCIContext, briefEditsCIContext). So the identical filter
    /// graph — the client's own exposure, contrast and saturation — landed on
    /// different numbers depending on who rendered it, and a cut-out is the
    /// one place in the app where both results end up side by side on screen.
    ///
    /// Measured on the real code by `Tools/run-layer-extract-color-test.py`
    /// before the options were added: with the client's own +0.62 exposure a
    /// channel was off by 52/255, and a brown eye came out (54,0,0) where the
    /// photo showed (89,50,26) — the darker parts of the iris clipped to
    /// nothing. With no edits at all the drift is 0, which is exactly why this
    /// went unnoticed for so long: on an untouched photo the bug is invisible.
    private static let sharedExtractionContext = CIContext(options: [
        .workingColorSpace: briefEditsSRGBColorSpace,
        .outputColorSpace: briefEditsSRGBColorSpace
    ])

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

    /// The pixels under an arbitrary MASK, as a PNG cropped to `pixelRect`.
    ///
    /// The mask twin of `extractSelectionPNG`, for the same consumer: an
    /// ImageLayer that can then be moved, scaled and rotated. PNG
    /// specifically, because a Vision mask has soft edges and only PNG
    /// carries the alpha that keeps them soft — a JPEG would hand back a
    /// hard rectangle with the background baked in around the person.
    static func extractMaskedPNG(mask: CIImage, from image: CIImage, pixelRect: CGRect) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              pixelRect.width >= 1, pixelRect.height >= 1 else {
            return nil
        }

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = clear
        blend.maskImage = mask

        guard let masked = blend.outputImage else {
            return nil
        }

        return pngData(for: masked, pixelRect: pixelRect.integral)
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
        // The colour space is named here too, not left to the context's
        // default output space: this is the tag the PNG carries onto the
        // client's disk, and it has to say the same thing the pixels mean.
        guard let cgImage = sharedExtractionContext.createCGImage(
            cropped, from: pixelRect, format: .RGBA8, colorSpace: briefEditsSRGBColorSpace) else {
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
    /// `context` is a parameter, not a hardcoded global, because which context
    /// this renders through decides whether the editor works.
    ///
    /// It used to render through the shared heavy context. That context is the
    /// one the full-resolution refine holds for seconds at a time on a RAW, so
    /// the histogram — computed in the same closure as the preview, right
    /// after the picture was successfully rendered — blocked on it. The
    /// finished image was sitting in a local variable and never got assigned,
    /// and the client saw an empty preview. Caught by logging every branch of
    /// renderNow and finding the trace simply stop after "got cgImage".
    static func luminanceHistogram(of image: CIImage, bucketCount: Int = 48,
                                   context: CIContext) -> [CGFloat] {
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
        context.render(
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
/// CISharpenLuminance's own default radius, in pixels.
///
/// Written down because `sharpenRadius` is expressed as a MULTIPLE of it, so
/// that a radius of 1 is byte-for-byte the filter this app ran before the
/// slider existed. Verified against the filter's attributes at run time — see
/// the assertion where it is used.
private let briefEditsDefaultSharpenRadius: Double = 1.69

// THREE contexts, by role, not one shared one — and the split is load-bearing.
//
// A CIContext serializes internally: every render through it takes the same
// `-[CIContext lock]`. So a single shared context makes every render in the
// app queue behind every other one, no matter how many DispatchQueues they
// were spread across. That was caught with `sample` on a Create that would
// not show a photo:
//
//     renderNow          → briefEditsDisplayCGImage → -[CIContext lock]  (waiting)
//     refreshEditedThumbnails → makeEditedShowGridThumbnail → same lock  (holding)
//
// ShowGrid re-rendering its edited thumbnails was holding the lock, and the
// editor's interactive preview was stuck behind it — the photo simply never
// appeared. An earlier attempt at this bug split the DISPATCH QUEUES apart,
// which changed nothing, because the queues were never the bottleneck.
//
// Each context keeps its own caches, which is the cost. It is worth paying:
// the three jobs have genuinely different urgency, and none of them should be
// able to stall the one the client is looking at.
private func makeBriefEditsCIContext() -> CIContext {
    CIContext(options: [
        .workingColorSpace: briefEditsSRGBColorSpace,
        .outputColorSpace: briefEditsSRGBColorSpace,
        .cacheIntermediates: false
    ])
}

// The one the client is watching: Create's interactive preview, and NOTHING
// else — not even the refine that later replaces what it drew.
//
// That exclusion is the whole value of this context and it was got wrong once
// already. The refine was routed here on the reasoning that it replaces the
// preview's own image, which is true and beside the point: it is a
// FULL-RESOLUTION render, seconds long on a RAW, and it holds this context's
// lock for every one of them. `sample` caught it exactly:
//
//     refinedRenderNow → -[CIContext lock]   (holding, mid full-res render)
//     renderNow        → -[CIContext lock]   (waiting)
//
// and the client saw an empty preview with the placeholder text. The rule is
// not "group renders by what they draw", it is "nothing slow shares a context
// with something interactive".
private let briefEditsPreviewCIContext = makeBriefEditsCIContext()

// ShowGrid's tiles and Create's filmstrip — many small renders, none of
// them urgent, and the ones that were blocking the preview.
private let briefEditsThumbnailCIContext = makeBriefEditsCIContext()

// The heavy end: the full-resolution refine, the exports, the erases. They all
// run on developRenderQueue, one at a time, so sharing one context between
// them costs nothing — and keeps every one of them off the preview's.
//
// One shared, Metal-backed context for both the live (downsampled) preview
// and the full-resolution export — CIContext is safe to reuse across many
// renders of different sizes.
private let briefEditsCIContext = CIContext(options: [
    .workingColorSpace: briefEditsSRGBColorSpace,
    .outputColorSpace: briefEditsSRGBColorSpace,
    .cacheIntermediates: false
])

// Renders a CIImage to a CGImage that is ALREADY DRAWN — the whole point of
// this helper, and it is not a detail.
//
// `createCGImage(_:from:)` hands back a CGImage backed by a lazily-rendered
// IOSurface: the filter graph is not evaluated when you call it, but when
// something first draws the result. So every render below could sit on a
// background queue looking perfectly well-behaved while the actual work was
// deferred to whoever displayed it — and that is Core Animation, on the MAIN
// THREAD, inside its layer-commit.
//
// Caught in the act with `sample` on a beachballed app: the main thread was
// 100% inside
//     CA::Layer::prepare_contents → CA::Render::prepare_image
//       → CI::copyIOSurfaceCallback → CIContext render
//         → 83 nested levels of CI::Context::recursive_render
// which is the entire patch-stroke filter graph being evaluated during a
// window flush. No amount of moving work onto developRenderQueue could have
// helped: the queue was never where the work happened.
//
// `deferred: false` makes createCGImage do the rendering there and then, on
// the thread that asked for it. Only for images destined for the SCREEN; the
// export paths hand their CGImage straight to NSBitmapImageRep, which forces
// the same realization on their own background queue already.
private func briefEditsDisplayCGImage(_ image: CIImage, from rect: CGRect,
                                      context: CIContext) -> CGImage? {
    context.createCGImage(image, from: rect, format: .RGBA8,
                          colorSpace: briefEditsSRGBColorSpace,
                          deferred: false)
}

// The interactive preview's own queue, separate from the heavy one below.
//
// They were one serial queue, and that was a real bug: the refine and the
// exports render the FULL-resolution image, which on a RAW with a deep patch
// graph is many seconds, and every interactive render sat behind it. The
// symptom was clicking a filmstrip thumbnail and getting the empty
// "Select a photo from the filmstrip" placeholder — the decode had finished,
// so nothing said "loading", but the render that would have produced a picture
// was still queued behind a refine and had not run yet.
//
// Splitting them is safe for the one reason that made a single queue necessary
// in the first place. That reason is the shared CIRAWFilter: render() pushes
// Exposure/Temperature/Tint into the filter, so two renders through the SAME
// filter must not overlap. But `previewBaseImage` and `fullBaseImage` hold
// DIFFERENT CIRAWFilter instances, deliberately — see loadPreviewBaseImage,
// which creates its own precisely so the draft filter can be driven on every
// slider tick without disturbing the full-quality one. renderNow is the only
// thing that touches the preview filter; everything else touches the full one.
// One serial queue each, and neither filter is ever written concurrently.
private let developPreviewRenderQueue = DispatchQueue(
    label: "com.rocketsbrief.briefshow.develop.render.preview", qos: .userInteractive)

// Serial (not concurrent) — PhotoEditRenderer.render() mutates a RAW
// photo's shared CIRAWFilter in place (see PhotoBaseImage.raw's own doc
// comment), so two renders for the same photo must never run at once, or
// their concurrent writes to the same filter's exposure/neutralTemperature/
// neutralTint properties would race. A serial queue also naturally finishes
// slider-drag renders in the order they were scheduled, so a stale result
// can never briefly flash on screen after a newer one — a small
// correctness improvement for the non-RAW path too, not just RAW.
private let developRenderQueue = DispatchQueue(label: "com.rocketsbrief.briefshow.develop.render")

/// Baking a photo's render in, and duplicating a photo beside itself.
///
/// Lives here rather than inside `DevelopView` because BOTH menus need it —
/// Create's filmstrip and ShowGrid's grid — and because the CIContext and
/// the render queue it uses are private to this file. Two copies of this
/// would be two places for "Duplicate" to come to mean different things.
enum PhotoBakeService {

    /// One photo's worth of work.
    ///
    /// `source` and `target` are the same photo for an in-place bake. For a
    /// duplicate they differ on purpose: the render is taken from the
    /// ORIGINAL — which is what honours its own flattened pixels — and
    /// stored under the COPY, so the copy ends up carrying the picture the
    /// client can see rather than the untouched file underneath it.
    struct BakeJob {
        let source: URL
        let target: URL
        let settings: PhotoEditSettings
    }

    /// Copies `url` beside itself and hands back the copy.
    ///
    /// The FILE is copied, not the flattened TIFF: the copy has to stay a
    /// valid photo of its own type, and it is also what Unflatten falls
    /// back to. The baked picture is written separately, by `bake`.
    static func duplicate(_ url: URL, suffix: String) -> URL? {
        guard let copyURL = duplicateURL(for: url, suffix: suffix) else {
            return nil
        }

        do {
            try FileManager.default.copyItem(at: url, to: copyURL)
        } catch {
            return nil
        }

        return copyURL
    }

    /// `Beach.jpg` → `Beach BW.jpg`, then `Beach BW 2.jpg`, and so on.
    ///
    /// The black-and-white copy is named for what it IS rather than
    /// Finder's "copy": it stops being a copy the moment it is made, and a
    /// folder full of "… copy" files says nothing about which one is the
    /// black-and-white version. A plain duplicate keeps "copy", which is
    /// the word Finder uses for exactly that.
    ///
    /// Gives up after 99 rather than looping forever if the filesystem
    /// keeps reporting every candidate as taken.
    static func duplicateURL(for url: URL, suffix: String) -> URL? {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension

        for attempt in 1...99 {
            let name = attempt == 1 ? "\(base) \(suffix)" : "\(base) \(suffix) \(attempt)"
            let candidate = fileExtension.isEmpty
                ? folder.appendingPathComponent(name)
                : folder.appendingPathComponent(name).appendingPathExtension(fileExtension)

            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    /// Bakes each job's render in, writes the results to `PhotoEditStore`,
    /// and reports what each photo was left carrying.
    ///
    /// On `developRenderQueue`, because this decodes and renders every photo
    /// at full resolution — the same work an export does, and not something
    /// to run on the main thread for a selection of forty. The completion
    /// runs on the main thread, after the store has been written and
    /// flushed, so a caller only has to reconcile its own view state.
    static func bake(_ jobs: [BakeJob], desaturate: Bool,
                     completion: @escaping (_ baked: [URL: PhotoEditSettings], _ failed: Int) -> Void) {
        guard !jobs.isEmpty else {
            completion([:], 0)
            return
        }

        developRenderQueue.async(qos: .userInitiated) {
            var baked: [URL: PhotoEditSettings] = [:]
            var failed = 0

            for job in jobs {
                if let result = bakedSettings(for: job, desaturate: desaturate) {
                    baked[job.target] = result
                } else {
                    failed += 1
                }
            }

            DispatchQueue.main.async {
                for (url, result) in baked {
                    PhotoEditStore.setSettings(result, for: url)
                }
                PhotoEditStore.flushNow()
                completion(baked, failed)
            }
        }
    }

    private static func bakedSettings(for job: BakeJob, desaturate: Bool) -> PhotoEditSettings? {
        // loadBaseImage opens the SOURCE's flattened copy when it has one,
        // so a photo that was already baked bakes again from the picture it
        // actually shows rather than from the file underneath it.
        guard let base = PhotoEditRenderer.loadBaseImage(from: job.source) else {
            return nil
        }

        // `applyCrop: false` for exactly the reason flattenPhoto gives: the
        // crop is a description of the photo and survives as a setting, so
        // baking it in would make it impossible to open the crop back up.
        let rendered = PhotoEditRenderer.render(job.settings, on: base, applyCrop: false)

        do {
            try FlattenedImageStore.flatten(rendered, settings: job.settings,
                                            for: job.target, context: briefEditsCIContext)
        } catch {
            return nil
        }

        var result = PhotoEditSettings()
        result.crop = job.settings.crop
        if desaturate {
            result.saturation = -1
        }
        return result
    }
}

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

/// Drives the card ShowGrid puts up while Create is opening.
///
/// Opening was never instant, and it used to give no sign at all: the client
/// double-clicked a photo and the app sat there looking hung — the report was
/// four seconds of nothing. Most of that turned out to be `PhotoEditStore`
/// re-decoding its whole dictionary per photo (fixed at the source, see its
/// own comment), but the rest is real work — building the window and decoding
/// the photograph — and real work deserves to be shown rather than hidden.
///
/// The fraction moves at genuine stage boundaries, not on a timer. The last
/// stage is the honest one: it ends when the first photo has actually been
/// decoded and drawn, which is the moment the editor is usable, so the bar
/// cannot reach the end while the client is still looking at an empty window.
final class DevelopLaunchProgress: ObservableObject {
    static let shared = DevelopLaunchProgress()

    @Published private(set) var isOpening = false
    @Published private(set) var fraction: Double = 0
    @Published private(set) var stage: String = ""

    private init() {}

    func begin() {
        isOpening = true
        fraction = 0.08
        stage = "Preparing…"
    }

    func report(_ fraction: Double, _ stage: String) {
        guard isOpening else { return }
        // Never backwards: the photo-decode stage can land before or after the
        // window stages depending on how big the file is, and a bar that
        // retreats reads as a fault.
        self.fraction = max(self.fraction, fraction)
        self.stage = stage
    }

    /// Called when the first photo is on screen. Holds the full bar briefly so
    /// it is seen completed rather than vanishing at nine tenths.
    func finish() {
        guard isOpening else { return }
        fraction = 1
        stage = "Ready"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.isOpening = false
            self?.fraction = 0
            self?.stage = ""
        }
    }

    /// Opening failed or the window was already up — take the card down now.
    func cancel() {
        isOpening = false
        fraction = 0
        stage = ""
    }
}

final class DevelopWindowController {
    static let shared = DevelopWindowController()

    /// The window's title, and — much more importantly — the string BOTH local
    /// key monitors match on to decide whether a keystroke is theirs.
    ///
    /// A constant rather than three copies of a literal, because those monitors
    /// are APP-WIDE: a monitor whose guard no longer matches its own window
    /// keeps receiving and ACTING ON keys while a different window is focused,
    /// with whatever context it happens to hold. That is not hypothetical — see
    /// the note at the top of BRIEFSHOW_DEVELOP_NOTES.md, where exactly that
    /// recursively copied the whole Desktop folder into itself, twice.
    ///
    /// So renaming the window is a one-line change here and cannot silently
    /// leave a guard behind.
    static let windowTitle = "Create"


    private var windowController: NSWindowController?

    /// True from the moment a click is accepted until the window exists.
    ///
    /// `windowController` is not set until the far side of the hop below, so it
    /// cannot answer "is one already coming". ShowGrid's launch card swallows
    /// clicks, but it draws one runloop turn AFTER `begin()` — that hop is the
    /// only reason it gets to draw at all — and a click landing in that gap
    /// used to queue a SECOND `openNow`, which builds a second window and
    /// leaves the first one orphaned with nothing pointing at it. Clicking
    /// again is precisely what someone does when a click looks ignored, so this
    /// guard covers the exact case the report describes.
    private var isOpening = false

    private var closeWatcher: DevelopWindowCloseWatcher?

    private init() {}

    func open(photoURLs: [URL], initialSelection: URL?) {
        guard !isOpening else {
            return
        }

        if let controller = windowController {
            // A window that is on screen: bring it forward.
            //
            // One that is NOT is stale, and it is reachable: closing Create
            // with the red titlebar button never ran `close()`, so the
            // controller stayed set, pointing at a hidden window built around
            // whatever photo list was open when it was made. Re-showing it
            // would hand back an editor for the wrong folder — and it is
            // exactly the shape of "I clicked and it did not react", since the
            // window it orders in may be anywhere, including behind this one.
            //
            // The delegate below now closes that gap at the source; this is
            // the belt to its braces, and it also covers a controller left over
            // from any other path that loses its window.
            if controller.window?.isVisible == true {
                DevelopLaunchProgress.shared.cancel()
                // Activate FIRST, order second — see the note in openNow.
                NSApp.activate(ignoringOtherApps: true)
                controller.window?.makeKeyAndOrderFront(nil)
                return
            }
            close()
        }

        isOpening = true
        DevelopLaunchProgress.shared.begin()

        // Everything below this hop is synchronous and is the slow part —
        // building the window and mounting the SwiftUI tree. Done inline it
        // would run to completion inside the SAME runloop turn that asked for
        // the card, so the card would never get a chance to draw and the
        // client would see exactly the frozen app this is meant to fix. The
        // hop lets one frame out first.
        DispatchQueue.main.async {
            self.openNow(photoURLs: photoURLs, initialSelection: initialSelection)
        }
    }

    private func openNow(photoURLs: [URL], initialSelection: URL?) {
        DevelopLaunchProgress.shared.report(0.25, "Opening Create…")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 640)
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller

        // Closing with the red titlebar button has to do everything the Done
        // button does. It did not: `close()` — and with it the flush of the
        // debounced settings write — only ran from Done, so a client who shut
        // the editor the ordinary macOS way left up to half a second of their
        // last edit sitting unwritten, and left this controller pointing at a
        // window that was no longer on screen.
        let watcher = DevelopWindowCloseWatcher { [weak self] in
            self?.close()
        }
        closeWatcher = watcher
        window.delegate = watcher

        DevelopLaunchProgress.shared.report(0.45, "Building the editor…")

        window.contentView = ClickThroughHostingView(
            rootView: DevelopView(
                photoURLs: photoURLs,
                initialSelection: initialSelection,
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )

        DevelopLaunchProgress.shared.report(0.7, "Loading the photo…")

        // ORDER MATTERS HERE, and it was the wrong way round.
        //
        // It was `showWindow` and then `activate`. Activating an app makes
        // AppKit re-assert that app's own window order, and the window it puts
        // on top is the one it considers key — which, in the same runloop turn
        // that a brand-new window is being mounted, is still ShowGrid. So the
        // editor could be built, shown, and then immediately buried behind the
        // window the client was looking at.
        //
        // From the client's seat that is a click that did nothing. And it
        // explains the other half of the report — that clicking a second time
        // worked — exactly: by then `windowController` is set and the window is
        // visible, so the second click takes the makeKeyAndOrderFront branch in
        // `open()` above, which does nothing but bring it forward.
        //
        // Reported right after switching the theme, and that fits rather than
        // being a coincidence: the theme swatch changes @Published state inside
        // `withAnimation`, which re-renders every view in this window that
        // reads AppColors — the header button style alone is used in 37 places.
        // A busy main thread is where a race between activating and ordering
        // gets decided the wrong way.
        //
        // Activate first, then order in, then make it key. The last call is not
        // redundant with showWindow: showWindow ran before the activation, and
        // this one is what fixes the front-most window after it.
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        isOpening = false

        // The card is taken down by DevelopView the moment the first photo is
        // actually drawn (see loadImages). This is the backstop for the case
        // where that never happens — an unreadable file, a decode that fails —
        // so a failed open cannot leave the card on screen forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            DevelopLaunchProgress.shared.cancel()
        }
    }

    func close() {
        // Anything still sitting in the debounced write goes out now. The
        // window that owns the edits must not be able to disappear with work
        // unwritten, and this is also what makes ShowGrid's thumbnails correct
        // the instant the editor is dismissed rather than half a second later.
        PhotoEditStore.flushNow()
        // Detached BEFORE closing, so the watcher cannot call back into this
        // and run the whole thing a second time.
        windowController?.window?.delegate = nil
        closeWatcher = nil
        windowController?.close()
        windowController = nil
        isOpening = false
    }
}

/// Turns "the window went away" into the same call the Done button makes.
///
/// A separate object rather than making the controller itself the delegate:
/// NSWindow holds its delegate weakly, and DevelopWindowController is a plain
/// singleton that is never otherwise referenced by AppKit, so this keeps the
/// ownership visible — the controller holds the watcher, the window points at
/// it, and both go away together in `close()`.
private final class DevelopWindowCloseWatcher: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
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

// Filmstrip thumbnails decode here rather than on DispatchQueue.global.
//
// Priority is the point. These used to run at .userInitiated — the same band
// as the edit render the client is actually looking at — so a folder's worth
// of thumbnail decodes competed directly with the preview. A thumbnail that
// fills in a moment later costs nothing; a dropped frame mid-slider-drag is
// the complaint. Serial rather than concurrent for the same reason: thumbnails
// appear left to right at a steady rate instead of all contending at once.
//
// This is the second half of the fix; LazyHStack in `filmstrip` is the first,
// and bounds HOW MANY are ever asked for. Either alone leaves the symptom.
private let filmstripThumbnailQueue = DispatchQueue(
    label: "com.rocketsbrief.briefshow.filmstrip-thumbnails",
    qos: .utility
)

// How many decoded filmstrip thumbnails are kept, and how big each one is
// decoded. The two numbers are one decision: an uncapped cache on a few
// thousand photos is hundreds of megabytes that never come back, so the budget
// is held at roughly 100 MB and the count follows from the size.
//
// 384px, raised from 240px when the filmstrip became resizable. The strip used
// to be a fixed 120pt with 100pt thumbnails, where 240px was exactly right on
// a Retina screen (100pt × 2) with a little to spare. Now the client can drag
// it taller, and a thumbnail drawn larger than its own pixels goes soft — so
// the decode has to cover the tallest the strip can get. 384px covers a 192pt
// thumbnail at 2x, which is what filmstripMaxHeight allows; the two must move
// together or one of them is a lie.
//
// Cost: ~0.59 MB decoded (384 × 384 × 4), against ~0.25 MB at 240px. The count
// drops from 400 to 180 to pay for it and the total is unchanged. Evicted
// oldest-first, and a re-scroll simply decodes again — cheap, since it is one
// at a time off the interactive path.
private let filmstripThumbnailPixelSize: CGFloat = 384
private let filmstripThumbnailCacheLimit = 180

// Where the brush cursor is, held in a reference the parent deliberately does
// NOT observe.
//
// The cursor moves 60-120 times a second. This position used to be @State on
// DevelopView, so every one of those hover events invalidated DevelopView.body
// — the image, every section of the adjustment panel, the filmstrip, the
// histogram — in order to move one circle. That is the "moving the mouse lags,
// it isn't smooth" report: the work per mouse move was proportional to the
// entire screen rather than to the ring being drawn.
//
// DevelopView keeps this as @State holding a CLASS, which persists the
// reference across body evaluations without subscribing to its @Published
// changes (only reassigning the property itself would invalidate the parent,
// and nothing does). BrushCursorRing observes it, so a mouse move now redraws
// the ring and nothing else.
final class BrushCursorPosition: ObservableObject {
    @Published var location: CGPoint?

    /// Whether a stroke is being painted right now. Lives here rather than in
    /// @State on DevelopView, and that is the whole point of it being here.
    ///
    /// It was @State, flipped true on the first drag event of every stroke, on
    /// the reasoning that twice per stroke is cheap. It is not: a @State write
    /// invalidates DevelopView.body, and that body is the image, the panel, the
    /// filmstrip, the histogram and the toolbar — including removalAreaPixels,
    /// which is O(painted points x erase dabs) and is read several times a
    /// pass. So every stroke began with a full rebuild of the whole screen,
    /// one that got heavier the more had already been painted. That is exactly
    /// the "it still lags sometimes, mostly when I start" that was reported
    /// after the earlier per-point fix.
    ///
    /// The only thing that reads it is the cursor ring, which observes this
    /// object already — so moving it here takes the count of body passes during
    /// a stroke from one to ZERO. Nothing outside the ring redraws until the
    /// mouse comes up and commitRemovalStroke() writes the finished stroke.
    @Published var isStrokeInProgress: Bool = false
}

// The ring that follows the cursor. Hit testing is off: the hover events and
// the paint drag both belong to the parent's own hit area, which stays exactly
// where it was — this view only draws.
private struct BrushCursorRing: View {
    @ObservedObject var cursor: BrushCursorPosition
    let diameter: CGFloat
    let color: Color
    let isDashed: Bool

    var body: some View {
        Group {
            // Hidden while painting: the stroke being drawn already shows the
            // brush at its true width, and a ring on top of it only doubles
            // the line. Read off the observed object rather than passed in, so
            // that setting it does not touch the parent's body.
            if let location = cursor.location, !cursor.isStrokeInProgress {
                Circle()
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 1.5, dash: isDashed ? [4, 3] : [])
                    )
                    .frame(width: diameter, height: diameter)
                    .position(location)
            }
        }
        .allowsHitTesting(false)
    }
}

// Points of the stroke being painted RIGHT NOW, in a reference the parent
// holds but does not observe — the same trick BrushCursorPosition uses, for
// the same reason and the other half of the same problem.
//
// This used to be @State on DevelopView, appended to on every drag event. A
// drag fires at screen rate, so painting one stroke invalidated the entire
// DevelopView.body — image, panel, filmstrip, histogram — dozens of times a
// second, and only to extend one line by one point. Reported as: painting
// lags, and please only work out what was painted once I let go.
//
// Now the parent learns nothing until the mouse comes up: only ActiveStrokeLayer
// observes this, so a drag redraws that one path and nothing else, and
// commitRemovalStroke() folds the finished stroke into `removalStrokes` in a
// single @State write — one body pass per stroke instead of one per point.
final class ActiveStrokePoints: ObservableObject {
    @Published var points: [CGPoint] = []
}

// Turns unit-space points into a screen-space path. A free function rather
// than a method so both DevelopView and ActiveStrokeLayer can call the SAME
// one — the in-progress stroke and the committed strokes have to be drawn
// identically, or the line would visibly shift the moment the mouse is let go.
func briefShowStrokePath(_ points: [CGPoint], frame: CGRect) -> Path {
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

// Every dab that an erase stroke takes away, in unit space.
func briefShowEraseDabs(_ strokes: [BrushStroke]) -> [CGRect] {
    strokes.filter(\.isErase).flatMap { stroke -> [CGRect] in
        let radius = stroke.size / 2
        return stroke.points.map {
            CGRect(x: $0.x - radius, y: $0.y - radius, width: stroke.size, height: stroke.size)
        }
    }
}

// The unit-space box a stroke covers, brush width included, ignoring any part
// of it that has since been erased. nil for a stroke with nothing left.
//
// A point is dropped once an erase dab covers its CENTRE, rather than when it
// is fully contained: an erase pass is made of overlapping dabs, and asking for
// full containment would let a point survive between two of them and hold the
// whole box open. That rule was already load-bearing when the size gate was the
// only thing measuring this — see the report that erasing made the area grow.
func briefShowStrokeBox(_ stroke: BrushStroke, erasedBy erasures: [CGRect] = []) -> CGRect? {
    let radius = stroke.size / 2
    var box: CGRect?
    for point in stroke.points where !erasures.contains(where: { $0.contains(point) }) {
        let dab = CGRect(x: point.x - radius, y: point.y - radius,
                         width: stroke.size, height: stroke.size)
        box = box?.union(dab) ?? dab
    }
    return box
}

// Splits what has been painted into SEPARATE groups of marks — one per cluster
// of strokes that sit near each other.
//
// This is a bug fix, not a refinement. Both models work inside a SQUARE region
// centred on the mask's overall bounding box, with the side capped at the
// photo's short edge (see squareRegion). Paint one mark at the far left and
// another at the far right of a landscape photo and that box spans nearly the
// full width, so the square lands in the MIDDLE of the frame — and contains
// neither mark. makeBuffers then counts zero hole pixels, returns nil, and the
// caller quietly wiped the paint and did nothing at all. Reported exactly that
// way: "kada kliknem na AI generative ništa se ne desi, samo izbriše paint".
//
// Splitting is also the sharper answer, which is why it beats simply widening
// the region: every mark gets its own 512 buffer over its own small piece of
// the photo, instead of all of them sharing one squashed over the whole frame.
// A region big enough to cover both marks would work and come back as mush.
//
// Boxes are inflated by a brush width before being compared, so marks that
// belong to the same object — dabs laid side by side, a hand and what it holds —
// stay in ONE group rather than being cut into pieces the model then has to
// blend back together across a seam.
//
// Returns the ORIGINAL strokes, grouped. The erase filtering decides only where
// each stroke still is, not what gets handed to the model — the mask subtracts
// erasures for real, in Core Image, where it can do it with soft edges.
func briefShowStrokeClusters(_ strokes: [BrushStroke], erasedBy erasures: [CGRect] = []) -> [[BrushStroke]] {
    var clusters: [(box: CGRect, reach: CGRect, strokes: [BrushStroke])] = []
    for stroke in strokes where !stroke.isErase {
        guard let box = briefShowStrokeBox(stroke, erasedBy: erasures) else { continue }
        clusters.append((box, box.insetBy(dx: -stroke.size, dy: -stroke.size), [stroke]))
    }

    // Merged to a fixed point rather than in a single pass: merging grows a
    // box, and a grown box can reach a cluster the smaller one could not.
    // Three marks in a row whose ends only meet through the middle one have to
    // come out as a single group, not as two — and the bridging mark is not
    // necessarily the one painted second.
    var didMerge = true
    while didMerge {
        didMerge = false
        search: for i in 0..<clusters.count {
            for j in (i + 1)..<clusters.count where clusters[i].reach.intersects(clusters[j].reach) {
                clusters[i].box = clusters[i].box.union(clusters[j].box)
                clusters[i].reach = clusters[i].reach.union(clusters[j].reach)
                clusters[i].strokes.append(contentsOf: clusters[j].strokes)
                clusters.remove(at: j)
                didMerge = true
                break search
            }
        }
    }
    return clusters.map(\.strokes)
}

// One repair the model will be asked to do.
struct BriefShowRemovalJob {
    var usesVisionMask: Bool
    var strokes: [BrushStroke]
    // Unit space. CGRect.null when there is nothing measurable — a Vision mask
    // whose bounding box could not be read — so it contributes nothing to a
    // size decision rather than pretending to a size it does not have.
    var box: CGRect
}

// The complete list of repairs one press of a Clean Up button will perform.
//
// Shared by eraseMaskedArea and by the size gate on the buttons, and that
// sharing is the point: the gate used to measure the union of EVERYTHING
// painted, which is why two small marks at opposite edges of the frame switched
// Quick off even though neither one is anywhere near its limit. What the model
// actually has to swallow is the biggest single job, so that is what has to be
// measured — and the only way to keep the two from drifting apart is for both
// to read the same list.
func briefShowRemovalJobs(
    strokes: [BrushStroke],
    hasVisionMask: Bool,
    visionBox: CGRect?
) -> [BriefShowRemovalJob] {
    let erasures = briefShowEraseDabs(strokes)
    var clusters = briefShowStrokeClusters(strokes, erasedBy: erasures)

    var jobs: [BriefShowRemovalJob] = []
    if hasVisionMask {
        // Marks painted ON the Vision mask belong to the object it found —
        // someone touching up a shoulder "Select People" missed is not asking
        // for a second repair right next to the first.
        var job = BriefShowRemovalJob(
            usesVisionMask: true, strokes: [], box: visionBox ?? .null)
        if let visionBox {
            var separate: [[BrushStroke]] = []
            for cluster in clusters {
                let box = cluster.compactMap { briefShowStrokeBox($0, erasedBy: erasures) }
                    .reduce(nil) { (union: CGRect?, next) in union?.union(next) ?? next }
                if let box, box.intersects(visionBox) {
                    job.strokes.append(contentsOf: cluster)
                    job.box = job.box.union(box)
                } else {
                    separate.append(cluster)
                }
            }
            clusters = separate
        }
        jobs.append(job)
    }

    for cluster in clusters {
        let box = cluster.compactMap { briefShowStrokeBox($0, erasedBy: erasures) }
            .reduce(nil) { (union: CGRect?, next) in union?.union(next) ?? next }
        jobs.append(BriefShowRemovalJob(usesVisionMask: false, strokes: cluster, box: box ?? .null))
    }
    return jobs
}

// Turns unit-space points into a CLOSED screen-space polygon. A free function
// for the same reason briefShowStrokePath is one: the outline being dragged and
// the outline once committed have to be drawn by the SAME code, or the shape
// would visibly jump the moment the mouse comes up.
func briefShowClosedPolygonPath(_ points: [CGPoint]) -> Path {
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

// Draws the free-hand outline being dragged right now — the Patch tool's and
// the Selection tool's, which are the same job twice.
//
// Exists for exactly the reason ActiveStrokeLayer does, and was added later
// because those two tools were left behind when the brush was fixed: their
// points lived in @State on DevelopView and were appended to on every drag
// event, so drawing one lasso invalidated the whole editor — image, panel,
// filmstrip, histogram — dozens of times a second. Reported as "kada kliknem na
// patch laguje, nije smooth".
//
// The hint text is INSIDE this view rather than beside it in the parent. Putting
// the "no points yet" condition in the parent's body would put the invalidation
// straight back, which is the thing this exists to avoid.
private struct ActiveOutlineLayer: View {
    @ObservedObject var outline: ActiveStrokePoints
    let frame: CGRect
    let color: Color
    let hint: String

    var body: some View {
        Group {
            if outline.points.count > 1 {
                briefShowClosedPolygonPath(outline.points.map {
                    CGPoint(x: frame.minX + $0.x * frame.width,
                            y: frame.minY + $0.y * frame.height)
                })
                .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.0, dash: [5, 3]))
            } else {
                Text(hint)
                    .font(.custom("Figtree", size: 11).weight(.medium))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

// What a painting tool's cursor is doing right now: the stroke being dragged,
// where the brush ring sits, and — for the clone stamp — where the ⌥-held
// "source will land here" ring sits.
//
// All three in ONE object because the overlays' conditions read them together
// ("brush ring, but only if no source ring and no stroke"), and a condition
// split across two observables would have to be evaluated in the parent, which
// is exactly the invalidation this exists to remove. Shared by the Brush and
// the Patch stamp; the Brush simply never sets `sourceHover`.
final class ToolCursor: ObservableObject {
    @Published var stroke: [CGPoint] = []
    @Published var brushHover: CGPoint?
    @Published var sourceHover: CGPoint?
}

// Draws the clone-stamp's live feedback. Same reason as ActiveStrokeLayer: this
// used to be four `if let` branches on @State in DevelopView's own body, read on
// every hover event and every drag event, so moving the mouse across the photo
// rebuilt the image, the panel, the filmstrip and the histogram — before any
// painting had even started.
/// Where the clone stamp is reading pixels FROM.
///
/// A circle the same size as the brush, dashed, exactly as Photoshop draws it
/// — because the thing worth knowing is not merely "somewhere over there" but
/// how much is being lifted, and the brush size is the answer to that. It
/// replaced a fixed 16-18pt "viewfinder" glyph that said nothing about size.
///
/// The dashes are what separate it at a glance from the solid brush ring that
/// shows where paint LANDS: solid is where you are, dashed is where it comes
/// from. The colour is the app's progress yellow, passed in rather than picked
/// here so it follows the theme.
///
/// Nothing under the dashes — no second ring, no shadow. Both were tried and
/// both were rejected for the same reason: they put a dark smudge on the
/// client's photograph to make an overlay easier to see, which is the wrong
/// trade on a tool for retouching pictures. The orange carries itself.
private struct PatchSourceCircle: View {
    let center: CGPoint
    let diameter: CGFloat
    let color: Color

    var body: some View {
        Circle()
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            .frame(width: diameter, height: diameter)
            .position(center)
    }
}

private struct PatchStampLayer: View {
    @ObservedObject var cursor: ToolCursor
    let frame: CGRect
    let diameter: CGFloat
    let color: Color
    let sourceOffset: CGSize?
    /// The dashed source ring's colour — the app's progress yellow, handed
    /// down from the view that observes the theme.
    let sourceColor: Color

    var body: some View {
        ZStack {
            if cursor.stroke.count > 1 {
                Path { path in
                    let scaled = cursor.stroke.map {
                        CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
                    }
                    path.move(to: scaled[0])
                    for point in scaled.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(color.opacity(0.8),
                        style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round))
            }

            // The source ring shows up for exactly TWO moments, and is absent
            // the rest of the time — Photoshop's own behaviour, and asked for
            // directly after a version that kept it on screen permanently.
            //
            // A ring that is always visible stops being information: it sits
            // over the photograph during every pause, every reposition, every
            // look at what has been done so far. It matters while a source is
            // being CHOSEN and while paint is being LAID DOWN. Between those,
            // the offset is remembered perfectly well without drawing it.
            if let last = cursor.stroke.last, let sourceOffset {
                // Painting. Last painted point plus this stroke's fixed
                // offset, so the ring travels alongside the brush and the two
                // circles move together — the offset was locked when the drag
                // began and cannot drift mid-stroke.
                //
                // Goes away by itself on mouse-up: commitPatchStroke empties
                // `cursor.stroke`, which is this branch's own condition.
                PatchSourceCircle(
                    center: CGPoint(x: frame.minX + (last.x + sourceOffset.width) * frame.width,
                                    y: frame.minY + (last.y + sourceOffset.height) * frame.height),
                    diameter: diameter, color: sourceColor)
            } else if let hover = cursor.sourceHover, cursor.stroke.isEmpty {
                // ⌥ held: the ring is under the cursor, showing exactly what
                // would be picked up by clicking here. Released, sourceHover
                // is cleared and the ring goes with it.
                PatchSourceCircle(center: hover, diameter: diameter, color: sourceColor)
            }

            // Cursor-size ring — where paint LANDS. Solid, against the source
            // ring's dashes. Hidden while ⌥ is held (that is a source pick,
            // not a paint) and while a stroke is in progress (the stroke
            // already draws itself at its true width).
            if let hover = cursor.brushHover, cursor.sourceHover == nil, cursor.stroke.isEmpty {
                Circle()
                    .stroke(color.opacity(0.9), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
                    .position(hover)
            }
        }
        .allowsHitTesting(false)
    }
}

// The ⌥-held source ring on its own, for the legacy Square/Circle patch
// overlay, which has no stroke and no brush ring to go with it.
private struct PatchSourceRing: View {
    @ObservedObject var cursor: ToolCursor
    /// The patch's own on-screen width, so the ring says how much would be
    /// lifted rather than just where from — same rule as PatchSourceCircle in
    /// the brush overlay, which this now shares.
    let diameter: CGFloat
    let color: Color

    var body: some View {
        Group {
            if let source = cursor.sourceHover {
                PatchSourceCircle(center: source, diameter: diameter, color: color)
            }
        }
        .allowsHitTesting(false)
    }
}

// The Brush tool's live feedback: the stroke being painted and the size ring.
// Same story as PatchStampLayer — both were left on @State when the Remove
// brush was moved off it, and both were reported as lag in their turn.
private struct BrushStrokeLayer: View {
    @ObservedObject var cursor: ToolCursor
    let frame: CGRect
    let diameter: CGFloat
    let color: Color
    let eraseColor: Color
    let isErasing: Bool

    var body: some View {
        ZStack {
            if cursor.stroke.count > 1 {
                Path { path in
                    let scaled = cursor.stroke.map {
                        CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
                    }
                    path.move(to: scaled[0])
                    for point in scaled.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke((isErasing ? eraseColor : color).opacity(0.55),
                        style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round))
            }

            if let hover = cursor.brushHover, cursor.stroke.isEmpty {
                Circle()
                    .stroke((isErasing ? eraseColor : color).opacity(0.9), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
                    .position(hover)
            }
        }
        .allowsHitTesting(false)
    }
}

// Draws only the stroke in progress. Hit testing off — the drag belongs to the
// parent's own hit area, which is what feeds this.
private struct ActiveStrokeLayer: View {
    @ObservedObject var stroke: ActiveStrokePoints
    let frame: CGRect
    let lineWidth: CGFloat
    let color: Color
    let isErase: Bool

    var body: some View {
        briefShowStrokePath(stroke.points, frame: frame)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .blendMode(isErase ? .destinationOut : .normal)
            .allowsHitTesting(false)
    }
}

// Clips to a rectangle fixed in the PARENT's coordinate space, which is what
// `.clipped()` cannot do — it always clips to the view's own bounds.
//
// Every tool overlay is framed to the preview container and draws against the
// FULL pre-crop image rect, so `.clipped()` bounds it to the PREVIEW. But the
// preview is bigger than the photo whenever the photo is letterboxed inside
// it, and a brush stroke could still run out over the grey margin beside the
// picture. The photo's own on-screen rect is what a stroke has to stop at, so
// that rect is passed in and clipped to directly.
private struct PreviewClipShape: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}

// The Develop panel's tabs. Every section listed here already existed; the
// tabs only decide which of them are mounted at once. Layers gets its own tab
// because it is a section you work IN rather than glance at, and it used to
// sit ten sections down a single long scroll.
//
// Hiding a tab does NOT disable any keyboard shortcut that matters. Cmd+V
// (paste as layer), Cmd+C/X, Cmd+Z, [ / ] and Backspace are all owned by the
// shared local NSEvent monitor in installEditingKeyMonitor(), which is
// installed on the Develop view itself, not inside any section. The one
// SwiftUI-owned shortcut in the panel is Return-commits-crop, which lives on
// the crop "Done" button and was already scoped to "only while that button
// exists" — switching away from the Edit tab mid-crop now also unmounts it,
// which is the same rule, not a new one.
enum DevelopPanelTab: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case retouch = "Retouch"
    case layers = "Layers"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .edit: return "slider.horizontal.3"
        case .retouch: return "wand.and.stars"
        case .layers: return "square.2.layers.3d"
        }
    }

    /// The tab bar lost its printed names when the tabs joined the header bar,
    /// so the tooltip has to say both what it is called and what is in it.
    var helpText: String {
        switch self {
        case .edit: return "Edit - light, colour, curves and detail."
        case .retouch: return "Retouch - tools, masks, selections and removal."
        case .layers: return "Layers - the layers on this photo."
        }
    }
}

// Reordering a layer by dragging its row. A DropDelegate rather than the
// simpler .onMove because .onMove requires a List, and this panel is a VStack
// inside a ScrollView — swapping in a List would restyle every row and nest a
// second scroller inside the existing one.
//
// Everything resolves by id, never by index. The array is reordered while the
// drag is still in flight (that is what makes rows slide under the cursor), so
// any index captured when the drag began is stale a moment later.
struct LayerDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    @Binding var layers: [ImageLayer]

    func dropEntered(info: DropInfo) {
        guard let dragging else {
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            _ = LayerDropDelegate.reorder(&layers, moving: dragging, onto: target)
        }
    }

    // The whole reorder, as a pure function on the array. Split out from
    // dropEntered for one reason: a drag cannot be scripted, but this can, so
    // "does dropping A onto B produce the right order" is answerable by
    // Tools/test-layer-reorder.swift instead of by hand-dragging rows in a
    // window nobody has managed to screenshot yet.
    //
    // Returns false and leaves the array untouched when there is nothing to do
    // (same id, or either id no longer present because the layer was deleted
    // mid-drag). Callers ignore the result; it exists so the test can assert
    // that a no-op really is one.
    @discardableResult
    static func reorder<T: Identifiable>(_ items: inout [T], moving dragging: T.ID, onto target: T.ID) -> Bool {
        guard dragging != target,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let to = items.firstIndex(where: { $0.id == target }) else {
            return false
        }
        let moved = items.remove(at: from)
        items.insert(moved, at: to)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    // Reached whether the drag was dropped on a row or abandoned, so the
    // in-flight id is cleared in exactly one place. The array is already in
    // its final order by now — dropEntered did the moving.
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct DevelopView: View {
    /// The photos in the filmstrip.
    ///
    /// `@State` rather than a `let` because "Duplicate & BW" writes new
    /// files into the folder while the editor is open, and they have to
    /// show up in the strip beside the photo they came from — a `let` can
    /// only be replaced by rebuilding the whole view, which would throw
    /// away the open photo, its undo stack and its decoded base image.
    ///
    /// Seeded once, from what ShowGrid handed over. A window that is
    /// reopened later is built fresh from the folder, which by then holds
    /// the new files anyway.
    @State private var photoURLs: [URL]
    let initialSelection: URL?
    let onClose: () -> Void

    init(photoURLs: [URL], initialSelection: URL?, onClose: @escaping () -> Void) {
        _photoURLs = State(initialValue: photoURLs)
        self.initialSelection = initialSelection
        self.onClose = onClose
    }

    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var selectedURL: URL?
    // Filmstrip multi-select (Cmd toggles one photo in/out, Shift selects
    // the whole range from selectionAnchor to the clicked photo) — separate
    // from selectedURL, which is "the photo currently open in the editor"
    // and keeps working exactly as before on a plain click. Used for the
    // right-click "Export…" context menu (exports the whole set when more
    // than one photo is selected) — see handleFilmstripClick/exportSinglePhoto.
    @State private var multiSelectedURLs: Set<URL> = []
    // Which photos in this folder are marked rejected. A mirror of
    // PhotoLabelStore, held here because that store is a plain static type with
    // no way to announce a change — the filmstrip has to be told to redraw, and
    // @State is what tells it.
    @State private var rejectedURLs: Set<URL> = []
    // The photo a Shift-click range is measured from — set on every plain
    // or Cmd click, left untouched by Shift-clicks themselves (so repeated
    // Shift-clicks keep extending/shrinking from the same anchor, matching
    // Finder/Photos convention rather than re-anchoring on every click).
    @State private var selectionAnchor: URL?
    @State private var settings = PhotoEditSettings()
    @State private var fullBaseImage: PhotoBaseImage?
    @State private var previewBaseImage: PhotoBaseImage?
    // The still frame shown once editing pauses is rendered from
    // `fullBaseImage` — the untouched, full-resolution, full-quality decode
    // that export uses. Nothing extra is decoded for it.
    @State private var refineWorkItem: DispatchWorkItem?
    // The refine once it is ON the render queue, so it can still be cancelled
    // between being queued and being started — see scheduleRefinedRender.
    @State private var refineQueueWorkItem: DispatchWorkItem?
    @State private var displayedImage: NSImage?
    @State private var histogramBins: [CGFloat] = []
    @State private var filmstripThumbnails: [URL: NSImage] = [:]
    // Decodes already dispatched. The `filmstripThumbnails[url] == nil` check
    // alone is not enough: it runs on the main thread before the dispatch, so
    // two .onAppear for the same url arriving before the first decode finishes
    // both pass it and decode the same photo twice.
    @State private var filmstripThumbnailsInFlight: Set<URL> = []
    // Insertion order, for oldest-first eviction at filmstripThumbnailCacheLimit.
    @State private var filmstripThumbnailOrder: [URL] = []
    @State private var isLoadingPreview = false
    @State private var showOriginal = false
    @State private var isCropping = false
    @State private var pendingCrop: EditCropRect = .full
    @State private var dragStartCrop: EditCropRect?
    // Where the rotation drag began: the pointer's angle around the crop's
    // centre, and the whole crop at that moment. Both nil between drags, which
    // is also how the cursor knows a turn is in progress (see cropCursor).
    @State private var rotateDragStartAngle: Double?
    // The WHOLE crop as it stood when the rotation drag began, not just its
    // angle — see rotateCropFrame for why keeping only the angle would ratchet
    // the frame smaller.
    @State private var rotateDragStartCrop: EditCropRect?
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
    /// Which of the eight bands the Colour Mixer's three sliders act on.
    ///
    /// Lightroom shows all twenty-four at once, in three tabs of eight. One
    /// band at a time is the right shape for a panel this narrow, and it is
    /// also the honest one: the three sliders under the swatches always say
    /// which colour they belong to, where a wall of twenty-four rows leaves the
    /// client counting to work out which "Saturation" is which.
    @State private var selectedColorBand: ColorBand = .red
    /// What has been typed into the Kelvin field, cleared once it is applied.
    ///
    /// The field is only MOUNTED while it is being used, and that is not a
    /// styling choice — it is a bug fix. A TextField sitting permanently in the
    /// panel becomes the window's first responder, and the ← / → slider nudge
    /// deliberately stands down whenever a field editor has focus (so arrows
    /// can move a caret). So an always-present Kelvin box silently took the
    /// arrow keys away from every slider in the panel. Reported exactly that
    /// way: "kada hoću da pomeram strelicama slide bar u Editu on ne reaguje".
    ///
    /// Same shape as renaming a preset: a value you click to edit, not a box
    /// that is always open. Nothing in this panel should hold focus it is not
    /// being given.
    @State private var kelvinFieldText = ""
    @State private var isEditingKelvin = false
    @State private var isAddingPreset = false
    /// Presets is a popover off the header bar now, not a section in the panel.
    @State private var showPresetsPopover = false
    /// Which header cell the pointer is over, so the bar can say what it is.
    @State private var hoveredHeaderItemID: String?
    @State private var newPresetName = ""
    /// Which preset is being renamed, and what it is being renamed to.
    @State private var renamingPresetID: UUID?
    @State private var renamingPresetName = ""
    /// What the last Lightroom import did, and what it could not do.
    @State private var presetImportNotice: String?
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

    // MARK: - Resizable layout

    // The two edges the client drags. Persisted app-wide, like the export
    // preferences above: a photographer sets the panel to the width they like
    // once, not once per photo and not once per launch.
    //
    // Bounds are not decoration. The panel's floor is what "Generative Clean
    // Up" beside "Quick Clean Up" needs before either starts truncating — the
    // widest row in the panel, and the reason 300 rather than something
    // smaller; the filmstrip's
    // ceiling is set by `filmstripThumbnailPixelSize` — 384px covers a 192pt
    // thumbnail at 2x, and 192 + the strip's own 20pt of padding is the 210
    // below. Past that the thumbnails are drawn larger than their own pixels
    // and go soft, so raising this number means raising the decode size in the
    // same commit, not on its own.
    @AppStorage("develop.layout.panelWidth") private var panelWidth: Double = 340
    @AppStorage("develop.layout.filmstripHeight") private var filmstripHeight: Double = 120

    // Whether the AI Manipulation block is unfolded.
    //
    // ⚠️ @State, NOT @AppStorage, and that is the fix for a real report: opening
    // a photo came up with the block already unfolded — *„kada uđem, dva puta
    // kliknem na sliku, AI sekcija je otvorena; neka bude zatvorena pa klijent
    // neka izabere šta hoće"*. Remembering it made sense while it was a titled
    // disclosure line that cost nothing closed. It stopped making sense in
    // KORAK 87, when this button started picking up the BRUSH as well: a
    // remembered "open" then meant a photo opening with the clean-up brush live
    // on a photograph somebody meant only to look at.
    //
    // So every fresh open of the editor starts closed, and the client chooses.
    // Within one session it stays as they left it, which is what someone
    // working through a batch wants.
    @State private var aiManipulationExpanded: Bool = false

    /// Whether the AI Manipulation block is on the panel.
    ///
    /// The header button's own state, OR the brush being live — and the second
    /// half is not belt-and-braces, it closes a hole. There is a THIRD way into
    /// this tool ("AI Clean Up" in the Remove section, which predates the header
    /// button), and it only switches the brush on. Without this the client
    /// could be painting with Quick and Generative Clean Up nowhere on screen —
    /// the two buttons that act on what they just painted.
    private var isAIManipulationVisible: Bool {
        aiManipulationExpanded || isRemoveBrushActive
    }

    private static let panelMinWidth: Double = 300
    private static let panelMaxWidth: Double = 560
    private static let filmstripMinHeight: Double = 92
    private static let filmstripMaxHeight: Double = 210

    // Dragging an edge is TWO pieces of state, and the split is what stops the
    // edge from shaking under the cursor.
    //
    // `…AtDragStart` is the anchor. A DragGesture reports translation
    // cumulatively from where the drag began, so applying it to the CURRENT
    // width on every .onChanged compounds it and the edge runs away. Same
    // anchor pattern as `panStart` in centerPreview, for the same reason.
    //
    // `…Live` is where the edge is RIGHT NOW, mid-drag, and it exists because
    // the stored value above is @AppStorage. Every write to @AppStorage is a
    // synchronous UserDefaults write plus a defaults-changed notification that
    // re-enters the view — sixty times a second while a drag is in flight.
    // That was the shaking: the edge was being driven by a value that only
    // caught up a frame or two later, so it lagged the cursor and snapped
    // forward in bursts. Mid-drag nothing touches UserDefaults; the final
    // position is committed once, in .onEnded.
    @State private var panelWidthAtDragStart: Double?
    @State private var filmstripHeightAtDragStart: Double?
    @State private var panelWidthLive: Double?
    @State private var filmstripHeightLive: Double?

    // What the layout actually reads: the live drag value while a drag is in
    // flight, the persisted one the rest of the time.
    private var effectivePanelWidth: Double { panelWidthLive ?? panelWidth }
    private var effectiveFilmstripHeight: Double { filmstripHeightLive ?? filmstripHeight }

    @State private var isFlattening = false

    /// Watched so the install row and the Generative button agree about what
    /// is happening. See SDModelInstall.swift.
    @ObservedObject private var modelInstaller = SDModelInstaller.shared

    /// Watched for one thing: whether the weights are being loaded into Core
    /// ML right now.
    ///
    /// ⚠️ Separate from `modelInstaller` on purpose, because they are separate
    /// costs and the client hit both. Installing is the 1.8 GB download, once
    /// ever. Loading is per launch and invisible — the client saw only that
    /// the first Generative Clean Up took two minutes and the next fifteen
    /// seconds. This is what lets the panel say which of the two is happening
    /// instead of leaving a button silent.
    @ObservedObject private var sdPipeline = SDInpaintPipeline.shared
    @State private var flattenErrorMessage: String?
    @State private var showSyncDialog = false

    // Right-click "Delete" / ⌫ in the filmstrip, routed through a
    // confirmation the same way ShowGrid's is — the photos leave the
    // client's folder, and a reflexive Backspace should not be enough on
    // its own to do that.
    @State private var pendingTrashPhotoURLs: [URL]?
    @State private var isTrashPhotoConfirmationPresented = false
    // Asked at the moment of exporting rather than set once in the panel:
    // "export all of these" is exactly when someone decides what kind of
    // file they want out, and the panel's own picker is far from the button
    // that starts the job.
    @State private var showExportAllOptions = false
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
    // Held, not observed — see BrushStrokeLayer.
    @State private var brushCursor = ToolCursor()
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

    // Drag-start snapshots for the radial/graduated on-canvas handles —
    // same pattern as dragStartCrop: captured on the first onChanged of a
    // drag, cleared on onEnded, so each drag computes its delta against a
    // stable baseline instead of the (already-mutated) live value.
    @State private var radialDragStart: RadialMaskGeometry?
    @State private var graduatedDragStart: GraduatedMaskGeometry?
    @State private var patchDragStart: PatchGeometry?
    // Points of an in-progress Free-shape patch outline (unit space), live
    // while the user is drawing it — same "don't touch the real model until
    // mouse-up" reasoning as brushCursor.stroke, so a canceled/
    // interrupted drag never leaves a stray half-drawn outline behind.
    // Held, not observed — see ActiveOutlineLayer.
    @State private var activePatchDrawPoints = ActiveStrokePoints()
    // Live mouse position (frame/view space) while hovering a patch's
    // canvas with ⌥ held — purely a "this is where the source will land if
    // you click now" preview ring, nil whenever the mouse isn't over the
    // canvas OR ⌥ isn't currently held. Mirrors brushCursor.brushHover's
    // pattern/reasoning.


    // Circle-mode Patch (clone-stamp brush) state — same "don't touch the
    // real model until mouse-up" pattern as brushCursor.stroke/
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
    // Held, not observed — see PatchStampLayer.
    @State private var patchCursor = ToolCursor()
    @State private var pendingPatchSource: CGPoint?
    @State private var patchStrokeOffset: CGSize?
    @State private var patchBrushSize: Double = 0.08
    @State private var patchBrushFeather: Double = 0.35
    // Cursor-size ring preview while hovering (not dragging, not ⌥-held) —
    // mirrors brushCursor.brushHover exactly, just a separate var since the two
    // tools' hover state can't be conflated (different rings/sizes).


    // Selection tool (Cut/Copy/Deselect -> layer clipboard). `activeSelection`
    // nil = tool not in use; non-nil = its outline is shown/editable on
    // canvas. Ephemeral like isCropping's pendingCrop — never written into
    // PhotoEditSettings itself, only consumed by Cut/Copy into a new/
    // modified ImageLayer.
    @State private var activeSelection: SelectionGeometry?
    @State private var selectionDragStart: SelectionGeometry?
    // Held, not observed — see ActiveOutlineLayer.
    @State private var activeSelectionDrawPoints = ActiveStrokePoints()
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
    // Which panel tab is showing.
    @State private var panelTab: DevelopPanelTab = .edit
    // Bumped to ask the panel to scroll the crop section into view. A counter
    // rather than a Bool or an optional id: pressing Crop twice in a row has to
    // scroll twice, and a value that is already equal to itself fires no
    // onChange.
    @State private var scrollToCropRequest = 0
    // The layer being dragged in the Layers list, by id — an index would go
    // stale the instant the drop reorders the array underneath it.
    @State private var draggingLayerID: UUID?
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

    /// What the bar is waiting on right now, or nil once the diffusion steps
    /// have taken over and the percentage speaks for itself.
    ///
    /// ⚠️ Exists because a percentage alone was not enough. The bar sat at 0%
    /// through the full-size render, the mask work, LaMa's base fill and the
    /// model load — *„mnogo zaglavljan na pocetku na 0% laod bar"* — and a
    /// number that does not move says "stuck" no matter what is behind it.
    /// Naming the stage turns the same wait into a report.
    @State private var aiEraseStage: String?
    // The AI erase is the one half of Remove that can fail for a reason the
    // user can act on (weights not installed yet), so unlike the exemplar
    // path it has somewhere to say so.
    @State private var removeErrorMessage: String?
    // Not an error — the one thing "Select People in Background" has to be
    // able to say out loud. Two people standing against each other merge
    // into one blob, so a stranger pressed right up to the subject is kept
    // rather than found, and the user needs to be told that instead of
    // quietly getting a mask with somebody missing from it.
    @State private var removeNotice: String?

    // The card that appears after Select People has actually
    // made a layer. Separate from removeNotice, which belongs to the Remove
    // section and says why an erase did or did not find anything — this one
    // is about layers that now exist and what can be done with them.
    @State private var newLayerNotice: String?

    // The layers the last Select People made, so the card's
    // Undo can take back exactly those. See removeNewLayers for why this is
    // not the ordinary undo stack.
    @State private var newLayerIDs: [UUID] = []

    // Edge outlines for selected derived (Background) layers, built once each.
    // Keyed by layer id, and a layer's matte never changes after it is made,
    // so there is nothing to invalidate.
    @State private var layerOutlineCache: [UUID: NSImage] = [:]
    // Which of the two find buttons produced the mask currently on screen,
    // so the line under them describes what was actually found.
    @State private var foundBackgroundOnly = false
    // Where the found mask sits, in the full render's unit space. Kept only
    // to answer one question cheaply in the panel: is the area about to be
    // erased too big for the Quick model? See removalAreaPixels.
    @State private var removalMaskUnitBox: CGRect?
    // 1 means "fit the window", which is where every photo starts. Zoom and
    // pan live in fittedImageFrame, so every overlay that derives its screen
    // position from that frame — crop, masks, layers, the removal brush —
    // follows the zoom without knowing it exists.
    @State private var zoomLevel: Double = 1
    @State private var panOffset: CGSize = .zero
    @State private var panStart: CGSize?
    // Photoshop's hand tool: hold Space and drag to move around a zoomed
    // photo WITHOUT putting the current tool down. The plain pan layer
    // below only exists when no tool owns the canvas, which is exactly
    // backwards for the case that actually needs panning — brushing out a
    // blemish at 4x, where the drag belongs to the brush.
    @State private var isSpaceHeld = false
    @State private var spaceKeyMonitor: Any?
    @State private var showOriginalKeyMonitor: Any?
    @State private var optionKeyMonitor: Any?
    @State private var scrollWheelMonitor: Any?
    /// Scroll deltas add up here until they are worth one size step.
    ///
    /// A trackpad reports a continuous stream of small fractions and a mouse
    /// wheel reports a few whole numbers per detent, so acting on every event
    /// would make the brush leap across its whole range on a trackpad and crawl
    /// on a wheel. Accumulating and stepping at a threshold gives both the same
    /// feel — see `briefEditsScrollStep`.
    @State private var scrollSizeAccumulator: CGFloat = 0
    /// Whether the pointer is anywhere over the preview area — see
    /// `isPointerOverCanvas`.
    @State private var isHoveringPreview = false
    @AppStorage("develop.aiRemove.feather")
    private var aiRemoveFeather: Double = SDInpaintPipeline.defaultFeather

    /// "Flyaway Hair" — Generative Clean Up only. See the long comment on
    /// `InpaintPipeline.aiRemoval`'s `flyawayHair` parameter for the
    /// mechanism and the measurement behind it. Off by default: widening the
    /// mask is right for a thin wisp and wrong for a normal object, so it
    /// must not change Generative's ordinary behaviour uninvited.
    @AppStorage("develop.aiRemove.flyawayHair")
    private var aiRemoveFlyawayHair = false
    // Hand-painted half of the Remove tool: paint over anything (a bin, a
    // sign, a stranger Vision didn't call a person) and erase that instead.
    // Strokes live in the FULL, pre-crop image's unit space, same as
    // removalMask, and are only turned into a real CIImage mask at Erase
    // time — while painting, the red ink on screen is a plain vector Path,
    // the same trick brushPaintOverlay uses to stay interactive.
    @State private var isRemoveBrushActive = false
    // Add or take away. The mask side already understood erase strokes
    // (BrushStroke.isErase, handled in PhotoEditRenderer.strokeMask) — what
    // was missing was any way to make one.
    @State private var isRemoveBrushErasing = false
    @State private var removalStrokes: [BrushStroke] = []
    @State private var activeRemovalStroke = ActiveStrokePoints()
    // 0.02, not the 0.06 this shipped with: at 6 the smallest thing anyone
    // could select was already bigger than most of what this tool is for (a
    // mole, an insect, a cable), and every use started by dragging the size
    // down. Explicit request.
    @State private var removalBrushSize: Double = 0.02
    @State private var removalBrushCursor = BrushCursorPosition()

    // Same soft-yellow-in-Dark, mid-gray-elsewhere accent PhotoShowSheet
    // uses for its own selection border, kept consistent here for the
    // filmstrip's selection ring and the "has edits" badge.
    private var accentColor: Color {
        themeManager.current == .dark
            ? Color(red: 1.0, green: 0.94, blue: 0.62)
            : Color(red: 0.56, green: 0.56, blue: 0.58)
    }

    // The Clean Up progress fill.
    //
    // Deliberately NOT accentColor: that is pale yellow only in dark mode — in
    // light mode it is a neutral grey, because it doubles as the filmstrip's
    // selection ring and a ring has to stay quiet. Grey is the one outcome a
    // progress bar cannot have, since yellow is the whole point of it. So: the
    // same pale yellow in dark, a deeper amber in light, where cream needs
    // more weight behind it to read at 6pt tall.
    private var signalYellow: Color {
        themeManager.current == .dark
            ? Color(red: 1.0, green: 0.94, blue: 0.62)
            : Color(red: 0.93, green: 0.72, blue: 0.16)
    }

    // The clone stamp's dashed source ring. Orange rather than the progress
    // yellow beside it: this ring is drawn ON the photograph, with no shadow
    // or backing ring to hold it up, so it has to separate from skin, sand and
    // sky by hue alone — and it also has to be told apart at a glance from the
    // solid accent ring that marks where paint lands. Yellow against a bright
    // frame did neither.
    private var patchSourceColor: Color {
        themeManager.current == .dark
            ? Color(red: 1.0, green: 0.62, blue: 0.23)
            : Color(red: 0.95, green: 0.45, blue: 0.10)
    }

    // Drives the indeterminate bar: 0...1, where the travelling segment sits
    // along the track. One value on the view rather than one per bar, so both
    // bars move together — they are showing the same job.
    @State private var eraseProgressPulse: Double = 0

    // Replaces the spinner-and-text pair. A spinner says "something is
    // happening"; the generative path takes ~13s and reports a real fraction
    // per diffusion step, so it can say how much is left instead.
    //
    // Determinate whenever there IS a fraction. LaMa's path has none, so that
    // case slides a short segment along the track.
    //
    // It used to PULSE A FULL-WIDTH BAR instead, and that was a bad call of
    // mine: a full bar reads as "100% and stuck", which is exactly how it was
    // reported — "shows 100% and holds there another 20 seconds". A bar that
    // is full is a bar that is finished, whatever it is doing with its
    // opacity. A travelling segment cannot be misread that way.
    /// "Reading the photo… 4%", or "Cleaning up… 62%", or "Erasing…".
    ///
    /// The percentage is kept beside the stage rather than replaced by it: a
    /// stage name says WHAT, a number says HOW FAR, and the complaint was about
    /// the number never leaving zero.
    private var eraseProgressLabel: String {
        guard let aiEraseProgress else { return "Erasing…" }
        let percent = Int((aiEraseProgress * 100).rounded())
        return "\(aiEraseStage ?? "Cleaning up…") \(percent)%"
    }

    private var eraseProgressBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The stage wins the label while there is one, because early on it
            // is the only thing that distinguishes a bar at 4% from a bar that
            // has stopped. Once the diffusion steps start, `aiEraseStage` goes
            // nil and this reads "Cleaning up… 62%" as it always did.
            Text(eraseProgressLabel)
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColors.border.opacity(0.6))

                    if let aiEraseProgress {
                        Capsule()
                            .fill(signalYellow)
                            .frame(width: min(max(aiEraseProgress, 0), 1) * proxy.size.width)
                    } else {
                        // A third of the track, travelling. Never touches
                        // either end, so it can never look like a finished bar.
                        let segment = proxy.size.width / 3
                        Capsule()
                            .fill(signalYellow)
                            .frame(width: segment)
                            .offset(x: eraseProgressPulse * (proxy.size.width - segment))
                    }
                }
                // The travelling segment is placed with .offset, and .offset
                // does NOT participate in layout — an offset view draws
                // wherever it is put, straight through its parent's bounds,
                // because SwiftUI clips nothing by default. That is the only
                // unclipped drawing in this view, and it is what walked out of
                // the panel and across the photograph. Clipping to the track
                // makes the escape structurally impossible rather than
                // depending on the arithmetic staying right.
                .clipped()
            }
            .frame(height: 6)
            // Animated so the bar slides between diffusion steps instead of
            // jumping: the generative path reports roughly every half second,
            // and un-animated that is a visible stutter rather than progress.
            .animation(.linear(duration: 0.25), value: aiEraseProgress)
        }
        .onAppear {
            eraseProgressPulse = 0
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                eraseProgressPulse = 1
            }
        }
    }

    private let histogramHeight: CGFloat = 56

    var body: some View {
        // The picture owns the whole left side, floor to ceiling. Nothing sits
        // above it any more: the file name, the tool strip and the Done button
        // all moved into the right panel, which is now the only place chrome
        // lives. On a 1470pt window that gave the photo back ~90pt of height —
        // the two rows plus their dividers — and it is height that a landscape
        // photo in a wide window is always short of.
        //
        // It also retires a whole class of bug the comments below used to
        // guard against. The old top bar and tool strip sat ABOVE the picture
        // in the same VStack, so anything in them that changed height — an
        // erase progress spinner appearing, a notice wrapping to a second line
        // — shoved the photo down and back up while the client was working on
        // it. That is why cleanUpNotice was pinned to a fixed 30pt slot and
        // why the erase progress was moved out of the tool strip. Beside the
        // picture rather than above it, none of those can move it at all.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                centerPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                panelResizeHandle

                adjustmentPanel
            }

            filmstripResizeHandle

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
            // Read once here rather than asked per thumbnail per redraw:
            // PhotoLabelStore.isRejected hits UserDefaults, and the filmstrip
            // draws every visible cell on every pass.
            reloadRejectedFlags()
        }
        // The folder's contents change under this window — a photo trashed, a
        // duplicate made — and a stale mirror would leave an X on a thumbnail
        // that is now a different photo.
        .onChange(of: photoURLs) { _ in
            reloadRejectedFlags()
        }
        .onChange(of: settings) { _ in
            scheduleRender()
            scheduleUndoCommit()
        }
        // pendingCrop deliberately has NO onChange here any more. It used to
        // call scheduleRender() on every change, which meant every frame of a
        // crop drag ran the whole preview pipeline — and produced a
        // BIT-IDENTICAL picture every time.
        //
        // The reason it is identical: renderNow() passes
        // `applyCrop: !isCropping`, so while the crop tool is open the render
        // ignores the crop completely. pendingCrop is not an input to it at
        // all. The only inputs are `settings`, `previewBaseImage` and
        // `showOriginal`, and none of the three moves during a drag.
        //
        // What that wasted per drag frame, in order: a full
        // PhotoEditRenderer.render, a CGImage conversion, a
        // PhotoEditStore.setSettings write, a luminanceHistogram pass over the
        // result, and a scheduleRefinedRender() — the FULL-RESOLUTION one.
        // At scheduleRender's 20ms throttle that is up to fifty of those a
        // second, for a picture that never changed. That is the reported
        // "moving or resizing the crop lags a bit".
        //
        // Nothing lost: every OTHER writer of pendingCrop either assigns
        // `settings` in the same breath (undo/redo, flatten, unflatten, bake,
        // preset, paste, reset) and is covered by the onChange above, or calls
        // scheduleRender() itself (toggleCropMode entering, commitCrop
        // leaving) — checked one by one. The ones that do neither
        // (applyCropAspectRatio, "Reset Crop", the drag) need no render,
        // because of the first paragraph.
        .onChange(of: showOriginal) { _ in renderNow() }
        .onAppear {
            installEditingKeyMonitor()
            installSpaceKeyMonitor()
        installShowOriginalKeyMonitor()
            installOptionKeyMonitor()
            installScrollWheelMonitor()
        }
        .onDisappear {
            removeEditingKeyMonitor()
            removeSpaceKeyMonitor()
        removeShowOriginalKeyMonitor()
            removeOptionKeyMonitor()
            removeScrollWheelMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoEditsChanged)) { note in
            guard let changed = note.userInfo?[photoEditsChangedURLsKey] as? Set<URL> else {
                return
            }
            refreshFilmstripThumbnails(changed)
        }
        .sheet(isPresented: $showSyncDialog) {
            syncDialogView
        }
        .sheet(isPresented: $showExportAllOptions) {
            exportAllOptionsView
        }
        .confirmationDialog(
            pendingTrashPhotoURLs?.count == 1
                ? "Move this photo to the Trash?"
                : "Move \(pendingTrashPhotoURLs?.count ?? 0) photos to the Trash?",
            isPresented: $isTrashPhotoConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let pendingTrashPhotoURLs {
                    trashPhotos(pendingTrashPhotoURLs)
                }
                pendingTrashPhotoURLs = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTrashPhotoURLs = nil
            }
        } message: {
            Text("The photos go to the macOS Trash, and can be put back from there. The edits stay recorded, so a restored photo comes back with them.")
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
            guard NSApp.keyWindow?.title == DevelopWindowController.windowTitle else {
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
            // `flags` is still needed by the arrow-key nudge below, which is a
            // FIXED shortcut rather than a bound one. The character lookup that
            // used to sit beside it is gone: every bound shortcut now goes
            // through KeyCombo.matches, which does the same narrowing to the
            // four modifiers that can tell one shortcut from another — see its
            // `relevantModifiers`, and the bug that rule exists to prevent.
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])

            // Each case only fires when there's actually something for it
            // to DO (a populated clipboard / a non-empty undo stack / an
            // active Selection outline / a selected mask or layer) —
            // otherwise falls through to the final `return event`, so
            // these keys still reach normal text-field editing (e.g.
            // typing/backspacing a preset name) whenever the relevant tool
            // isn't in active use. Without these guards, every one of
            // these keys anywhere in Develop — including inside a plain
            // text field — would be swallowed by this monitor.
            // Every binding below comes from ShortcutStore, so the client can
            // change any of them (Edit ▸ Keyboard Shortcuts). The DEFAULTS in
            // ShortcutAction are exactly the keys this monitor used to have
            // written into it, so nothing about a fresh install changed.
            //
            // A press inside a text field is left alone throughout: in a field
            // ⌘A means select the TEXT, and Q and E are letters.
            let isTyping = (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor ?? false

            if !event.isARepeat, !isTyping {
                if ShortcutStore.matches(event, .pasteLayer), layerClipboard != nil {
                    pasteLayer(); return nil
                }
                if ShortcutStore.matches(event, .copySelection), activeSelection != nil {
                    copySelection(); return nil
                }
                if ShortcutStore.matches(event, .cutSelection), activeSelection != nil {
                    cutSelection(); return nil
                }
                if ShortcutStore.matches(event, .selectAllPhotos), !photoURLs.isEmpty {
                    selectAllPhotos(); return nil
                }
                // Guarded on there being a photo open, like every case above
                // is guarded on having something to do — with nothing open,
                // R falls through and stays an ordinary letter.
                if ShortcutStore.matches(event, .toggleCrop), selectedURL != nil {
                    toggleCropMode(); return nil
                }
                // X marks the filmstrip's photos rejected, exactly as it does
                // in ShowGrid — same flag, same store, so a photo rejected in
                // one window is rejected in the other and both windows' bulk
                // exports skip it.
                if ShortcutStore.matches(event, .rejectPhoto),
                   selectedURL != nil || !multiSelectedURLs.isEmpty {
                    toggleRejectedForFilmstripSelection(); return nil
                }

                // ⚠️ Every one of these is GUARDED the same way the cases above
                // are, and the guard is the point: with nothing to act on the
                // key is not swallowed, it falls through and stays an ordinary
                // letter. A shortcut that eats a keystroke and does nothing is
                // worse than no shortcut.
                if ShortcutStore.matches(event, .openCleanUp), selectedURL != nil {
                    toggleAICleanUp(); return nil
                }
                // Guarded on the model being available AND on there being paint
                // down — the same two conditions that enable the buttons. On an
                // Intel Mac the Generative key does nothing at all, exactly as
                // its button is disabled there.
                if ShortcutStore.matches(event, .quickCleanUp),
                   cleanUpUnavailableReason(.quick) == nil, hasRemovalArea, !isRemoving {
                    eraseMaskedArea(using: .quick); return nil
                }
                if ShortcutStore.matches(event, .generativeCleanUp),
                   cleanUpUnavailableReason(.generative) == nil, hasRemovalArea, !isRemoving {
                    eraseMaskedArea(using: .generative); return nil
                }
                if ShortcutStore.matches(event, .selectPeople),
                   selectedURL != nil, !isFindingPeople, !isRemoving {
                    selectPeopleAsLayer(); return nil
                }
                if ShortcutStore.matches(event, .flattenPhoto),
                   selectedURL != nil, !isFlattening, hasUnbakedEdits {
                    flattenPhoto(); return nil
                }
                if ShortcutStore.matches(event, .backToGrid) {
                    onClose(); return nil
                }
                // The two filmstrip-menu items, acting on the same set the
                // right-click menu would: the whole multi-selection when there
                // is one, otherwise the open photo.
                if ShortcutStore.matches(event, .blackAndWhite), let url = selectedURL {
                    applyBlackAndWhite(to: contextMenuTargets(for: url)); return nil
                }
                if ShortcutStore.matches(event, .duplicateBlackAndWhite), let url = selectedURL {
                    duplicatePhotos(contextMenuTargets(for: url), blackAndWhite: true); return nil
                }
            }

            // ⚠️ See Original is HELD, not toggled — the button beside it is
            // press-and-hold and the key has to mean the same thing. So it is
            // the one shortcut that needs keyUp as well, and it is handled in
            // its own monitor (installShowOriginalKeyMonitor) rather than here,
            // where only keyDown arrives.

            // Stepping through the filmstrip. Repeats ARE allowed — holding the
            // key to run through a folder is the point of having it on a letter
            // rather than on a menu — and each press is one bounded index move,
            // so nothing can pile up the way a repeated paste once did.
            if !isTyping {
                if ShortcutStore.matches(event, .nextPhoto), stepPhoto(by: 1) {
                    return nil
                }
                if ShortcutStore.matches(event, .previousPhoto), stepPhoto(by: -1) {
                    return nil
                }
            }
            // Cmd +/- zoom, Cmd 0 back to fit. Repeat is allowed on purpose —
            // holding Cmd+= to zoom in is the expected feel — and each press
            // is one clamped multiply, so nothing accumulates the way the
            // Cmd+V paste-per-repeat bug did. Both "=" and "+" are matched
            // because the same physical key reports as "=" unshifted and "+"
            // with shift, and people press it either way.
            // Zoom. "+" and "_" are matched alongside "=" and "-" because the
            // same physical key reports either way depending on Shift, and
            // people press it both ways.
            if !isTyping {
                if ShortcutStore.matches(event, .zoomIn) || shiftedTwin(event, of: .zoomIn, "+") {
                    stepZoom(1); return nil
                }
                if ShortcutStore.matches(event, .zoomOut) || shiftedTwin(event, of: .zoomOut, "_") {
                    stepZoom(-1); return nil
                }
                if ShortcutStore.matches(event, .zoomToFit) {
                    resetZoom(); return nil
                }
                if ShortcutStore.matches(event, .undo), !undoStack.isEmpty {
                    undo(); return nil
                }
                if ShortcutStore.matches(event, .redo), !redoStack.isEmpty {
                    redo(); return nil
                }
                if ShortcutStore.matches(event, .decreaseToolSize), activeToolHasAdjustableSize {
                    adjustActiveToolSize(increase: false); return nil
                }
                if ShortcutStore.matches(event, .increaseToolSize), activeToolHasAdjustableSize {
                    adjustActiveToolSize(increase: true); return nil
                }
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

            // Nothing INSIDE the photo is selected, so Delete means the
            // photo itself — the same action as the filmstrip's right-click
            // Delete.
            //
            // ⚠️ The mask/layer branch above wins on purpose, and the order
            // of these two is load-bearing: Delete pressed while a mask is
            // armed must remove the mask, never the whole photograph. That
            // is also why this one cannot be folded into the branch above.
            if flags.isEmpty || flags == .command,
               event.keyCode == 51 || event.keyCode == 117,
               selectedLayerID == nil, selectedLocalAdjustmentID == nil,
               !keyboardDeleteTargets.isEmpty {
                pendingTrashPhotoURLs = keyboardDeleteTargets
                isTrashPhotoConfirmationPresented = true
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

    // Space held = hand tool, for as long as it is down. Its own monitor
    // rather than a branch in the one above because that one watches
    // .keyDown only, and the whole point here is knowing when the key comes
    // back UP.
    //
    // Both of BRIEFSHOW_DEVELOP_NOTES.md's rules for a new local monitor
    // apply and are followed: the window guard is the first line (a local
    // monitor is app-wide, not per-window — see item #18, where a missing
    // one recursively copied the Desktop into itself), and a repeat is let
    // through untouched rather than swallowed. Holding Space is precisely
    // the case that generates a repeat storm, and item #15 is what happens
    // when one of those is swallowed and acted on.
    /// Makes ⌥ show the clone stamp's source ring the moment it is PRESSED.
    ///
    /// The ring's position used to come only from `.onContinuousHover`, which
    /// fires on mouse MOVEMENT — so holding ⌥ with the mouse still did
    /// nothing, and the ring appeared only once the cursor was nudged. The
    /// position is already known (the brush ring is tracking it), so this
    /// simply moves it across on the key event instead of waiting for a mouse
    /// event to do the same thing.
    ///
    /// Scoped to this window by title, per the rule at the top of
    /// BRIEFSHOW_DEVELOP_NOTES.md: local monitors are APP-WIDE, and one whose
    /// guard does not match its own window keeps acting while another window
    /// is focused. `.flagsChanged` carries no isARepeat and swallows nothing —
    /// the event is always returned, because ⌥ belongs to everything else too.
    private func installOptionKeyMonitor() {
        guard optionKeyMonitor == nil else {
            return
        }
        optionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            guard NSApp.keyWindow?.title == DevelopWindowController.windowTitle else {
                return event
            }
            let optionHeld = event.modifierFlags.contains(.option)
            // Only while a patch is the live tool. Nothing else draws this
            // ring, and moving another tool's hover state would be a bug.
            guard selectedAdjustmentIndex.map({ settings.localAdjustments[$0].type == .patch }) ?? false else {
                return event
            }
            // Mid-stroke ⌥ never reinterprets anything — same rule the drag
            // gesture already follows.
            guard patchCursor.stroke.isEmpty else {
                return event
            }

            if optionHeld {
                if let brushHover = patchCursor.brushHover {
                    patchCursor.sourceHover = brushHover
                    patchCursor.brushHover = nil
                }
            } else if let sourceHover = patchCursor.sourceHover {
                patchCursor.brushHover = sourceHover
                patchCursor.sourceHover = nil
            }
            return event
        }
    }

    /// Scroll over the photo to resize the tool circle — bigger up, smaller
    /// down, the way every other editor does it.
    ///
    /// It fires ONLY while the pointer is actually over the picture with a
    /// sizeable tool armed, and that guard is the whole safety of it: the right
    /// hand panel is a scroll view, so a monitor that took every scroll would
    /// resize the brush whenever the client tried to scroll down to Vignette.
    /// The test is the tool's own hover position, which the overlays already
    /// track for drawing the cursor ring — it is non-nil exactly while the
    /// pointer is over the canvas, so there is no second source of truth to
    /// keep in step.
    ///
    /// The event is swallowed only when it is used. A scroll that resizes
    /// nothing is handed back, so the panel keeps scrolling normally.
    private func installScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else {
            return
        }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard NSApp.keyWindow?.title == DevelopWindowController.windowTitle,
                  activeToolHasAdjustableSize,
                  isPointerOverCanvas else {
                return event
            }
            // A modifier held with a scroll is somebody asking for something
            // else — horizontal scrolling, a zoom gesture, whatever the system
            // does with it. Only a plain scroll resizes.
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else {
                return event
            }

            // The PHYSICAL direction, not the reported one. macOS already
            // inverts the delta when "natural" scrolling is on, so reading the
            // delta raw would make the gesture mean opposite things on two
            // Macs with different settings. The gesture should be the gesture.
            let delta = event.isDirectionInvertedFromDevice
                ? -event.scrollingDeltaY
                : event.scrollingDeltaY
            guard delta != 0 else {
                return nil
            }

            // A trackpad's deltas are fractions; a wheel's are whole detents.
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 6 : 1

            // Reset when the direction reverses, so changing your mind is
            // immediate rather than having to spend the accumulated other way
            // first.
            if scrollSizeAccumulator != 0,
               (scrollSizeAccumulator > 0) != (delta > 0) {
                scrollSizeAccumulator = 0
            }
            scrollSizeAccumulator += delta

            while abs(scrollSizeAccumulator) >= step {
                adjustActiveToolSize(increase: scrollSizeAccumulator > 0)
                scrollSizeAccumulator -= scrollSizeAccumulator > 0 ? step : -step
            }
            return nil
        }
    }

    private func removeScrollWheelMonitor() {
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor)
            self.scrollWheelMonitor = nil
        }
        scrollSizeAccumulator = 0
    }

    /// Is the pointer over the picture, with a tool that draws a ring?
    ///
    /// Read from the same hover positions the overlays use to draw the cursor,
    /// so "the ring is on screen" and "scrolling resizes it" are one fact
    /// rather than two that can disagree.
    private var isPointerOverCanvas: Bool {
        isHoveringPreview
            || removalBrushCursor.location != nil
            || brushCursor.brushHover != nil
            || patchCursor.brushHover != nil
    }

    private func removeOptionKeyMonitor() {
        if let optionKeyMonitor {
            NSEvent.removeMonitor(optionKeyMonitor)
        }
        optionKeyMonitor = nil
    }

    /// See Original, on a key that is HELD.
    ///
    /// Its own monitor, and not a preference: the main shortcut monitor takes
    /// only `.keyDown`, and "hold to compare" needs the release too. The button
    /// beside it has always been press-and-hold — a toggle would mean the
    /// client can walk away with the original on screen and not know it — so
    /// the key had to mean the same thing.
    ///
    /// Rebindable like the rest: it asks ShortcutStore rather than matching a
    /// literal, so whatever the client sets in Edit ▸ Keyboard Shortcuts is
    /// what is held here.
    private func installShowOriginalKeyMonitor() {
        guard showOriginalKeyMonitor == nil else {
            return
        }
        showOriginalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard NSApp.keyWindow?.title == DevelopWindowController.windowTitle else {
                return event
            }
            // A field editor gets its letters, the rule KORAK 58 set for every
            // input in this app.
            guard !((NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor ?? false) else {
                return event
            }
            // keyUp carries no modifier state worth matching against, so the
            // release is recognised by its key alone — otherwise letting go of
            // the modifier first would leave the original stuck on screen.
            guard ShortcutStore.matches(event, .showOriginal)
                    || (event.type == .keyUp && ShortcutStore.matchesKeyOnly(event, .showOriginal)) else {
                return event
            }
            guard selectedURL != nil else {
                return event
            }
            if event.isARepeat {
                return nil
            }
            showOriginal = (event.type == .keyDown)
            return nil
        }
    }

    private func removeShowOriginalKeyMonitor() {
        if let showOriginalKeyMonitor {
            NSEvent.removeMonitor(showOriginalKeyMonitor)
        }
        showOriginalKeyMonitor = nil
        // Never leave the comparison stuck on because the window closed
        // mid-hold.
        showOriginal = false
    }

    private func installSpaceKeyMonitor() {
        guard spaceKeyMonitor == nil else {
            return
        }
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard NSApp.keyWindow?.title == DevelopWindowController.windowTitle else {
                return event
            }
            guard event.keyCode == 49 else {          // space
                return event
            }
            // A space typed into the preset-name field is a space, not a
            // hand tool. Same field-editor guard the arrow keys use.
            guard !((NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor ?? false) else {
                return event
            }
            // Swallowed whether or not there is anything to pan, and that is
            // the fix for a real complaint: at fit, returning the event left
            // it unhandled at the end of the responder chain, and AppKit
            // answers an unhandled key with the system alert beep — so
            // holding Space to pan produced a stream of "tin tin tin".
            // Nothing in Develop wants a bare Space for anything else (the
            // one thing that would, a text field, is excluded above), so
            // there is nothing to give it back to.
            if event.isARepeat {
                return nil
            }
            isSpaceHeld = zoomLevel > 1 && event.type == .keyDown
            return nil
        }
    }

    private func removeSpaceKeyMonitor() {
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
        }
        spaceKeyMonitor = nil
        // Cleared on the way out: a key-up that arrives after the monitor is
        // gone can never clear it, and a stuck "space is down" would leave an
        // invisible layer swallowing every drag on the canvas.
        isSpaceHeld = false
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
                    patchBrushSize = min(max(patchBrushSize * factor, 0.001), 0.3)
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

    // MARK: - Draggable edges

    // The line between the picture and the panel, and the line between the
    // picture and the filmstrip. Each one IS the divider that used to be
    // there — the hairline is drawn at the same 1pt, so nothing looks
    // different until the cursor reaches it.
    //
    // The hit area is deliberately wider than the hairline (7pt, centred on
    // it). A 1pt drag target is a target the client hunts for; every app that
    // does this — Lightroom, Xcode, Finder's column view — gives the edge a
    // few points of slop in both directions. `.contentShape` is what makes the
    // transparent padding draggable rather than just empty.

    private var panelResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay(
                Rectangle()
                    .fill(AppColors.border)
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                // push/pop rather than .set: the cursor has to go back to
                // whatever the tool underneath had (the brush circle, the crop
                // handles), and .set would leave the resize arrows behind.
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            // .global, not the default local space. The gesture is attached
            // to the handle, and the handle MOVES as a result of the drag —
            // in local coordinates that is a feedback loop, because each
            // frame's translation is measured from a view that the previous
            // frame just displaced. Global coordinates are fixed to the
            // window, so the translation means the same thing throughout.
            // This was the other half of the shaking.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = panelWidthAtDragStart ?? panelWidth
                        panelWidthAtDragStart = start
                        // Minus: the panel is on the RIGHT, so dragging the
                        // edge left (negative translation) makes it wider.
                        panelWidthLive = min(max(start - value.translation.width,
                                                 Self.panelMinWidth),
                                             Self.panelMaxWidth)
                    }
                    .onEnded { _ in
                        if let live = panelWidthLive {
                            panelWidth = live
                        }
                        panelWidthAtDragStart = nil
                        panelWidthLive = nil
                    }
            )
    }

    private var filmstripResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 7)
            .overlay(
                Rectangle()
                    .fill(AppColors.border)
                    .frame(height: 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = filmstripHeightAtDragStart ?? filmstripHeight
                        filmstripHeightAtDragStart = start
                        // Minus, same reason: the filmstrip is BELOW, so
                        // dragging its top edge up (negative) grows it.
                        filmstripHeightLive = min(max(start - value.translation.height,
                                                      Self.filmstripMinHeight),
                                                  Self.filmstripMaxHeight)
                    }
                    .onEnded { _ in
                        if let live = filmstripHeightLive {
                            filmstripHeight = live
                        }
                        filmstripHeightAtDragStart = nil
                        filmstripHeightLive = nil
                    }
            )
    }

    // Thumbnails fill whatever height the client has dragged the strip to,
    // rather than staying 100pt in a 260pt strip with 160pt of dead space
    // under them — a drag that grew the container and not its contents would
    // be a drag that does nothing worth doing.
    //
    // The 20 is the LazyHStack's own 10pt padding, top and bottom.
    private var filmstripThumbnailSide: CGFloat {
        max(56, CGFloat(effectiveFilmstripHeight) - 20)
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                // LazyHStack, emphatically not HStack. A plain HStack inside a
                // ScrollView builds and mounts EVERY child immediately, so
                // .onAppear fired on every thumbnail in the folder the moment
                // Develop opened — and each of those calls
                // makeShowGridThumbnail, which passes
                // kCGImageSourceCreateThumbnailFromImageAlways and therefore
                // decodes the FULL image before scaling it to 240px. Opening a
                // folder of 300 RAWs started 300 full decodes at once. That is
                // the "Develop stutters as if every photo opened at full size"
                // report, and it was literally true.
                //
                // Lazy mounts only what is scrolled into view, so the cost is
                // proportional to what the client can actually see.
                LazyHStack(spacing: 8) {
                    ForEach(photoURLs, id: \.self) { url in
                        filmstripThumbnail(for: url)
                    }
                }
                .padding(10)
            }

            // Select All / Deselect / Sync / Export All used to stand here,
            // in two columns pinned to the right end of the strip. They are on
            // the right-click menu now, per request: they are four controls
            // that are pressed occasionally, and they were permanently
            // occupying the one row whose whole job is showing photographs.
            // Every one of them acts on the SELECTION, and the selection is
            // made by clicking thumbnails — so the menu on a thumbnail is
            // where the hand already is.
        }
        .frame(height: CGFloat(effectiveFilmstripHeight))
        .background(AppColors.panel)
    }

    private func filmstripThumbnail(for url: URL) -> some View {
        let isOpen = selectedURL == url
        let isMultiSelected = multiSelectedURLs.contains(url)
        let hasEdits = PhotoEditStore.hasEdits(url)
        let isRejected = rejectedURLs.contains(url)

        return ZStack(alignment: .topTrailing) {
            Group {
                if let image = filmstripThumbnails[url] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // A spinner, not a flat plate. Decoding a strip of RAWs
                    // takes real time — each one is a full decode before it is
                    // scaled, and the edits are then rendered over it — and a
                    // row of empty rectangles reads as photos that failed
                    // rather than photos on their way.
                    ZStack {
                        Rectangle().fill(AppColors.panelAlt)
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                }
            }
            .frame(width: filmstripThumbnailSide, height: filmstripThumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Dimmed and flagged, the same way ShowGrid's grid cell shows a
            // rejected photo. The dim is on the PICTURE only, so the selection
            // ring and both badges stay at full strength — a strip where the
            // ring fades too would read as "not selected" rather than
            // "rejected".
            .opacity(isRejected ? 0.42 : 1)
            .overlay(alignment: .bottomLeading) {
                if isRejected {
                    // Bottom-left, because top-left is the selection tick and
                    // top-right is the edits badge. Three marks in a 100pt
                    // thumbnail need three different corners or they overlap
                    // into a smear.
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(AppColors.background)
                        .padding(3)
                        .background(Circle().fill(AppColors.ink.opacity(0.92)))
                        .padding(4)
                }
            }
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
                // The SAME ink-on-background pair the edits badge below uses,
                // and for the same reason it uses it: those two colours are
                // the app's own text pair, so they are guaranteed to contrast
                // in every theme, and they follow the theme instead of
                // standing outside it.
                //
                // This was a fixed macOS-blue until 2.09., chosen to match
                // Finder's and Photos' "item is selected" affordance. The
                // client asked for it to follow the theme like the badge on
                // the right does — a blue disc is the one thing in this strip
                // that belongs to another app's palette rather than to this
                // one.
                //
                // `.palette` stays: it colours the tick and the disc as two
                // separate layers, which is what keeps the tick readable. A
                // single flat colour here once produced a near-white blob on
                // light thumbnails, and that is not worth rediscovering.
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AppColors.background, AppColors.ink.opacity(0.92))
                    .font(.system(size: 15))
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if hasEdits {
                // NOT accentColor. In the dark theme that is a pale cream, and
                // a white glyph on pale cream is a white glyph on nothing —
                // reported with a screenshot, the badge was visible and the
                // icon inside it was not.
                //
                // ink-on-background instead, which is the app's own text pair:
                // it is guaranteed to contrast in every theme because that is
                // the one thing those two colours are for, and it reads as part
                // of the app rather than as a warning. accentColor stays the
                // selection ring, which is what it is reserved for.
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(AppColors.background)
                    .padding(4)
                    .background(Circle().fill(AppColors.ink.opacity(0.92)))
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
                // editor (selectedURL), same as the "Syncing" button that
                // used to sit beside the strip — right-clicking a DIFFERENT
                // thumbnail within the same selection still syncs FROM the
                // open photo, not from the one under the cursor, so this
                // reads the same regardless of which selected thumbnail you
                // happen to right-click.
                //
                // Count in the label because the menu is transient: the old
                // button sat on screen where "Sync (0)" could be read at
                // leisure, a menu item is seen for a second and has to say
                // how many photos it is about to write to in that second.
                let syncTargets = selectedURL.map { multiSelectedURLs.subtracting([$0]).count } ?? 0
                Button("Sync to \(syncTargets) Selected…") {
                    showSyncDialog = true
                }
                .disabled(syncTargets == 0)
            } else {
                Button("Export…") {
                    exportSinglePhoto(url)
                }
            }

            Divider()

            // The other half of what stood beside the strip. Selection
            // commands are in the same menu as the things that consume a
            // selection, in the order they are used: select, then act.
            Button("Select All") {
                selectAllPhotos()
            }

            Button("Deselect") {
                deselectAllPhotos()
            }
            .disabled(multiSelectedURLs.isEmpty)

            // Select All then Reset here is how a whole folder goes back to
            // its originals, which is the request this answers.
            Button(multiSelectedURLs.count > 1
                   ? "Reset \(multiSelectedURLs.count) Selected to Original"
                   : "Reset to Original") {
                if multiSelectedURLs.count > 1 {
                    resetSelectedPhotos()
                } else {
                    PhotoEditStore.setSettings(PhotoEditSettings(), for: url)
                    if url == selectedURL {
                        resetAllSettings()
                    }
                    PhotoEditStore.flushNow()
                }
            }

            Divider()

            // Two one-press looks, on the same target rule as Export at the
            // top of this menu: the whole selection when the right-clicked
            // photo is part of one, otherwise just the photo under the
            // cursor. One right-click must not mean two different sets
            // depending on which item is picked.
            //
            // Counts in the labels for the same reason Sync's is there — a
            // menu item is read for a second, and has to say how many
            // photos it is about to change in that second.
            let bwTargets = contextMenuTargets(for: url)

            Button(bwTargets.count > 1 ? "Black & White (\(bwTargets.count))" : "Black & White") {
                applyBlackAndWhite(to: bwTargets)
            }

            Button(bwTargets.count > 1 ? "Duplicate (\(bwTargets.count))" : "Duplicate") {
                duplicatePhotos(bwTargets, blackAndWhite: false)
            }

            Button(bwTargets.count > 1 ? "Duplicate & BW (\(bwTargets.count))" : "Duplicate & BW") {
                duplicatePhotos(bwTargets, blackAndWhite: true)
            }

            Divider()

            Button(bwTargets.count > 1 ? "Delete (\(bwTargets.count))" : "Delete", role: .destructive) {
                pendingTrashPhotoURLs = bwTargets
                isTrashPhotoConfirmationPresented = true
            }

            Divider()

            // Folder-wide, not selection-wide — it exports every EDITED photo
            // in the folder regardless of what is selected, which is why it
            // keeps its own count and sits below a divider rather than among
            // the selection commands.
            let editedCount = photoURLs.filter { PhotoEditStore.hasEdits($0) }.count
            Button("Export All Edited (\(editedCount))…") {
                showExportAllOptions = true
            }
            .disabled(editedCount == 0)
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

    /// `force` re-decodes a thumbnail this view already has, for when the
    /// photo's EDITS changed rather than the photo. The existing image is
    /// deliberately left on screen until the new one is ready — clearing it
    /// first would flash a spinner in the strip on every edit.
    // The filmstrip is a view of the photos AS THEY ARE, so it has to hear
    // when they change — not only when they are first decoded.
    //
    // Without this the strip kept whatever it decoded on open: resetting a
    // photo back to its original left the strip still showing the edited
    // version, disagreeing with the picture directly above it. The
    // notification is already coalesced on the sending side (see
    // PhotoEditStore.flushNow), so a slider drag produces one re-decode at the
    // end of it, not one per frame.
    private func refreshFilmstripThumbnails(_ changed: Set<URL>) {
        for url in photoURLs where changed.contains(url) {
            loadFilmstripThumbnail(for: url, force: true)
        }
    }

    private func loadFilmstripThumbnail(for url: URL, force: Bool = false) {
        guard force || filmstripThumbnails[url] == nil else {
            return
        }
        guard !filmstripThumbnailsInFlight.contains(url) else {
            return
        }
        filmstripThumbnailsInFlight.insert(url)

        filmstripThumbnailQueue.async {
            // Edited, like ShowGrid's tiles. The filmstrip used to show the
            // untouched original, so a photo already worked on looked
            // unedited in the strip until it was clicked and the big preview
            // rendered — the strip and the picture above it disagreeing about
            // the same photograph.
            let image = makeEditedShowGridThumbnail(from: url, maxPixelSize: filmstripThumbnailPixelSize)

            DispatchQueue.main.async {
                filmstripThumbnailsInFlight.remove(url)
                guard let image else {
                    return
                }
                filmstripThumbnails[url] = image
                // Re-decoded after an eviction: drop the stale position first,
                // or the old entry would evict this fresh one on the next pass.
                filmstripThumbnailOrder.removeAll { $0 == url }
                filmstripThumbnailOrder.append(url)
                evictOldestFilmstripThumbnailsIfNeeded()
            }
        }
    }

    // Oldest-first, and never the photo currently open — that one is on screen
    // in the filmstrip's selection ring, so dropping it would visibly blank the
    // row the client is working from.
    private func evictOldestFilmstripThumbnailsIfNeeded() {
        while filmstripThumbnailOrder.count > filmstripThumbnailCacheLimit {
            guard let oldest = filmstripThumbnailOrder.first else {
                return
            }
            filmstripThumbnailOrder.removeFirst()
            if oldest != selectedURL {
                filmstripThumbnails[oldest] = nil
            }
        }
    }

    // MARK: Top bar

    // What used to be the top bar across the picture. It is a column now, not
    // a row: 340pt cannot hold a file name, a status, Before/After and Done
    // side by side, and squeezing them would truncate the one thing here that
    // is not replaceable — the name of the photo being worked on.
    //
    // Erase progress and export status keep their old slot beside the name,
    // for the reason they were put there: the generative path takes ~13s, long
    // enough that the eye leaves the button, and it comes back to the top.
    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedURL {
                HStack(spacing: 8) {
                    // .middle, not the default .tail: photographers' filenames
                    // differ in the SHOT NUMBER at the end (_0473.CR2), so
                    // truncating the tail makes every name in a folder read
                    // identically. The middle is the disposable part.
                    Text(selectedURL.lastPathComponent)
                        .font(.custom("Figtree", size: 13).weight(.semibold))
                        .foregroundColor(AppColors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(selectedURL.lastPathComponent)

                    if PhotoEditRenderer.isRAW(selectedURL) {
                        rawBadge
                    }

                    Spacer(minLength: 0)
                }

                if isRemoving {
                    eraseProgressBar
                }
            }

            if let exportStatusText {
                Text(exportStatusText)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(AppColors.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ONE bar, icon only, every cell the same size and no gap
            // anywhere in it — asked for in those terms: *„sve da bude bez
            // texta samo dugmad sa ikonicom i da se sve stavi pod jednu
            // sekciju i sva dugmad da budu iste velicine i da nikad ne
            // ostavlja prostor prazan izmedju ikonica ili sa strane"*.
            //
            // The words are not lost, they moved into the tooltip: hovering a
            // cell says what it does. That is also why the tooltips are
            // sentences rather than the old labels — with the label gone from
            // the screen, the tooltip is the only place left that can explain
            // a glyph.
            panelHeaderActionBar

            // Directly under the buttons, because that is where the client
            // pressed and where he is looking: *„kada kliknem gore na quick
            // action select people treba da se pojavi onaj loading bar baš
            // ispod da zna klijent da radi"*.
            //
            // The Tools strip keeps its own copy. This is not a duplicate by
            // accident — the two ways in are far apart on screen, and a bar
            // that appears next to the OTHER button is a bar the client does
            // not see. Both read the same `isFindingPeople`, so neither can
            // say something the other does not.
            //
            // Indeterminate, for the reason written on the other one: Vision
            // reports no progress, and an invented percentage is worse than
            // an honest spinner.
            if isFindingPeople {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looking for people…")
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)

                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                }
            }

            // ⚠️ Flattening is the longest wait in this window — it renders the
            // WHOLE frame at full resolution and writes an uncompressed TIFF of
            // it (see FlattenedImageStore: measured at 102 MB on the client's
            // own 5176×3448 RAW). Without this the button greyed out and the
            // window sat there, which is precisely the complaint KORAK 49 fixed
            // once already for the flattened-preview window: *„obavezno loading
            // bar"*.
            //
            // Indeterminate for the same honest reason as the people bar: a
            // render and a file write report no progress, and a made-up
            // percentage is worse than none.
            //
            // The caption is skipped when `exportStatusText` is already saying
            // something — a batch bake from the grid sets that and shares this
            // same `isFlattening`, and two lines saying the same thing read as
            // a bug.
            if isFlattening {
                VStack(alignment: .leading, spacing: 4) {
                    if exportStatusText == nil {
                        Text("Flattening…")
                            .font(.custom("Figtree", size: 11))
                            .foregroundColor(AppColors.muted)
                    }

                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // The tools, over the photo instead of scattered down the right panel.
    //
    // The panel stays where it is and keeps what it is good at — sliders,
    // lists, the options belonging to whichever tool is running. What it was
    // bad at is being the only way to REACH a tool: Crop lived under "Crop &
    // Rotate", Patch under "Masks", Select Area under "Remove", each behind a
    // different amount of scrolling, so picking a tool meant knowing which
    // section it had been filed under. Up here they are one row, always in
    // the same place, and each one lights up while it is the active tool.
    // Crop, Selection and Patch. They are NOT AI — nothing here calls a model
    // — which is the whole reason they were split off from the block below
    // when that block became "AI Manipulation". Grouping them under that title
    // would have been the label lying about three of its own buttons.
    // Patch alone. Crop and Selection were here too and are gone from this
    // row — not removed from the app, just from their SECOND home: Crop is
    // Edit's "Crop & Rotate" section and Selection is the "Selection" section
    // a little further down this same tab. Three buttons whose only job was
    // duplicating controls a few rows away cost more panel than they saved.
    //
    // Patch has no such other home — the Masks section's "Patch Circle" was
    // the duplicate, and it is this button that survived — so the row stays
    // for it.
    private var toolsRowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Tools")

            HStack(spacing: 6) {
                // Patch is a CIRCLE by default and that is deliberate. It is a
                // clone stamp: the circle IS the tool, the brush you paint
                // with, not an outline you have to correct first — so arriving
                // ready to paint is the point of it. (Selection, by contrast,
                // starts free-hand, because a selection goes around something
                // that already has a shape.) The two were briefly made to
                // match and that was wrong on this side; written down so they
                // are not "made consistent" again by someone tidying up.
                toolButton("Patch", systemImage: "bandage",
                           isActive: selectedAdjustmentIndex.map { settings.localAdjustments[$0].type == .patch } ?? false) {
                    addLocalAdjustment(.patch(name: nextMaskName("Patch"), shape: .circle))
                }

                // Moved here from the Remove section, because what it does
                // changed: it no longer finds people to ERASE, it lifts them
                // onto a layer of their own so they can be graded apart from
                // the rest of the frame. That is a tool, not a removal.
                toolButton("Select People", systemImage: "person.crop.rectangle",
                           isActive: isFindingPeople) {
                    selectPeopleAsLayer()
                }
                .disabled(isFindingPeople || isRemoving || selectedURL == nil)
                .opacity((isFindingPeople || isRemoving || selectedURL == nil) ? 0.4 : 1)

                Spacer(minLength: 0)
            }

            // Vision reports no progress, so this is an INDETERMINATE bar
            // and not a percentage. A percentage here would be invented,
            // and the one thing this has to do is be believed: the search
            // takes long enough on a big frame that a still panel reads as
            // a button that did nothing.
            if isFindingPeople {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looking for people…")
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)

                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                }
            }

            // Shown only once a layer actually exists, so it is a report of
            // something that happened rather than a promise.
            if let newLayerNotice {
                VStack(alignment: .leading, spacing: 8) {
                    Text(newLayerNotice)
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    // One way out, not two. "Remove Paint Selection" stood
                    // here and was dropped on sight: the search leaves no
                    // paint behind — it makes layers — so the button
                    // offered to undo something that had not happened.
                    //
                    // ⚠️ This does NOT call undo(). It used to, and that was
                    // the reported bug: undo() pops ONE step off the stack,
                    // and by the time anybody presses this the top of the
                    // stack is usually something else — moving the layer,
                    // a slider — so the layers stayed and an unrelated edit
                    // was taken back instead. This button has one job and
                    // has to do that job whatever else has happened since.
                    // It writes settings.layers like any other edit, so
                    // Cmd+Z still puts them back.
                    panelActionButton("Undo", systemImage: "arrow.uturn.backward") {
                        removeNewLayers()
                        self.newLayerNotice = nil
                    }
                }
                .padding(10)
                .background(AppColors.panelAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppColors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Lifts the people in the frame onto a layer of their own.
    ///
    /// The same Vision mask "Select People" always used, put to a different
    /// purpose: instead of handing the mask to the eraser, the pixels under
    /// it are copied out as a PNG (alpha and all) and dropped straight back
    /// at the same spot as an ImageLayer. On screen nothing moves — the
    /// copy lands exactly over the people it came from — but there is now a
    /// layer holding them, and the layer's own sliders reach only them.
    ///
    /// An active Selection still confines the search, the way it always
    /// did: rope off the background, and only the people inside the rope
    /// are lifted.
    ///
    /// ⚠️ Known, and inherent to a pixel layer: the copy is taken from the
    /// render AS IT IS NOW. Global sliders moved afterwards change the photo
    /// underneath and not the layer on top, which will show as the people
    /// drifting away from the rest of the frame. That is how every pasted
    /// layer in this app already behaves; it is worth knowing, not worth
    /// pretending otherwise.
    ///
    /// ⚠️ Also known: one layer for everybody found, not one per person.
    /// The mask is a single image and splitting it into connected
    /// components is a separate piece of work.
    private func selectPeopleAsLayer() {
        guard let fullBaseImage, let selectedURL else {
            return
        }

        isFindingPeople = true
        removeNotice = nil
        newLayerNotice = nil

        let settingsSnapshot = settings
        let photoAtActionTime = selectedURL
        let confineTo = activeSelection

        // Read confineTo FIRST, then fold AI Clean Up away. Turning the brush
        // off does not clear an active Selection today — only turning it ON
        // does — but this ordering means a later change to that cannot quietly
        // drop the region the client asked to search inside.
        //
        // Closed here at the START, not on completion: the press has to be
        // answered immediately, and the search runs for seconds. Waiting until
        // the layers exist would leave the client looking at the clean-up
        // brush wondering whether the button registered.
        closeAICleanUp()

        developRenderQueue.async(qos: .userInitiated) {
            // applyCrop: false, because a layer's x/y/width/height live in
            // the pre-crop unit space — the same reason compositeLayers runs
            // before the crop.
            let full = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage, applyCrop: false)
            var mask = SubjectMasker.personMask(for: full)

            if let found = mask, let confineTo,
               !(confineTo.shape == .free && confineTo.points.count < 3) {
                let shape = PhotoEditRenderer.selectionMask(confineTo, extent: full.extent)
                mask = found.applyingFilter("CIMultiplyBlendMode", parameters: [
                    kCIInputBackgroundImageKey: shape
                ]).cropped(to: full.extent)
            }

            // ⚠️ The two layers are deliberately DIFFERENT KINDS, and the
            // difference is what each one is for.
            //
            // People is a PIXEL layer — a real cut-out — because the client
            // asked to move, scale and rotate them, and a matte cannot be
            // moved: sliding a mask does not slide the people, it slides a
            // hole and shows the photo through it somewhere else.
            //
            // Background is DERIVED — a matte over the photo, no pixels —
            // because it covers the whole frame, and a full-frame PNG in
            // UserDefaults is tens of megabytes rewritten on every flush
            // (see ImageLayer.maskData). Nobody wants to drag the
            // background anywhere either.
            let box = mask.flatMap {
                InpaintPipeline.maskBoundingBox($0, extent: full.extent, context: briefEditsCIContext)
            }
            let peoplePNG = (mask != nil && box != nil)
                ? PhotoEditRenderer.extractMaskedPNG(mask: mask!, from: full, pixelRect: box!)
                : nil

            var placement: (x: Double, y: Double, width: Double, height: Double)?
            if let box {
                // A layer's y is its TOP edge measured downward; Core
                // Image's is the bottom edge measured upward. maxY is the
                // top, so the distance down to it is 1 minus that fraction.
                let extent = full.extent
                placement = (
                    x: (box.minX - extent.minX) / extent.width,
                    y: 1 - (box.maxY - extent.minY) / extent.height,
                    width: box.width / extent.width,
                    height: box.height / extent.height
                )
            }

            let backgroundMask = mask
                .flatMap { $0.applyingFilter("CIColorInvert").cropped(to: full.extent) }
                .flatMap { PhotoEditRenderer.maskPNG($0, extent: full.extent) }

            DispatchQueue.main.async {
                isFindingPeople = false

                guard selectedURL == photoAtActionTime else {
                    return
                }

                guard let peoplePNG, let placement, let backgroundMask,
                      placement.width > 0, placement.height > 0 else {
                    removeNotice = "No people found in this photo. Anyone small enough in the frame is usually below what the detector can see — cut them out by hand with the Selection tool instead."
                    return
                }

                // Background first, people second: layers composite in array
                // order, so the people end up on top of the background the
                // way the picture itself is arranged.
                let background = ImageLayer(
                    name: nextLayerName("Background"), imageData: Data(),
                    x: 0, y: 0, width: 1, height: 1, maskData: backgroundMask
                )
                let people = ImageLayer(
                    name: nextLayerName("People"), imageData: peoplePNG,
                    x: placement.x, y: placement.y,
                    width: placement.width, height: placement.height
                )

                settings.layers.append(background)
                settings.layers.append(people)
                newLayerIDs = [background.id, people.id]
                selectedLayerID = people.id

                // Straight to Layers, every time, asked for as *„uvek kad se
                // klikne select people i to zavrsi automatski baci na layers"*.
                // This makes two layers and selects one of them; leaving the
                // panel on Edit meant the client had to go and find the result
                // of the thing he had just pressed. It runs from BOTH ways in
                // (the header button and the one in Tools) because it sits at
                // the end of the work, not on either button.
                panelTab = .layers
                newLayerNotice = "Two layers now: People and Background. The People layer is selected — drag it on the photo to move it, drag a corner to resize, or use the knob above it to rotate. Its own sliders change only them."
            }
        }
    }
    /// Takes back exactly the layers the last Select People made.
    ///
    /// By id, not by popping the undo stack — see the card's Undo button for
    /// what went wrong when it was the other way round. Writes
    /// settings.layers like any ordinary edit, so Cmd+Z still restores them.
    private func removeNewLayers() {
        let doomed = Set(newLayerIDs)
        guard !doomed.isEmpty else {
            return
        }

        if let selectedLayerID, doomed.contains(selectedLayerID) {
            self.selectedLayerID = nil
        }
        settings.layers.removeAll { doomed.contains($0.id) }
        newLayerIDs = []
    }

    // Everything that calls a model, behind one disclosure arrow.
    //
    // Collapsed it is a single line; open it is four rows plus whatever the
    // brush needs. That is the point of making it fold: this is the tallest
    // thing in the panel and it is only tall while it is being used, so the
    // sections under it (Masks, Selection, Remove) are otherwise pushed a
    // screen down for a client who is not cleaning anything up right now.
    //
    // The open/closed state is remembered app-wide, like the layout sizes —
    // someone who never uses the AI path should close it once, not once per
    // photo.
    // ⚠️ NO TITLE ROW ANY MORE, and no chevron. This used to be a disclosure
    // whose closed state was still one titled line in the panel, and that line
    // is what the client asked to be rid of: the way in is the "AI Clean Up"
    // button in the header, and when it is off this block is not there at all.
    //
    // `aiManipulationExpanded` is unchanged and still the same @AppStorage key,
    // so a client who left it open keeps it open across this build.
    private var aiManipulationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isAIManipulationVisible {
                // ⚠️ NO "Clean Up" BUTTON HERE ANY MORE. It moved to the panel
                // header, where one press both opens this block and picks up
                // the brush; leaving a copy behind would be leaving the second
                // step of the two-step that was just removed.
                HStack(spacing: 6) {
                    // Explicit way out. Select People is NOT gone — it lives on
                    // in the Remove section below, which is its only entry
                    // point now. It was moved rather than deleted because it
                    // MAKES a selection, and the request was for a way to leave
                    // the tool, not to lose a way into it.
                    //
                    // Disabled rather than hidden while the tool is off: a
                    // button that appears and disappears reflows the row around
                    // it, and these rows are meant to be muscle memory.
                    toolButton("Exit Clean Up", systemImage: "xmark",
                               isActive: false,
                               isEnabled: isRemoveBrushActive) {
                        toggleRemoveBrush()
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    toolButton("Quick Clean Up", systemImage: "wand.and.rays",
                               isActive: false,
                               isEnabled: cleanUpUnavailableReason(.quick) == nil,
                               help: cleanUpUnavailableReason(.quick)) {
                        eraseMaskedArea(using: .quick)
                    }

                    // "Generative Clean Up", not "AI Clean Up": the paint tool in
                    // the row above now carries that name, and two buttons reading
                    // the same in one strip is worse than either name on its own.
                    // "Generative" is also the truer word — this is the Stable
                    // Diffusion path (~13s), against LaMa's ~1s beside it.
                    toolButton("Generative Clean Up", systemImage: "wand.and.stars",
                               isActive: false,
                               isEnabled: cleanUpUnavailableReason(.generative) == nil,
                               help: cleanUpUnavailableReason(.generative)) {
                        eraseMaskedArea(using: .generative)
                    }

                    Spacer(minLength: 0)
                }

                // ⚠️ The way in for the 1.8 GB weights, and the first time this
                // app has ever offered one. Until now the Generative button sat
                // greyed out on every machine but the developer's, because the
                // models were only ever read from a folder nothing wrote — see
                // SDModelInstall.swift.
                //
                // Shown ONLY while they are actually missing, and on BOTH
                // processors. It was arm64-only while the pipeline was compiled
                // out on Intel — downloading 1.8 GB for a button that could not
                // run would have been taking the client's afternoon for
                // nothing. That is no longer the case: an Intel Mac has
                // installed these weights and run them.
                //
                // (The sentence that used to stand here, saying Intel compiles
                // the pipeline out, contradicted the paragraph under it. It was
                // left behind by the port and is removed rather than kept.)
                if !SDInpaintPipeline.shared.isModelInstalled || modelInstaller.isWorking {
                    sdModelInstallRow
                } else {
                    sdModelReadinessRow
                }

                // Everything the Clean Up brush needs, appearing under the rows
                // only while the brush is in play.
                //
                // This block is allowed to change height freely, which it was
                // NOT when the strip lived above the picture — back then every
                // appear and disappear shoved the photo down and back up, which
                // is why the notice below was pinned to a fixed 30pt slot and
                // the size slider was crammed onto the end of a button row. In
                // a column BESIDE the picture the photo cannot move, so both
                // are now what they wanted to be: full width, as tall as they
                // need.
                if isRemoveBrushActive {
                    HStack(spacing: 8) {
                        Text("Size")
                            .font(.custom("Figtree", size: 11))
                            .foregroundColor(AppColors.muted)

                        EditTrackSlider(value: $removalBrushSize, range: 0.01...0.3,
                                        step: 0.01, accent: accentColor)
                            .frame(maxWidth: .infinity)

                        Text(String(format: "%.0f", removalBrushSize * 100))
                            .font(.custom("Figtree", size: 11))
                            .foregroundColor(AppColors.muted)
                            .monospacedDigit()
                            .frame(width: 20, alignment: .trailing)
                    }

                    // Add / Erase, Lightroom's own pairing: pick Erase and the
                    // brush takes area back OUT of what is already marked instead
                    // of adding to it — including anything Select People found.
                    //
                    // Two visible buttons rather than a held modifier key: "hold
                    // this to take some back" is the sort of thing only the person
                    // who wrote it remembers.
                    HStack(spacing: 6) {
                        ForEach([false, true], id: \.self) { erasing in
                            Button {
                                isRemoveBrushErasing = erasing
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: erasing ? "eraser" : "plus")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(erasing ? "Erase" : "Add")
                                        .font(.custom("Figtree", size: 11))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(isRemoveBrushErasing == erasing ? AppColors.ink : AppColors.muted)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isRemoveBrushErasing == erasing ? accentColor.opacity(0.18) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(isRemoveBrushErasing == erasing ? accentColor.opacity(0.55) : AppColors.border,
                                            lineWidth: 1)
                            )
                        }
                    }
                }

                // Drops every mark on the photo — painted strokes and a Select
                // People mask alike — without touching the picture itself. Shown
                // whenever there IS something to drop, brush on or off, since a
                // Select People mask is made with the brush off.
                //
                // Named "Clear", not "Clean": three buttons above say "Clean Up"
                // and every one of them CHANGES the photo. This one only throws
                // away the marking.
                if hasRemovalArea {
                    Button {
                        clearRemovalMask()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Clear AI Area")
                                .font(.custom("Figtree", size: 11))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppColors.muted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
                }

                // The Clean Up tool's commentary. It was briefly drawn over the
                // picture, which kept it out of the layout but put text on the
                // client's photograph — the one place it must not be. Then it was
                // a fixed-height slot in the top bar, because a bar above the
                // picture that grew a second line pushed the picture down.
                //
                // Neither constraint applies here: this is a column beside the
                // photo, so the text can simply be as tall as it is.
                if let notice = cleanUpNotice {
                    Text(notice)
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Why a Clean Up button cannot be pressed right now, in one sentence, or
    // nil when it can. A greyed-out button with no explanation is the thing
    // being fixed here — the client reported exactly that: two dead buttons
    // and no way to know whether the problem was the selection, the size, or
    // the app.
    /// Install / progress / failure for the Generative weights, in one row.
    ///
    /// Three states in one place rather than three scattered views: the client
    /// presses one button and watches the same strip answer, which is what
    /// makes a 1.8 GB wait tolerable. The percentage is real here — unlike the
    /// people search and the flatten, a download reports its own progress, so
    /// showing it is honest rather than invented.
    /// One quiet line saying whether the Generative model is ready to go.
    ///
    /// ⚠️ THIS IS ALSO HOW THE TIMINGS GET MEASURED ON A MACHINE THAT IS NOT
    /// THIS ONE. The load and priming costs are the whole subject of the
    /// "why was the first one slow" question, and they differ completely
    /// between a Neural Engine and a Radeon. The app logs them, but a GUI app's
    /// log is somewhere a client has no reason to go — so the numbers are put
    /// on screen, where they can simply be read out.
    ///
    /// Small and muted on purpose: it is a status line, not a feature. Once the
    /// model is warm it says one short sentence and stops competing with the
    /// two buttons above it.
    private var sdModelReadinessRow: some View {
        HStack(spacing: 6) {
            if sdPipeline.isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("Getting the Generative model ready…")
            } else if sdPipeline.isLoaded {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                Text(sdReadinessDetail)
            } else {
                // Installed on disk but not loaded and not loading: the warm-up
                // failed, or it has not been reached yet. Says neither "ready"
                // nor "broken", because it is neither.
                Text("Generative model installed. It loads on first use.")
            }
            Spacer(minLength: 0)
        }
        .font(.custom("Figtree", size: 10))
        .foregroundColor(AppColors.muted)
    }

    /// "Generative model ready (41s + 3s at launch)." — or without the numbers
    /// on the launches where Core ML had everything cached and there was
    /// nothing worth reporting.
    private var sdReadinessDetail: String {
        let load = sdPipeline.lastPrepareSeconds
        let prime = sdPipeline.lastPrimeSeconds
        guard let load, let prime, load + prime >= 1 else {
            return "Generative model ready."
        }
        return String(format: "Generative model ready (%.0fs load + %.0fs warm-up).", load, prime)
    }

    private var sdModelInstallRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch modelInstaller.state {
            case .idle:
                HStack(spacing: 8) {
                    Button {
                        modelInstaller.install()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Install Model (\(SDModelInstaller.downloadSizeText))")
                        }
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                    .help("Downloads the Generative Clean Up weights once. Quick Clean Up works without them.")

                    Spacer(minLength: 0)
                }

            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Downloading the model… \(Int(fraction * 100))%")
                            .font(.custom("Figtree", size: 11))
                            .foregroundColor(AppColors.muted)

                        Spacer()

                        Button("Cancel") { modelInstaller.cancel() }
                            .buttonStyle(.plain)
                            .font(.custom("Figtree", size: 11))
                            .foregroundColor(AppColors.muted)
                    }

                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                }

            case .unpacking:
                VStack(alignment: .leading, spacing: 4) {
                    // No percentage: unpacking reports none, and an invented
                    // one is worse than none — the same rule the people search
                    // and the flatten bar already follow.
                    Text("Unpacking the model…")
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)

                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Try Again") { modelInstaller.install() }
                        .buttonStyle(ShowHeaderButtonStyle())
                }
            }
        }
    }

    private func cleanUpUnavailableReason(_ engine: RemovalEngine) -> String? {
        if selectedURL == nil {
            return "Open a photo first."
        }
        if isRemoving {
            return "Already cleaning up — wait for this one to finish."
        }
        if !hasRemovalArea {
            return "Nothing is selected yet. Paint over what should go with AI Clean Up. (Select People no longer feeds this — it lifts people onto a layer instead, in Tools.)"
        }
        if !removalAreaFits(engine) {
            return engine.oversizeReason
        }
        // Generative Clean Up does not exist on an Intel Mac: its tensor
        // packing is Float16, which x86_64 macOS has no such type for, so
        // the pipeline is compiled out entirely (see DevelopSDInpaint.swift).
        // Said here, where the button already explains itself, rather than
        // letting the client press it and read an error afterwards.
        if engine == .generative, !SDInpaintPipeline.shared.isModelInstalled {
            #if arch(arm64)
            // ⚠️ This no longer means "you are out of luck". The weights are a
            // 1.8 GB release asset and the app installs them itself now — see
            // SDModelInstall.swift for why they cannot ride in the bundle. The
            // sentence points at the button that does it.
            return "The Generative Clean Up model isn't installed yet — use Install Model below (\(SDModelInstaller.downloadSizeText)). Quick AI Clean Up works without it."
            #else
            // ⚠️ Intel used to be told "you need an Apple Silicon Mac", because
            // the pipeline was compiled out here. It is not any more — the
            // tensors go through SDHalf now — so the model can be installed and
            // run on this machine too. The wait is the honest caveat, not the
            // architecture.
            return "The Generative Clean Up model isn't installed yet — use Install Model below (\(SDModelInstaller.downloadSizeText)). On an Intel Mac it runs, but slowly. Quick AI Clean Up is instant either way."
            #endif
        }
        return nil
    }

    // The row under the strip: whatever the active tool needs at hand, and
    // nothing when it needs nothing. A size slider belongs next to the tool
    // it resizes, not four sections down a panel the client has to scroll.
    /// The Clean Up tool's running commentary, or nil when it has nothing to
    /// say. Returned as text rather than a view so the top bar can draw it in
    /// its own empty middle, at a fixed height that cannot move the picture.
    ///
    /// Silent unless this tool is actually in play — brush on, something
    /// selected, or a reason the erase cannot run. It no longer needs to be
    /// permanently visible: what made that worth asking for was that the old
    /// docked row disappeared and shifted everything below it, and a
    /// fixed-height slot in the top bar cannot do that whether it is filled
    /// or empty.
    private var cleanUpNotice: String? {
        let reason = hasRemovalArea ? nil : cleanUpUnavailableReason(.quick)
        let painting = isRemoveBrushErasing
            ? "Painting takes area back out of the selection."
            : "Painting adds to the selection."

        // ⚠️ Says WHICH wait this is, and that is the entire point.
        //
        // The client's report was that the first Generative Clean Up after
        // opening the app took 1.5–2 minutes and every one after it took 15
        // seconds. Both numbers were correct and nothing was broken: the first
        // one was also paying to load 1.6 GB of weights into Core ML, which
        // happens once per launch. But the app said nothing while it did, so
        // from the outside it was a button that sometimes hangs.
        //
        // The load is now started at launch (see BriefShowApp.init), so most
        // of the time this line never appears. It appears when the client got
        // here first — and then it is the difference between waiting and
        // wondering.
        //
        // NOT a reason to disable the button. Pressing it during the load is
        // fine: the erase blocks on the same lock, the load finishes, and the
        // erase runs. Disabling would take away a press that works.
        let preparing = sdPipeline.isPreparing
            ? "Getting the Generative model ready — it loads once each time the app opens. Quick AI Clean Up is unaffected."
            : nil

        guard isRemoveBrushActive || hasRemovalArea || reason != nil || preparing != nil else {
            return nil
        }
        guard isRemoveBrushActive || hasRemovalArea else {
            return [reason, preparing].compactMap { $0 }.joined(separator: "  ")
        }
        return [reason, preparing, painting].compactMap { $0 }.joined(separator: "  ")
    }

    // `textIcon` draws letters where the SF Symbol would go — used for "AI",
    // which has no glyph that says what it is. Sized and framed to occupy the
    // same box a symbol does, so a strip mixing the two stays on one baseline.
    private func toolButton(
        _ title: String,
        systemImage: String,
        textIcon: String? = nil,
        isActive: Bool,
        isEnabled: Bool = true,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let live = isEnabled && selectedURL != nil
        return Button(action: action) {
            HStack(spacing: 5) {
                if let textIcon {
                    Text(textIcon)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .frame(width: 14, height: 12)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                }
                Text(title)
                    .font(.custom("Figtree", size: 11).weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundColor(isActive ? AppColors.ink : AppColors.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? accentColor.opacity(0.55) : AppColors.border.opacity(0.7), lineWidth: 1)
            )
            // Without this the Button only hits on the glyph and label
            // themselves and the first click often lands on nothing — the
            // same missing-contentShape bug already fixed on maskAddButton
            // and the aspect-ratio row, see BRIEFSHOW_DEVELOP_NOTES.md.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!live)
        .opacity(live ? 1 : 0.35)
        // On a disabled button the tooltip is the ONLY way the reason can
        // reach the pointer that just tried to click it.
        .help(help ?? "")
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
    // MARK: Header action bar

    /// What a header cell draws. One glyph, never a word.
    private enum HeaderGlyph {
        case symbol(String)
        /// The letters "AI". There is no SF Symbol that says AI, and a wand
        /// would say the same thing as the Clean Up buttons it opens.
        case badge(String)
    }

    private struct HeaderBarItem: Identifiable {
        enum Behaviour {
            case tap(() -> Void)
            /// Shows the original for as long as it is HELD — a gesture, not a
            /// press, which is why it cannot just be a Button like the rest.
            case holdForOriginal
            /// Opens the Presets popover, anchored to its own cell.
            case presets
        }

        let id: String
        let glyph: HeaderGlyph
        /// The tooltip — and now the ONLY place this button's name survives.
        /// It says what the button does rather than only what it was called,
        /// because a glyph with no label has nothing else to explain it.
        let help: String
        var isActive = false
        var isDisabled = false
        let behaviour: Behaviour
    }

    private static let headerCellHeight: CGFloat = 34

    /// How many cells go in one row.
    ///
    /// ⚠️ Only DIVISORS of the button count are ever returned, and that is the
    /// whole trick. With a divisor every row is full, so the bar can never end
    /// in a hole — which is the requirement, stated twice: *„da nikad ne
    /// ostavlja prostor prazan izmedju ikonica ili sa strane"* and *„uvek isto
    /// gore isto dole"*. The panel is draggable from 300 to 560, so the count
    /// per row has to change with it: twelve buttons go 12×1, 6×2, 4×3, 3×4,
    /// 2×6 and nothing else.
    ///
    /// ⚠️ It is also why the Unflatten cell is PERMANENT (greyed out when there
    /// is nothing to unflatten) instead of appearing only on a flattened
    /// photo: twelve divides six ways, eleven divides none at all — a row
    /// would have to end short. Flatten already greys out for its own reason,
    /// so the pair behaves alike.
    private static func headerBarColumns(for width: CGFloat, count: Int) -> Int {
        guard count > 1 else {
            return max(count, 1)
        }
        // 28 = the panel's own horizontal padding, which is not the bar's to use.
        let available = max(width - 28, 60)
        // Aimed at, not required: the split whose cells land NEAREST this is
        // the one taken. A minimum alone was tried first and it sat on six per
        // row across almost the whole drag range — technically legal, but it
        // ignored the width instead of following it, which is the opposite of
        // what was asked (*„zavisno kako se desna strana siri ili suzava"*).
        let idealCell: CGFloat = 64
        // A floor, so a very narrow panel gives up a row rather than a target
        // too small to hit.
        let smallestCell: CGFloat = 34

        let divisors = (1...count).filter { count % $0 == 0 }.sorted()
        var best = divisors.first ?? 1
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for columns in divisors {
            // The seams between cells are a pixel each, and they come out of
            // the same width the cells divide.
            let cell = (available - CGFloat(columns - 1)) / CGFloat(columns)
            guard cell >= smallestCell else {
                continue
            }
            let distance = abs(cell - idealCell)
            if distance < bestDistance {
                bestDistance = distance
                best = columns
            }
        }

        return best
    }

    /// One tool at a time. Pressing a header cell puts down whatever else was
    /// holding the canvas — reported as *„i kada kliknem na nesto sve ostalo da
    /// iskljuci! jer edit ostaje uvek ukljucen koliko vidim"*.
    ///
    /// ⚠️ The crop is COMMITTED, not cancelled. Pressing the Crop cell a second
    /// time commits too, so leaving by another door must not mean losing the
    /// frame that was just dragged.
    private func releaseCanvasTools(keepCrop: Bool = false, keepAI: Bool = false) {
        if !keepAI {
            closeAICleanUp()
        }
        if !keepCrop && isCropping {
            commitCrop()
        }
    }

    /// The ONE cell that is lit, and the reason it is computed in one place
    /// rather than each cell deciding for itself: with each deciding, Edit sat
    /// lit under a live Crop or AI brush, and two lit cells read as two things
    /// running at once.
    ///
    /// A tab is lit only when nothing is holding the canvas. Since pressing a
    /// tab now also puts those tools down, pressing one always lights it.
    private var activeHeaderCellID: String {
        if showOriginal {
            return "original"
        }
        if isCropping {
            return "crop"
        }
        if isAIManipulationVisible {
            return "ai"
        }
        if showPresetsPopover {
            return "presets"
        }
        return "tab." + panelTab.rawValue
    }

    private var headerBarItems: [HeaderBarItem] {
        let noPhoto = selectedURL == nil
        let isFlattenedPhoto = selectedURL.map { FlattenedImageStore.isFlattened($0) } ?? false

        // A tab is a cell like any other now, so it is built here rather than
        // appended as a block — the client's order interleaves them with the
        // actions: *„grid button da bude prvi pa posle original button posle
        // toga Ai pa Crop pa Edit.. pa ostalo"*.
        func tabItem(_ tab: DevelopPanelTab) -> HeaderBarItem {
            HeaderBarItem(id: "tab." + tab.rawValue,
                          glyph: .symbol(tab.systemImage),
                          help: tab.helpText,
                          isActive: activeHeaderCellID == "tab." + tab.rawValue,
                          behaviour: .tap {
                              releaseCanvasTools()
                              panelTab = tab
                          })
        }

        return [
            // First, by request. "Grid", not "Done", and named after where it
            // goes rather than after finishing something: edits are saved as
            // they are made, so nothing here is waiting to be confirmed.
            HeaderBarItem(id: "grid",
                          glyph: .symbol("square.grid.2x2"),
                          help: "Grid - back to the grid of photos.",
                          behaviour: .tap { onClose() }),

            HeaderBarItem(id: "original",
                          glyph: .symbol("photo"),
                          help: "Original - hold to see this photo as it came out of the camera.",
                          isActive: activeHeaderCellID == "original",
                          isDisabled: noPhoto,
                          behaviour: .holdForOriginal),

            HeaderBarItem(id: "ai",
                          glyph: .badge("AI"),
                          help: "AI Clean Up - paint over what should go, then let the model fill it in.",
                          isActive: activeHeaderCellID == "ai",
                          isDisabled: noPhoto,
                          behaviour: .tap {
                              // Commits a crop in progress first: the brush and
                              // the crop frame both own the canvas, and only one
                              // of them can have it.
                              releaseCanvasTools(keepAI: true)
                              toggleAICleanUp()
                          }),

            HeaderBarItem(id: "crop",
                          glyph: .symbol("crop"),
                          help: "Crop - crop, straighten and rotate this photo.",
                          isActive: activeHeaderCellID == "crop",
                          isDisabled: noPhoto,
                          behaviour: .tap {
                              releaseCanvasTools(keepCrop: true)
                              toggleCropMode()
                          }),

            tabItem(.edit),

            // ⚠️ "pa ostalo" — the rest keep the order they already had, so
            // nothing moves that was not asked to move.
            // The full circle, not "arrow.uturn.backward": this puts back EVERY
            // setting at once, and a full circle says "all the way round to
            // where it started" where a u-turn says "one step back".
            HeaderBarItem(id: "reset",
                          glyph: .symbol("arrow.counterclockwise"),
                          help: "Reset - put this photo back to the original.",
                          isDisabled: settings.isNeutral,
                          behaviour: .tap { resetAllSettings() }),

            HeaderBarItem(id: "people",
                          glyph: .symbol("person.crop.rectangle"),
                          help: "Select People - lift the people in this photo onto their own layer, with the background on a second one.",
                          isDisabled: isFindingPeople || isRemoving || noPhoto,
                          behaviour: .tap { selectPeopleAsLayer() }),

            HeaderBarItem(id: "flatten",
                          glyph: .symbol("square.stack.3d.down.forward"),
                          help: isFlattening
                              ? "Flattening…"
                              : (isFlattenedPhoto
                                 ? "Flatten Again - bake what has been done since the last flatten into the photo. Your original file is never touched."
                                 : "Flatten Photo - bake the grade, the masks and the AI Clean Up into the photo. Your original file is never touched."),
                          isDisabled: isFlattening || noPhoto || !hasUnbakedEdits,
                          behaviour: .tap { flattenPhoto() }),

            HeaderBarItem(id: "unflatten",
                          glyph: .symbol("arrow.uturn.backward"),
                          help: "Unflatten - go back to the original file and the settings from before the first flatten. Anything done since is discarded.",
                          isDisabled: isFlattening || !isFlattenedPhoto,
                          behaviour: .tap { unflattenPhoto() }),

            HeaderBarItem(id: "presets",
                          glyph: .symbol("paintpalette"),
                          help: "Presets - save this look, apply a saved one, or import from Lightroom.",
                          isActive: activeHeaderCellID == "presets",
                          behaviour: .presets),

            tabItem(.retouch),
            tabItem(.layers)
        ]
    }

    private func headerBarCell(_ item: HeaderBarItem) -> some View {
        let face = Group {
            switch item.glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 14, weight: .semibold))
            case .badge(let text):
                Text(text)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
            }
        }
        .foregroundColor(item.isActive ? AppColors.hoverInk : AppColors.ink)
        .opacity(item.isDisabled ? 0.35 : 1)
        // maxWidth .infinity is what makes every cell the same width and the
        // row full: the cells divide whatever the panel gives them, so there
        // is nothing left over at either end.
        .frame(maxWidth: .infinity)
        .frame(height: Self.headerCellHeight)
        .background(item.isActive ? AppColors.panelAlt : Color.clear)
        // Load-bearing, not decoration: without it only the glyph itself is
        // hit-testable and the space around it is dead — the same omission was
        // a real bug on the Crop/Rotate and aspect-ratio buttons (a50776f).
        .contentShape(Rectangle())

        return Group {
            switch item.behaviour {
            case .tap(let action):
                Button(action: action) {
                    face
                }
                .buttonStyle(.plain)
                .disabled(item.isDisabled)

            case .holdForOriginal:
                face
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in showOriginal = true }
                            .onEnded { _ in showOriginal = false }
                    )

            case .presets:
                Button {
                    showPresetsPopover.toggle()
                } label: {
                    face
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPresetsPopover, arrowEdge: .bottom) {
                    presetsPopover
                }
            }
        }
        // ⚠️ NO .help() here, and that is a decision, not an omission. KORAK 117
        // put one on this control after finding the old one could never fire;
        // the client then saw the caption under the bar and said the white
        // hover card need not say it a second time: *„nemora da pise opet kao
        // hovered kartica ona bela moze da pise ispod samo"*. Two labels for
        // one button, one of them a second late, is worse than the one that is
        // already there.
        .onHover { inside in
            if inside {
                hoveredHeaderItemID = item.id
            } else if hoveredHeaderItemID == item.id {
                hoveredHeaderItemID = nil
            }
        }
    }

    /// What the pointer is over, said in words directly under the bar.
    ///
    /// The system tooltip is still attached and still correct, but it waits
    /// about a second and it is easy to miss — and once the labels came off the
    /// buttons, "what is this one?" cannot depend on a delay. This answers
    /// instantly and cannot fail to appear.
    ///
    /// ⚠️ Fixed height, and a space when nothing is hovered. Letting the line
    /// come and go would move every section under it up and down as the pointer
    /// crosses the bar.
    private var headerHoverCaption: some View {
        let hovered = headerBarItems.first { $0.id == hoveredHeaderItemID }

        return Text(hovered?.help ?? " ")
            .font(.custom("Figtree", size: 10.5).weight(.medium))
            .foregroundColor(AppColors.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 13)
    }

    private var panelHeaderActionBar: some View {
        let items = headerBarItems
        let columns = Self.headerBarColumns(for: CGFloat(effectivePanelWidth),
                                            count: items.count)
        let rows: [[HeaderBarItem]] = stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }

        // Hairlines rather than spacing. A gap between cells is exactly what
        // was asked to go, but a bar with no seam at all reads as one wide
        // button, so the seam is a single pixel and the cells still touch.
        return VStack(alignment: .leading, spacing: 5) {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 {
                    Rectangle()
                        .fill(AppColors.border.opacity(0.5))
                        .frame(height: 1)
                }

                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { cellIndex, item in
                        if cellIndex > 0 {
                            Rectangle()
                                .fill(AppColors.border.opacity(0.5))
                                .frame(width: 1, height: Self.headerCellHeight)
                        }

                        headerBarCell(item)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
        )

            headerHoverCaption
        }
    }

    /// The Presets section, in a popover instead of a permanent block in the
    /// panel. It opens from any tab this way, which the old section could not
    /// do — it lived inside Edit.
    private var presetsPopover: some View {
        ScrollView {
            presetsSection
                .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
        .background(AppColors.panel)
    }

    // Opens and closes the AI Manipulation block above the tabs.
    //
    // ⚠️ That block used to be a titled disclosure line sitting there whether
    // or not anyone wanted it. It is gone from the panel now and appears only
    // while this is on — asked for in exactly those terms: *„ai manipulation
    // nestaje dole jer kad kliknem AI onda otvara ai manipulation deo"*.
    //
    // The letters "AI" rather than a glyph, framed to a fixed width — the same
    // badge the Clean Up button inside the block uses, so the way in and the
    // thing it opens carry the same mark. There is no SF Symbol that says AI,
    // and a wand would say the same thing as the two Clean Up buttons it sits
    // above (see KORAK 28).
    /// What the AI Clean Up button does, so the KEY and the BUTTON cannot
    /// drift apart. Both call this; neither owns the behaviour.
    private func toggleAICleanUp() {
        withAnimation(.easeInOut(duration: 0.18)) {
            if isAIManipulationVisible {
                aiManipulationExpanded = false
                if isRemoveBrushActive {
                    toggleRemoveBrush()
                }
            } else {
                aiManipulationExpanded = true
                if !isRemoveBrushActive {
                    toggleRemoveBrush()
                }
            }
        }
    }

    /// Folds AI Clean Up away, whether or not it is open. `toggleAICleanUp()`
    /// cannot be used for this — called while the block is already shut it
    /// OPENS it, and puts the brush in the client's hand on the way.
    ///
    /// This exists because another tool taking over the canvas has to be able
    /// to say so. While the AI brush is live the tool overlay chain picks
    /// `removalPaintOverlay` first, so a layer's frame, handles and rotate
    /// knob are simply not drawn — reported as Select People finishing and
    /// *„ne pokazuje mi da je people selected, dok ja ne kliknem na close ai
    /// clean up"*. The layer was selected all along; it just had nothing on
    /// screen to say so.
    ///
    /// ⚠️ The painted AREA survives this, deliberately — see
    /// `deactivateRemoveBrush`. Only the brush is put down, so clean-up work
    /// already on the photo is not thrown away by pressing another tool.
    /// ⚠️ This is now THE call for "another tool is taking over", and every
    /// such place uses it instead of `deactivateRemoveBrush()` alone.
    ///
    /// Those places used to put the brush down and leave the block UNFOLDED,
    /// which is the state the client reported: *„neki put ai cleaner je otvoren
    /// jer sam kliknuo na crop pa ja trebam da ga zatvorim pa otvorim opet da
    /// bi dobio paint brush"*. An open AI Clean Up with no brush in hand reads
    /// as broken, and the only way out was to close it and open it again —
    /// pressing the same button twice to get back where you already looked to
    /// be.
    ///
    /// The brush goes down FIRST and unconditionally, outside the visibility
    /// guard: the two can come apart, and a brush still owning the canvas
    /// while the block is folded away would be the same bug with nothing on
    /// screen to explain it.
    private func closeAICleanUp() {
        deactivateRemoveBrush()
        guard isAIManipulationVisible else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            aiManipulationExpanded = false
        }
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
                        // .clipped() clips DRAWING, not hit testing. Zoomed in,
                        // `fitted` is far taller than the preview — measured at
                        // 2x on a 498pt container: fitted=(197,-238 727x974), so
                        // the picture's hit region ran 238pt ABOVE the preview,
                        // straight over the tool strip. centerPreview is the last
                        // child of the VStack, so it sits on top of that strip in
                        // z-order and quietly ate every click on AI Selection,
                        // Quick Clean Up and AI Clean Up — the buttons stayed
                        // enabled and looked normal, which is why this read as
                        // "the button does nothing when zoomed".
                        //
                        // Measured, not reasoned: with zoom at 1.95 a synthetic
                        // click on Quick Clean Up produced NO tap; the identical
                        // click at zoom 1.0 produced one, with the button
                        // reporting ENABLED in both cases.
                        //
                        // allowsHitTesting(false) rather than a container-level
                        // clip: the picture is display-only (every gesture lives
                        // in the overlays above it), and clipping the container
                        // would shave the crop tool's corner handles, which is
                        // exactly why the clip was put on the image alone.
                        .allowsHitTesting(false)

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
                        // Crop stays OUTSIDE the containment below on purpose:
                        // its corner handles sit right on the image edge and
                        // have to be grabbable a few points beyond it.
                        cropOverlay(frame: fitted, containerSize: proxy.size)
                    } else {
                        // Every tool overlay draws against the FULL pre-crop
                        // image frame, which zoomed in is far larger than the
                        // preview — measured at 2x: container 1121x502 against
                        // full=(-268,-262 1573x1048). Their hit areas
                        // (patchBrushOverlay, patchCanvasClickArea,
                        // patchFreeDrawOverlay, selectionFreeDrawOverlay,
                        // brushPaintOverlay, brushMaskCanvas) are sized to that
                        // frame, so unbounded they reach hundreds of points
                        // above the preview and sit over the tool strip, eating
                        // clicks on buttons that are enabled and look fine.
                        //
                        // That is the same defect the preview Image had, proved
                        // by measurement there; contentShape after the frame is
                        // what bounds interaction, since .clipped() bounds only
                        // drawing.
                        Group {
                            if isRemoveBrushActive {
                                removalPaintOverlay(frame: fullImageFrame(from: fitted), imageFrame: fitted, containerSize: proxy.size)
                            } else if let index = selectedAdjustmentIndex {
                                localAdjustmentOverlay(settings.localAdjustments[index], frame: fullImageFrame(from: fitted))
                            } else if let activeSelection {
                                selectionOverlay(activeSelection, frame: fullImageFrame(from: fitted))
                            // Pixel layers get the full frame — outline,
                            // corner handles, rotate knob — because they can
                            // be moved, resized and turned.
                            //
                            // A derived layer gets an outline and NOTHING to
                            // grab: it is a matte over the photo, and moving a
                            // matte moves a hole, not what is under it. It
                            // still has to LOOK selected, which is what
                            // derivedLayerOutlineOverlay is for.
                            } else if let index = selectedLayerIndex, !settings.layers[index].isDerived {
                                layerOverlay(settings.layers[index], frame: fullImageFrame(from: fitted))
                            } else if let index = selectedLayerIndex {
                                derivedLayerOutlineOverlay(settings.layers[index], frame: fullImageFrame(from: fitted))
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .clipped()
                    }

                    // Space-to-pan, deliberately AFTER every tool overlay
                    // above: a ZStack hands the drag to the LAST view that
                    // claims it, so a layer placed before them would be
                    // shadowed by the brush/crop/mask the moment one is
                    // active — which is the only time this is needed.
                    if isSpaceHeld, zoomLevel > 1 {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .onHover { inside in
                                if inside {
                                    NSCursor.openHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let start = panStart ?? panOffset
                                        panStart = start
                                        let limitX = max((fitted.width - proxy.size.width) / 2, 0)
                                        let limitY = max((fitted.height - proxy.size.height) / 2, 0)
                                        panOffset = CGSize(
                                            width: min(max(start.width + value.translation.width, -limitX), limitX),
                                            height: min(max(start.height + value.translation.height, -limitY), limitY))
                                    }
                                    .onEnded { _ in panStart = nil }
                            )
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
                        // Clipped to the photo rather than to the preview, for
                        // the reason spelled out on removalPaintOverlay's own
                        // clip: this mask is drawn against the full pre-crop
                        // frame, so under a crop it genuinely covers area that
                        // is off the picture, and the preview's letterbox
                        // margin is not part of the picture either.
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipShape(PreviewClipShape(
                            rect: fitted.intersection(CGRect(origin: .zero, size: proxy.size))))
                        .allowsHitTesting(false)
                    }
                } else if isLoadingPreview || selectedURL != nil {
                    // A photo IS chosen and its picture is not on screen yet,
                    // so it is still on its way — say that, rather than the
                    // "nothing is selected" text.
                    //
                    // isLoadingPreview goes false when the DECODE lands, which
                    // is not when the picture appears: the first render still
                    // has to run. On a flattened photo that gap used to be
                    // seconds long, and what filled it was an empty panel
                    // telling the client to select a photo they had already
                    // selected — reported as "I lose the image, it will not
                    // show it to me". The gap itself is fixed elsewhere in this
                    // file; this makes sure the window never lies about it
                    // again, whatever the cause.
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
        // Belt to the tool cursors' braces, for the scroll-to-resize monitor.
        //
        // The per-tool hover positions cover the brush, the patch and the Clean
        // Up brush, because those three draw a ring that has to follow the
        // mouse. A radial mask and the Selection tool have a size but no ring,
        // so they track nothing — and without this they would be the two tools
        // where scrolling quietly did nothing.
        //
        // On the container rather than per tool: one place, every tool,
        // including any added later.
        .onContinuousHover { phase in
            switch phase {
            case .active: isHoveringPreview = true
            case .ended: isHoveringPreview = false
            }
        }
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
        // Nothing to pan at fit, and the monitor stops updating isSpaceHeld
        // below 1x — so without this a Space held across a Cmd+0 would stay
        // latched on and swallow drags once zoomed back in.
        isSpaceHeld = false
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
        // Edge handles, so the crop can be pulled in from one side without
        // touching the other three — dragging a corner always moves two
        // edges at once, which is the wrong tool for "just take a bit off
        // the bottom".
        case top, bottom, left, right

        var isCorner: Bool {
            self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight
        }

        // Which edges of the crop this handle drags. A corner moves two of
        // them; an edge handle moves one, and the perpendicular axis is
        // either left alone (Free) or follows from the locked ratio.
        var movesLeftEdge: Bool { self == .topLeft || self == .bottomLeft || self == .left }
        var movesRightEdge: Bool { self == .topRight || self == .bottomRight || self == .right }
        var movesTopEdge: Bool { self == .topLeft || self == .topRight || self == .top }
        var movesBottomEdge: Bool { self == .bottomLeft || self == .bottomRight || self == .bottom }
        var isEdge: Bool { self == .top || self == .bottom || self == .left || self == .right }
    }

    /// The rotate cursor.
    ///
    /// macOS ships no rotate cursor, so this is drawn: an SF Symbol arrow in
    /// white over a black outline. The outline is what makes it usable — this
    /// cursor lives ON the photograph, and a plain white glyph disappears over
    /// sand or sky exactly the way the clone-stamp ring did before it was given
    /// its own hue (see patchSourceColor).
    ///
    /// Built once and held: NSCursor(image:) rasterises, and doing that on
    /// every hover would be per-frame work for a picture that never changes.
    /// The white curved double-headed arrow that means "drag here to turn the
    /// crop frame" — an arc with an arrowhead at each end, asked for in exactly
    /// those words: *„bela kriva sa strelicama na point a i b"*.
    ///
    /// Hand-drawn, like OpenFolderShape and CreateMark elsewhere in this
    /// app, because SF Symbols has no double-headed arc on any macOS version.
    ///
    /// ⚠️ PURE WHITE, no outline, by request. It is therefore faint over a
    /// bright sky — that is the trade the client chose when they asked for it
    /// half the size and without the black.
    ///
    /// Drawn into an explicit 2× bitmap rather than through `lockFocus`, since
    /// at 14pt a 1× cursor is visibly ragged on a Retina display.
    private static func makeRotateCursorImage(rotatedBy screenDegrees: CGFloat) -> NSImage {
        let side: CGFloat = 14
        let pixelScale: CGFloat = 2
        let centre = NSPoint(x: side / 2, y: side / 2)
        let radius: CGFloat = 4.25
        // A shallow arc. Wide enough to read as an arc rather than a hook,
        // short enough that the two heads are clearly two ends of one stroke.
        //
        // ⚠️ AppKit draws with y UP, so 90° here is the top of the picture and
        // this is a TOP arc — which is the pose for a pointer ABOVE the crop's
        // centre, exactly as the client described it: *„strelice na dole… to
        // treba da bude kad je cursor na gornjem delu slike"*. Turning the
        // glyph CLOCKWISE on screen therefore means SUBTRACTING here.
        let startDegrees: CGFloat = 20 - screenDegrees
        let endDegrees: CGFloat = 160 - screenDegrees

        func point(atDegrees degrees: CGFloat, distance: CGFloat) -> NSPoint {
            let radians = degrees * .pi / 180
            return NSPoint(x: centre.x + cos(radians) * distance,
                           y: centre.y + sin(radians) * distance)
        }

        // An arrowhead sitting ON the arc, pointing along the tangent — away
        // from the arc's middle, so the two heads point in opposite directions
        // and the whole thing says "either way".
        func head(atDegrees degrees: CGFloat, clockwise: Bool) -> NSBezierPath {
            let radians = degrees * .pi / 180
            let onArc = point(atDegrees: degrees, distance: radius)
            let tangent = radians + (clockwise ? -.pi / 2 : .pi / 2)
            let normal = tangent + .pi / 2

            let path = NSBezierPath()
            path.move(to: NSPoint(x: onArc.x + cos(tangent) * 3, y: onArc.y + sin(tangent) * 3))
            path.line(to: NSPoint(x: onArc.x + cos(normal) * 1.9, y: onArc.y + sin(normal) * 1.9))
            path.line(to: NSPoint(x: onArc.x - cos(normal) * 1.9, y: onArc.y - sin(normal) * 1.9))
            path.close()
            return path
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side * pixelScale), pixelsHigh: Int(side * pixelScale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        NSColor.white.setStroke()
        NSColor.white.setFill()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius,
                      startAngle: startDegrees, endAngle: endDegrees)
        arc.lineWidth = 1.2
        arc.lineCapStyle = .round
        arc.stroke()

        head(atDegrees: startDegrees, clockwise: true).fill()
        head(atDegrees: endDegrees, clockwise: false).fill()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// One cursor per 15° of turn, built once and held.
    ///
    /// The glyph follows the pointer AROUND the crop's centre — arrowheads down
    /// when the pointer is above it, up when it is below, tilted at the corners
    /// — because that is what a rotation handle is: a tangent to the circle the
    /// drag will travel along. Asked for in those terms: *„kada je kursor dole
    /// onda strelice da pokazuju na gore… za svaki ćošak strelice da budu
    /// nagnute"*.
    ///
    /// 24 pictures rather than one drawn per mouse-move: `NSCursor(image:)`
    /// rasterises, and this cursor is set on EVERY move (see cropCursor), so
    /// drawing per move would be a rasterised image per frame. 15° is finer
    /// than the eye reads on a 14pt glyph.
    private static let rotateCursorSteps = 24

    private static let rotateCursors: [NSCursor] = (0..<rotateCursorSteps).map { step in
        let degrees = CGFloat(step) * (360 / CGFloat(rotateCursorSteps))
        let image = makeRotateCursorImage(rotatedBy: degrees)
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2,
                                                      y: image.size.height / 2))
    }

    /// The rotate cursor turned to match where `point` sits around `centre`.
    private static func rotateCursor(at point: CGPoint, around centre: CGPoint) -> NSCursor {
        // Screen angle from the centre to the pointer: 0 is to the right, 90 is
        // DOWN (screen y grows downward). +90 puts the zero of the glyph's own
        // turn where the pointer is directly ABOVE the centre, which is the
        // pose makeRotateCursorImage draws at 0.
        let screenDegrees = atan2(point.y - centre.y, point.x - centre.x) * 180 / .pi + 90
        let stepSize = 360 / Double(rotateCursorSteps)
        var step = Int((screenDegrees / stepSize).rounded()) % rotateCursorSteps
        if step < 0 { step += rotateCursorSteps }
        return rotateCursors[step]
    }

    /// Draws a cursor from an SF Symbol: white glyph, black outline, centred
    /// hot spot. Built once by each caller and held — NSCursor(image:)
    /// rasterises, and doing that per hover would be per-frame work for a
    /// picture that never changes.
    private static func makeSymbolCursor(_ symbolName: String) -> NSCursor {
        let side: CGFloat = 26
        let canvas = NSImage(size: NSSize(width: side, height: side))
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        canvas.lockFocus()
        if let symbol {
            let size = symbol.size
            let origin = NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
            let box = NSRect(origin: origin, size: size)

            // Outline first: the same glyph drawn at eight offsets in black,
            // which is cheaper and sharper than a shadow and does not bleed.
            NSColor.black.set()
            for dx in [-1.0, 0.0, 1.0] as [CGFloat] {
                for dy in [-1.0, 0.0, 1.0] as [CGFloat] where !(dx == 0 && dy == 0) {
                    symbol.draw(in: box.offsetBy(dx: dx, dy: dy),
                                from: .zero, operation: .sourceOver, fraction: 1,
                                respectFlipped: true,
                                hints: [.interpolation: NSImageInterpolation.high.rawValue])
                }
            }
            symbol.isTemplate = true
            NSColor.white.set()
            symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        canvas.unlockFocus()

        return NSCursor(image: canvas, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    /// The crop frame itself — the upright box `rect`, turned `degrees` about
    /// its own centre. One place builds this outline; the darkening, the drawn
    /// border and the move area all take it from here, so they cannot drift
    /// apart into three rectangles that nearly agree.
    private static func cropFramePath(_ rect: CGRect, degrees: Double) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // Screen Y grows DOWNWARD, so this matrix turns clockwise for a
        // positive angle — the same direction `EditCropRect.angle` is
        // documented to mean, and the same one the renderer undoes.
        let radians = degrees * .pi / 180
        let c = cos(radians)
        let sn = sin(radians)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].map { p -> CGPoint in
            let dx = p.x - centre.x
            let dy = p.y - centre.y
            return CGPoint(x: centre.x + dx * c - dy * sn,
                           y: centre.y + dx * sn + dy * c)
        }

        path.move(to: corners[0])
        path.addLine(to: corners[1])
        path.addLine(to: corners[2])
        path.addLine(to: corners[3])
        path.closeSubpath()
        return path
    }

    /// A point of the crop frame's own space (origin at the frame's centre,
    /// axes along the frame's own sides) placed into container space.
    private static func cropFramePoint(_ offset: CGPoint, centre: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let c = cos(radians)
        let sn = sin(radians)
        return CGPoint(x: centre.x + offset.x * c - offset.y * sn,
                       y: centre.y + offset.x * sn + offset.y * c)
    }

    /// A drag measured on SCREEN, expressed along the crop frame's own two
    /// sides. The inverse of `cropFramePoint`'s rotation.
    ///
    /// Every crop gesture is read in container coordinates and converted here,
    /// rather than letting SwiftUI hand back already-rotated numbers from
    /// inside a `.rotationEffect`. The conversion is then written down and
    /// checkable, instead of resting on an assumption about what a gesture
    /// reports underneath a transform.
    private static func cropFrameTranslation(_ translation: CGSize, degrees: Double) -> CGSize {
        let radians = degrees * .pi / 180
        let c = cos(radians)
        let sn = sin(radians)
        return CGSize(width: translation.width * c + translation.height * sn,
                      height: -translation.width * sn + translation.height * c)
    }

    /// Everything OUTSIDE the crop frame, as one even-odd shape — the rotation
    /// zone.
    ///
    /// It was a 24pt band hugging the edges for one round, and that was wrong
    /// twice over. It was hard to find, and worse, it fought the corner
    /// handles for the same few points: *„kada dođem mišem na ćošak tačku, on
    /// mi pokaže ruku i krene rotacija, pa onda opet pokušavam da smanjim crop,
    /// opet rotacija"*.
    ///
    /// The rule is now the simple one the client stated: **on a handle, only
    /// resize; anywhere outside the crop, rotate.** There is nothing else out
    /// there to compete with — outside the frame is the darkened area — and the
    /// eight handles are declared AFTER this in the ZStack, so they keep their
    /// own points outright.
    private struct CropOutsideShape: Shape {
        let frame: CGRect
        let degrees: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addRect(rect)
            path.addPath(DevelopView.cropFramePath(frame, degrees: degrees))
            return path
        }
    }

    private func cropOverlay(frame: CGRect, containerSize: CGSize) -> some View {
        // The UNROTATED box, in container coordinates. The angle is applied on
        // top of it by cropFramePath — the stored rectangle stays the upright
        // box everywhere, and only the drawing and the hit areas are turned.
        let rect = CGRect(
            x: frame.minX + pendingCrop.x * frame.width,
            y: frame.minY + pendingCrop.y * frame.height,
            width: pendingCrop.width * frame.width,
            height: pendingCrop.height * frame.height
        )
        let angle = pendingCrop.angle
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let framePath = Self.cropFramePath(rect, degrees: angle)

        return ZStack {
            // Even-odd fill of [full canvas, crop frame] darkens everything
            // outside the crop while leaving the frame itself clear. Takes the
            // TURNED outline, so the clear area is the frame that is actually
            // on screen rather than the upright box behind it.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: containerSize))
                path.addPath(framePath)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Rotation: everywhere outside the crop — see CropOutsideShape.
            //
            // Declared BEFORE the move area and the handles: a ZStack gives a
            // gesture to the last view that claims it, so those two win where
            // they overlap.
            Color.clear
                .contentShape(CropOutsideShape(frame: rect, degrees: angle), eoFill: true)
                .gesture(
                    // Named space, not local: this view is the whole container,
                    // and the angle is measured from the frame's centre to the
                    // pointer — both of which have to be in the same
                    // coordinates as `rect`.
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.cropOverlaySpace))
                        .onChanged { value in
                            rotateCropFrame(to: value.location, around: centre)
                        }
                        .onEnded { _ in
                            rotateDragStartAngle = nil
                            rotateDragStartCrop = nil
                        }
                )

            // The frame's own area: the drawn border, and the drag that picks
            // the whole frame up and moves it.
            Color.clear
                .contentShape(framePath)
                .gesture(
                    // Container space, like every other crop gesture here, so
                    // the translation arrives in SCREEN terms and the code that
                    // needs it along the frame's own sides converts it once,
                    // in the open — see cropFrameTranslation.
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.cropOverlaySpace))
                        .onChanged { value in
                            moveCrop(by: value.translation, frame: frame)
                        }
                        .onEnded { _ in
                            dragStartCrop = nil
                        }
                )

            framePath
                .stroke(Color.white, lineWidth: 1.0)
                .allowsHitTesting(false)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                cropHandleView(handle, rect: rect, angle: angle, centre: centre, frame: frame)
            }
        }
        .coordinateSpace(name: Self.cropOverlaySpace)
        // ⚠️ ONE place decides the cursor for the whole crop tool, and it SETS
        // rather than pushes.
        //
        // Every layer here used to push its own on `.onHover(true)` and pop on
        // `.onHover(false)`. Four overlapping layers — outside, the frame, the
        // handles, and the tool overlays underneath — means pushes and pops
        // interleave in an order nobody controls: cross from a handle straight
        // onto the outside area and the pop for the handle can arrive AFTER the
        // push for the outside, leaving the stack holding the wrong picture.
        // That is why the rotate cursor never appeared even once the zone
        // underneath it was correct and its gesture worked: *„nema ikonica kada
        // je cursor na mestu za rotaciju"*. The push/pop hazard is written down
        // twice elsewhere in this file; this is what it looks like when it
        // actually happens.
        //
        // `.set()` on every mouse-move is the fix, not a workaround: AppKit
        // resets the cursor from its own tracking areas as the pointer moves,
        // and setting it again on each move is how a view holds one. There is
        // no stack left to unbalance.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                cropCursor(at: point, rect: rect, angle: angle).set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }

    /// Which cursor belongs at `point`, in the crop overlay's own coordinates.
    ///
    /// The order is the same order the ZStack gives its gestures away in, and
    /// it has to be: a cursor that disagrees with what a press will do is worse
    /// than no cursor at all — that disagreement is exactly what made the
    /// corner unusable two rounds ago.
    private func cropCursor(at point: CGPoint, rect: CGRect, angle: Double) -> NSCursor {
        // A drag in progress keeps its own cursor wherever the pointer wanders.
        // Turning the frame swings the pointer well outside the handle it
        // started on, and a cursor that changed halfway through would read as
        // the tool having let go.
        if rotateDragStartAngle != nil {
            return Self.rotateCursor(at: point, around: CGPoint(x: rect.midX, y: rect.midY))
        }
        if dragStartCrop != nil {
            return .closedHand
        }

        // Handles first, and with the SAME reach their hit areas have — 30pt
        // for a corner, 24 for an edge bar, so the picture and the press agree
        // to the point.
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        for handle in CropHandle.allCases {
            let position = Self.cropHandlePosition(handle, rect: rect, centre: centre, degrees: angle)
            let reach: CGFloat = handle.isCorner ? 15 : 12
            if abs(point.x - position.x) <= reach + 4, abs(point.y - position.y) <= reach + 4 {
                return .openHand
            }
        }

        if Self.cropFramePath(rect, degrees: angle).contains(point) {
            return .openHand
        }

        return Self.rotateCursor(at: point, around: centre)
    }

    /// Where a handle sits, in the overlay's coordinates. Shared by the handle
    /// views and by the cursor above, so the two cannot drift apart.
    private static func cropHandlePosition(_ handle: CropHandle, rect: CGRect, centre: CGPoint, degrees: Double) -> CGPoint {
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let offset: CGPoint
        switch handle {
        case .topLeft: offset = CGPoint(x: -halfWidth, y: -halfHeight)
        case .topRight: offset = CGPoint(x: halfWidth, y: -halfHeight)
        case .bottomLeft: offset = CGPoint(x: -halfWidth, y: halfHeight)
        case .bottomRight: offset = CGPoint(x: halfWidth, y: halfHeight)
        case .top: offset = CGPoint(x: 0, y: -halfHeight)
        case .bottom: offset = CGPoint(x: 0, y: halfHeight)
        case .left: offset = CGPoint(x: -halfWidth, y: 0)
        case .right: offset = CGPoint(x: halfWidth, y: 0)
        }
        return cropFramePoint(offset, centre: centre, degrees: degrees)
    }

    private static let cropOverlaySpace = "develop.cropOverlay"

    /// Turns the crop FRAME, by dragging the band along its edges.
    ///
    /// Measures the ANGLE from the frame's centre to the pointer and moves the
    /// frame by however much that angle has turned since the drag began — so
    /// the frame follows the hand rather than following how far the hand
    /// moved, which is what makes a rotation drag feel like a rotation and not
    /// like a slider.
    ///
    /// ⚠️ This turns the RECTANGLE, not the photograph. It was built the other
    /// way round in KORAK 77 and reported as wrong: *„da mogu da rotiram krop
    /// (ne sliku)"*. The Straighten slider still turns the photograph, and the
    /// two are independent on purpose — see EditCropRect.angle.
    private func rotateCropFrame(to location: CGPoint, around centre: CGPoint) {
        let dx = location.x - centre.x
        let dy = location.y - centre.y
        // Too close to the centre and the angle is noise — a pixel of movement
        // swings it through ninety degrees.
        guard dx * dx + dy * dy > 400 else { return }

        let angle = atan2(dy, dx) * 180 / .pi

        // The whole crop is remembered at the start of the drag, not just the
        // angle it had. Turning a frame can force it to shrink to stay on the
        // photograph, and recomputing every frame FROM THE START means turning
        // out and back returns the frame to the size it was. Keeping only the
        // angle would ratchet it smaller each way the hand moved.
        guard let startAngle = rotateDragStartAngle,
              let startCrop = rotateDragStartCrop else {
            rotateDragStartAngle = angle
            rotateDragStartCrop = pendingCrop
            return
        }

        // Normalised into -180...180 so a drag across the ±180 seam does not
        // snap the frame through half a turn.
        var delta = angle - startAngle
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }

        var next = startCrop
        next.angle = min(max(startCrop.angle + delta, -45), 45)
        pendingCrop = constrainedToImage(next)
        // The client has taken the crop into their own hands, so a later
        // Straighten drag must not auto-fit over it — same reason commitCrop
        // clears this.
        cropIsAutoFitted = false
    }

    /// Keeps a crop frame — turned or not — inside the photograph.
    ///
    /// ⚠️ Works in a space PROPORTIONAL TO PIXELS (width `ratio`, height 1),
    /// never in fraction space. Fractions of width and fractions of height are
    /// different units, and a rotation that mixes the two axes is only
    /// meaningful once they share a scale. Everything below is homogeneous in
    /// (width, height), so any space proportional to pixels gives the same
    /// answer — which is why the aspect ratio alone is enough and the pixel
    /// dimensions are not needed.
    ///
    /// A turned rectangle lies inside an upright one exactly when its bounding
    /// box does, because the bounding box is made of its own extreme corners.
    /// So this is the containment test itself, not a conservative stand-in for
    /// one.
    ///
    /// At angle 0 it is the plain clamp that was here before: A and B collapse
    /// to the half-width and half-height, and a crop already inside comes back
    /// untouched.
    private func constrainedToImage(_ crop: EditCropRect) -> EditCropRect {
        guard let ratio = currentImagePixelRatio, ratio > 0 else {
            // No image measured yet — better to leave the numbers alone than
            // to clamp them against a shape that has not been established.
            return crop
        }

        let imageWidth = ratio
        let imageHeight = 1.0
        var halfWidth = crop.width * imageWidth / 2
        var halfHeight = crop.height * imageHeight / 2
        guard halfWidth > 0, halfHeight > 0 else { return crop }

        let radians = crop.angle * .pi / 180
        let c = abs(cos(radians))
        let sn = abs(sin(radians))

        var boundsHalfWidth = halfWidth * c + halfHeight * sn
        var boundsHalfHeight = halfWidth * sn + halfHeight * c
        guard boundsHalfWidth > 0, boundsHalfHeight > 0 else { return crop }

        // Too big to fit at this angle: shrink about the centre. BOTH sides by
        // the same factor, so a locked aspect ratio still holds exactly.
        if boundsHalfWidth > imageWidth / 2 || boundsHalfHeight > imageHeight / 2 {
            let scale = min(imageWidth / 2 / boundsHalfWidth, imageHeight / 2 / boundsHalfHeight)
            halfWidth *= scale
            halfHeight *= scale
            boundsHalfWidth *= scale
            boundsHalfHeight *= scale
        }

        var centreX = (crop.x + crop.width / 2) * imageWidth
        var centreY = (crop.y + crop.height / 2) * imageHeight
        centreX = min(max(centreX, boundsHalfWidth), imageWidth - boundsHalfWidth)
        centreY = min(max(centreY, boundsHalfHeight), imageHeight - boundsHalfHeight)

        var next = crop
        next.width = 2 * halfWidth / imageWidth
        next.height = 2 * halfHeight / imageHeight
        next.x = (centreX - halfWidth) / imageWidth
        next.y = (centreY - halfHeight) / imageHeight
        return next
    }

    private func cropHandleView(_ handle: CropHandle, rect: CGRect, angle: Double, centre: CGPoint, frame: CGRect) -> some View {
        // Placed in the frame's OWN space and turned into container space in
        // one step, so a handle sits on its corner at every angle without eight
        // separate pieces of trigonometry. Through the same helper the cursor
        // uses — see cropHandlePosition.
        let position = Self.cropHandlePosition(handle, rect: rect, centre: centre, degrees: angle)

        // Edge handles are bars lying ALONG their edge rather than dots:
        // the shape says which way it moves before it is touched, and a
        // dot at an edge midpoint reads as a corner of something else.
        let size: CGSize
        switch handle {
        case .top, .bottom: size = CGSize(width: 26, height: 7)
        case .left, .right: size = CGSize(width: 7, height: 26)
        default: size = CGSize(width: 12, height: 12)
        }

        // ⚠️ CENTRED ON THE HANDLE, and generously sized. Not offset inward,
        // which is what it was for one round and what produced the worst report
        // yet: the drawn dot sat on the corner while what actually caught the
        // pointer sat 11pt inside it, so aiming at the dot landed in the
        // rotation zone. Hover said hand, press said rotate — *„pa onda jedan
        // nekako ubodem da smanjim krop"*.
        //
        // 30pt for a corner (the dot is 12) so that anywhere on or immediately
        // around the dot resizes, which is the client's rule: on the corner,
        // ONLY narrowing and widening, never rotation. Being declared last in
        // the ZStack is what makes that hold — the rotation zone underneath
        // covers these same points and loses them.
        let hitWidth = max(size.width, handle.isCorner ? 30 : 24)
        let hitHeight = max(size.height, handle.isCorner ? 30 : 24)

        return Capsule()
            .fill(Color.white)
            .frame(width: size.width, height: size.height)
            .shadow(radius: 1)
            // Hit area larger than the drawn bar in both directions, so a
            // thin 7pt edge handle is still catchable without pixel-hunting.
            .frame(width: hitWidth, height: hitHeight)
            .contentShape(Rectangle())
            // The bar lies along its own edge, so it turns with the frame. The
            // hit area turns with it, which is the point — a bar drawn on a
            // tilted edge with an upright hit box is a handle that is caught
            // next to itself.
            .rotationEffect(.degrees(angle))
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.cropOverlaySpace))
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
        next.x = start.x + dx
        next.y = start.y + dy

        if next.angle == 0 {
            // Untouched from before the frame could turn: at zero this is the
            // whole constraint, and leaving it in place keeps the ordinary
            // case exactly as it was rather than routing it through new maths.
            next.x = min(max(0, next.x), 1 - next.width)
            next.y = min(max(0, next.y), 1 - next.height)
            pendingCrop = next
        } else {
            // A turned frame runs off the picture sooner than its upright box
            // does, so the limit is the turned frame's own bounding box.
            pendingCrop = constrainedToImage(next)
        }
    }

    // The image's own pixel width/height ratio (post-rotation) — needed to
    // convert a target width:height ratio (e.g. 4:3) into the right
    // width/height FRACTIONS for EditCropRect, since fraction space isn't
    // the same shape as pixel space unless the image itself is square.
    /// Which preset a crop that is ALREADY on the photo matches, if any.
    ///
    /// Needed because `settings.cropAspect` only tells you the ratio someone
    /// chose THROUGH THIS TOOL. A photo can arrive at a perfectly good 4:3 crop
    /// without that ever having happened: synced from another photo by a build
    /// that had nowhere to put the lock, cropped by an older version, or
    /// carried in on a preset. The client's report is exactly that case — "the
    /// photo IS cropped 4:3, but the row says Free, so dragging a handle goes
    /// free-form".
    ///
    /// So the rectangle is asked as well as the record. The rectangle is the
    /// thing the client can see, and it should be believed.
    ///
    /// Tolerance is 1%: the presets are far apart (0.75, 1, 1.33, 1.78) so
    /// nothing can be mistaken for its neighbour, while a crop that went
    /// through fraction space and a bounds clamp is allowed to be a hair off
    /// without being called free-form.
    private func inferredCropAspect(from crop: EditCropRect) -> CropAspectRatioOption {
        guard let imagePixelRatio = currentImagePixelRatio, imagePixelRatio > 0,
              crop.width > 0, crop.height > 0 else {
            return .free
        }
        // crop.width/height are fractions OF THE IMAGE, so the real ratio is
        // that shape times the image's own pixel ratio — the same conversion
        // resizeCrop does in the other direction.
        let actual = (crop.width / crop.height) * imagePixelRatio
        for option in CropAspectRatioOption.allCases {
            guard let ratio = option.ratio, ratio > 0 else { continue }
            if abs(actual - ratio) / ratio < 0.01 {
                return option
            }
        }
        return .free
    }

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

        // The drag arrives in SCREEN terms; a resize happens along the frame's
        // own two sides. At angle 0 this conversion is the identity, so the
        // free-form and ratio-locked maths below are reached with exactly the
        // numbers they were written against.
        let alongFrame = Self.cropFrameTranslation(translation, degrees: start.angle)
        let dx = alongFrame.width / frame.width
        let dy = alongFrame.height / frame.height
        let minSize = 0.05

        // What stays fixed while the handle moves, per axis. A corner pins
        // the opposite corner; an edge handle pins the opposite edge and,
        // on the axis it does NOT drag, keeps the crop centred where it was
        // (which only matters under a locked ratio, where that axis has to
        // move too — in Free it stays exactly as it was).
        let centreX = start.x + start.width / 2
        let centreY = start.y + start.height / 2

        // Raw, independent-axis proposed size — same math the old
        // free-form-only code used, just factored out so the ratio-lock
        // branch below can reconcile it before the final bounds clamp.
        var rawWidth = start.width
        var anchorX = start.x
        if handle.movesLeftEdge {
            rawWidth = start.width - dx
            anchorX = start.x + start.width
        } else if handle.movesRightEdge {
            rawWidth = start.width + dx
            anchorX = start.x
        }

        var rawHeight = start.height
        var anchorY = start.y
        if handle.movesTopEdge {
            rawHeight = start.height - dy
            anchorY = start.y + start.height
        } else if handle.movesBottomEdge {
            rawHeight = start.height + dy
            anchorY = start.y
        }

        rawWidth = max(rawWidth, minSize)
        rawHeight = max(rawHeight, minSize)

        // Room to grow before running off the image. On an axis the handle
        // doesn't drag, growth is symmetric about the centre, so the limit
        // is twice the smaller side — half of it goes each way.
        let maxWidthAllowed: Double
        if handle.movesLeftEdge {
            maxWidthAllowed = anchorX
        } else if handle.movesRightEdge {
            maxWidthAllowed = 1 - anchorX
        } else {
            maxWidthAllowed = 2 * min(centreX, 1 - centreX)
        }
        let maxHeightAllowed: Double
        if handle.movesTopEdge {
            maxHeightAllowed = anchorY
        } else if handle.movesBottomEdge {
            maxHeightAllowed = 1 - anchorY
        } else {
            maxHeightAllowed = 2 * min(centreY, 1 - centreY)
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
            //
            // An EDGE handle can't use that rule: only one axis was
            // actually dragged, and "take the larger box" would quietly
            // ignore the drag whenever it SHRANK the crop (the untouched
            // axis would always imply the bigger box). So the dragged axis
            // drives, and the other one follows from the ratio.
            var w: Double
            var h: Double
            if handle == .left || handle == .right {
                w = widthFromWidth
                h = heightFromWidth
            } else if handle == .top || handle == .bottom {
                w = widthFromHeight
                h = heightFromHeight
            } else if widthFromWidth >= widthFromHeight {
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

        // `angle: start.angle` and not the default — the memberwise initializer
        // would quietly put the frame back upright, which is a resize silently
        // undoing a rotation.
        var next = EditCropRect(x: 0, y: 0, width: finalWidth, height: finalHeight, angle: start.angle)
        if handle.movesLeftEdge {
            next.x = anchorX - finalWidth
        } else if handle.movesRightEdge {
            next.x = anchorX
        } else {
            // Centred: in Free this is a no-op (finalWidth == start.width,
            // so it lands back on start.x); under a locked ratio it is what
            // makes a top/bottom drag widen the crop evenly to both sides.
            next.x = centreX - finalWidth / 2
        }
        if handle.movesTopEdge {
            next.y = anchorY - finalHeight
        } else if handle.movesBottomEdge {
            next.y = anchorY
        } else {
            next.y = centreY - finalHeight / 2
        }
        // The centred branches above can still push a hair outside after
        // the minSize floor kicks in, so both origins get a final clamp —
        // the anchored branches are already inside by construction.
        next.x = min(max(next.x, 0), max(0, 1 - next.width))
        next.y = min(max(next.y, 0), max(0, 1 - next.height))

        if next.angle != 0 {
            next = anchoredAfterResize(handle, start: start, resized: next)
            next = constrainedToImage(next)
        }

        pendingCrop = next
    }

    /// Puts a resized frame back so that the side or corner the drag did NOT
    /// touch stays exactly where it is ON SCREEN.
    ///
    /// The block above anchors in the UNROTATED box, which is the same thing
    /// while the frame is upright. Once it is turned it is not: the frame
    /// rotates about its own centre, so changing the size moves the centre,
    /// and the corner that was supposed to be pinned swings away from the
    /// pointer. Reported as an easy thing to miss and an obvious thing to see.
    ///
    /// ⚠️ Only called when the frame is turned. At angle 0 this computes
    /// exactly what the block above already did, and running it there would be
    /// the same answer through more arithmetic — with a chance of differing in
    /// the last bits of a Double for no gain.
    private func anchoredAfterResize(_ handle: CropHandle, start: EditCropRect, resized: EditCropRect) -> EditCropRect {
        guard let ratio = currentImagePixelRatio, ratio > 0 else { return resized }

        let imageWidth = ratio
        let imageHeight = 1.0

        // Which point of the frame the drag leaves alone, as a sign per axis:
        // dragging the left edge pins the right one (+1), dragging the right
        // pins the left (-1), and an axis the handle does not touch keeps its
        // centre (0) — the same three cases the anchoring above has.
        let signX: Double = handle.movesLeftEdge ? 1 : (handle.movesRightEdge ? -1 : 0)
        let signY: Double = handle.movesTopEdge ? 1 : (handle.movesBottomEdge ? -1 : 0)

        let startCentre = CGPoint(x: (start.x + start.width / 2) * imageWidth,
                                  y: (start.y + start.height / 2) * imageHeight)
        let startOffset = CGPoint(x: signX * start.width * imageWidth / 2,
                                  y: signY * start.height * imageHeight / 2)
        let resizedOffset = CGPoint(x: signX * resized.width * imageWidth / 2,
                                    y: signY * resized.height * imageHeight / 2)

        // Where the pinned point is on screen, and where the new centre has to
        // go for the pinned point to land back on it.
        let pinned = Self.cropFramePoint(startOffset, centre: startCentre, degrees: resized.angle)
        let turnedBack = Self.cropFramePoint(resizedOffset, centre: .zero, degrees: resized.angle)
        let centre = CGPoint(x: pinned.x - turnedBack.x, y: pinned.y - turnedBack.y)

        var next = resized
        next.x = (centre.x - resized.width * imageWidth / 2) / imageWidth
        next.y = (centre.y - resized.height * imageHeight / 2) / imageHeight
        return next
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
        // Floor of 1, not 2: the brush now goes down to 0.001 and a ring
        // clamped at 2pt would stop shrinking well before the brush does,
        // showing the client a size that is not the size they set.
        let brushDiameter = max(patchBrushSize * max(frame.width, frame.height), 1)

        return ZStack {
            // Always mounted, drawing nothing when there is nothing to draw.
            // Every branch that used to live here read @State and so ran in
            // DevelopView's own body on each hover and drag event.
            PatchStampLayer(
                cursor: patchCursor, frame: frame, diameter: brushDiameter,
                color: accentColor, sourceOffset: patchStrokeOffset,
                sourceColor: patchSourceColor)

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if NSEvent.modifierFlags.contains(.option) {
                            patchCursor.sourceHover = location
                            patchCursor.brushHover = nil
                        } else {
                            patchCursor.brushHover = location
                            patchCursor.sourceHover = nil
                        }
                    case .ended:
                        patchCursor.sourceHover = nil
                        patchCursor.brushHover = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Nothing painted yet in THIS gesture and ⌥ is
                            // held: this drag is setting the source, not
                            // painting — just track the preview ring,
                            // don't touch patchCursor.stroke. Once a
                            // point HAS been recorded, ⌥ being pressed
                            // transiently mid-stroke can never flip modes
                            // (a real clone stamp never reinterprets an
                            // in-progress stroke either).
                            if patchCursor.stroke.isEmpty && NSEvent.modifierFlags.contains(.option) {
                                patchCursor.sourceHover = value.location
                                return
                            }
                            paintPatchStroke(at: value.location, frame: frame)
                        }
                        .onEnded { value in
                            if patchCursor.stroke.isEmpty {
                                if NSEvent.modifierFlags.contains(.option), let unit = unitPoint(from: value.location, frame: frame) {
                                    pendingPatchSource = unit
                                }
                                patchCursor.sourceHover = nil
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
            patchCanvasClickArea(frame: frame,
                                 sourceDiameter: max(geo.radiusX * 2 * frame.width, 2))

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
    // `sourceDiameter` is the patch's own on-screen width — the ring has to
    // say how much would be lifted, not just from where, and these two shapes
    // carry their size in the mask rather than in a brush setting.
    private func patchCanvasClickArea(frame: CGRect, sourceDiameter: CGFloat) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        patchCursor.sourceHover = NSEvent.modifierFlags.contains(.option) ? location : nil
                    case .ended:
                        patchCursor.sourceHover = nil
                    }
                }
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handlePatchCanvasTap(at: value.location, frame: frame)
                        }
                )

            // "Source will land here if you click now" preview — only
            // shown while ⌥ is actually held (patchCursor.sourceHover is
            // nil otherwise), a cheap ring rather than a live pixel
            // preview of the source content itself (which would mean
            // re-rendering a cropped thumbnail on every hover event —
            // too much for interactive hover, same tradeoff the brush
            // cursor preview already made).
            // Its own observing view rather than an `if let` here. Now that
            // the hover position lives on an object this body does NOT
            // observe, reading it here would show whatever it happened to
            // hold when the body last ran — a ring frozen where the mouse
            // used to be.
            PatchSourceRing(cursor: patchCursor, diameter: sourceDiameter,
                            color: patchSourceColor)
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
            patchCanvasClickArea(frame: frame,
                                 sourceDiameter: max(geo.radiusX * 2 * frame.width, 2))

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
        briefShowClosedPolygonPath(points)
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
            // Always mounted, and it draws the hint itself when there is
            // nothing yet: a condition here in the parent would put the
            // per-point invalidation straight back.
            ActiveOutlineLayer(
                outline: activePatchDrawPoints, frame: frame,
                color: accentColor, hint: "Drag to draw the patch outline")

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
        if let last = activePatchDrawPoints.points.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activePatchDrawPoints.points.append(unit)
    }

    // Requires at least 3 points (a real polygon, not a line/dot) to commit
    // — mirrors commitBrushStroke's `count > 1` guard, just a higher bar
    // since a 2-point "outline" wouldn't enclose any area for freeMask to
    // fill. The outline's own centroid becomes centerX/Y, so the move
    // handle and source marker both start from somewhere sensible on the
    // shape the user actually drew, not the (0.5, 0.5) default.
    private func commitPatchOutline() {
        defer { activePatchDrawPoints.points = [] }
        guard let index = selectedAdjustmentIndex, activePatchDrawPoints.points.count > 2 else {
            return
        }
        let count = Double(activePatchDrawPoints.points.count)
        let centroidX = activePatchDrawPoints.points.reduce(0) { $0 + $1.x } / count
        let centroidY = activePatchDrawPoints.points.reduce(0) { $0 + $1.y } / count
        settings.localAdjustments[index].patch?.points = activePatchDrawPoints.points
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
            // Always mounted, and it draws the hint itself when there is
            // nothing yet: a condition here in the parent would put the
            // per-point invalidation straight back.
            ActiveOutlineLayer(
                outline: activeSelectionDrawPoints, frame: frame,
                color: accentColor, hint: "Drag to draw the selection outline")

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
        if let last = activeSelectionDrawPoints.points.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activeSelectionDrawPoints.points.append(unit)
    }

    private func commitSelectionOutline() {
        defer { activeSelectionDrawPoints.points = [] }
        guard activeSelectionDrawPoints.points.count > 2 else {
            return
        }
        let count = Double(activeSelectionDrawPoints.points.count)
        let centroidX = activeSelectionDrawPoints.points.reduce(0) { $0 + $1.x } / count
        let centroidY = activeSelectionDrawPoints.points.reduce(0) { $0 + $1.y } / count
        activeSelection?.points = activeSelectionDrawPoints.points
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
    /// The selected layer's frame on the canvas: an outline, four corner
    /// handles, and a knob above it to turn it by.
    ///
    /// The outline and its handles are drawn INSIDE a container the size of
    /// the layer and rotated with it, so the frame sits on the picture
    /// rather than beside it. Two things follow from that and both are
    /// load-bearing:
    ///
    /// - The rotation anchor is the container's centre, which is the
    ///   layer's centre. Rotating the canvas-sized view instead would turn
    ///   the frame about the corner of the PHOTO and send it off screen.
    /// - The drag maths stays in unrotated space (see `unrotated`), because
    ///   pulling a corner means "wider along this edge", not "wider along
    ///   the screen".
    /// What a selected derived layer shows on the photograph.
    ///
    /// ⚠️ THE MATTE ITSELF, not a frame. Reported as *„kliknem na layer ali mi
    /// ne pokazuje da je selektovan na slici"* — and the reason there was
    /// nothing to see is a decision that is still right: an outline round a
    /// derived layer would be a rectangle round the whole picture, saying
    /// nothing about which part of it the layer is. What is actually needed is
    /// to see WHERE the region is, which is exactly what the matte is.
    ///
    /// Tinted rather than outlined because the matte has no outline worth
    /// drawing: its edge runs around every palm frond, and vectorising that to
    /// stroke it would cost more than showing the region does.
    ///
    /// The colour is deliberately unnatural: magenta cannot be mistaken for
    /// anything in the photograph.
    /// ⚠️ AN INDICATOR THAT SHOWS WHERE SOMETHING WAS FOUND MUST GET OUT OF
    /// THE WAY THE MOMENT THERE IS A RESULT TO LOOK AT. This wash was once
    /// left on top of a finished result and did real damage on sight — the
    /// picture came back a colour it was not. Written down here because the
    /// mistake is cheap to repeat: see SKY_ARCHIVE/BRIEFSHOW_SKY_NOTES.md §8.
    @ViewBuilder
    /// What a selected derived (Background) layer looks like on the photo.
    ///
    /// ⚠️ This used to be a MAGENTA WASH over the whole region, and it was
    /// reported for exactly the reason KORAK 93 already wrote down and this
    /// overlay then went on to repeat: *„kada kliknem na background ne treba da
    /// mi pokazuje paint mask over, samo selection kao za ljude"*. A Background
    /// layer's own sliders — Exposure, Black & White, Blur — change the very
    /// pixels the wash was covering, so the client was tinting a photograph he
    /// could no longer see. An indicator saying WHERE something is has to get
    /// out of the way the moment there is a result to look at.
    ///
    /// What is left says the same thing without painting over anything: the
    /// layer's frame, drawn like the pixel layer's frame so a selected layer
    /// looks selected either way, plus a thin outline along the matte's own
    /// edge so it is clear WHICH region this is.
    ///
    /// ⚠️ Deliberately WITHOUT corner handles and without the rotate knob.
    /// A derived layer is a region of the photo, not a piece sitting on it —
    /// it cannot be moved or resized (see ImageLayer.maskData, and the panel
    /// text that says so). Handles that do nothing when pulled would read as
    /// broken, which is worse than not offering them.
    private func derivedLayerOutlineOverlay(_ layer: ImageLayer, frame: CGRect) -> some View {
        ZStack {
            if let outline = layerOutlineImage(for: layer) {
                Image(nsImage: outline)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }

            // The layer's bounds. A derived layer covers the whole frame, so
            // this is the picture's own edge — which is the truth about how
            // far the layer reaches.
            Rectangle()
                .stroke(layerSelectionColor, lineWidth: 1.4)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
        .allowsHitTesting(false)
    }

    /// Its own small context, like PhotoEditRenderer's extraction one. Not the editor's heavy render
    /// context: this draws a flat tint a handful of times per session, and
    /// dragging a pipeline built for 45MP renders into that would be waste.
    /// ⚠️ Bare ON PURPOSE, unlike sharedExtractionContext next to the
    /// extraction path. Nothing here is a photograph: this builds a flat
    /// coloured line out of a matte, and it never lands in an export. Its
    /// numbers were measured through a context exactly like this one — see
    /// run-layer-outline-test.py, which uses the same bare context — so giving
    /// it colour-space options would change the measured line for no gain.
    private static let overlayContext = CIContext()

    /// The matte's EDGE, built once per layer and kept.
    ///
    /// Built here rather than in the render pipeline: this is a thing the
    /// client looks at while choosing, not part of the photograph, and it must
    /// never end up in an export.
    ///
    /// The edge comes from a morphology gradient — dilate minus erode — which
    /// on a grey matte leaves a bright band exactly on the boundary and black
    /// everywhere else. That band is then turned into alpha, so what gets
    /// drawn is a line round the region and NOTHING over its inside. The
    /// filled tint this replaced is described on the overlay above.
    private func layerOutlineImage(for layer: ImageLayer) -> NSImage? {
        if let cached = layerOutlineCache[layer.id] {
            return cached
        }
        guard let data = layer.maskData, let mask = CIImage(data: data) else {
            return nil
        }

        // Scaled to the stored matte, not fixed: maskPNG caps the mask at
        // 1024px, but a smaller photo stores a smaller one, and a band of a
        // fixed pixel width would be hairline on one and a stripe on another.
        let side = min(mask.extent.width, mask.extent.height)
        let radius = max(1.5, side * 0.0022)
        let band = mask.applyingFilter("CIMorphologyGradient", parameters: [
            kCIInputRadiusKey: radius
        ]).cropped(to: mask.extent)

        // Luminance to alpha: the band is bright on black, and SwiftUI draws
        // by ALPHA, not by brightness — without this the black would be
        // painted too and the wash would be back, in another colour.
        let alpha = band.applyingFilter("CIMaskToAlpha")

        // ⚠️ The alpha is multiplied UP, not set. Measured with
        // run-layer-outline-test.py before this factor existed: the strongest
        // pixel anywhere on the line came out at 0.451, not the 0.9 the matrix
        // asked for, because a hard edge lands BETWEEN pixels and each one on
        // the boundary only gets part of the band. A line at 45% over a
        // photograph is a line the client has to look for. Everything off the
        // boundary is a true zero (same harness: worst alpha inside and
        // outside the region both 0.000), so lifting the whole band cannot
        // bring back a wash — there is nothing there to lift.
        let tinted = alpha.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 2.4),
            "inputBiasVector": CIVector(x: 0.96, y: 0.96, z: 0.98, w: 0)
        ]).applyingFilter("CIColorClamp")

        let extent = tinted.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite,
              let cgImage = Self.overlayContext.createCGImage(tinted, from: extent) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: extent.width, height: extent.height))
        layerOutlineCache[layer.id] = image
        return image
    }

    private func layerOverlay(_ layer: ImageLayer, frame: CGRect) -> some View {
        let rect = CGRect(
            x: frame.minX + layer.x * frame.width,
            y: frame.minY + layer.y * frame.height,
            width: layer.width * frame.width,
            height: layer.height * frame.height
        )
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let angle = layer.rotationDegrees
        let stem: CGFloat = 26

        return ZStack {
            ZStack {
                Rectangle()
                    .stroke(layerSelectionColor, lineWidth: 1.4)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in moveLayer(by: value.translation, frame: frame) }
                            .onEnded { _ in endLayerDrag() }
                    )

                // The stem, drawn from the top edge up to the knob.
                Path { path in
                    path.move(to: CGPoint(x: rect.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: rect.width / 2, y: -stem))
                }
                .stroke(layerSelectionColor, lineWidth: 1.2)
                .allowsHitTesting(false)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppColors.background)
                    .padding(4)
                    .background(Circle().fill(layerSelectionColor))
                    .shadow(radius: 1)
                    .position(x: rect.width / 2, y: -stem)
                    .gesture(
                        // Named space, not the knob's own: the angle is
                        // measured from the layer's centre, and the knob
                        // is moving while it is measured.
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.layerCanvasSpace))
                            .onChanged { value in
                                rotateLayer(towards: value.location, centre: centre)
                            }
                            .onEnded { _ in endLayerDrag() }
                    )

                ForEach(LayerCorner.allCases, id: \.self) { corner in
                    layerHandleView(corner, size: rect.size, frame: frame, angle: angle)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(angle))
            .position(centre)
        }
        .coordinateSpace(name: Self.layerCanvasSpace)
    }

    private static let layerCanvasSpace = "briefshow.layerCanvas"

    private func layerHandleView(_ corner: LayerCorner, size: CGSize, frame: CGRect, angle: Double) -> some View {
        let position: CGPoint
        switch corner {
        case .topLeft: position = CGPoint(x: 0, y: 0)
        case .topRight: position = CGPoint(x: size.width, y: 0)
        case .bottomLeft: position = CGPoint(x: 0, y: size.height)
        case .bottomRight: position = CGPoint(x: size.width, y: size.height)
        }

        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(layerSelectionColor, lineWidth: 1))
            .frame(width: 12, height: 12)
            .shadow(radius: 1)
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        resizeLayer(corner, by: unrotated(value.translation, by: angle), frame: frame)
                    }
                    .onEnded { _ in endLayerDrag() }
            )
    }

    /// Points the layer at `location`, measured from its centre.
    private func rotateLayer(towards location: CGPoint, centre: CGPoint) {
        guard let index = selectedLayerIndex else {
            return
        }

        let dx = location.x - centre.x
        let dy = location.y - centre.y
        guard abs(dx) > 1 || abs(dy) > 1 else {
            return
        }

        // Measured from straight UP, because that is where the knob sits
        // when the layer is unrotated — so "no rotation" is the knob at the
        // top, not at the right.
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 {
            degrees += 360
        }

        // A 5° detent, so level stays level. Holding Shift is the usual way
        // to ask for that, but this app has no modifier plumbing in its
        // gestures and a photograph is almost never wanted at 37.4°.
        settings.layers[index].rotationDegrees = (degrees / 5).rounded() * 5
    }

    /// Turns a screen-space drag back into the layer's own axes.
    ///
    /// Without this a corner drag on a rotated layer resizes along the
    /// screen instead of along the edge the client is pulling, which reads
    /// as the layer fighting the cursor.
    private func unrotated(_ translation: CGSize, by degrees: Double) -> CGSize {
        guard degrees != 0 else {
            return translation
        }
        let radians = -degrees * .pi / 180
        return CGSize(
            width: translation.width * cos(radians) - translation.height * sin(radians),
            height: translation.width * sin(radians) + translation.height * cos(radians)
        )
    }


    /// Puts the layer down: the drag is over, so the full-resolution refine
    /// that isDrawingStroke held back for the length of it can run now.
    private func endLayerDrag() {
        layerDragStart = nil
        scheduleRefinedRender()
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
    // `brushCursor.stroke` (unit space) and shows a cheap, purely
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
            // Always mounted; see BrushStrokeLayer. The stroke preview and the
            // size ring both used to be `if let` on @State right here.
            BrushStrokeLayer(
                cursor: brushCursor, frame: frame, diameter: brushDiameter,
                color: accentColor, eraseColor: .red, isErasing: brushIsErasing)

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        brushCursor.brushHover = location
                    case .ended:
                        brushCursor.brushHover = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            brushCursor.brushHover = value.location
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
    // as the translucent paint the tool is supposed to look like.
    // The real mask is only built at Erase time (see eraseMaskedArea).
    // `frame` is the FULL pre-crop image rect, in the preview container's own
    // coordinate space; `containerSize` is that container. Both are needed, and
    // they are not interchangeable: strokes are stored as fractions of the full
    // image so they must be drawn against `frame`, but the part of it the
    // client can actually see and click is bounded by `containerSize` — and
    // zoomed in, `frame` is several times larger than the container.
    private func removalPaintOverlay(frame: CGRect, imageFrame: CGRect, containerSize: CGSize) -> some View {
        let longEdge = max(frame.width, frame.height)
        let brushDiameter = max(removalBrushSize * longEdge, 2)
        // Rose, matching InpaintPipeline.overlayImage — painting by hand and
        // finding people automatically produce ONE mask that gets erased in
        // one go, so showing them in two different colours would say they were
        // two different things. Changed from blue on request.
        //
        // Rose rather than plain red, deliberately: the note this replaces
        // recorded that pure red reads as a WARNING on a photo rather than as
        // "this is selected", and that on the warm frames this tool is used on
        // — skin, sand, sunset — red is among the hardest things to pick out.
        // Pushing the hue toward magenta keeps the warm, pink cast that was
        // asked for while staying off the orange-red axis those photos are
        // actually built from.
        let ink = Color(red: 1.0, green: 0.35, blue: 0.51)

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
                        // An erase stroke has to REMOVE the blue underneath
                        // it, not paint more of it — .destinationOut inside
                        // the compositing group below is what actually
                        // punches the hole, so what is on screen matches the
                        // mask strokeMask builds from the same strokes.
                        .blendMode(stroke.isErase ? .destinationOut : .normal)
                }

                // Always mounted, drawing nothing when there are no points.
                // Mounting it conditionally would put the condition back in the
                // parent's body, which is the invalidation this exists to avoid.
                ActiveStrokeLayer(
                    stroke: activeRemovalStroke,
                    frame: frame,
                    lineWidth: brushDiameter,
                    color: ink,
                    isErase: isRemoveBrushErasing
                )
            }
            .compositingGroup()
            .opacity(0.45)
            // Clipped to the PHOTO, not to the preview. `frame` is the full
            // pre-crop image, which zoomed in (or under a tight crop) extends
            // well past the preview area, and unclipped strokes were painted
            // straight over the panel beside it. Clipping to the preview fixed
            // that but left the other half of it: the photo is letterboxed
            // inside the preview, so a stroke could still be painted over the
            // grey margin next to the picture. `imageFrame` IS the picture.
            //
            // Intersected with the container because the two bounds are not
            // nested in a fixed order: at fit the photo is smaller than the
            // preview, zoomed in it is larger, and the stroke has to stop at
            // whichever is tighter on each edge.
            .frame(width: containerSize.width, height: containerSize.height)
            .clipShape(PreviewClipShape(
                rect: imageFrame.intersection(CGRect(origin: .zero, size: containerSize))))
            .allowsHitTesting(false)

            // Dashed while erasing, so which of the two the next drag will do
            // is visible before it happens rather than after.
            //
            // Gone entirely while a clean up is running: a ring following the
            // mouse over a brush that will not paint is the tool telling the
            // client it is ready when it is not.
            if !isRemoving {
                BrushCursorRing(
                    cursor: removalBrushCursor,
                    diameter: brushDiameter,
                    color: isRemoveBrushErasing ? Color.white.opacity(0.95) : ink.opacity(0.9),
                    isDashed: isRemoveBrushErasing
                )
                .frame(width: containerSize.width, height: containerSize.height)
            }

            // Sized to the CONTAINER, not to `frame`. It used to be
            // `.frame(frame.size).position(frame.mid)`, which at fit is the
            // same thing but zoomed in is a hit rect several times larger than
            // its own parent — and the parent is bounded by .frame(proxy.size),
            // so the overflow is not hit-testable. That is why painting stopped
            // working once zoomed while the button itself still toggled.
            //
            // The coordinate space does not change: .position() already made
            // the old hit area report locations in the container's space (which
            // is why unitPoint(from:frame:) subtracting frame.minX was correct),
            // and a container-filling view reports the same space. So `frame`
            // stays the mapping target for both the hover and the drag.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: containerSize.width, height: containerSize.height)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        removalBrushCursor.location = location
                    case .ended:
                        removalBrushCursor.location = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !removalBrushCursor.isStrokeInProgress {
                                removalBrushCursor.isStrokeInProgress = true
                            }
                            removalBrushCursor.location = value.location
                            paintRemovalBrush(at: value.location, frame: frame, imageFrame: imageFrame)
                        }
                        .onEnded { _ in
                            removalBrushCursor.isStrokeInProgress = false
                            commitRemovalStroke()
                        }
                )
                // The canvas stops taking the brush for as long as the model is
                // working. Requested directly: "kada je progres cleaning up
                // loading bar da se blokira dalje painting na slici dok ai ne
                // završi."
                //
                // Everything the job needs was snapshotted at the press, so a
                // stroke painted now could not join it — and clearRemovalMask()
                // at the end wipes the strokes, so it would either vanish
                // without explanation or, worse, outlive the wipe and be swept
                // into the next removal. Disabling the hit area is also what
                // makes the brush ring disappear, since the hover that drives
                // it comes through the same view.
                .disabled(isRemoving)
        }
    }

    private func strokePath(_ points: [CGPoint], frame: CGRect) -> Path {
        briefShowStrokePath(points, frame: frame)
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
        if let last = brushCursor.stroke.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        brushCursor.stroke.append(unit)
    }

    private func commitBrushStroke() {
        defer { brushCursor.stroke = [] }
        guard let index = selectedAdjustmentIndex, brushCursor.stroke.count > 1 else {
            return
        }
        let stroke = BrushStroke(points: brushCursor.stroke, size: brushSize, hardness: brushHardness, isErase: brushIsErasing)
        if settings.localAdjustments[index].brush == nil {
            settings.localAdjustments[index].brush = BrushMaskGeometry()
        }
        settings.localAdjustments[index].brush?.strokes.append(stroke)
    }

    // Records one dab of an in-progress clone-stamp stroke. The FIRST dab
    // of a fresh stroke (patchCursor.stroke still empty) is where a
    // pending ⌥-click source (if any) gets turned into this stroke's fixed
    // offset — see patchStrokeOffset's doc comment for why that offset then
    // carries over to later strokes too. If no source has EVER been set
    // (patchStrokeOffset is still nil), painting is a no-op: there's
    // nothing to clone from yet.
    private func paintPatchStroke(at location: CGPoint, frame: CGRect) {
        guard let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        if patchCursor.stroke.isEmpty {
            if let source = pendingPatchSource {
                patchStrokeOffset = CGSize(width: source.x - unit.x, height: source.y - unit.y)
                pendingPatchSource = nil
            }
            guard patchStrokeOffset != nil else {
                return
            }
        }
        if let last = patchCursor.stroke.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        patchCursor.stroke.append(unit)
    }

    // Unlike commitBrushStroke, a single-point "stroke" (a plain click, no
    // drag) IS committed — a one-dab clone stamp is a normal, common use
    // (spot-heal a single blemish), and brushStrokeDabs already renders a
    // 1-point stroke correctly (see its own doc comment).
    private func commitPatchStroke() {
        defer { patchCursor.stroke = [] }
        guard let index = selectedAdjustmentIndex, !patchCursor.stroke.isEmpty, let offset = patchStrokeOffset else {
            return
        }
        let stroke = PatchStroke(
            points: patchCursor.stroke,
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
        VStack(spacing: 0) {
            panelHeader

            Divider()

            // On the panel's main face, ABOVE the tabs, rather than filed
            // inside Retouch. It is the one block that is not about a category
            // of adjustment — it is the model doing work on the photo — and
            // from up here it is reachable whichever tab is open.
            //
            // Folded shut by default, which is what earns it the position:
            // closed it costs a single line, so being permanently available
            // does not permanently cost the sections below it any room.
            // Padding and divider live INSIDE the condition too. Left outside
            // they would leave a 20pt empty stripe and a stray line across the
            // panel with nothing between them — which is the titled line the
            // client wanted gone, only worse for being blank.
            if isAIManipulationVisible {
                aiManipulationSection
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider()
            }

            ScrollViewReader { panelScroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch panelTab {
                    case .edit:
                        histogramView

                        Divider()

                        // ⚠️ Crop & Rotate is here ONLY while the crop tool is
                        // on. It used to sit in the panel whether or not anyone
                        // was cropping, and the client asked for it to go for a
                        // precise reason: *„ovo ukloni isto jer bi se to
                        // otvorilo kad bi kliknuo na crop dugme"*. Pressing Crop
                        // already switches to this tab and scrolls here
                        // (toggleCropMode), so the section arrives exactly when
                        // it is wanted and takes no room the rest of the time.
                        //
                        // Presets is gone from this scroll altogether — it is
                        // the Presets cell in the header bar now, in a popover.
                        if isCropping {
                            cropRotateSection
                                .id(Self.cropSectionAnchor)

                            Divider()
                        }

                        lightSection

                        Divider()

                        colorSection

                        Divider().background(AppColors.border.opacity(0.5))

                        colorMixerSection

                        Divider()

                        detailSection

                    case .retouch:
                        // Tools stays here and is NOT repeated above the tab
                        // bar beside AI Manipulation: Crop, Selection and
                        // Patch belong to retouching, and a second copy of
                        // three buttons in a panel this narrow costs more than
                        // it saves.
                        toolsRowSection

                        Divider()

                        masksSection

                        Divider()

                        selectionSection

                        Divider()

                        removeSection

                    case .layers:
                        layersSection
                    }

                    Divider()

                    panelFooter
                }
                .padding(18)
            }
            // Pressing Crop in the header used to leave the client to find the
            // ratio buttons themselves — they sit inside "Crop & Rotate", far
            // enough down the panel to be off screen. The tool is on; the
            // controls for it should be where the eye already went.
            //
            // Animated, because a panel that jumps has not told anyone where it
            // went. anchor .top puts the section's own heading at the top of
            // the scroll rather than centring it, so what is under the cursor
            // afterwards is the section that was asked for.
            .onChange(of: scrollToCropRequest) { _ in
                withAnimation(.easeInOut(duration: 0.28)) {
                    panelScroll.scrollTo(Self.cropSectionAnchor, anchor: .top)
                }
            }
            }
        }
        .frame(width: CGFloat(effectivePanelWidth))
        .background(AppColors.panel)
    }

    // Settings, Reset and Export act on the whole photo, not on whichever tab
    // is open, so they sit below every tab's content instead of living at the
    // bottom of one of them. Appended inside the scroll rather than pinned:
    // exportActionsSection carries the filmstrip and the format card, and
    // pinning that much would eat the panel on a short window.
    private var panelFooter: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsActionsSection

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                resetButton

                // Only when there is actually a set to act on. A permanently
                // visible "Reset 0 Selected" would be a button that spends
                // most of its life meaning nothing.
                if multiSelectedURLs.count > 1 {
                    panelActionButton("Reset \(multiSelectedURLs.count) Selected",
                                      systemImage: "arrow.counterclockwise.circle") {
                        resetSelectedPhotos()
                    }
                }
            }

            Divider()

            flattenSection

            Divider()

            exportActionsSection
        }
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

                // "Import", not "Import from Lightroom". Lightroom is what it
                // happens to READ today, not what the button is for — and the
                // panel already says which formats when you open it. Naming a
                // button after one supported format is a name that has to be
                // changed every time another one is added.
                Button {
                    importLightroomPresets()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .help("Import presets. Supports Lightroom / Camera Raw .xmp "
                      + "files — pick one, several, or a whole folder.")
            }

            if let presetImportNotice {
                Text(presetImportNotice)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// The JPEG/PNG/TIFF choice, drawn by hand instead of `.pickerStyle(.segmented)`.
    ///
    /// AppKit's segmented control paints itself from the SYSTEM appearance, not
    /// from this app's theme. Under the dark theme that put grey-on-grey labels
    /// on a panel of a different grey again — reported with a screenshot, and it
    /// was barely readable. A theme the app draws everywhere else and then hands
    /// off to the system in one place is a theme with a hole in it.
    ///
    /// Same AppColors every other control here uses, so it goes dark and light
    /// with the rest of the window.
    private var exportFormatPicker: some View {
        HStack(spacing: 0) {
            ForEach(ExportFormat.allCases) { option in
                let isSelected = exportFormat == option
                Button {
                    exportFormatRaw = option.rawValue
                } label: {
                    Text(option.title)
                        .font(.custom("Figtree", size: 11)
                                .weight(isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? AppColors.ink : AppColors.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? AppColors.background : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(AppColors.panelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppColors.border.opacity(0.7), lineWidth: 1)
        )
    }

    private func presetRow(_ preset: PhotoEditPreset) -> some View {
        HStack(spacing: 8) {
            if renamingPresetID == preset.id {
                // The row becomes the field, rather than opening a dialog over
                // it: the name is already there to be corrected, and a sheet
                // for one word is a sheet too many.
                TextField("Preset name", text: $renamingPresetName)
                    .textFieldStyle(.roundedBorder)
                    .font(.custom("Figtree", size: 12))
                    .onSubmit { commitPresetRename() }

                Button("Save") { commitPresetRename() }
                    .buttonStyle(ShowHeaderButtonStyle())
                    .disabled(renamingPresetName
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel") { cancelPresetRename() }
                    .buttonStyle(ShowHeaderButtonStyle())
            } else {
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
                // Double-click is the Finder gesture for renaming and costs no
                // space in the row; the pencil is there so it can be found
                // without knowing that.
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    beginPresetRename(preset)
                })

                Button {
                    beginPresetRename(preset)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)
                .help("Rename this preset")

                Button {
                    deletePreset(preset)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)
                .help("Delete this preset")
            }
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
            whiteBalanceReadout
            editSlider("Tint", value: $settings.tint, range: -1...1,
                       trackGradient: DevelopView.tintTrack)
            editSlider("Saturation", value: $settings.saturation, range: -1...1,
                       trackGradient: DevelopView.saturationTrack)
            editSlider("Vibrance", value: $settings.vibrance, range: -1...1,
                       trackGradient: DevelopView.vibranceTrack)
        }
    }

    /// The white balance the Temperature slider is actually asking for, in the
    /// units Lightroom and the camera both speak.
    ///
    /// This app stores an OFFSET from the photo's own as-shot white balance
    /// rather than an absolute Kelvin, and that is the right thing to store —
    /// it is what lets one look be carried onto photographs shot under
    /// different light, which is exactly what Sync and a preset are for. But an
    /// offset of +0.33 is not a number anybody can compare with Lightroom, or
    /// with a grey card, or with the back of the camera.
    ///
    /// So the Kelvin is SHOWN, computed from the same `asShot + offset × 3000`
    /// the RAW render performs, and can be typed in to set the offset. Nothing
    /// about what is stored changes.
    ///
    /// Only for RAW: a JPEG has no as-shot Kelvin to be relative to, so there
    /// is no honest number to print. Lightroom does the same and shows its
    /// non-raw Temperature on a plain −100...100 scale.
    @ViewBuilder
    private var whiteBalanceReadout: some View {
        if let asShot = asShotWhiteBalance {
            HStack(spacing: 6) {
                Text("As shot \(Int(asShot.temperature.rounded())) K")
                    .font(.custom("Figtree", size: 10))
                    .foregroundColor(AppColors.muted.opacity(0.8))

                Spacer()

                if isEditingKelvin {
                    TextField("K", text: $kelvinFieldText)
                        .textFieldStyle(.roundedBorder)
                        .font(.custom("Figtree", size: 11))
                        .frame(width: 70)
                        .onSubmit { commitKelvinField(asShot: asShot) }

                    Button("Cancel") { cancelKelvinEdit() }
                        .buttonStyle(ShowHeaderButtonStyle())
                } else {
                    Button {
                        kelvinFieldText = "\(Int(currentKelvin(asShot: asShot).rounded()))"
                        isEditingKelvin = true
                    } label: {
                        Text("\(Int(currentKelvin(asShot: asShot).rounded())) K")
                            .font(.custom("Figtree", size: 11).weight(.medium))
                            .foregroundColor(AppColors.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(AppColors.border.opacity(0.7), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to type a colour temperature in Kelvin, the way "
                          + "Lightroom states it, and the slider moves to match.")
                }
            }
        }
    }

    /// The camera's own white balance, when this photo is a RAW.
    private var asShotWhiteBalance: (temperature: Double, tint: Double)? {
        guard case .raw(_, let temperature, let tint) = fullBaseImage else {
            return nil
        }
        return (Double(temperature), Double(tint))
    }

    /// The same arithmetic `render` performs, so the number on screen is the
    /// number the picture was made with rather than a second opinion.
    private func currentKelvin(asShot: (temperature: Double, tint: Double)) -> Double {
        min(max(asShot.temperature + settings.temperature * 3000, 2000), 50000)
    }

    private func cancelKelvinEdit() {
        isEditingKelvin = false
        kelvinFieldText = ""
    }

    private func commitKelvinField(asShot: (temperature: Double, tint: Double)) {
        defer { cancelKelvinEdit() }
        let trimmed = kelvinFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kelvin = Double(trimmed.replacingOccurrences(of: "K", with: "")
                                    .trimmingCharacters(in: .whitespaces)) else {
            return
        }
        // Back through the same relation, and clamped to the slider's own range
        // rather than silently accepting a Kelvin the slider cannot hold.
        let offset = (min(max(kelvin, 2000), 50000) - asShot.temperature) / 3000
        settings.temperature = min(max(offset, -1), 1)
    }

    /// Lightroom's Colour Mixer / HSL panel: pick a colour, move three sliders.
    ///
    /// The swatches are the control. A row of eight named buttons would work
    /// and would be worse — the client is looking for a colour in their
    /// photograph, not for a word, and "aqua" and "purple" are exactly the two
    /// names people disagree about.
    private var colorMixerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionTitle("Color Mixer")

                Spacer()

                if !settings.colorMixer.isNeutral {
                    Button {
                        settings.colorMixer = ColorMixer()
                    } label: {
                        Text("Reset")
                            .font(.custom("Figtree", size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppColors.muted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
                    .help("Put all eight colours back to zero.")
                }
            }

            HStack(spacing: 6) {
                ForEach(ColorBand.allCases) { band in
                    colorBandSwatch(band, mixer: settings.colorMixer)
                }
            }

            let band = selectedColorBand
            editSlider("Hue", key: "mixer.hue",
                       value: colorMixerBinding(band, \.hue), range: -1...1)
            editSlider("Saturation", key: "mixer.saturation",
                       value: colorMixerBinding(band, \.saturation), range: -1...1)
            editSlider("Luminance", key: "mixer.luminance",
                       value: colorMixerBinding(band, \.luminance), range: -1...1)
        }
    }

    /// `mixer` is a parameter rather than always `settings.colorMixer` because
    /// a selected LAYER has a mixer of its own now, and the row of swatches —
    /// including the "this band has been moved" dot — has to describe whichever
    /// one the panel is showing. The two panels share the picker (
    /// `selectedColorBand`) on purpose: it is which colour you are looking at,
    /// not an edit, and carrying the choice across reads as the same panel.
    private func colorBandSwatch(_ band: ColorBand, mixer: ColorMixer) -> some View {
        let isSelected = selectedColorBand == band
        // A band that has been moved keeps a mark whichever one is selected,
        // so a look built on three colours does not hide two of them behind a
        // picker. Without it the panel would show one band's sliders and give
        // no sign at all that the others had been touched.
        let isTouched = !mixer[band].isNeutral

        return Button {
            selectedColorBand = band
        } label: {
            Circle()
                .fill(band.swatch)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle().stroke(AppColors.ink.opacity(isSelected ? 0.9 : 0.25),
                                    lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(isTouched ? AppColors.ink.opacity(0.85) : .clear)
                        .frame(width: 4, height: 4)
                        .offset(y: 6)
                }
                .padding(.bottom, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(band.title)
    }

    /// One band's one slider, as a Binding.
    ///
    /// Written by hand rather than reaching for `$settings.colorMixer.red.hue`
    /// because the BAND is chosen at runtime: the subscript picks the band and
    /// the key path picks the slider, and the setter puts the whole band back.
    private func colorMixerBinding(_ band: ColorBand,
                                   _ slider: WritableKeyPath<ColorMixerBand, Double>) -> Binding<Double> {
        Binding(
            get: { settings.colorMixer[band][keyPath: slider] },
            set: { newValue in
                var updated = settings.colorMixer[band]
                updated[keyPath: slider] = newValue
                settings.colorMixer[band] = updated
            }
        )
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
            // Shown only while there is sharpening for it to shape. A radius
            // with the amount at zero is a control that cannot do anything, and
            // Lightroom's own panel greys its sub-sliders the same way.
            if settings.sharpness > 0 {
                editSlider("  Radius", key: "sharpen.radius",
                           value: $settings.sharpenRadius, range: 0.5...3) {
                    String(format: "%.1f", $0)
                }
            }
            editSlider("Texture", value: $settings.texture, range: -1...1)
            editSlider("Clarity", value: $settings.clarity, range: -1...1)
            editSlider("Dehaze", value: $settings.dehaze, range: -1...1)
            editSlider("Soft Glow", value: $settings.softGlow, range: 0...1) { String(format: "%.0f", $0 * 100) }
            editSlider("Vignette", value: $settings.vignette, range: -1...1)
            // Same rule as Radius: the shape of a vignette of zero is nothing.
            if settings.vignette != 0 {
                editSlider("  Midpoint", key: "vignette.midpoint",
                           value: $settings.vignetteMidpoint, range: 0...1) {
                    String(format: "%.0f", $0 * 100)
                }
                editSlider("  Feather", key: "vignette.feather",
                           value: $settings.vignetteFeather, range: 0...1) {
                    String(format: "%.0f", $0 * 100)
                }
                editSlider("  Roundness", key: "vignette.roundness",
                           value: $settings.vignetteRoundness, range: -1...1)
            }
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

            // Patch is NOT here any more. "Patch Circle" and the Tools row's
            // "Patch" were the same call with the same shape, so one of them
            // had to go; it kept the Tools row, beside Crop and Selection,
            // because Patch is a tool you pick up, not a kind of mask you add
            // to a list. "Patch Free" went with it — Free is reachable on a
            // Selection, and two entry points to the same tool differing only
            // in a default shape was the sort of thing you have to already
            // know to use.
            //
            // Square was dropped earlier, per explicit request, and remains a
            // Selection-tool-only shape (see addSelection).

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
                    // Floor is 0.001 — 0.1 on the dial — not 0.02. Retouching a
                    // face works at sizes where 2 is already too coarse: an eyelash,
                    // a stray hair, a sensor spot in a gradient sky. %.1f rather than
                    // %.0f because at this end whole numbers are the wrong resolution
                    // to report in; 0 and 0 would be two different brushes.
                    editSlider("Brush Size", key: "patchBrush.size", value: $patchBrushSize, range: 0.001...0.3) { String(format: "%.1f", $0 * 100) }
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

            // Select People used to stand here, and it does not any more:
            // it no longer FEEDS an erase. It makes a layer out of the
            // people instead, which is a Tools job, so it moved to the
            // Tools row beside Patch. What is left in this section is the
            // manual half below, which is now the only way to build a
            // removal mask.
            //
            // The manual half, and the one that carries the tool: Vision
            // only knows people, and most of what anyone wants gone (a bin,
            // a sign, a cable, a mole, an insect) isn't one. Called "Select
            // Area" rather than "Brush" because what it produces is a
            // selection to be erased, not a brush stroke that changes
            // pixels — every other brush in this app does the latter.
            // Painting also stacks WITH a found mask rather than replacing
            // it, so "find the people, then paint the two things Vision
            // missed" is one Erase, not two.
            panelActionButton(isRemoveBrushActive ? "AI Clean Up (painting)" : "AI Clean Up", systemImage: "paintbrush") {
                toggleRemoveBrush()
            }
            .disabled(isFindingPeople || isRemoving || selectedURL == nil)
            .opacity((isFindingPeople || isRemoving || selectedURL == nil) ? 0.4 : 1)

            if isRemoveBrushActive {
                // Add / Erase, side by side rather than a modifier key: the
                // whole tool is aimed at someone who paints over a thing and
                // presses a button, and "hold this key to take some back" is
                // the sort of thing only the person who wrote it remembers.
                HStack(spacing: 6) {
                    ForEach([false, true], id: \.self) { erasing in
                        Button {
                            isRemoveBrushErasing = erasing
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: erasing ? "eraser" : "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(erasing ? "Erase" : "Add")
                                    .font(.custom("Figtree", size: 11))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(isRemoveBrushErasing == erasing ? AppColors.ink : AppColors.muted)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isRemoveBrushErasing == erasing ? accentColor.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isRemoveBrushErasing == erasing ? accentColor.opacity(0.55) : AppColors.border,
                                        lineWidth: 1)
                        )
                    }
                }

                editSlider("Area Size", key: "removeBrush.size", value: $removalBrushSize, range: 0.01...0.3) {
                    String(format: "%.0f", $0 * 100)
                }
                Text(isRemoveBrushErasing
                     ? "Paint to take area back out of the selection. [ and ] resize it."
                     : "Paint over what should go. [ and ] resize it.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // "Looking for people…" used to be here too. It moved to the
            // Tools row with the button that causes it — a progress line in
            // a section that no longer starts the work is a line nobody can
            // connect to anything.
            if hasRemovalArea {
                Text(removalMask == nil
                     ? "Painted area ready. Quick is fast and matches the surroundings; AI Clean Up invents what belongs there."
                     : (activeSelection == nil
                        ? (foundBackgroundOnly
                           ? "People behind your subject found. Quick is fast and matches the surroundings; AI Clean Up invents what belongs there."
                           : "People found. Quick is fast and matches the surroundings; AI Clean Up invents what belongs there.")
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
                cleanUpButton(.quick, systemImage: "wand.and.rays")

                // Same mask, same resulting ImageLayer — the only difference
                // is what invents the missing pixels. Kept as a separate
                // button rather than a mode toggle because the two have
                // completely different costs: instant is a second, AI is
                // thirty diffusion steps.
                //
                // No prompt field, and none is needed: the model always runs
                // with SDInpaintPipeline.defaultPrompt, which asks for the
                // surroundings continued and names no object at all — so the
                // same one button removes a stranger, a mole or an insect
                // without the client typing a word.
                //
                // The field used to live behind a gear here. It was removed
                // deliberately after measuring what the alternative was worth:
                // see BRIEFSHOW_DEVELOP_NOTES.md for the side-by-side, where
                // an instruction-shaped prompt made the model paint a rock
                // garden into a beach.
                cleanUpButton(.generative, systemImage: "wand.and.stars")

                // ⚠️ ADDS to Generative Clean Up, does not change what it does
                // by default — asked for in exactly those terms: *„jel moze
                // da se doda ne mnjea nego doda"*. Off, Generative behaves
                // exactly as it did. On, it widens the mask before erasing —
                // see the long comment on `flyawayHair` in
                // InpaintPipeline.aiRemoval for why growth, not the prompt, is
                // the lever for a thin strand, and for the measurement behind
                // 0.006.
                //
                // Generative only: reported specifically against that button,
                // and Quick's own LaMa fill is the thing being compared
                // against, so widening it too would erase the comparison.
                Toggle("Flyaway Hair", isOn: $aiRemoveFlyawayHair)
                    .toggleStyle(.checkbox)
                    .font(.custom("Figtree", size: 11))
                    .help("Grows the selection further before Generative Clean Up erases it, so a thin stray hair against sky or background doesn't leave a faint trace. Leave off for anything that isn't a wisp of hair — a wider erase on a real object removes more of what's around it than it should.")

                // The patch is generated, not copied, so its tone lands a hair
                // off the photo's and a hard edge shows as a rectangle. This is
                // how far it fades out — as a fraction of the repaired area, so
                // the setting means the same thing on a small object and a
                // large one. Out in the open now that the gear it used to
                // share is gone.
                editSlider("Edge Feather", key: "aiRemove.feather",
                           value: $aiRemoveFeather, range: 0...1) {
                    String(format: "%.0f", $0 * 100)
                }
                .disabled(isRemoving)
                .opacity(isRemoving ? 0.4 : 1)

                panelActionButton("Clear Selection", systemImage: "xmark.circle") {
                    clearRemovalMask()
                }
                .disabled(isRemoving)
                .opacity(isRemoving ? 0.4 : 1)
            } else if !isRemoveBrushActive {
                Text("Finds everyone in the photo — or only inside an active Selection. AI Selection paints anything else by hand.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isRemoving {
                eraseProgressBar
            }

            if let removeNotice {
                Text(removeNotice)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let removeErrorMessage {
                Text(removeErrorMessage)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // One erase button, gated on whether the painted area is actually within
    // what THAT model can repair.
    //
    // The gate is a real block rather than the warning it started as, at the
    // client's request and for a good reason: the failure is not subtle
    // degradation, it is a white smear or an invented crowd of strangers,
    // arriving after a wait. A button that cannot produce a usable result is
    // more honest switched off with the reason underneath it.
    //
    // The SELECTION itself is never limited — only the buttons are. The same
    // painted area feeds both models and a Selection outline, so capping the
    // brush would take away work the other model, or a later smaller pass,
    // can still do.
    private func cleanUpButton(_ engine: RemovalEngine, systemImage: String) -> some View {
        let fits = removalAreaFits(engine)
        return VStack(alignment: .leading, spacing: 6) {
            panelActionButton(engine.title, systemImage: systemImage) {
                eraseMaskedArea(using: engine)
            }
            .disabled(isRemoving || !fits)
            .opacity((isRemoving || !fits) ? 0.4 : 1)

            if !fits || removalAreaWarrantsCaution(engine) {
                Text(engine.oversizeReason)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Remove (Vision + inpainting) actions

    // Either half of the tool counts: a Vision mask, painted strokes, or
    // both at once (they are unioned at Erase time).
    private var hasRemovalArea: Bool {
        removalMask != nil || !removalStrokes.isEmpty
    }

    // How big, in the photo's own pixels, the longest side of the BIGGEST
    // single repair is.
    //
    // The biggest single repair, not the extent of everything painted, and the
    // difference is the whole point of this having been rewritten: one press
    // now performs one repair per group of marks (see briefShowRemovalJobs), so
    // two small marks at opposite edges of the frame are two small jobs. The
    // old measurement unioned them into a box spanning the entire photo and
    // switched Quick off over it — a limit reported against work that was never
    // going to be done in one piece.
    private var removalAreaPixels: CGFloat? {
        guard let fullBaseImage else {
            return nil
        }
        let extent = fullBaseImage.extent
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }

        let boxes = briefShowRemovalJobs(
            strokes: removalStrokes,
            hasVisionMask: removalMask != nil,
            visionBox: removalMaskUnitBox
        ).map(\.box).filter { !$0.isNull }

        guard !boxes.isEmpty else {
            return nil
        }
        return boxes.map { max($0.width * extent.width, $0.height * extent.height) }.max()
    }

    // Measured, not guessed, on the user's own beach RAW (5176px wide):
    // an ~830px hole came back clean, a ~1550px one came back as a smear of
    // sand where the sea and horizon had been. The reason is the fixed 512
    // buffer the model runs in — the region handed to it is twice the hole,
    // so a 1550px hole means squeezing 3100px of photo into 512 and the
    // structure the model would need to continue (a horizon, a shoreline) is
    // gone before it ever sees it. 1000px is the middle of the two measured
    // points. See BRIEFSHOW_DEVELOP_NOTES.md.
    private func removalAreaFits(_ engine: RemovalEngine) -> Bool {
        guard let limit = engine.blockingAreaPixels else {
            return true
        }
        return (removalAreaPixels ?? 0) <= limit
    }

    private func removalAreaWarrantsCaution(_ engine: RemovalEngine) -> Bool {
        guard let limit = engine.cautionAreaPixels else {
            return false
        }
        return (removalAreaPixels ?? 0) > limit
    }

    private func clearRemovalMask() {
        removalMask = nil
        removalOverlay = nil
        removalStrokes = []
        activeRemovalStroke.points = []
        removeNotice = nil
        foundBackgroundOnly = false
        removalMaskUnitBox = nil
    }

    // Turning the brush on takes over the canvas the same way picking a
    // mask or the Selection tool does — those overlays share one hit area,
    // so leaving another one active would mean two tools fighting over the
    // same drag.
    /// Stops the Clean Up brush OWNING the canvas, without throwing away what
    /// it has already marked.
    ///
    /// `removalPaintOverlay` is the first branch of the overlay chain, so
    /// while the brush is on no other tool can receive a drag at all. Turning
    /// the brush ON already cleared every other tool (see toggleRemoveBrush
    /// below) but nothing did the reverse, so picking Patch while the brush
    /// was still on added the patch mask and then left the client painting an
    /// AI selection with an AI selection cursor — reported exactly that way.
    ///
    /// The painted AREA deliberately survives. It is the client's work and it
    /// is what Quick and Generative Clean Up consume; only the brush is put
    /// down.
    private func deactivateRemoveBrush() {
        guard isRemoveBrushActive else {
            return
        }
        isRemoveBrushActive = false
        isRemoveBrushErasing = false
        activeRemovalStroke.points = []
    }

    private func toggleRemoveBrush() {
        isRemoveBrushActive.toggle()
        if !isRemoveBrushActive {
            isRemoveBrushErasing = false
        }
        guard isRemoveBrushActive else {
            activeRemovalStroke.points = []
            return
        }
        selectedLocalAdjustmentID = nil
        activeSelection = nil
        activeSelectionDrawPoints.points = []
        selectedLayerID = nil
        isCropping = false
    }

    // `frame` is the full pre-crop image (the space stroke points are stored
    // in); `imageFrame` is the part of it actually on screen — the photo. They
    // differ whenever a crop is set, and the photo is letterboxed inside the
    // preview either way.
    private func paintRemovalBrush(at location: CGPoint, frame: CGRect, imageFrame: CGRect) {
        // Points outside the picture are DROPPED, not clamped. unitPoint()
        // clamps into 0...1, so a drag that wandered into the grey margin used
        // to pile points onto the photo's edge — a hard line of selection down
        // the side of the frame that nobody painted.
        //
        // Dropping is safe, and that is worth stating: the stroke is drawn as
        // straight segments between consecutive stored points, and a segment
        // between two points inside a rectangle stays inside it. So a drag that
        // leaves the photo and comes back cannot put geometry outside it — the
        // line simply cuts across, which is what it would have done anyway had
        // the mouse travelled that way inside the frame.
        // Nothing new gets painted while a clean up is running. The strokes
        // the model is working from were snapshotted when the button was
        // pressed, so anything added now is not in the job — it would sit on
        // the photo looking selected, survive the clearRemovalMask() that ends
        // the job, and then be silently carried into the NEXT clean up as if
        // the client had meant it there. The gesture is switched off in
        // removalPaintOverlay too; this is the funnel every path goes through,
        // so the rule is stated here as well.
        guard !isRemoving else {
            return
        }
        guard imageFrame.contains(location), let unit = unitPoint(from: location, frame: frame) else {
            return
        }
        // Same minimum-spacing filter as paintBrush — see its doc comment.
        if let last = activeRemovalStroke.points.last {
            let dx = unit.x - last.x, dy = unit.y - last.y
            if (dx * dx + dy * dy) < 0.0001 {
                return
            }
        }
        activeRemovalStroke.points.append(unit)
    }

    private func commitRemovalStroke() {
        defer { activeRemovalStroke.points = [] }
        // A drag that was under way when the clean up started ends here, and
        // it ends with nothing recorded — see paintRemovalBrush.
        guard !isRemoving else {
            return
        }
        // One point counts: a single click should dab the brush where it was
        // clicked, rather than needing a drag before anything appears.
        // brushStrokeDabs already handles a one-point stroke, so the mask side
        // has always been ready for this.
        guard !activeRemovalStroke.points.isEmpty else {
            return
        }
        // hardness 1: this is a SELECTION, not a soft adjustment — a feathered
        // edge would fall under the mask threshold and quietly shrink what
        // gets erased. The pipeline grows and softens the hole itself.
        removalStrokes.append(BrushStroke(
            points: activeRemovalStroke.points,
            size: removalBrushSize,
            hardness: 1,
            isErase: isRemoveBrushErasing
        ))
    }

    // Runs on the FULL, PRE-CROP render — not the cropped one a Cut/Copy
    // works from — because that is the space compositeLayers interprets an
    // ImageLayer's coordinates in, and the erase's output is an
    // ImageLayer. Using the cropped render here would land every repair at
    // the wrong place on any photo that has a crop.
    /// ⚠️ CURRENTLY UNREACHABLE — nothing calls this.
    ///
    /// It was the old "Select People" behaviour: find people and hand the
    /// mask to the eraser. That button now lifts people onto a layer
    /// instead (see `selectPeopleAsLayer`), so this has no caller.
    ///
    /// Kept, not deleted, because it is the whole working find-then-erase
    /// path including the `backgroundOnly` variant, and it is a lot of
    /// measured behaviour to throw away on the assumption nobody wants it
    /// back. Anything reading this: it does not run today.
    private func findPeople(backgroundOnly: Bool = false) {
        guard let fullBaseImage, let selectedURL else {
            return
        }
        isFindingPeople = true
        removeNotice = nil
        let settingsSnapshot = settings
        let photoAtActionTime = selectedURL
        let confineTo = activeSelection

        developRenderQueue.async(qos: .userInitiated) {
            let full = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage, applyCrop: false)
            var mask = SubjectMasker.personMask(for: full)

            // Before the Selection intersection, not after: the subject is
            // whoever is largest in the WHOLE frame, and a rope drawn round
            // the strangers would otherwise promote the biggest stranger to
            // subject and spare exactly the person meant to go.
            var nobodyBehind = false
            if backgroundOnly {
                if let found = mask {
                    let behind = SubjectMasker.backgroundPeople(
                        in: found, extent: full.extent, context: briefEditsCIContext)
                    nobodyBehind = behind == nil
                    mask = behind
                } else {
                    nobodyBehind = true
                }
            }

            if let mask_ = mask, let confineTo, !(confineTo.shape == .free && confineTo.points.count < 3) {
                let shape = PhotoEditRenderer.selectionMask(confineTo, extent: full.extent)
                mask = mask_.applyingFilter("CIMultiplyBlendMode", parameters: [
                    kCIInputBackgroundImageKey: shape
                ]).cropped(to: full.extent)
            }

            let overlay = mask.flatMap {
                InpaintPipeline.overlayImage(for: $0, context: briefEditsCIContext)
            }
            let box = mask.flatMap {
                InpaintPipeline.maskBoundingBox($0, extent: full.extent, context: briefEditsCIContext)
            }
            let unitBox = box.map {
                CGRect(x: ($0.minX - full.extent.minX) / full.extent.width,
                       y: ($0.minY - full.extent.minY) / full.extent.height,
                       width: $0.width / full.extent.width,
                       height: $0.height / full.extent.height)
            }

            DispatchQueue.main.async {
                isFindingPeople = false
                guard selectedURL == photoAtActionTime else {
                    return
                }
                removalMask = mask
                removalOverlay = overlay
                removalMaskUnitBox = unitBox
                foundBackgroundOnly = backgroundOnly
                if nobodyBehind {
                    // Two different causes, one message, because the user
                    // cannot act differently on them: either everyone Vision
                    // found is one connected group, or the people further
                    // away were too small for Vision to find at all (it works
                    // at about 2000px internally, so someone 60px tall in a
                    // 5000px frame is ~25px to it — below what it resolves).
                    // Measured on the user's own beach RAW, where Vision
                    // returned exactly one blob; see BRIEFSHOW_DEVELOP_NOTES.md.
                    removeNotice = "Nobody found in the background. People far enough away to be small in the frame are usually below what the detector can see, and anyone standing right against your subject counts as part of them. Paint over them with AI Selection instead."
                }
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

        var title: String {
            switch self {
            case .quick: return "Quick AI Clean Up"
            case .generative: return "Generative Clean Up"
            }
        }

        // What happens as the painted area grows — and the two models fail so
        // differently that they get different treatment, not different numbers.
        //
        // Both run in a 512 buffer over a region twice the size of the hole,
        // so both work from a downscaled copy. Measured on the user's beach
        // RAW (5176px wide), same masks through both, results looked at; full
        // tables in BRIEFSHOW_DEVELOP_NOTES.md.
        //
        // QUICK fails on SIZE, predictably: clean at ~830px, a smear of the
        // sea at ~1550px, and it does not matter what is around the hole. A
        // size limit describes that exactly, so it is a hard block.
        //
        // AI CLEAN UP fails on CONTENT, not size. Over plain sand it is clean
        // at 300, 600, 900, 1200 AND 1600px. Next to the shoreline it starts
        // inventing parasols and awnings from 600px up. A size limit cannot
        // express that, and blocking at the structured case's number would
        // switch the button off for every large removal over open ground that
        // works perfectly well — so this one only cautions.
        //
        // (A cheap detector for "is there structure around this hole?" was
        // tried and dropped: the coarse variation of the surrounding ring
        // reads 42-54 over plain sand and 44-79 over the shoreline, which
        // overlaps exactly where the results diverge. Numbers in the notes.)
        var blockingAreaPixels: CGFloat? {
            switch self {
            // Was 1000, sitting between a clean 830 and a smeared 1550 at the
            // old maxWorkingEdge of 1100. That cap is now 1600, so the region
            // is scaled down a third less for the same hole and the smear
            // threshold moves up with it. 1500 keeps the same margin below the
            // old failure point that 1000 kept — it does not permit the
            // failure at a bigger number, it moves where the failure starts.
            case .quick: return 2200
            case .generative: return nil    // no size at which this reliably fails
            }
        }

        var cautionAreaPixels: CGFloat? {
            switch self {
            case .quick: return nil         // it is blocked before it needs a caution
            // Was 600, "where inventing began, over structure". Inventing is
            // no longer what happens: Generative now starts from Quick's fill
            // and only finishes it (see SDInpaintPipeline.defaultRefineStrength),
            // so it cannot decide a car belongs in the gap any more. What is
            // left is the softness both models share once the area is large,
            // measured on C4S_7891: clean at 1242px, soft from 1656px.
            case .generative: return 1400
            }
        }

        var oversizeReason: String {
            switch self {
            case .quick:
                return "Quick works from a downscaled copy, and past about this size it smears a big region instead of rebuilding it. Paint a smaller area, or take this one out in a few passes."
            case .generative:
                return "An area this large comes back softer than the photo around it — there is not enough left nearby to rebuild it sharply. It will not invent anything, but taking it out in two or three smaller passes will look better."
            }
        }
    }

    // MARK: The Generative bar's lead-in
    //
    // The diffusion steps get 88% of the track and the four stages before them
    // share the first 12%. The split is not arbitrary: the steps are the bulk
    // of the work and must keep most of the bar, but the lead-in is the part
    // that used to be invisible, and it needs enough room that each stage is a
    // visible move rather than a rounding difference.
    private static let eraseLeadInStart: Double = 0.02
    private static let eraseLeadInEnd: Double = 0.12

    /// Moves the Generative bar to `fraction`, but never backwards.
    ///
    /// ⚠️ The guard matters with more than one mark on the photo. Marks are
    /// erased one at a time (see briefShowRemovalJobs) and each one walks its
    /// own stages, so the second mark would report "reading the photo, 4%"
    /// while the bar stood at 60%. A progress bar that goes back reads as a
    /// failure and a restart.
    private func advanceEraseProgress(to fraction: Double, stage: String?) {
        aiEraseProgress = max(aiEraseProgress ?? 0, fraction)
        aiEraseStage = stage
    }

    private func eraseMaskedArea(using engine: RemovalEngine) {
        guard hasRemovalArea, let fullBaseImage, let selectedURL else {
            return
        }
        isRemoving = true
        removeErrorMessage = nil
        // Only the generative path is slow enough to need a percentage; LaMa
        // finishes before a progress bar would finish appearing.
        //
        // ⚠️ STARTS AT 2%, NOT 0%, and that is not decoration. Zero is the one
        // reading a progress bar cannot survive: it is what a bar shows when it
        // has not started, so a bar that sits on it looks broken however much
        // work is going on behind it. Asked for in exactly those words — *„tu
        // bar me da se vidi da radi neka krene 2% (da nije nula)"*.
        //
        // Everything from here to the first diffusion step is reported by the
        // stages below, which are real events finishing, not a timer counting.
        aiEraseProgress = engine == .generative ? Self.eraseLeadInStart : nil
        aiEraseStage = engine == .generative ? "Preparing…" : nil
        let settingsSnapshot = settings
        let photoAtActionTime = selectedURL
        let visionMask = removalMask
        let visionBox = removalMaskUnitBox
        let strokes = removalStrokes
        let feather = aiRemoveFeather
        let flyawayHair = aiRemoveFlyawayHair

        developRenderQueue.async(qos: .userInitiated) {
            let full = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage, applyCrop: false)

            let erasures = strokes.filter { $0.isErase }

            // ONE REMOVAL PER GROUP OF MARKS, not one removal for everything
            // painted at once. See briefShowStrokeClusters for why: a single
            // mask spanning two far-apart marks puts the model's square working
            // region in the empty middle of the frame and repairs nothing.
            //
            // The same call backs the size gate on the buttons, so what gets
            // measured there and what gets repaired here cannot drift apart.
            let jobs = briefShowRemovalJobs(
                strokes: strokes, hasVisionMask: visionMask != nil, visionBox: visionBox)

            // Builds the mask for ONE job. Same add-then-subtract order the
            // single-mask version used, and the order is still the whole point:
            // strokeMask handles erase strokes only against the other painted
            // strokes, so running both kinds through it together would leave an
            // erase unable to touch the Vision mask — which is exactly what
            // someone erasing means to do when "Select People" grabbed a
            // shoulder it should not have.
            //
            // Every job subtracts ALL the erasures, not just nearby ones: an
            // erase stroke that falls outside this job's marks simply removes
            // nothing from it, so there is no need to work out which is which.
            func maskForJob(_ job: BriefShowRemovalJob) -> CIImage? {
                var mask: CIImage? = job.usesVisionMask ? visionMask : nil
                if !job.strokes.isEmpty {
                    let painted = PhotoEditRenderer.strokeMask(job.strokes, extent: full.extent)
                    mask = mask.map {
                        $0.applyingFilter("CIMaximumCompositing", parameters: [
                            kCIInputBackgroundImageKey: painted
                        ]).cropped(to: full.extent)
                    } ?? painted
                }
                guard let current = mask else {
                    return nil
                }
                guard !erasures.isEmpty else {
                    return current
                }
                // Built as a POSITIVE mask (isErase cleared) and then
                // inverted, because strokeMask starts from black: a set of
                // erase-only strokes handed to it would multiply black by
                // white and come back black, erasing nothing.
                let cut = PhotoEditRenderer.strokeMask(
                    erasures.map {
                        BrushStroke(points: $0.points, size: $0.size, hardness: $0.hardness, isErase: false)
                    },
                    extent: full.extent
                )
                let keep = cut.applyingFilter("CIColorInvert").cropped(to: full.extent)
                return current.applyingFilter("CIMultiplyBlendMode", parameters: [
                    kCIInputBackgroundImageKey: keep
                ]).cropped(to: full.extent)
            }

            var removals: [InpaintPipeline.Removal] = []
            var failure: String?

            for (index, job) in jobs.enumerated() {
                guard let jobMask = maskForJob(job) else {
                    continue
                }
                do {
                    let removal: InpaintPipeline.Removal?
                    switch engine {
                    case .quick:
                        removal = try InpaintPipeline.quickAIRemoval(
                            mask: jobMask, from: full, context: briefEditsCIContext, feather: feather)
                    case .generative:
                        removal = try InpaintPipeline.aiRemoval(
                            mask: jobMask, from: full, context: briefEditsCIContext,
                            prompt: SDInpaintPipeline.defaultPrompt, feather: feather,
                            progress: { done, total in
                                // Counted across ALL the jobs, not restarted
                                // for each one: three marks used to mean the
                                // bar running 0-100 three times, which reads as
                                // the app going round in circles.
                                let within = Double(done) / Double(max(total, 1))
                                let overall = (Double(index) + within) / Double(max(jobs.count, 1))
                                // Compressed into what is left after the
                                // lead-in, so the steps start where the stages
                                // stopped instead of snapping back to it.
                                let placed = Self.eraseLeadInEnd
                                    + (1 - Self.eraseLeadInEnd) * overall
                                DispatchQueue.main.async {
                                    // Stage goes nil here: from the first step
                                    // on, the percentage is the honest account
                                    // of what is happening and needs no label.
                                    advanceEraseProgress(to: placed, stage: nil)
                                }
                            },
                            // The four stages that run before any percentage
                            // exists. Spread across the lead-in so each one is
                            // a visible move — this is the stretch the client
                            // watched sit at zero.
                            stage: { stage in
                                let (fraction, text): (Double, String) = {
                                    switch stage {
                                    case .readingPhoto:
                                        return (0.04, "Reading the photo…")
                                    case .baseFilled:
                                        return (0.07, "Filling the gap…")
                                    case .loadingModel:
                                        // Usually instant now, because the
                                        // weights are loaded and primed at
                                        // launch. When it is not instant this
                                        // is the longest wait in the job, and
                                        // it finally says so.
                                        return (0.08, "Loading the AI model…")
                                    case .modelReady:
                                        return (Self.eraseLeadInEnd, "Cleaning up…")
                                    }
                                }()
                                DispatchQueue.main.async {
                                    advanceEraseProgress(to: fraction, stage: text)
                                }
                            },
                            flyawayHair: flyawayHair
                        )
                    }
                    if let removal {
                        removals.append(removal)
                    }
                } catch {
                    // Stop, but keep what already worked: two marks out of
                    // three repaired is worth having, and redoing the third is
                    // a smaller job than redoing all of them.
                    failure = error.localizedDescription
                    break
                }
            }

            DispatchQueue.main.async {
                isRemoving = false
                aiEraseProgress = nil
                aiEraseStage = nil
                // Same guard as performSelectionExtraction: the repair is
                // pixels belonging to ONE photo, so it is dropped rather
                // than misapplied if the client moved on while it ran.
                guard selectedURL == photoAtActionTime else {
                    clearRemovalMask()
                    return
                }

                if let failure {
                    removeErrorMessage = failure
                }

                guard !removals.isEmpty else {
                    // THE PAINT STAYS. It used to be wiped here, which is how a
                    // removal that quietly produced nothing looked from the
                    // outside: click, the selection vanishes, the photo is
                    // unchanged, and nothing says why. Keeping it means the
                    // client can adjust and try again instead of painting the
                    // whole thing over.
                    if failure == nil {
                        removeErrorMessage = "Nothing was repaired. Try painting over the marks again, a little more generously."
                    }
                    return
                }

                // One layer per removal, appended in turn so each gets its own
                // number from nextLayerName — and so each can be undone or
                // hidden on its own, which is the point of splitting them.
                for removal in removals {
                    settings.layers.append(ImageLayer(
                        name: nextLayerName("Removed"), imageData: removal.pngData,
                        x: removal.boundsUnit.minX, y: removal.boundsUnit.minY,
                        width: removal.boundsUnit.width, height: removal.boundsUnit.height
                    ))
                }
                clearRemovalMask()
                activeSelection = nil
                // The brush deliberately STAYS ON. It used to switch itself off
                // here, which meant every clean up ended by throwing the client
                // out of the tool they were in the middle of using — reported
                // directly: "posle izbaci da moram opet da kliknem na AI
                // Selection". Removing something is rarely one removal; the
                // normal shape of the work is paint, clean, paint the next
                // thing, clean again.
                //
                // clearRemovalMask() above already emptied the strokes, so what
                // is left is the brush armed over a clean slate, which is
                // exactly the state the next removal starts from. Erase mode is
                // reset with it: erasing FROM an empty selection does nothing,
                // so staying in it would be a dead cursor.
                isRemoveBrushErasing = false
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
            HStack(spacing: 8) {
                sectionTitle("Layers")

                Spacer()

                if !settings.layers.isEmpty {
                    // Removes every layer in one go, instead of ten trips to
                    // the trash icon. Requested as "clear all history"; the
                    // word History is left off because this app HAS a history —
                    // the Cmd+Z stack — and this button does not touch it. It
                    // clears the layer list.
                    //
                    // Not guarded by a confirmation dialog, deliberately: it
                    // writes settings.layers, so it lands on the undo stack
                    // like any other edit and Cmd+Z brings every layer back.
                    // A confirmation would be a second click protecting against
                    // something one keystroke already undoes.
                    Button {
                        selectedLayerID = nil
                        settings.layers.removeAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Clear All")
                                .font(.custom("Figtree", size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppColors.muted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
                    .help("Remove every layer. Cmd+Z brings them back.")

                    Text("\(settings.layers.count)")
                        .font(.custom("Figtree", size: 11))
                        .foregroundColor(AppColors.muted)
                }
            }

            panelActionButton("Paste as Layer", systemImage: "doc.on.clipboard") {
                pasteLayer()
            }
            .disabled(layerClipboard == nil)
            .opacity(layerClipboard == nil ? 0.4 : 1)
            // This modifier does NOT serve Cmd+V, despite appearances. The
            // shared local NSEvent monitor (installEditingKeyMonitor) matches
            // Cmd+V first and returns nil, so the event never reaches
            // SwiftUI's shortcut dispatch; and when layerClipboard is nil this
            // button is disabled, so the shortcut would do nothing then
            // either. It is kept purely because it draws the ⌘V hint beside
            // the title. The previous comment here claimed the button had to
            // stay mounted for paste to work — it does not, and that mattered
            // when Layers moved behind a tab: paste keeps working from any
            // tab precisely because the monitor, not this button, owns it.
            .keyboardShortcut("v", modifiers: .command)

            if settings.layers.isEmpty {
                Text("No layers yet. Cut or copy a selection, then paste it here.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Topmost layer first, the way every layers panel reads.
            // settings.layers is stored bottom-to-top because compositeLayers
            // draws it in array order, so this reverses for DISPLAY only —
            // every action still resolves through the layer's id, and the drop
            // delegate reorders the real array.
            ForEach(Array(settings.layers.reversed())) { layer in
                layerRow(layer)
                    .onDrag {
                        draggingLayerID = layer.id
                        return NSItemProvider(object: layer.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: LayerDropDelegate(
                            target: layer.id,
                            dragging: $draggingLayerID,
                            layers: $settings.layers
                        )
                    )
            }

            if let index = selectedLayerIndex {
                selectedLayerEditor(index: index)
            }
        }
    }

    private func layerRow(_ layer: ImageLayer) -> some View {
        let isSelected = selectedLayerID == layer.id

        return HStack(spacing: 8) {
            // Grip glyph, not the old stack-of-layers icon: the row is now
            // draggable and this is the only thing that says so.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(AppColors.muted.opacity(draggingLayerID == layer.id ? 1 : 0.6))
                .frame(width: 12)
                .help("Drag to reorder")

            Button {
                toggleLayerEnabled(layer.id)
            } label: {
                Image(systemName: layer.isEnabled ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                .stroke(isSelected ? layerSelectionColor : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The Layers panel's own selection colour.
    ///
    /// Deliberately NOT `accentColor`. That yellow is the "this slider is
    /// armed for the arrow keys" signal, and a list you scan down does not
    /// need to shout the way one live control does — reported as too loud,
    /// and it also made the panel read as if three things were armed at
    /// once. A grey still reads as selected against panelAlt.
    ///
    /// Only the LAYER row. maskRow keeps the accent: nothing was reported
    /// about it, and changing it here would be tidying by assumption.
    private var layerSelectionColor: Color {
        themeManager.current == .dark
            ? Color(red: 0.46, green: 0.46, blue: 0.48)
            : Color(red: 0.38, green: 0.38, blue: 0.40)
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

            // Black & White and Blur, as switches rather than sliders: both
            // are things a client wants ON, and the amount is a detail they
            // may never touch. B&W is saturation at its bottom stop — the
            // same value the Saturation slider below already produces, so
            // there is no second way to describe one state.
            HStack(spacing: 6) {
                layerToggleButton("Black & White", systemImage: "circle.lefthalf.filled",
                                  isOn: layer.adjustments.saturation <= -1) {
                    guard let i = selectedLayerIndex else { return }
                    settings.layers[i].adjustments.saturation =
                        settings.layers[i].adjustments.saturation <= -1 ? 0 : -1
                }

                layerToggleButton("Blur", systemImage: "drop.fill", isOn: layer.blur > 0) {
                    guard let i = selectedLayerIndex else { return }
                    // 0.35 rather than full strength: a background at 1.0 is
                    // unrecognisable, and switching this on is usually about
                    // separating the subject, not erasing what is behind them.
                    settings.layers[i].blur = settings.layers[i].blur > 0 ? 0 : 0.35
                }

                // Back to the layer as it was MADE, without unmaking it —
                // "I tried black and white on them, I don't like it". Not a
                // toggle, so it is drawn as off and simply acts.
                //
                // Geometry is deliberately NOT reset. This undoes the LOOK;
                // a pasted piece that was carefully placed should not jump
                // back across the photo because somebody wanted its
                // exposure back to zero.
                layerToggleButton("Reset", systemImage: "arrow.counterclockwise", isOn: false) {
                    guard let i = selectedLayerIndex else { return }
                    settings.layers[i].adjustments = LocalAdjustmentSettings()
                    settings.layers[i].blur = 0
                    settings.layers[i].opacity = 1
                    settings.layers[i].blendMode = .normal
                    settings.layers[i].rotationDegrees = 0
                    // "As it was made" means every choice made since — the
                    // first version left one of them out and Reset read as
                    // broken rather than partial.
                }
            }

            if layer.blur > 0 {
                editSlider("Blur Amount", key: "layer.blur", value: layerBlurBinding, range: 0.01...1) {
                    String(format: "%.0f", $0 * 100)
                }
            }

            // Our own row, not `.pickerStyle(.segmented)`.
            //
            // The native segmented control draws its labels with the SYSTEM
            // appearance, not this app's theme, so on the dark theme the
            // three unselected modes came out near-black on near-black and
            // were reported as unreadable. Same class of problem the
            // Stepper had (see ContentView), except a segmented control
            // paints its own text and `.preferredColorScheme` cannot reach
            // it. Built from the app's own colours instead — the same
            // shape as the Add/Erase pair in the Remove section, so the
            // panel has one way of drawing a choice rather than two.
            // Blend mode and dragging belong to a PASTED piece: something
            // that arrived from elsewhere, meets what is behind it, and can
            // be put somewhere else. A derived layer is a region OF this
            // photo — there is nothing behind it but itself, and moving it
            // would only slide a matte off the thing it was cut around.
            // Hidden rather than disabled: a row of dead controls invites
            // the client to work out why.
            if !layer.isDerived {
                HStack(spacing: 6) {
                    ForEach(LayerBlendMode.allCases, id: \.self) { mode in
                        let isSelected = layer.blendMode == mode

                        Button {
                            layerBlendModeBinding.wrappedValue = mode
                        } label: {
                            Text(mode.label)
                                .font(.custom("Figtree", size: 11).weight(isSelected ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(isSelected ? AppColors.ink : AppColors.muted)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? layerSelectionColor.opacity(0.30) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? layerSelectionColor : AppColors.border, lineWidth: 1)
                        )
                    }
                }

                Text("Drag the layer on the photo to move it; drag a corner to resize.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
            } else {
                Text("This layer is a part of the photo itself, so it stays where it is — and it follows the picture when the sliders above the panel move.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // The same sliders the global Light/Colour sections have, bound
            // through layerAdjustmentBinding instead of $settings — exactly
            // how a selected MASK already works (see selectedMaskEditor).
            //
            // ⚠️ The global sliders are deliberately left alone. Retargeting
            // THEM at the selected layer was the other way to read the
            // request, and it is worse: it would silently change what the
            // main panel means depending on a selection made somewhere else
            // in the panel, and it would leave no way to adjust the whole
            // photo while a layer happens to be selected. Here the rule is
            // plain — sliders up there are the photo, sliders in this card
            // are this layer, and with no layer selected there is only the
            // photo.
            Text("These change this layer only.")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)

            editSlider("Exposure", key: "layer.exposure", value: layerAdjustmentBinding(\.exposure), range: -3...3, step: 0.05) { String(format: "%+.2f", $0) }
            editSlider("Contrast", key: "layer.contrast", value: layerAdjustmentBinding(\.contrast), range: -1...1)
            editSlider("Highlights", key: "layer.highlights", value: layerAdjustmentBinding(\.highlights), range: -1...1)
            editSlider("Shadows", key: "layer.shadows", value: layerAdjustmentBinding(\.shadows), range: -1...1)
            editSlider("Whites", key: "layer.whites", value: layerAdjustmentBinding(\.whites), range: -1...1)
            editSlider("Blacks", key: "layer.blacks", value: layerAdjustmentBinding(\.blacks), range: -1...1)
            // ⚠️ The SAME four tracks the photo's Color section uses, and they
            // belong here for the same reason they belong there: the colour on
            // the track is what the slider does. Left plain they were the one
            // visible difference between editing a layer and editing the
            // photo — reported as *„temperatue tint slide bar u toj sekciji
            // nisu u boji… mora da bude taj slide bar edit isti kao kad
            // editujem normalnu sliku"*.
            //
            // Safe to share: all four are static constants built from fixed
            // colours (see temperatureTrack below), so none of them reads the
            // photo. A layer gets the identical track, not a lookalike.
            editSlider("Temperature", key: "layer.temperature", value: layerAdjustmentBinding(\.temperature), range: -1...1,
                       trackGradient: DevelopView.temperatureTrack)
            editSlider("Tint", key: "layer.tint", value: layerAdjustmentBinding(\.tint), range: -1...1,
                       trackGradient: DevelopView.tintTrack)
            editSlider("Saturation", key: "layer.saturation", value: layerAdjustmentBinding(\.saturation), range: -1...1,
                       trackGradient: DevelopView.saturationTrack)
            editSlider("Vibrance", key: "layer.vibrance", value: layerAdjustmentBinding(\.vibrance), range: -1...1,
                       trackGradient: DevelopView.vibranceTrack)
            editSlider("Sharpness", key: "layer.sharpness", value: layerAdjustmentBinding(\.sharpness), range: 0...1) { String(format: "%.0f", $0 * 100) }
            // Same rule the photo's panel uses: a radius with the amount at
            // zero is a control that cannot do anything.
            if selectedLayerAdjustments.sharpness > 0 {
                editSlider("  Radius", key: "layer.sharpenRadius",
                           value: layerAdjustmentBinding(\.sharpenRadius), range: 0.5...3) {
                    String(format: "%.1f", $0)
                }
            }

            // ⚠️ The rest of "Detail & Effects", in the photo panel's own
            // order and with its own ranges — this is the half the client was
            // missing: *„nemam iste opcije za edit kao celokupan edit"*. Same
            // labels and same numbers on purpose, so a layer's Clarity of +40
            // is the photo's Clarity of +40 and not a second dialect.
            editSlider("Texture", key: "layer.texture", value: layerAdjustmentBinding(\.texture), range: -1...1)
            editSlider("Clarity", key: "layer.clarity", value: layerAdjustmentBinding(\.clarity), range: -1...1)
            editSlider("Dehaze", key: "layer.dehaze", value: layerAdjustmentBinding(\.dehaze), range: -1...1)
            editSlider("Soft Glow", key: "layer.softGlow", value: layerAdjustmentBinding(\.softGlow), range: 0...1) { String(format: "%.0f", $0 * 100) }
            editSlider("Vignette", key: "layer.vignette", value: layerAdjustmentBinding(\.vignette), range: -1...1)
            if selectedLayerAdjustments.vignette != 0 {
                editSlider("  Midpoint", key: "layer.vignetteMidpoint",
                           value: layerAdjustmentBinding(\.vignetteMidpoint), range: 0...1) {
                    String(format: "%.0f", $0 * 100)
                }
                editSlider("  Feather", key: "layer.vignetteFeather",
                           value: layerAdjustmentBinding(\.vignetteFeather), range: 0...1) {
                    String(format: "%.0f", $0 * 100)
                }
                editSlider("  Roundness", key: "layer.vignetteRoundness",
                           value: layerAdjustmentBinding(\.vignetteRoundness), range: -1...1)
            }

            layerColorMixerSection
        }
    }

    /// The layer's own eight-band mixer — the same control the photo has, bound
    /// to the layer instead. Built here rather than by parameterising
    /// `colorMixerSection` because the two differ in more than their binding:
    /// this one carries the layer's name in its title, so it is obvious which
    /// of the two mixers is on screen.
    private var layerColorMixerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionTitle("Color Mixer")

                Spacer()

                if !selectedLayerAdjustments.colorMixer.isNeutral {
                    Button {
                        guard let index = selectedLayerIndex else { return }
                        settings.layers[index].adjustments.colorMixer = ColorMixer()
                    } label: {
                        Text("Reset")
                            .font(.custom("Figtree", size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppColors.muted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
                    .help("Put all eight colours back to zero on this layer.")
                }
            }

            HStack(spacing: 6) {
                ForEach(ColorBand.allCases) { band in
                    colorBandSwatch(band, mixer: selectedLayerAdjustments.colorMixer)
                }
            }

            let band = selectedColorBand
            editSlider("Hue", key: "layer.mixer.hue",
                       value: layerColorMixerBinding(band, \.hue), range: -1...1)
            editSlider("Saturation", key: "layer.mixer.saturation",
                       value: layerColorMixerBinding(band, \.saturation), range: -1...1)
            editSlider("Luminance", key: "layer.mixer.luminance",
                       value: layerColorMixerBinding(band, \.luminance), range: -1...1)
        }
    }

    /// The selected layer's adjustments, or a neutral set when there is no
    /// layer selected. Read by the `if` conditions above, which run while the
    /// panel is being built and cannot use `guard let`.
    private var selectedLayerAdjustments: LocalAdjustmentSettings {
        guard let index = selectedLayerIndex else {
            return LocalAdjustmentSettings()
        }
        return settings.layers[index].adjustments
    }

    private func layerColorMixerBinding(_ band: ColorBand,
                                        _ slider: WritableKeyPath<ColorMixerBand, Double>) -> Binding<Double> {
        Binding(
            get: { selectedLayerAdjustments.colorMixer[band][keyPath: slider] },
            set: { newValue in
                guard let index = selectedLayerIndex else {
                    return
                }
                var updated = settings.layers[index].adjustments.colorMixer[band]
                updated[keyPath: slider] = newValue
                settings.layers[index].adjustments.colorMixer[band] = updated
            }
        )
    }
    /// A switch in the layer editor: on, off, and it says which it is.
    private func layerToggleButton(_ title: String, systemImage: String,
                                   isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.custom("Figtree", size: 11).weight(isOn ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isOn ? AppColors.ink : AppColors.muted)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isOn ? layerSelectionColor.opacity(0.30) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isOn ? layerSelectionColor : AppColors.border, lineWidth: 1)
        )
    }

    private var layerBlurBinding: Binding<Double> {
        Binding(
            get: {
                guard let index = selectedLayerIndex else {
                    return 0
                }
                return settings.layers[index].blur
            },
            set: { newValue in
                guard let index = selectedLayerIndex else {
                    return
                }
                settings.layers[index].blur = newValue
            }
        )
    }

    /// Mirrors `localAdjustmentBinding`, resolved through
    /// `selectedLayerIndex` every get and set because which array slot is
    /// "selected" is tracked by UUID, not by index — a layer can be
    /// reordered by a drag while its own editor is open.
    private func layerAdjustmentBinding(_ keyPath: WritableKeyPath<LocalAdjustmentSettings, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let index = selectedLayerIndex else {
                    return 0
                }
                return settings.layers[index].adjustments[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = selectedLayerIndex else {
                    return
                }
                settings.layers[index].adjustments[keyPath: keyPath] = newValue
            }
        )
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
                GradientTrackSlider(value: value, range: range, step: step, gradient: trackGradient) { editing in
                    if editing, selectedSliderKey != sliderKey {
                        selectedSliderKey = sliderKey
                    }
                }
            } else {
                EditTrackSlider(value: value, range: range, step: step, accent: accentColor) { editing in
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
    /// The same key with Shift held, for the one pair where the keyboard gives
    /// two characters for one key: "=" / "+" and "-" / "_".
    ///
    /// Only applies while the binding is still the default one — if the client
    /// has rebound Zoom In to something else, there is no twin to guess at.
    private func shiftedTwin(_ event: NSEvent, of action: ShortcutAction, _ twin: String) -> Bool {
        let combo = ShortcutStore.combo(for: action)
        guard combo == action.defaultCombo else {
            return false
        }
        var shifted = combo
        shifted.character = twin
        shifted.shift = true
        return shifted.matches(event)
    }

    /// Moves `by` photos along the filmstrip. Returns false at either end and
    /// when there is nowhere to go, so the key falls through untouched rather
    /// than being swallowed for nothing.
    @discardableResult
    private func stepPhoto(by offset: Int) -> Bool {
        guard let selectedURL,
              let index = photoURLs.firstIndex(of: selectedURL) else {
            return false
        }
        let target = index + offset
        guard photoURLs.indices.contains(target) else {
            return false
        }
        selectPhoto(photoURLs[target])
        return true
    }

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

    // Shared by the header's "Reset" and the footer's "Reset All" so the two
    // cannot drift into clearing different things.
    private func resetAllSettings() {
        settings = PhotoEditSettings()
        pendingCrop = .full
        // Cleared alongside settings.cropAspect, which the line above just put
        // back to .free. Without this, pressing Reset with the crop tool OPEN
        // would leave 4:3 lit in the ratio row — and commitCrop would then
        // write that stale lock straight back over the reset.
        selectedCropAspectRatio = .free
        cropIsAutoFitted = false
        selectedLocalAdjustmentID = nil
        activeSelection = nil
        activeSelectionDrawPoints.points = []
        selectedLayerID = nil
    }

    /// Puts every photo in the filmstrip's multi-select back to its original.
    ///
    /// Reset used to reach exactly one photo — whichever was open — so undoing
    /// a folder's worth of edits meant opening each one and pressing Reset,
    /// which is the same work the client was trying to undo.
    ///
    /// The open photo, if it is in the set, is reset through `settings` rather
    /// than through the store: that is the copy the sliders and the preview
    /// are bound to, and writing only the store would leave the panel showing
    /// edits that no longer exist.
    private func resetSelectedPhotos() {
        let targets = multiSelectedURLs
        guard !targets.isEmpty else {
            return
        }

        for url in targets where url != selectedURL {
            PhotoEditStore.setSettings(PhotoEditSettings(), for: url)
        }

        if let selectedURL, targets.contains(selectedURL) {
            resetAllSettings()
        }

        // The strip and the grid are told at once rather than waiting for the
        // debounce: this is a deliberate, one-shot action on many photos, not
        // a slider being dragged.
        PhotoEditStore.flushNow()
    }

    // MARK: Black & White, Duplicate

    /// What a filmstrip context-menu action acts on.
    ///
    /// The whole multi-selection when the right-clicked photo belongs to
    /// one, and otherwise just the photo under the cursor — the rule the
    /// Export items at the top of that menu already use. Returned in
    /// `photoURLs` order rather than the Set's, so anything that reports a
    /// count or inserts beside an original works in strip order.
    private func contextMenuTargets(for url: URL) -> [URL] {
        guard multiSelectedURLs.contains(url), multiSelectedURLs.count > 1 else {
            return [url]
        }
        return photoURLs.filter { multiSelectedURLs.contains($0) }
    }

    /// The settings a photo is actually SHOWING.
    ///
    /// For the open photo that is the live `settings`, not the store's copy:
    /// `renderNow` writes the store on a 0.02 s debounce, so it can be one
    /// change behind what the client is looking at, and baking the store's
    /// copy would bake a picture that is not on screen.
    private func visibleSettings(for url: URL) -> PhotoEditSettings {
        url == selectedURL ? settings : PhotoEditStore.settings(for: url)
    }

    /// Makes every target black and white, layers and masks included.
    ///
    /// **Why this bakes first, when `saturation = -1` alone looks like it
    /// should be enough.** It is not, and the picture that proved it had a
    /// row of orange retouch dots still in colour on an otherwise grey
    /// portrait. `PhotoEditRenderer.render` composites local adjustments and
    /// then layers AFTER the colour controls — deliberately, since a pasted
    /// piece is new content sitting above the stack — so a global
    /// desaturation never reaches them.
    ///
    /// Baking puts the layers INTO the pixels, and only then is the colour
    /// taken out, which by that point reaches everything.
    ///
    /// **This section is the only place in the app that flattens without
    /// being asked**, and `flattenPhoto`'s own comment says that should
    /// never happen as a side effect. Done here because it was asked for
    /// explicitly, and because it is cheap to undo: flatten NEVER touches
    /// the client's file — it writes a TIFF into Application Support and
    /// every decode goes through `FlattenedImageStore.sourceURL` — so the
    /// original is still on disk and Unflatten puts it back.
    private func applyBlackAndWhite(to targets: [URL]) {
        guard !targets.isEmpty else {
            return
        }

        let jobs = targets.map {
            PhotoBakeService.BakeJob(source: $0, target: $0, settings: visibleSettings(for: $0))
        }

        runBake(jobs, desaturate: true, busyMessage: "Making black & white…") { done, failed in
            showTransientStatus(failed == 0
                                ? "\(done) in black & white"
                                : "\(done) in black & white, \(failed) failed")
        }
    }

    /// Copies each target beside itself and bakes the copy.
    ///
    /// **The copy is always baked, even without `blackAndWhite`.** That is
    /// the whole point of a duplicate here: a plain file copy carries the
    /// pixels of the ORIGINAL file, and every edit — including whatever was
    /// already flattened into the photo — is keyed by URL, so the copy would
    /// arrive as the untouched original. That is exactly what was reported.
    /// Baking from the original's own render is what makes the copy look
    /// like the photo it was copied from.
    ///
    /// The original is never touched either way; the bake lands on the copy.
    private func duplicatePhotos(_ targets: [URL], blackAndWhite: Bool) {
        guard !targets.isEmpty else {
            return
        }

        var jobs: [PhotoBakeService.BakeJob] = []
        var created: [URL] = []
        var failures = 0

        for target in targets {
            guard let copyURL = PhotoBakeService.duplicate(target,
                                                           suffix: blackAndWhite ? "BW" : "copy") else {
                failures += 1
                continue
            }

            jobs.append(PhotoBakeService.BakeJob(source: target, target: copyURL,
                                                 settings: visibleSettings(for: target)))
            created.append(copyURL)

            // Right after the photo it came from, not at the end of the
            // strip: the two are a pair, and a client who duplicates four
            // photos out of two hundred should not have to scroll to the
            // end to find out whether it worked.
            if let index = photoURLs.firstIndex(of: target) {
                photoURLs.insert(copyURL, at: photoURLs.index(after: index))
            } else {
                photoURLs.append(copyURL)
            }
        }

        if !created.isEmpty {
            // Select what was just made, but do NOT open it. The client is
            // looking at a photo they were working on; moving the preview
            // off it would take that away as a side effect of making a
            // copy — the same reason Select All deliberately leaves
            // selectedURL alone.
            multiSelectedURLs = Set(created)
            selectionAnchor = created.first
        }

        let copyFailures = failures
        runBake(jobs, desaturate: blackAndWhite, busyMessage: "Duplicating…") { done, bakeFailures in
            let total = copyFailures + bakeFailures
            let what = blackAndWhite ? "Duplicated \(done) in B&W" : "Duplicated \(done)"
            showTransientStatus(total == 0 ? what : "\(what), \(total) failed")
        }
    }

    /// Runs a bake and puts the open photo's own state back in step with it.
    private func runBake(_ jobs: [PhotoBakeService.BakeJob], desaturate: Bool,
                         busyMessage: String,
                         completion: @escaping (_ done: Int, _ failed: Int) -> Void) {
        guard !jobs.isEmpty else {
            completion(0, 0)
            return
        }

        let openPhoto = selectedURL

        isFlattening = true
        exportStatusText = busyMessage

        PhotoBakeService.bake(jobs, desaturate: desaturate) { baked, failed in
            isFlattening = false

            // Re-checked rather than remembered: the client can open a
            // different photo while a selection of forty is baking, and
            // `settings` would by then belong to that other photo. Writing
            // the baked result into it would put one photo's settings onto
            // another.
            if let openPhoto, selectedURL == openPhoto, let result = baked[openPhoto] {
                // Everything that was in the settings is in the pixels now,
                // so the panel, the masks, the layers and the undo history
                // all describe a picture that no longer exists. Same
                // clean-up flattenPhoto does, for the same reason.
                settings = result
                pendingCrop = result.crop ?? .full
                selectedLocalAdjustmentID = nil
                activeSelection = nil
                selectedLayerID = nil
                clearRemovalMask()
                undoStack = []
                redoStack = []
                lastCommittedSettings = result
                // The base changed on disk, so the decode has to happen
                // again — nothing in memory describes the baked file.
                loadImages(for: openPhoto)
            }

            completion(baked.count, failed)
        }
    }

    /// What ⌫ deletes: the multi-selection when there is one, otherwise
    /// the photo currently open. In strip order, so the count and the
    /// fallback below both work off the same sequence the client sees.
    private var keyboardDeleteTargets: [URL] {
        if !multiSelectedURLs.isEmpty {
            return photoURLs.filter { multiSelectedURLs.contains($0) }
        }
        if let selectedURL {
            return [selectedURL]
        }
        return []
    }

    /// Moves photos to the macOS Trash and takes them out of the strip.
    ///
    /// The edit records are deliberately NOT cleared. A photo put back from
    /// the Trash lands at the same path with the same size, which is how
    /// `PhotoEditStore` keys its entries — so it comes back with its edits
    /// rather than as a stranger. ShowGrid's own trash does clear labels,
    /// and that difference is on purpose: a label is a decision about a
    /// photo you were sorting, an edit is work.
    private func trashPhotos(_ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }

        // Where the open photo sits BEFORE anything is removed — after the
        // removal that index means a different photo, which is exactly the
        // one that should open next.
        let openIndex = selectedURL.flatMap { photoURLs.firstIndex(of: $0) }

        var removed: Set<URL> = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                removed.insert(url)
            } catch {
                continue
            }
        }

        guard !removed.isEmpty else {
            showTransientStatus("Could not move to the Trash")
            return
        }

        photoURLs.removeAll { removed.contains($0) }
        multiSelectedURLs.subtract(removed)
        for url in removed {
            filmstripThumbnails.removeValue(forKey: url)
        }
        if let anchor = selectionAnchor, removed.contains(anchor) {
            selectionAnchor = nil
        }

        if let current = selectedURL, removed.contains(current) {
            if photoURLs.isEmpty {
                // An editor with nothing to edit is not a state worth
                // drawing. Closing is also what the client is about to do
                // by hand anyway.
                onClose()
                return
            }

            let next = min(openIndex ?? 0, photoURLs.count - 1)
            selectPhoto(photoURLs[next])
        }

        let failed = urls.count - removed.count
        showTransientStatus(failed == 0
                            ? "Moved \(removed.count) to the Trash"
                            : "Moved \(removed.count) to the Trash, \(failed) failed")
    }

    /// A one-line message in the strip's status spot, gone after 1.6 s.
    ///
    /// The same show-then-dismiss the export and sync paths write out by
    /// hand in five other places. Those are left alone here — they sit
    /// inside background completions with their own timing — but the call
    /// sites added in this section share one, rather than becoming four
    /// more copies of it.
    private func showTransientStatus(_ message: String) {
        exportStatusText = message
        let dismissWorkItem = DispatchWorkItem { exportStatusText = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: dismissWorkItem)
    }

    // MARK: Flatten

    /// Bakes the current render into the photo and clears the settings.
    ///
    /// Deliberately a BUTTON the client presses, not something Sync does on its
    /// own: it is the one action here that changes what the photo IS rather
    /// than how it is described, and that should never happen as a side effect
    /// of pressing something else.
    private func flattenPhoto() {
        guard let selectedURL, let fullBaseImage else {
            return
        }
        // The uncropped render, for the same reason layers are stored uncropped:
        // the crop is a description of the photo and survives as a setting, so
        // baking it in would make it impossible to open the crop back up.
        let settingsSnapshot = settings
        let cropToKeep = settings.crop
        let photoAtActionTime = selectedURL

        isFlattening = true
        flattenErrorMessage = nil

        developRenderQueue.async(qos: .userInitiated) {
            let rendered = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage,
                                                    applyCrop: false)
            var failure: String?
            do {
                try FlattenedImageStore.flatten(rendered, settings: settingsSnapshot,
                                                for: photoAtActionTime,
                                                context: briefEditsCIContext)
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                isFlattening = false
                guard selectedURL == photoAtActionTime else {
                    return
                }
                if let failure {
                    flattenErrorMessage = failure
                    return
                }
                // Everything is in the pixels now. The crop is the one thing
                // kept, because it was not baked.
                var cleared = PhotoEditSettings()
                cleared.crop = cropToKeep
                settings = cleared
                pendingCrop = cropToKeep ?? .full
                selectedLocalAdjustmentID = nil
                activeSelection = nil
                selectedLayerID = nil
                clearRemovalMask()
                undoStack = []
                redoStack = []
                lastCommittedSettings = cleared
                PhotoEditStore.setSettings(cleared, for: photoAtActionTime)
                PhotoEditStore.flushNow()
                // The base has changed on disk, so the decode has to happen
                // again — nothing in memory describes the flattened file yet.
                loadImages(for: photoAtActionTime)
            }
        }
    }

    private func unflattenPhoto() {
        guard let selectedURL else {
            return
        }
        let restored = FlattenedImageStore.unflatten(selectedURL)
        let previous = restored ?? PhotoEditSettings()
        settings = previous
        pendingCrop = previous.crop ?? .full
        selectedLocalAdjustmentID = nil
        activeSelection = nil
        selectedLayerID = nil
        clearRemovalMask()
        undoStack = []
        redoStack = []
        lastCommittedSettings = previous
        PhotoEditStore.setSettings(previous, for: selectedURL)
        PhotoEditStore.flushNow()
        loadImages(for: selectedURL)
    }

    /// Is there anything a flatten would actually bake?
    ///
    /// Not `settings.isNeutral`, which counts a crop as an edit. The crop is
    /// deliberately NOT baked (flattenPhoto renders with `applyCrop: false`),
    /// so a photo carrying nothing but a crop has nothing to flatten — and
    /// after a flatten the crop is exactly what is left behind, which would
    /// otherwise leave the button lit up forever offering to bake nothing.
    private var hasUnbakedEdits: Bool {
        var cropOnly = PhotoEditSettings()
        cropOnly.crop = settings.crop
        return settings != cropOnly
    }

    private var flattenSection: some View {
        let isFlattened = selectedURL.map { FlattenedImageStore.isFlattened($0) } ?? false

        return VStack(alignment: .leading, spacing: 8) {
            // Flatten is offered whenever there is anything to bake — INCLUDING
            // on a photo that is already flattened. That case is not an edge
            // case, it is the ordinary way of working: flatten, then clean up
            // something else, and the clean up is a fresh layer of baked pixels
            // sitting outside the tonal chain again, with exactly the defect
            // flattening exists to fix. The panel used to swap the button out
            // for Unflatten the moment a photo was flattened, so the second
            // clean up had no way to be baked at all — reported directly.
            if hasUnbakedEdits {
                panelActionButton(isFlattening
                                    ? "Flattening…"
                                    : (isFlattened ? "Flatten Again" : "Flatten Photo"),
                                  systemImage: "square.stack.3d.down.forward") {
                    flattenPhoto()
                }
                .opacity(isFlattening ? 0.4 : 1)
                .disabled(isFlattening)

                Text(isFlattened
                     ? "Bakes what has been done since the last flatten — an AI Clean Up "
                       + "included — into the photo, so a grade applied afterwards reaches "
                       + "all of it too."
                     : "Bakes the grade, the masks and the AI Clean Up into the photo, "
                       + "so anything applied afterwards — a synced grade included — "
                       + "reaches all of it. Your original file is never touched, and "
                       + "Unflatten puts this back.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isFlattened {
                Text("This photo is flattened. Edits now apply to everything, "
                     + "including the AI Clean Up.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)

                panelActionButton("Unflatten", systemImage: "arrow.uturn.backward") {
                    unflattenPhoto()
                }

                // Said plainly, because Unflatten goes all the way back to the
                // original file however many times the photo has been baked —
                // there is one saved copy, not a stack of them.
                Text("Goes back to the original file and the settings from before "
                     + "the first flatten. Anything done since is discarded.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let flattenErrorMessage {
                Text(flattenErrorMessage)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resetButton: some View {
        panelActionButton("Reset All", systemImage: "arrow.counterclockwise") {
            resetAllSettings()
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
            exportFormatPicker

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
            // Same card the filmstrip's own Export All opens, so the two
            // entry points behave identically rather than one asking and the
            // other silently using whatever the picker above happens to say.
            panelActionButton("Export All Edited (\(editedCount))", systemImage: "square.and.arrow.up.on.square", isProminent: true) {
                showExportAllOptions = true
            }
            .opacity(editedCount == 0 ? 0.4 : 1)
            .disabled(editedCount == 0)
        }
    }

    // The card Export All opens: what kind of file, and how good, decided
    // right before the job runs. It writes the same two @AppStorage values
    // the panel's own picker does, so the choice made here is the choice the
    // panel shows afterwards — one setting, two places to reach it, never
    // two settings that disagree.
    private var exportAllOptionsView: some View {
        let editedCount = photoURLs.filter { PhotoEditStore.hasEdits($0) }.count

        return VStack(alignment: .leading, spacing: 14) {
            Text("Export \(editedCount) edited photo\(editedCount == 1 ? "" : "s")")
                .font(.custom("Figtree", size: 15).weight(.semibold))
                .foregroundColor(AppColors.ink)

            VStack(alignment: .leading, spacing: 8) {
                Text("Format")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)

                exportFormatPicker
            }

            if exportFormat.isLossy {
                VStack(alignment: .leading, spacing: 6) {
                    editSlider("Quality", key: "exportAll.quality",
                               value: $exportQuality, range: 0.4...1.0) {
                        String(format: "%.0f", $0 * 100)
                    }
                    Text("100 is the largest file and the closest to the original; below about 80 the difference starts to show on skin and skies.")
                        .font(.custom("Figtree", size: 10))
                        .foregroundColor(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(exportFormat.title) is lossless — every export is full quality and a much larger file.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Photos with no edits are skipped. You pick one destination folder next.")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    showExportAllOptions = false
                }
                .buttonStyle(ShowHeaderButtonStyle())

                Button("Export") {
                    showExportAllOptions = false
                    // After the sheet is down, not before: the destination
                    // picker is a modal of its own and two modals racing each
                    // other is how a Save panel ends up behind a sheet.
                    DispatchQueue.main.async {
                        exportAllEditedPhotos()
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
                .disabled(editedCount == 0)
                .opacity(editedCount == 0 ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(AppColors.background)
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
        brushCursor.stroke = []
        activePatchDrawPoints.points = []
        patchCursor.stroke = []
        pendingPatchSource = nil
        patchStrokeOffset = nil
        // Same reasoning as selectedLocalAdjustmentID above — a Selection
        // outline or layer index from the PREVIOUS photo has no business
        // surviving onto this one. layerClipboard is deliberately left
        // alone: it's meant to survive a photo switch (that's the whole
        // point of "cut from one photo, paste onto another").
        activeSelection = nil
        activeSelectionDrawPoints.points = []
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
        if renamingPresetID == preset.id {
            cancelPresetRename()
        }
        presets.removeAll { $0.id == preset.id }
        PhotoEditPresetStore.save(presets)
    }

    private func beginPresetRename(_ preset: PhotoEditPreset) {
        renamingPresetID = preset.id
        renamingPresetName = preset.name
    }

    private func cancelPresetRename() {
        renamingPresetID = nil
        renamingPresetName = ""
    }

    /// Renames in place — same id, same settings, so a renamed preset is the
    /// same preset and not a copy of it.
    private func commitPresetRename() {
        defer { cancelPresetRename() }
        guard let id = renamingPresetID,
              let index = presets.firstIndex(where: { $0.id == id }) else {
            return
        }
        let trimmed = renamingPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        presets[index].name = trimmed
        PhotoEditPresetStore.save(presets)
    }

    /// Reads Lightroom / Camera Raw .xmp presets into this app's own list.
    ///
    /// Folders are allowed, and that is not a nicety — preset packs are sold
    /// and shipped as folders of .xmp files, so picking one file at a time out
    /// of a set of forty is not how anyone would use this.
    ///
    /// The result is reported in full, including what did NOT come across. A
    /// Lightroom preset can carry a colour mixer, a tone curve, colour grading
    /// and a camera profile, none of which exist here; importing those in
    /// silence would leave the client comparing this against Lightroom and
    /// finding a difference with nothing to explain it. See
    /// LightroomPresetImport for the mapping itself.
    private func importLightroomPresets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose preset files, or a folder of them. Lightroom / Camera Raw .xmp is supported."
        panel.prompt = "Import"
        if let xmp = UTType(filenameExtension: "xmp") {
            panel.allowedContentTypes = [xmp, .folder]
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }

        let files = panel.urls.flatMap { LightroomPresetImport.presetFiles(under: $0) }
        guard !files.isEmpty else {
            presetImportNotice = "No .xmp presets found there."
            return
        }

        var imported: [PhotoEditPreset] = []
        var failed = 0
        // A set, because forty presets from one pack tend to leave out the same
        // four things and a list would repeat them forty times.
        var missing: Set<String> = []

        for file in files {
            guard let result = try? LightroomPresetImport.read(file) else {
                failed += 1
                continue
            }
            imported.append(result.preset)
            missing.formUnion(result.unsupported)
        }

        guard !imported.isEmpty else {
            presetImportNotice = "Could not read \(files.count == 1 ? "that preset" : "any of those presets")."
            return
        }

        presets.append(contentsOf: imported)
        PhotoEditPresetStore.save(presets)

        var lines = ["Imported \(imported.count) preset\(imported.count == 1 ? "" : "s")."]
        if failed > 0 {
            lines.append("\(failed) could not be read.")
        }
        if !missing.isEmpty {
            lines.append("Not carried over (Create has no equivalent): "
                         + missing.sorted().joined(separator: ", ") + ".")
        }
        presetImportNotice = lines.joined(separator: " ")
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
            // The lock travels with the rectangle. Syncing one without the
            // other is what the client hit: every target got the 4:3 box and
            // none of them knew to hold 4:3 when a handle was dragged.
            result.cropAspect = source.cropAspect
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
            // The mixer is colour work, so it travels with Color rather than
            // getting a checkbox of its own — the dialog is meant to read as
            // the panel with checkboxes, and the mixer sits under Color there.
            result.colorMixer = source.colorMixer
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
        closeAICleanUp()
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
            closeAICleanUp()
        }
        brushCursor.stroke = []
        activePatchDrawPoints.points = []
        patchCursor.stroke = []
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
        activeSelectionDrawPoints.points = []
        selectedLocalAdjustmentID = nil
        selectedLayerID = nil
        isCropping = false
        closeAICleanUp()
    }

    private func deselectSelection() {
        activeSelection = nil
        selectionDragStart = nil
        activeSelectionDrawPoints.points = []
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
                activeSelectionDrawPoints.points = []
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
        closeAICleanUp()
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
            // ⚠️ This one did not even put the brush down, let alone fold the
            // block: picking a layer while the AI brush was live left
            // `removalPaintOverlay` first in the chain, so the layer's frame,
            // handles and rotate knob were not drawn. That is precisely the bug
            // KORAK 106 fixed for Select People, still sitting here on the
            // ordinary way of selecting a layer.
            closeAICleanUp()
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

    private static let cropSectionAnchor = "develop.section.cropRotate"

    private func toggleCropMode() {
        if isCropping {
            commitCrop()
        } else {
            // The ratio buttons live in the Edit tab. Opening the tool from the
            // header while Retouch is showing would scroll a panel that does
            // not contain the section at all, so the tab is switched first.
            panelTab = .edit
            // One runloop turn, so the switch above has actually put the
            // section in the tree before it is asked to scroll to it.
            DispatchQueue.main.async { scrollToCropRequest += 1 }
            pendingCrop = settings.crop ?? .full
            isCropping = true
            selectedLocalAdjustmentID = nil
            activeSelection = nil
            selectedLayerID = nil
            // Restored, not reset. This line WAS `= .free`, and that is the
            // reported bug: a photo synced to 4:3 opened its crop tool with no
            // lock at all, so the first handle drag went free-form.
            //
            // The stored lock wins when there is one. When there is not — and
            // there is not on any photo synced or cropped before 2.09., which
            // is every photo the client already has — the RECTANGLE is asked
            // instead. A photo sitting at a clean 4:3 opens locked to 4:3
            // whether or not anyone ever recorded that, because that is what
            // the client can see on screen.
            //
            // Only when a crop actually exists. An UNCROPPED photo stays Free
            // even if the frame itself happens to be 4:3: there the ratio is
            // the camera's, not a decision anyone made, and locking to it would
            // silently take free-form dragging away from every photo shot on a
            // 4:3 body.
            if settings.cropAspect != .free {
                selectedCropAspectRatio = settings.cropAspect
            } else if let existingCrop = settings.crop {
                selectedCropAspectRatio = inferredCropAspect(from: existingCrop)
            } else {
                selectedCropAspectRatio = .free
            }
            closeAICleanUp()
            scheduleRender()
        }
    }

    private func commitCrop() {
        settings.crop = (pendingCrop == .full) ? nil : pendingCrop
        // Written HERE and not on every ratio-button tap, deliberately: tapping
        // through the row would otherwise write `settings` six times, and an
        // onChange on `settings` re-renders the photograph. The lock is stored
        // at the same moment as the rectangle it produced, which is also the
        // only moment the two can disagree.
        settings.cropAspect = selectedCropAspectRatio
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

        // The angle rides along: picking 4:3 is a decision about SHAPE, and
        // taking the frame's rotation away at the same time would be a second
        // decision nobody asked for. Constrained afterwards because the
        // largest centred rectangle is computed as though the frame were
        // upright, and a turned one needs more room than that.
        pendingCrop = constrainedToImage(
            EditCropRect(
                x: (1 - cropWidthFraction) / 2,
                y: (1 - cropHeightFraction) / 2,
                width: cropWidthFraction,
                height: cropHeightFraction,
                angle: pendingCrop.angle
            )
        )
        cropIsAutoFitted = false
    }

    private func loadImages(for url: URL) {
        isLoadingPreview = true
        fullBaseImage = nil
        previewBaseImage = nil
        refineWorkItem?.cancel()
        refineWorkItem = nil
        displayedImage = nil
        histogramBins = []

        DispatchQueue.global(qos: .userInitiated).async {
            // Off the main thread, before the decode that is about to open the
            // file: a flattened copy written by an older build is LZW and costs
            // ~10 s on its first render. Reads the TIFF header and returns
            // immediately for everything else.
            FlattenedImageStore.upgradeLegacyCompressedFile(for: url)

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
                // The photo is on screen — this is the moment Create is
                // genuinely usable, so it is the moment the opening card comes
                // down. A no-op on every later photo switch, since the card is
                // only up during a launch.
                DevelopLaunchProgress.shared.finish()
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

        developPreviewRenderQueue.async(qos: .userInteractive) {
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
            guard generation == renderGeneration else {
                return
            }
            guard let cgImage = briefEditsDisplayCGImage(rendered, from: rendered.extent,
                                                        context: briefEditsPreviewCIContext) else {
                return
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            // The PICTURE is committed first, on its own, before anything else
            // is computed. It is what the client is waiting for, and nothing
            // secondary gets to hold it up — the histogram did exactly that
            // once and cost the editor its preview entirely.
            DispatchQueue.main.async {
                guard selectedURL == photoAtRenderTime, generation == renderGeneration else {
                    return
                }
                displayedImage = image
                scheduleRefinedRender()
            }

            // Then the histogram, on the same queue, through the same context
            // the picture was rendered with. It arrives a beat later, which is
            // the right trade for a readout beside the photo.
            let bins = PhotoEditRenderer.luminanceHistogram(of: rendered,
                                                            context: briefEditsPreviewCIContext)
            DispatchQueue.main.async {
                guard selectedURL == photoAtRenderTime, generation == renderGeneration else {
                    return
                }
                histogramBins = bins
            }
        }
    }

    // The sharp still, drawn from the ORIGINAL once the edits stop moving.
    //
    // Reported directly, with a side-by-side against Quick Look on the same
    // .NEF: the Develop preview was visibly softer. Two causes, compounding,
    // both in `loadPreviewBaseImage` — that decode is 1600px (upscaled about
    // 2x into a Retina preview area ~3000 physical pixels wide) and uses
    // draft demosaic. Both were chosen so a RAW can be re-rendered at ~20ms
    // cadence mid-drag, which is the right call FOR a drag and the wrong one
    // for a photo sitting still.
    //
    // So the fast preview keeps the drag smooth, and this replaces it with
    // the real thing the moment the client stops: `fullBaseImage`, the same
    // untouched full-resolution decode export renders from. Nothing extra is
    // decoded — and because it is genuinely full resolution, zooming in now
    // shows real detail instead of an enlarged 1600px preview.
    //
    // A DEBOUNCE, unlike renderNow's throttle above, and deliberately: this
    // render is the expensive one, and the only moment it is worth doing is
    // when nothing has changed for a while. Every new edit cancels the
    // pending one, so a slider dragged for ten seconds costs exactly one
    // refine at the end of it rather than one per frame.
    //
    // It shares developRenderQueue with export, the erases and the selection
    // extraction, which matters more than it looks: they all render through
    // the SAME full-resolution CIRAWFilter instance, and PhotoEditRenderer
    // .render pushes Exposure/Temperature/Tint into it. One serial queue is
    // what keeps two of them from writing that filter at the same time.
    //
    // The interactive preview is NOT on this queue — it renders through its
    // own separate filter, so it has its own queue and never has to wait
    // behind one of these. See developPreviewRenderQueue.
    /// True while the client is mid-stroke — painting a patch, a Clean Up
    /// brush, a mask, or drawing a selection outline.
    private var isDrawingStroke: Bool {
        !patchCursor.stroke.isEmpty
            || !brushCursor.stroke.isEmpty
            || !activePatchDrawPoints.points.isEmpty
            || !activeSelectionDrawPoints.points.isEmpty
            // Dragging, resizing or rotating a LAYER counts, for the same
            // reason painting does: a full-resolution refine in the middle of
            // it is work for a frame the client is already dragging away from.
            // A drag that pauses for half a second — which is most careful
            // placements — used to start one.
            //
            // ⚠️ Nothing is lost at the end: every gesture that clears
            // layerDragStart calls scheduleRefinedRender() as it does so, so
            // the sharp frame arrives when the layer is put down. Without that
            // call this guard would leave the photo at preview resolution
            // until some unrelated edit happened to kick a refine.
            || layerDragStart != nil
    }

    private func scheduleRefinedRender() {
        refineWorkItem?.cancel()
        // A refine already sitting on the render queue but not yet started is
        // dropped too. Cancelling only the main-thread timer left those to run
        // — and on the SERIAL render queue a started refine blocks every
        // interactive render behind it, however stale it has become.
        refineQueueWorkItem?.cancel()
        refineQueueWorkItem = nil

        guard let fullBaseImage else {
            return
        }

        // Not while a stroke is being drawn. The refine renders at FULL
        // resolution — for a RAW that is a full-quality demosaic of the whole
        // frame — and the client mid-stroke is looking at their brush, not at
        // per-pixel sharpness.
        guard !isDrawingStroke else {
            return
        }

        // A RAW waits a little longer for silence than a JPEG, because its
        // refine re-demosaics the whole frame rather than re-running a filter
        // chain over an already-decoded image. A run of clicks collapses into
        // ONE refine at the end instead of one per click.
        //
        // This was 1.2s, and that was an over-correction of mine. It was set
        // while chasing a two-minute freeze that looked like refines piling
        // up; the real cause turned out to be every render in the app sharing
        // one CIContext and therefore one lock (see briefEditsPreviewCIContext).
        // With that fixed, a long delay buys nothing and costs the client the
        // sharp frame for over a second after every single change — which is
        // most of what "the photo looks soft while I work on it" was.
        let isRAW: Bool
        switch fullBaseImage {
        case .raw: isRAW = true
        case .standard: isRAW = false
        }

        let work = DispatchWorkItem { refinedRenderNow() }
        refineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isRAW ? 0.45 : 0.3), execute: work)
    }

    private func refinedRenderNow() {
        guard let fullBaseImage else {
            return
        }
        // Not bumped: this render is a REPLACEMENT for whatever the fast
        // path last produced, not a new state. It carries the generation it
        // was scheduled under and is thrown away if anything has changed
        // since — which is what keeps a slow sharp render from ever landing
        // on top of a newer fast one.
        let generation = renderGeneration
        let effectiveSettings = showOriginal ? PhotoEditSettings() : settings
        let cropEnabled = !isCropping
        let photoAtRenderTime = selectedURL

        // Held so a later edit can cancel this before it starts. `isCancelled`
        // is then checked again after the render, because the expensive part
        // cannot be interrupted once it is under way — the check cannot save
        // the work, but it does stop a stale sharp frame from replacing a
        // newer fast one.
        let work = DispatchWorkItem(qos: .utility) { [self] in
            guard generation == renderGeneration else {
                return
            }
            let rendered = PhotoEditRenderer.render(effectiveSettings, on: fullBaseImage, applyCrop: cropEnabled)
            guard generation == renderGeneration,
                  let cgImage = briefEditsDisplayCGImage(rendered, from: rendered.extent,
                                                         context: briefEditsCIContext) else {
                return
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            DispatchQueue.main.async {
                guard selectedURL == photoAtRenderTime, generation == renderGeneration else {
                    return
                }
                // Histogram deliberately not recomputed: it was measured on
                // the same edits a moment ago and would be identical, and
                // this path is meant to change what the picture LOOKS like,
                // nothing else.
                displayedImage = image
                refineQueueWorkItem = nil
            }
        }
        refineQueueWorkItem = work
        developRenderQueue.async(execute: work)
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
        // Exported anyway, and SAID so — decided 1.09. Pressing Export with one
        // named photo open is a statement of intent, not an oversight, and
        // refusing would mean un-rejecting a photo just to get one file out.
        // The bulk exports still skip rejected photos without asking.
        if PhotoLabelStore.isRejected(selectedURL) {
            panel.message = "This photo is marked rejected. Exporting it anyway."
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let settingsSnapshot = settings
        exportStatusText = "Exporting…"

        developRenderQueue.async(qos: .userInitiated) {
            let rendered = PhotoEditRenderer.render(settingsSnapshot, on: fullBaseImage)
            var didWrite = false

            if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent,
                                                              format: format.renderFormat,
                                                              colorSpace: briefEditsSRGBColorSpace) {
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
        // Same single-photo rule as exportEditedCopy: one named photo, asked
        // for by name, goes out with a warning rather than being refused.
        if PhotoLabelStore.isRejected(url) {
            panel.message = "This photo is marked rejected. Exporting it anyway."
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let settingsForPhoto = PhotoEditStore.settings(for: url)
        exportStatusText = "Exporting…"

        developRenderQueue.async(qos: .userInitiated) {
            var didWrite = false

            if let base = PhotoEditRenderer.loadBaseImage(from: url) {
                let rendered = PhotoEditRenderer.render(settingsForPhoto, on: base)
                if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent,
                                                                  format: format.renderFormat,
                                                                  colorSpace: briefEditsSRGBColorSpace) {
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

    /// Marks or unmarks the filmstrip's current photos as rejected.
    ///
    /// The same flag ShowGrid's X sets — one store, so a photo rejected while
    /// reviewing the grid is still rejected here, and the bulk exports below
    /// skip it either way.
    ///
    /// Acts on the multi-selection when there is one, otherwise on the photo
    /// that is open. That is the same target rule the rest of this window uses
    /// for anything that acts on "the photos I mean".
    private func toggleRejectedForFilmstripSelection() {
        let targets = multiSelectedURLs.isEmpty
            ? [selectedURL].compactMap { $0 }
            : photoURLs.filter { multiSelectedURLs.contains($0) }
        guard !targets.isEmpty else { return }

        // One decision for the whole set, taken from the first photo, so a
        // mixed selection is brought together rather than inverted photo by
        // photo — the same rule cycleRating uses in ShowGrid.
        let shouldReject = !rejectedURLs.contains(targets[0])
        for url in targets {
            if shouldReject {
                rejectedURLs.insert(url)
            } else {
                rejectedURLs.remove(url)
            }
            PhotoLabelStore.setRejected(shouldReject, for: url)
        }
    }

    private func reloadRejectedFlags() {
        rejectedURLs = Set(photoURLs.filter { PhotoLabelStore.isRejected($0) })
    }

    /// Drops rejected photos out of a bulk export, and says how many went.
    ///
    /// Bulk only. A client who presses Export with ONE photo open and that
    /// photo rejected gets it exported anyway, with a warning — decided 1.09.:
    /// pressing export on a single named photo is a statement of intent, not
    /// an oversight, and refusing it would mean un-rejecting a photo just to
    /// get one file out. That case is handled at its own call site, not here.
    private func withoutRejected(_ urls: [URL]) -> (kept: [URL], skipped: Int) {
        let kept = urls.filter { !PhotoLabelStore.isRejected($0) }
        return (kept, urls.count - kept.count)
    }

    /// The one line the export panel adds when photos are being left out.
    private func rejectedSkipNotice(_ skipped: Int) -> String {
        skipped == 0
            ? ""
            : "\n\n\(skipped) rejected photo\(skipped == 1 ? " is" : "s are") being skipped."
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
        // Filtered BEFORE the panel opens, so the count in its message is the
        // count of files the client will actually find in the folder.
        let (urls, skippedRejected) = withoutRejected(urls)
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
            + rejectedSkipNotice(skippedRejected)

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
                    if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent,
                                                                      format: format.renderFormat,
                                                                      colorSpace: briefEditsSRGBColorSpace) {
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
        let (editedURLs, skippedRejected) =
            withoutRejected(photoURLs.filter { PhotoEditStore.hasEdits($0) })
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
            + rejectedSkipNotice(skippedRejected)

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
                    if let cgImage = briefEditsCIContext.createCGImage(rendered, from: rendered.extent,
                                                                      format: format.renderFormat,
                                                                      colorSpace: briefEditsSRGBColorSpace) {
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
// The panel's own slider, in place of SwiftUI's, for one reason: a stock
// macOS Slider fills its track from the LEFT edge to the thumb, so an
// untouched Exposure or Contrast sits at the centre looking half-applied,
// and there is no visual difference between "0" and "somewhere in the
// middle of the range". Lightroom anchors the fill at ZERO and grows it
// outward — left of centre is negative, right is positive, and a
// neutral photo shows a bare track everywhere.
//
// The anchor is derived, not configured: it is wherever 0 falls inside the
// range, which puts it at the centre for the -1...1 controls and at the far
// left for the genuinely one-directional ones (Sharpness, sizes, opacities,
// Quality), so both kinds get the right behaviour from the same view.
/// Where a slider's thumb goes while it is being dragged.
///
/// ⚠️ Pulled out of the two slider views because it was WRONG in both, in the
/// same way, and because it is the kind of thing that has to be measurable:
/// see Tools/run-slider-drag-test.py.
///
/// The bug it fixes, reported as *„kada pomerim expose da ne skoči odma baš
/// expose"*: both sliders set their value from the ABSOLUTE press position —
/// `value = lowerBound + (location.x / usable) * span` — so pressing anywhere
/// on the track teleported the thumb under the pointer. On Exposure that is
/// brutal: the track is about 270pt for a ±3 EV span, so a press 60pt to the
/// right of centre was an instant **+1.37 EV**, before the pointer had moved at
/// all. Nothing was wrong with the exposure maths — measured on the client's
/// own C4S_5744.NEF, +0.05 EV moves the picture by 0.6% — the slider was
/// handing it a number he never asked for.
///
/// What it does now:
///
/// - **A press that lands ON the thumb does not move it.** The drag is
///   measured from where it was grabbed, so a 3pt nudge is a 3pt nudge.
/// - **A press on the empty track still jumps there**, which is what a track
///   is for and what Lightroom does — but from then on that press behaves like
///   a grab, so the rest of the drag is relative too.
enum EditSliderDrag {
    struct Grab {
        var startValue: Double
        var startX: CGFloat
    }

    /// The generous half-width, in points, within which a press counts as
    /// having landed on the thumb. A little wider than the thumb itself: the
    /// whole point is that grabbing it must be easy, and being one pixel out
    /// should not cost a jump.
    static let grabSlack: CGFloat = 4

    static func begin(pressX: CGFloat, thumbX: CGFloat, thumbSize: CGFloat,
                      usable: CGFloat, range: ClosedRange<Double>,
                      value: Double) -> Grab {
        let thumbCentre = thumbX + thumbSize / 2
        if abs(pressX - thumbCentre) <= thumbSize / 2 + grabSlack {
            return Grab(startValue: value, startX: pressX)
        }
        return Grab(startValue: valueAt(pressX, thumbSize: thumbSize, usable: usable, range: range),
                    startX: pressX)
    }

    /// Absolute mapping — used only for the jump on a press that misses the
    /// thumb, never while dragging.
    static func valueAt(_ pressX: CGFloat, thumbSize: CGFloat,
                        usable: CGFloat, range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        let x = min(max(pressX - thumbSize / 2, 0), usable)
        return range.lowerBound + Double(x / usable) * span
    }

    /// Relative mapping — every event after the press, including the press
    /// itself once `begin` has decided where it started from.
    static func value(at x: CGFloat, grab: Grab, usable: CGFloat,
                      range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        let moved = Double((x - grab.startX) / usable) * span
        return min(max(grab.startValue + moved, range.lowerBound), range.upperBound)
    }
}

private struct EditTrackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accent: Color
    var onEditingChanged: (Bool) -> Void = { _ in }

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 16
    private let rowHeight: CGFloat = 20

    // Eight intervals, so seven marks. Chosen so the CENTRE falls on one of
    // them: every bipolar slider in this panel has its zero at the middle, and
    // a tick spacing that straddled it would put the zero marker between two
    // marks and make the track look mis-drawn.
    private let tickIntervals = 8

    /// Where this drag started, or nil when no drag is in flight. See
    /// EditSliderDrag for what it is for.
    @State private var grab: EditSliderDrag.Grab?

    var body: some View {
        GeometryReader { proxy in
            // The thumb's LEADING edge travels across (width - thumbSize),
            // so its CENTRE stays inside the track at both ends instead of
            // hanging half-off — hence every conversion below goes through
            // `usable` and offsets by half a thumb.
            let usable = max(proxy.size.width - thumbSize, 1)
            let span = range.upperBound - range.lowerBound
            let clamped = min(max(span > 0 ? (value - range.lowerBound) / span : 0, 0), 1)
            // Clamped into the range so a slider that never reaches zero
            // (Feather starts at patchMinimumFeather) anchors at its own
            // lower bound rather than off the end of the track.
            let zero = min(max(0, range.lowerBound), range.upperBound)
            let zeroFraction = span > 0 ? (zero - range.lowerBound) / span : 0
            let thumbX = usable * CGFloat(clamped)
            let zeroX = usable * CGFloat(zeroFraction)
            let isBipolar = zeroFraction > 0.001 && zeroFraction < 0.999

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.ink.opacity(0.12))
                    .frame(height: trackHeight)
                    .overlay(
                        Capsule()
                            .stroke(AppColors.ink.opacity(0.18), lineWidth: 0.5)
                    )

                // Taller than the track on purpose: the fill runs straight
                // over the middle of it, and the ends sticking out above and
                // below are what keep "where is zero" readable at any value.
                if isBipolar {
                    Rectangle()
                        .fill(AppColors.ink.opacity(0.35))
                        .frame(width: 1, height: trackHeight + 6)
                        .offset(x: zeroX + thumbSize / 2 - 0.5)
                }

                Capsule()
                    .fill(accent)
                    .frame(width: abs(thumbX - zeroX), height: trackHeight)
                    .offset(x: min(thumbX, zeroX) + thumbSize / 2)

                // Lightroom's tick marks, on request. They do the one thing a
                // bare track cannot: give the thumb something to be measured
                // against, so "a bit more" becomes a distance you can see
                // rather than a number you have to read off the end of the row.
                //
                // Interior only — a tick sitting on the capsule's rounded end
                // reads as a chip out of the track, not as a mark. Drawn AFTER
                // the fill so they stay visible along the whole track the way
                // Lightroom's do, instead of being swallowed by it as soon as
                // the slider is pushed away from zero.
                ForEach(1..<tickIntervals, id: \.self) { index in
                    let fraction = CGFloat(index) / CGFloat(tickIntervals)
                    // The centre tick is skipped on a bipolar slider: the zero
                    // marker above is already there and is deliberately taller,
                    // and two marks in one place would flatten that difference.
                    if !(isBipolar && abs(fraction - CGFloat(zeroFraction)) < 0.001) {
                        Rectangle()
                            .fill(AppColors.ink.opacity(0.22))
                            .frame(width: 1, height: trackHeight - 2)
                            .offset(x: usable * fraction + thumbSize / 2 - 0.5)
                    }
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle()
                            .stroke(AppColors.ink.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: thumbX)
            }
            .frame(width: proxy.size.width, height: rowHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onEditingChanged(true)
                        let grab = self.grab ?? EditSliderDrag.begin(
                            pressX: drag.startLocation.x, thumbX: thumbX,
                            thumbSize: thumbSize, usable: usable, range: range, value: value)
                        self.grab = grab
                        value = EditSliderDrag.value(at: drag.location.x, grab: grab,
                                                     usable: usable, range: range)
                    }
                    .onEnded { _ in
                        grab = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: rowHeight)
        // A hand-drawn control is invisible to the accessibility tree, and
        // AXIncrement/AXDecrement on these sliders is the ONE reliable way
        // this app's panel can be driven in a scripted test (clicking a
        // slider does not work — see BRIEFSHOW_DEVELOP_NOTES.md). Declaring
        // it adjustable hands that back.
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { direction in
            let delta = (step > 0 ? step : 0.01) * (direction == .increment ? 1 : -1)
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        }
    }
}

private struct GradientTrackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let gradient: LinearGradient
    var onEditingChanged: (Bool) -> Void = { _ in }

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 16
    private let rowHeight: CGFloat = 20

    // Same spacing as EditTrackSlider's, and it has to be the same: these
    // sliders sit in one column with those, and two tick rhythms down one
    // panel would read as a mistake rather than as a distinction.
    private let tickIntervals = 8

    /// Where this drag started, or nil when no drag is in flight. See
    /// EditSliderDrag for what it is for.
    @State private var grab: EditSliderDrag.Grab?

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
            let zero = min(max(0, range.lowerBound), range.upperBound)
            let zeroFraction = span > 0 ? (zero - range.lowerBound) / span : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(gradient)
                    .frame(height: trackHeight)
                    .overlay(
                        Capsule()
                            .stroke(AppColors.ink.opacity(0.18), lineWidth: 0.5)
                    )

                // These four (Temperature, Tint, Saturation, Vibrance) are
                // bipolar too, and their gradient track leaves no room for a
                // fill to say so — so the notch that marks zero is the only
                // thing that can, and it is the same notch the plain sliders
                // draw in EditTrackSlider.
                let isBipolar = zeroFraction > 0.001 && zeroFraction < 0.999
                if isBipolar {
                    Rectangle()
                        .fill(AppColors.ink.opacity(0.35))
                        .frame(width: 1, height: trackHeight + 6)
                        .offset(x: usable * CGFloat(zeroFraction) + thumbSize / 2 - 0.5)
                }

                // The same tick marks the plain sliders got. A little stronger
                // here than the 0.22 used there, because these run over a
                // colour gradient rather than a flat track and the lighter
                // stops (the yellow end of Temperature) would otherwise swallow
                // them.
                ForEach(1..<tickIntervals, id: \.self) { index in
                    let tickFraction = CGFloat(index) / CGFloat(tickIntervals)
                    if !(isBipolar && abs(tickFraction - CGFloat(zeroFraction)) < 0.001) {
                        Rectangle()
                            .fill(AppColors.ink.opacity(0.28))
                            .frame(width: 1, height: trackHeight - 2)
                            .offset(x: usable * tickFraction + thumbSize / 2 - 0.5)
                    }
                }

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
                        let grab = self.grab ?? EditSliderDrag.begin(
                            pressX: drag.startLocation.x, thumbX: usable * CGFloat(clamped),
                            thumbSize: thumbSize, usable: usable, range: range, value: value)
                        self.grab = grab
                        value = EditSliderDrag.value(at: drag.location.x, grab: grab,
                                                     usable: usable, range: range)
                    }
                    .onEnded { _ in
                        grab = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: rowHeight)
        // Same reason as EditTrackSlider: hand-drawn controls are invisible
        // to the accessibility tree, and AXIncrement/AXDecrement is how these
        // sliders get driven in a scripted test.
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { direction in
            let delta = (step > 0 ? step : 0.01) * (direction == .increment ? 1 : -1)
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        }
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
