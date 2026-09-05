//
//  DevelopLightroomPreset.swift
//  BriefShow
//
//  Reading Lightroom / Camera Raw presets (.xmp) into LumenoLab's own
//  PhotoEditSettings.
//
//  What this is NOT: a Lightroom-compatible renderer. Adobe's sliders sit on
//  top of a colour pipeline this app does not have, and a good half of what a
//  .xmp can carry — the colour mixer, the tone curve, colour grading, the
//  camera profile — has no dial here at all. So an imported preset is an
//  APPROXIMATION of the look, built from the controls that do line up, and the
//  import says out loud which parts of the file it had to leave behind rather
//  than importing them silently and letting the client wonder why it looks
//  different from Lightroom.
//

import Foundation
import UniformTypeIdentifiers

extension ColorBand {
    /// The word Adobe puts on the end of HueAdjustment / SaturationAdjustment /
    /// LuminanceAdjustment. Identical to this app's own names, which is not a
    /// coincidence — the bands were built from Adobe's.
    var adobeSuffix: String { title }
}

enum LightroomPresetImport {

    struct Result {
        var preset: PhotoEditPreset
        /// Parts of the file this app has no equivalent for, in words the
        /// client would recognise from Lightroom's own panel.
        var unsupported: [String]
    }

    enum Failure: LocalizedError {
        case unreadable
        case notAPreset

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "The file could not be read as XMP."
            case .notAPreset:
                return "No preset settings in this file."
            }
        }
    }

    // MARK: Reading

    static func read(_ url: URL) throws -> Result {
        guard let data = try? Data(contentsOf: url) else {
            throw Failure.unreadable
        }
        let parser = XMPParser()
        guard parser.parse(data) else {
            throw Failure.unreadable
        }
        guard !parser.values.isEmpty else {
            throw Failure.notAPreset
        }

        let name = parser.presetName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = url.deletingPathExtension().lastPathComponent
        let settings = settings(from: parser.values)

        return Result(
            preset: PhotoEditPreset(
                id: UUID(),
                name: (name?.isEmpty == false ? name! : fallback),
                settings: settings
            ),
            unsupported: unsupportedParts(in: parser)
        )
    }

    /// Every .xmp under `url` — the file itself, or the whole folder when a
    /// folder is chosen, because preset packs ship as folders.
    static func presetFiles(under url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            return url.pathExtension.lowercased() == "xmp" ? [url] : []
        }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "xmp" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Mapping

    /// Lightroom's numbers into this app's.
    ///
    /// Most are a plain divide by 100 — Adobe runs -100...100 where this runs
    /// -1...1 — and the ones that are not are the interesting part:
    ///
    /// **Highlights is inverted.** In Lightroom, positive Highlights makes
    /// highlights BRIGHTER and negative recovers them. Here it is the other way
    /// round: `render` builds the tone curve with `0.75 - highlights`, so
    /// positive darkens. That sign was kept once already for the sake of photos
    /// edited under an older build, so the import flips instead. A preset that
    /// recovers highlights at -77 has to arrive here as +0.77 or it would blow
    /// them out instead.
    ///
    /// **Vignette is inverted too**, for the same kind of reason: Lightroom's
    /// Post-Crop Vignetting is negative to darken the corners, this app's
    /// `vignette` is positive to darken them.
    ///
    /// **White balance is relative, not absolute.** Lightroom stores Kelvin
    /// (6339 K); this app stores an OFFSET from the photo's own as-shot white
    /// balance, scaled so that 1.0 is 3000 K (see `render`'s
    /// `asShotTemperature + temperature * 3000`). The preset carries the as-shot
    /// value of the photo it was made from, so the offset the photographer
    /// actually dialled in is the difference between the two — and an offset is
    /// the right thing to carry to a different photo anyway. An absolute Kelvin
    /// cannot be expressed here at all.
    ///
    /// **Sharpening is read against Lightroom's default, not against zero.**
    /// Lightroom starts every RAW at Sharpness 40, so 40 in a preset means "I
    /// left sharpening alone". Importing that as 0.4 here would sharpen a photo
    /// nobody asked to sharpen, so the default is subtracted first.
    private static func settings(from values: [String: String]) -> PhotoEditSettings {
        var s = PhotoEditSettings()

        func number(_ key: String) -> Double? {
            guard let raw = values[key] else { return nil }
            // "+70", "-0.10", "25" — Adobe signs its positives.
            return Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "+ ")))
                ?? Double(raw.trimmingCharacters(in: .whitespaces))
        }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        func hundredths(_ key: String, invert: Bool = false) -> Double? {
            guard let v = number(key) else { return nil }
            return clamp((invert ? -v : v) / 100, -1, 1)
        }

        // Exposure is already in EV in both.
        if let v = number("Exposure2012") { s.exposure = clamp(v, -3, 3) }

        if let v = hundredths("Contrast2012") { s.contrast = v }
        // No longer inverted: since 05.09.2026 this app's Highlights carries
        // Lightroom's own sign, so -77 in the file is -0.77 here and the
        // slider shows the same -77 the photographer set in Lightroom.
        if let v = hundredths("Highlights2012") { s.highlights = v }
        if let v = hundredths("Shadows2012") { s.shadows = v }
        if let v = hundredths("Whites2012") { s.whites = v }
        if let v = hundredths("Blacks2012") { s.blacks = v }
        if let v = hundredths("Saturation") { s.saturation = v }

        // The Colour Mixer, all twenty-four of them.
        //
        // Adobe names the bands the same way this app does, so the only work is
        // the divide by 100 — and the band centres were copied from Adobe when
        // ColorBand was written precisely so that "Yellow" here means the same
        // wedge of the hue wheel it meant there.
        for band in ColorBand.allCases {
            let adobe = band.adobeSuffix
            var mixed = ColorMixerBand()
            if let v = hundredths("HueAdjustment" + adobe) { mixed.hue = v }
            if let v = hundredths("SaturationAdjustment" + adobe) { mixed.saturation = v }
            if let v = hundredths("LuminanceAdjustment" + adobe) { mixed.luminance = v }
            s.colorMixer[band] = mixed
        }

        // A black & white preset comes across as black & white.
        //
        // Lightroom builds its greyscale from the B&W mixer — eight per-colour
        // weights this app has no dial for — so this cannot match it channel
        // for channel. But the choice is not "exact greyscale or approximate
        // greyscale", it is "greyscale or COLOUR", and a monochrome look
        // arriving in full colour is not an approximation of anything. Full
        // desaturation wins on every axis that matters, and the report says
        // the mixing is what was lost.
        if values["ConvertToGrayscale"]?.caseInsensitiveCompare("true") == .orderedSame {
            s.saturation = -1
        }
        if let v = hundredths("Vibrance") { s.vibrance = v }
        if let v = hundredths("Texture") { s.texture = v }
        if let v = hundredths("Clarity2012") { s.clarity = v }
        if let v = hundredths("Dehaze") { s.dehaze = v }
        if let v = hundredths("PostCropVignetteAmount", invert: true) { s.vignette = v }

        // The vignette's SHAPE, and this part is a straight copy because the
        // fields were given Lightroom's own defaults when they were added:
        // midpoint 50, feather 50, roundness 0 mean the same thing on both
        // sides, so there is no baseline to subtract and no sign to flip.
        if let v = number("PostCropVignetteMidpoint") {
            s.vignetteMidpoint = clamp(v / 100, 0, 1)
        }
        if let v = number("PostCropVignetteFeather") {
            s.vignetteFeather = clamp(v / 100, 0, 1)
        }
        if let v = number("PostCropVignetteRoundness") {
            s.vignetteRoundness = clamp(v / 100, -1, 1)
        }

        // Sharpening radius, in the same 0.5...3 Lightroom uses.
        if let v = number("SharpenRadius") {
            s.sharpenRadius = clamp(v, 0.5, 3)
        }

        // Sharpening. This USED to subtract Lightroom's RAW default of 40 first,
        // on the reasoning that a preset carrying 40 is a preset that never
        // touched the slider and should therefore sharpen nothing.
        //
        // ⚠️ That reasoning was about the PRESET; the client is looking at the
        // PICTURE. Lightroom applies that default when it renders a RAW and it
        // is in the exported JPEG, so importing it as zero is what made our
        // render read softer than his. He said it plainly: the export is
        // *„više svetlija više čistija"*.
        //
        // The scale is measured, not converted. Mean absolute Laplacian of luma
        // against his Lightroom export, whose own figure is 7.96:
        //
        //     ours, no sharpening    4.65
        //     Sharpness 40 as 0.10   7.41
        //     Sharpness 40 as 0.15   7.92   <- taken
        //     Sharpness 40 as 0.20   8.43
        //     Sharpness 40 as 0.36   10.02  (what a plain /110 would give)
        //
        // ⚠️ This RAISES the RMS against the export, 13.36 to 14.79, while making
        // the picture right. Sharpening moves every edge and a difference metric
        // charges for that whichever way it moves. Here the eye and the
        // Laplacian agree and the RMS is the one that is wrong.
        if let v = number("Sharpness") {
            s.sharpness = clamp(v / lightroomSharpnessDivisor, 0, 1)
        }

        // White balance, only when the preset actually sets one. "As Shot"
        // means "leave this photo's own white balance alone", which is exactly
        // what a temperature of 0 does here.
        let whiteBalance = values["WhiteBalance"] ?? ""
        if whiteBalance.caseInsensitiveCompare("As Shot") != .orderedSame {
            // ⚠️ Kept as an ABSOLUTE, not as an offset, and that is the fix for
            // a 351 K miss the client could read off the panel. The preset
            // carries ADOBE'S as-shot for the photo it was made from (5,350 K
            // on his NEF); Core Image reads 4,999 K off the same file. Carrying
            // Adobe's offset therefore landed on 5,988 K where Lightroom sits
            // at 6,339 K. A preset that names a Kelvin means that Kelvin.
            //
            // The offset is still filled in beside it, so the slider's thumb
            // has somewhere to sit and so an older build — which knows nothing
            // of the absolute — still renders approximately the same look.
            if let kelvin = number("Temperature") {
                let absolute = clamp(kelvin, 2000, 50000)
                s.temperatureKelvin = absolute
                let baseline = number("AsShotTemperature") ?? assumedAsShotKelvin
                s.temperature = clamp((absolute - baseline) / 3000, -1, 1)
            }
            if let tint = number("Tint") {
                let absolute = clamp(tint, -150, 150)
                s.tintAbsolute = absolute
                let baseline = number("AsShotTint") ?? 0
                s.tint = clamp((absolute - baseline) / 100, -1, 1)
            }
        }

        return s
    }

    static let lightroomDefaultSharpness: Double = 40

    /// Lightroom's Sharpness 40 renders like 0.15 here. Measured against the
    /// client's own export, not converted from the slider ranges — see the
    /// table where it is used.
    static let lightroomSharpnessDivisor: Double = 265
    static let assumedAsShotKelvin: Double = 5500

    // MARK: What could not come across

    /// Lightroom writes every control into a preset, set or not — so "not
    /// zero" is the wrong test for "the photographer used this".
    ///
    /// Caught on the first real file: it was reporting Colour Grading, Noise
    /// Reduction and Sharpening detail as lost, when all three were sitting at
    /// Adobe's own defaults — `ColorGradeBlending` is 50 out of the box,
    /// `ColorNoiseReduction` is 25 on every RAW, `SharpenDetail` is 25. A list
    /// of things that were never there teaches the client to stop reading the
    /// list, which costs more than saying nothing would.
    ///
    /// So each control is compared against its DEFAULT, and only the ones that
    /// moved are reported. Anything not named here defaults to 0.
    private static let lightroomDefaults: [String: Double] = [
        "ColorGradeBlending": 50,
        "ColorNoiseReduction": 25,
        "ColorNoiseReductionDetail": 50,
        "ColorNoiseReductionSmoothness": 50,
        "SharpenRadius": 1.0,
        "SharpenDetail": 25,
        "PostCropVignetteMidpoint": 50,
        "PostCropVignetteFeather": 50,
        // 1 is Highlight Priority, Lightroom's own default.
        "PostCropVignetteStyle": 1,
        "PerspectiveScale": 100,
        "DefringePurpleHueLo": 30,
        "DefringePurpleHueHi": 70,
        "DefringeGreenHueLo": 40,
        "DefringeGreenHueHi": 60,
        "ParametricShadowSplit": 25,
        "ParametricMidtoneSplit": 50,
        "ParametricHighlightSplit": 75
    ]

    /// Named the way Lightroom's own panel names them, so the client can look
    /// at the preset in Lightroom and see exactly what is missing here.
    private static func unsupportedParts(in parser: XMPParser) -> [String] {
        let values = parser.values
        var parts: [String] = []

        func number(_ key: String) -> Double {
            Double(values[key]?.trimmingCharacters(in: CharacterSet(charactersIn: "+ ")) ?? "") ?? 0
        }
        /// True when the control is present AND away from its default.
        func moved(_ key: String) -> Bool {
            guard values[key] != nil else { return false }
            return number(key) != (lightroomDefaults[key] ?? 0)
        }
        func anyMoved(_ prefixes: [String]) -> Bool {
            values.keys.contains { key in
                prefixes.contains { key.hasPrefix($0) } && moved(key)
            }
        }

        if values["ConvertToGrayscale"]?.caseInsensitiveCompare("true") == .orderedSame {
            // The conversion itself DOES come across, as full desaturation —
            // see `settings(from:)`. What cannot is how Lightroom weighted the
            // colours on the way to grey.
            parts.append("Black & White channel mixing (imported as plain desaturation)")
        }
        if parser.hasNonLinearToneCurve {
            parts.append("Tone Curve")
        }
        if anyMoved(["SplitToning", "ColorGrade"]) {
            parts.append("Colour Grading / Split Toning")
        }
        if moved("GrainAmount") {
            parts.append("Grain")
        }
        if moved("LuminanceSmoothing") || moved("ColorNoiseReduction") {
            parts.append("Noise Reduction")
        }
        // Radius comes across now; Detail and Masking still have no dial here.
        if moved("SharpenDetail") || moved("SharpenEdgeMasking") {
            parts.append("Sharpening Detail and Masking")
        }
        if values["LensProfileEnable"] == "1" || moved("AutoLateralCA")
            || moved("DefringePurpleAmount") || moved("DefringeGreenAmount") {
            parts.append("Lens Corrections")
        }
        if anyMoved(["Perspective"]) {
            parts.append("Transform")
        }
        if anyMoved(["ParametricShadows", "ParametricDarks",
                     "ParametricLights", "ParametricHighlights"]) {
            parts.append("Parametric Tone Curve")
        }
        // A profile is not a slider — it is the colour rendering everything
        // else sits on — so it is the one most worth naming. Adobe Color and
        // Adobe Standard are the defaults and are not worth mentioning.
        if let look = parser.lookName,
           !["Adobe Color", "Adobe Standard", "Adobe Monochrome"].contains(look) {
            parts.append("Profile “\(look)”")
        }
        // The vignette's midpoint, feather and roundness now come across. Its
        // STYLE does not: Lightroom offers Highlight Priority / Colour Priority
        // / Paint Overlay, which are three different ways of mixing the
        // darkening with the picture, and this app has the one.
        if moved("PostCropVignetteAmount"), moved("PostCropVignetteStyle") {
            parts.append("Vignette style (Highlight / Colour Priority)")
        }

        return parts
    }
}

