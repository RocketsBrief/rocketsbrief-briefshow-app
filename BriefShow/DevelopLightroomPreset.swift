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
                return "No Camera Raw settings in this file."
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
        if let v = hundredths("Highlights2012", invert: true) { s.highlights = v }
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

        // Sharpening: Lightroom's own RAW default is 40, and that is the value
        // a preset carries when the photographer never touched the slider.
        if let v = number("Sharpness") {
            s.sharpness = clamp((v - lightroomDefaultSharpness) / 110, 0, 1)
        }

        // White balance, only when the preset actually sets one. "As Shot"
        // means "leave this photo's own white balance alone", which is exactly
        // what a temperature of 0 does here.
        let whiteBalance = values["WhiteBalance"] ?? ""
        if whiteBalance.caseInsensitiveCompare("As Shot") != .orderedSame {
            if let kelvin = number("Temperature") {
                // Without an as-shot reference there is nothing to be relative
                // TO, so a daylight baseline is assumed and the import says so.
                let baseline = number("AsShotTemperature") ?? assumedAsShotKelvin
                s.temperature = clamp((kelvin - baseline) / 3000, -1, 1)
            }
            if let tint = number("Tint") {
                let baseline = number("AsShotTint") ?? 0
                s.tint = clamp((tint - baseline) / 100, -1, 1)
            }
        }

        return s
    }

    static let lightroomDefaultSharpness: Double = 40
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
        if moved("SharpenRadius") || moved("SharpenDetail") || moved("SharpenEdgeMasking") {
            parts.append("Sharpening detail (radius / detail / masking)")
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
        // Only worth saying when there IS a vignette: the shape of a vignette
        // of zero is not something anyone lost.
        if moved("PostCropVignetteAmount"),
           moved("PostCropVignetteFeather") || moved("PostCropVignetteMidpoint")
            || moved("PostCropVignetteRoundness") {
            parts.append("Vignette shape (midpoint / feather / roundness)")
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