// MARK: - The XML side

/// Pulls the `crs:` values out of an XMP file.
///
/// Two shapes have to be handled, because both are written in the wild: the
/// settings as ATTRIBUTES on `rdf:Description` (what Lightroom Classic writes,
/// and what the file this was built against uses) and the same settings as
/// child ELEMENTS. Namespace processing is deliberately left OFF so element
/// names arrive prefixed — `crs:Exposure2012` — which is what makes them
/// telling apart from `rdf:` and `x:` a matter of reading the name.
/// Writing this app's presets back out as Camera Raw `.xmp`.
///
/// The mirror of LightroomPresetImport, and deliberately the same numbers read
/// backwards: every scale, sign and baseline below is the inverse of one there.
/// A preset exported here and imported back must come out identical, and
/// Tools/run-preset-export-test.py runs exactly that round trip rather than
/// leaving it to be believed.
///
/// **What does NOT go into the file, because Lightroom has nowhere to put it:**
/// the crop rectangle and its locked ratio, rotation and straightening, masks
/// (local adjustments), pasted layers, and `softGlow` — which is this app's
/// own control with no Camera Raw equivalent. Those are all per-PHOTOGRAPH
/// work rather than a look, apart from softGlow, which is named in the
/// exporter's own report so nobody has to discover it by comparing renders.
enum LightroomPresetExport {

    /// Everything an exported preset could not carry, in words that match the
    /// panel the client is looking at.
    static func unsupportedParts(of settings: PhotoEditSettings) -> [String] {
        var parts: [String] = []
        if settings.softGlow != 0 { parts.append("Soft Glow") }
        if settings.crop != nil { parts.append("Crop") }
        if settings.rotationQuarterTurns != 0 || settings.straightenDegrees != 0 {
            parts.append("Rotation / Straighten")
        }
        if !settings.localAdjustments.isEmpty { parts.append("Masks") }
        if !settings.layers.isEmpty { parts.append("Layers") }
        return parts
    }

    /// A file name that survives a file system: the preset's own name, with the
    /// characters a path cannot hold replaced.
    static func fileName(for preset: PhotoEditPreset) -> String {
        let cleaned = preset.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Preset" : cleaned) + ".xmp"
    }

    static func write(_ preset: PhotoEditPreset, to url: URL) throws {
        try xmp(for: preset).data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func xmp(for preset: PhotoEditPreset) -> String {
        let s = preset.settings
        var attributes: [(String, String)] = []

        func put(_ key: String, _ value: String) { attributes.append((key, value)) }
        /// Adobe writes its whole numbers signed, and reads them either way —
        /// this matches the files it writes so a diff against one is readable.
        func whole(_ key: String, _ value: Double) {
            let n = Int(value.rounded())
            put(key, n > 0 ? "+\(n)" : "\(n)")
        }
        func hundredths(_ key: String, _ value: Double, invert: Bool = false) {
            whole(key, (invert ? -value : value) * 100)
        }

        put("crs:PresetType", "Normal")
        put("crs:Cluster", "")
        put("crs:UUID", preset.id.uuidString.replacingOccurrences(of: "-", with: ""))
        put("crs:SupportsAmount", "False")
        put("crs:SupportsColor", "True")
        put("crs:SupportsMonochrome", "True")
        put("crs:SupportsHighDynamicRange", "True")
        put("crs:SupportsNormalDynamicRange", "True")
        put("crs:SupportsSceneReferred", "True")
        put("crs:SupportsOutputReferred", "True")
        put("crs:CameraModelRestriction", "")
        put("crs:Copyright", "")
        put("crs:ContactInfo", "")
        put("crs:Version", exportedVersion)
        put("crs:ProcessVersion", exportedProcessVersion)

        // White balance. An absolute Kelvin is written as itself; otherwise the
        // offset is turned back into a Kelvin against the same assumed as-shot
        // the import subtracts, so the pair round-trips. Neither set means the
        // preset leaves the photo's own white balance alone, which is what
        // Lightroom calls As Shot.
        let kelvin = s.temperatureKelvin ?? (s.temperature != 0
                                             ? LightroomPresetImport.assumedAsShotKelvin + s.temperature * 3000
                                             : nil)
        let tint = s.tintAbsolute ?? (s.tint != 0 ? s.tint * 100 : nil)
        if kelvin != nil || tint != nil {
            put("crs:WhiteBalance", "Custom")
            if let kelvin { put("crs:Temperature", "\(Int(kelvin.rounded()))") }
            if let tint { whole("crs:Tint", tint) }
        } else {
            put("crs:WhiteBalance", "As Shot")
        }

        put("crs:Exposure2012", String(format: "%+.2f", s.exposure))
        hundredths("crs:Contrast2012", s.contrast)
        // Since 05.09.2026 both sides carry Lightroom's sign, so there is no
        // flip here — see the import's own note.
        hundredths("crs:Highlights2012", s.highlights)
        hundredths("crs:Shadows2012", s.shadows)
        hundredths("crs:Whites2012", s.whites)
        hundredths("crs:Blacks2012", s.blacks)
        hundredths("crs:Texture", s.texture)
        hundredths("crs:Clarity2012", s.clarity)
        hundredths("crs:Dehaze", s.dehaze)
        hundredths("crs:Vibrance", s.vibrance)
        hundredths("crs:Saturation", s.saturation)

        // Sharpening, back through the measured scale rather than the nominal
        // one — 0.15 here is Lightroom's 40. See lightroomSharpnessDivisor.
        whole("crs:Sharpness", s.sharpness * LightroomPresetImport.lightroomSharpnessDivisor)
        put("crs:SharpenRadius", String(format: "%+.1f", s.sharpenRadius))

        // Vignette: inverted, because Lightroom darkens with a negative Amount.
        hundredths("crs:PostCropVignetteAmount", s.vignette, invert: true)
        whole("crs:PostCropVignetteMidpoint", s.vignetteMidpoint * 100)
        whole("crs:PostCropVignetteFeather", s.vignetteFeather * 100)
        whole("crs:PostCropVignetteRoundness", s.vignetteRoundness * 100)
        put("crs:PostCropVignetteStyle", "1")

        for band in ColorBand.allCases {
            let mixed = s.colorMixer[band] ?? ColorMixerBand()
            hundredths("crs:HueAdjustment" + band.adobeSuffix, mixed.hue)
            hundredths("crs:SaturationAdjustment" + band.adobeSuffix, mixed.saturation)
            hundredths("crs:LuminanceAdjustment" + band.adobeSuffix, mixed.luminance)
        }

        let body = attributes
            .map { "   \($0.0)=\"\(escaped($0.1))\"" }
            .joined(separator: "\n")

        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="C4S Suite">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        \(body)>
           <crs:Name>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(escaped(preset.name))</rdf:li>
            </rdf:Alt>
           </crs:Name>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    /// What the import reads out of `crs:Version` / `crs:ProcessVersion`:
    /// nothing at all today, but Lightroom refuses a preset whose process
    /// version it does not know, so these name the one this app was calibrated
    /// against rather than inventing one.
    static let exportedVersion = "17.5"
    static let exportedProcessVersion = "15.4"

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class XMPParser: NSObject, XMLParserDelegate {

    /// crs keys with the prefix stripped: "Exposure2012" -> "-0.10".
    private(set) var values: [String: String] = [:]
    private(set) var presetName: String?
    private(set) var lookName: String?
    private(set) var hasNonLinearToneCurve = false

    private var elementStack: [String] = []
    /// Depth of the outermost rdf:Description, which is the preset itself.
    private var rootDepth: Int?
    private var text = ""
    private var toneCurvePoints: [String] = []

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        return parser.parse()
    }

    /// Everything nested inside a SECOND rdf:Description belongs to something
    /// else — `crs:Look` carries its own, complete with its own `crs:Name`, and
    /// harvesting that would overwrite the preset's name with "Adobe Color".
    private var isInsideNestedDescription: Bool {
        guard let rootDepth else { return false }
        return elementStack.dropFirst(rootDepth + 1).contains("rdf:Description")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        text = ""

        if elementName == "rdf:Description" {
            if rootDepth == nil {
                rootDepth = elementStack.count - 1
                for (key, value) in attributeDict where key.hasPrefix("crs:") {
                    values[String(key.dropFirst(4))] = value
                }
            } else if lookName == nil, elementStack.contains("crs:Look") {
                lookName = attributeDict["crs:Name"]
            }
            return
        }

        // Nested crs elements that carry their own attributes (crs:LensBlur).
        // Their attributes are NOT the preset's and are skipped; only the
        // presence of a non-default one would matter, and none of them map.
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            elementStack.removeLast()
            text = ""
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "rdf:li" {
            // The name comes through rdf:Alt/rdf:li, and only the preset's own
            // — not the profile's, not the group's.
            if elementStack.contains("crs:Name"), !isInsideNestedDescription,
               presetName == nil, !trimmed.isEmpty {
                presetName = trimmed
            }
            if elementStack.contains("crs:ToneCurvePV2012"), !trimmed.isEmpty {
                toneCurvePoints.append(trimmed)
            }
            return
        }

        if elementName == "crs:ToneCurvePV2012" {
            // Linear is the two corner points and nothing else. Anything more
            // is a curve this app cannot draw.
            let linear = ["0, 0", "255, 255"]
            let normalised = toneCurvePoints.map {
                $0.replacingOccurrences(of: "  ", with: " ")
            }
            hasNonLinearToneCurve = normalised != linear
            toneCurvePoints = []
            return
        }

        // A crs value written as an element rather than an attribute. Only at
        // the preset's own level, and only when the attribute form did not
        // already provide it.
        if elementName.hasPrefix("crs:"), !trimmed.isEmpty, !isInsideNestedDescription {
            let key = String(elementName.dropFirst(4))
            if values[key] == nil {
                values[key] = trimmed
            }
        }
    }
}
