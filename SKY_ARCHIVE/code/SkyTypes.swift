// Everything BriefShow knew about skies, lifted out of Develop.swift and
// DevelopInpaint.swift on 2 September 2026 when the feature was removed.
//
// Not compiled. This is the archive that makes "let's carry on with the sky"
// a paste rather than a rewrite. Read BRIEFSHOW_SKY_NOTES.md first — it says
// what each of these is for, what was measured, and where the wall is.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum SkyStyle: String, Codable, CaseIterable, Identifiable {
    case clearBlue
    case blueWithSun
    case softClouds
    case overcast
    case goldenHour
    case sunset
    case dramatic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clearBlue: return "Clear Blue"
        case .blueWithSun: return "Blue + Sun"
        case .softClouds: return "Soft Clouds"
        case .overcast: return "Overcast"
        case .goldenHour: return "Golden Hour"
        case .sunset: return "Sunset"
        case .dramatic: return "Dramatic"
        }
    }
}

struct SkyPhoto: Identifiable, Equatable, Hashable {
    let name: String
    var id: String { name }

    /// Every bundled photograph, in the order the picker shows them.
    static let all: [SkyPhoto] = (1...15).map { SkyPhoto(name: "sky-\($0)") }

    /// ⚠️ Looked up FLAT first, and the subdirectory only as a fallback.
    /// The files live in `BriefShow/Skies/` in the repo, but that folder is
    /// inside a file system synchronized group, and Xcode copies its contents
    /// into `Contents/Resources` **without the folder** — verified in the built
    /// bundle, not assumed. Asking for the subdirectory first would fail on
    /// every single lookup and quietly work anyway, which is the kind of thing
    /// that is discovered years later.
    var url: URL? {
        Bundle.main.url(forResource: name, withExtension: "jpg")
            ?? Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Skies")
    }
}

enum SkyChoice: Codable, Equatable, Hashable {
    case drawn(SkyStyle)
    case photo(String)

    private static let photoPrefix = "photo:"

    var label: String {
        switch self {
        case .drawn(let style): return style.label
        case .photo(let name):
            // "sky-7" reads as a filename. The client picked these by looking
            // at them, so a number is all the name that is needed.
            return "Sky \(name.replacingOccurrences(of: "sky-", with: ""))"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix(Self.photoPrefix) {
            self = .photo(String(raw.dropFirst(Self.photoPrefix.count)))
        } else if let style = SkyStyle(rawValue: raw) {
            self = .drawn(style)
        } else {
            // An unknown name from a newer build. Falling back to a real sky
            // rather than throwing: throwing would drop the whole photo's
            // record on the floor (see PhotoEditStore.allSettings).
            self = .drawn(.clearBlue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .drawn(let style): try container.encode(style.rawValue)
        case .photo(let name): try container.encode(Self.photoPrefix + name)
        }
    }
}

enum SkyPainter {

    /// The sky for a choice — drawn or photographed — filling `extent`.
    static func image(_ choice: SkyChoice, extent: CGRect) -> CIImage {
        switch choice {
        case .drawn(let style):
            return image(style, extent: extent)
        case .photo(let name):
            return photograph(named: name, extent: extent)
        }
    }

    /// A bundled photograph, scaled to COVER `extent` and centred.
    ///
    /// Cover rather than fit: a sky that is fitted leaves bars at the sides or
    /// top, and a bar in a replaced sky is not a small fault — it is the one
    /// thing that says "this was pasted". Centred rather than anchored to the
    /// top, because these are cropped to the sky already, so the interesting
    /// part is the middle of what is left.
    ///
    /// Falls back to a drawn sky if the file is missing, rather than returning
    /// nothing: an empty layer would read as "Change Sky broke", and a plain
    /// blue sky is a truthful thing to show while saying so in the log.
    static func photograph(named name: String, extent: CGRect) -> CIImage {
        guard let url = SkyPhoto(name: name).url,
              let loaded = CIImage(contentsOf: url) else {
            return image(.clearBlue, extent: extent)
        }

        let source = loaded.extent
        guard source.width > 0, source.height > 0 else {
            return image(.clearBlue, extent: extent)
        }

        let scale = max(extent.width / source.width, extent.height / source.height)
        let scaled = loaded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = scaled.transformed(by: CGAffineTransform(
            translationX: extent.midX - scaled.extent.midX,
            y: extent.midY - scaled.extent.midY
        ))
        return centred.cropped(to: extent)
    }

    /// A small sample of a photograph for the picker, made once and kept.
    static func preview(_ choice: SkyChoice) -> NSImage? {
        switch choice {
        case .drawn(let style):
            return preview(style)
        case .photo(let name):
            if let cached = photoPreviewCache[name] {
                return cached
            }
            let size = CGSize(width: 220, height: 140)
            let extent = CGRect(origin: .zero, size: size)
            guard let cgImage = previewContext.createCGImage(photograph(named: name, extent: extent), from: extent) else {
                return nil
            }
            let image = NSImage(cgImage: cgImage, size: size)
            photoPreviewCache[name] = image
            return image
        }
    }

    nonisolated(unsafe) private static var photoPreviewCache: [String: NSImage] = [:]

    /// A small drawn sample for the picker, made once and kept.
    ///
    /// The picker shows the REAL thing rather than an illustration of it —
    /// these are the same three steps `image` runs, at 220px. A hand-drawn
    /// swatch would be a promise the renderer might not keep.
    static func preview(_ style: SkyStyle) -> NSImage? {
        if let cached = previewCache[style] {
            return cached
        }

        let size = CGSize(width: 220, height: 140)
        let extent = CGRect(origin: .zero, size: size)
        guard let cgImage = previewContext.createCGImage(image(style, extent: extent), from: extent) else {
            return nil
        }

        let rendered = NSImage(cgImage: cgImage, size: size)
        previewCache[style] = rendered
        return rendered
    }

    private static var previewCache: [SkyStyle: NSImage] = [:]
    private static let previewContext = CIContext(options: [.useSoftwareRenderer: false])

    static func image(_ style: SkyStyle, extent: CGRect) -> CIImage {
        guard extent.width > 1, extent.height > 1 else {
            return CIImage(color: .gray).cropped(to: extent)
        }

        var sky = gradient(style, extent: extent)

        if let sun = sunPosition(style) {
            sky = addSun(to: sky, style: style, at: sun, extent: extent)
        }

        if cloudAmount(style) > 0 {
            sky = addClouds(to: sky, style: style, extent: extent)
        }

        return sky.cropped(to: extent)
    }

    // MARK: The base gradient

    /// Top colour, horizon colour. Real skies get paler and warmer toward
    /// the horizon — that gradient is most of what makes one read as sky
    /// rather than as a flat fill.
    private static func colours(_ style: SkyStyle) -> (top: CIColor, horizon: CIColor) {
        switch style {
        case .clearBlue:
            return (CIColor(red: 0.16, green: 0.42, blue: 0.78),
                    CIColor(red: 0.72, green: 0.85, blue: 0.95))
        case .blueWithSun:
            return (CIColor(red: 0.20, green: 0.46, blue: 0.80),
                    CIColor(red: 0.80, green: 0.89, blue: 0.96))
        case .softClouds:
            return (CIColor(red: 0.30, green: 0.54, blue: 0.82),
                    CIColor(red: 0.84, green: 0.90, blue: 0.95))
        case .overcast:
            return (CIColor(red: 0.55, green: 0.59, blue: 0.64),
                    CIColor(red: 0.82, green: 0.84, blue: 0.86))
        case .goldenHour:
            return (CIColor(red: 0.35, green: 0.47, blue: 0.72),
                    CIColor(red: 0.99, green: 0.80, blue: 0.52))
        case .sunset:
            return (CIColor(red: 0.24, green: 0.20, blue: 0.44),
                    CIColor(red: 0.98, green: 0.53, blue: 0.32))
        case .dramatic:
            // Storm light, not night. The first pass at 0.12 top with dark
            // cloud over it rendered as a black rectangle — a dramatic sky
            // still has to be a sky somebody can see through.
            return (CIColor(red: 0.30, green: 0.36, blue: 0.46),
                    CIColor(red: 0.78, green: 0.79, blue: 0.80))
        }
    }

    private static func gradient(_ style: SkyStyle, extent: CGRect) -> CIImage {
        let palette = colours(style)
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: extent.midX, y: extent.maxY)
        filter.point1 = CGPoint(x: extent.midX, y: extent.minY)
        filter.color0 = palette.top
        filter.color1 = palette.horizon
        return (filter.outputImage ?? CIImage(color: palette.top)).cropped(to: extent)
    }

    // MARK: Sun

    /// Where the sun sits, in unit coordinates measured from the bottom
    /// left the way Core Image does. nil for the styles that have none.
    private static func sunPosition(_ style: SkyStyle) -> CGPoint? {
        switch style {
        case .clearBlue, .overcast, .dramatic: return nil
        case .blueWithSun: return CGPoint(x: 0.74, y: 0.80)
        case .softClouds: return CGPoint(x: 0.28, y: 0.78)
        case .goldenHour: return CGPoint(x: 0.68, y: 0.30)
        case .sunset: return CGPoint(x: 0.62, y: 0.18)
        }
    }

    private static func sunColour(_ style: SkyStyle) -> CIColor {
        switch style {
        case .goldenHour: return CIColor(red: 1.0, green: 0.88, blue: 0.62, alpha: 1)
        case .sunset: return CIColor(red: 1.0, green: 0.74, blue: 0.42, alpha: 1)
        default: return CIColor(red: 1.0, green: 0.98, blue: 0.90, alpha: 1)
        }
    }

    /// A tight core inside a wide glow, screened over the gradient.
    ///
    /// Two radials rather than one: a single gradient big enough to glow
    /// has no disc in it, and one small enough to be a disc lights nothing
    /// around it. Screen rather than normal, so the sun brightens the sky
    /// it sits in instead of punching a hole through it.
    private static func addSun(to sky: CIImage, style: SkyStyle,
                               at unit: CGPoint, extent: CGRect) -> CIImage {
        let centre = CGPoint(x: extent.minX + unit.x * extent.width,
                             y: extent.minY + unit.y * extent.height)
        let shortEdge = min(extent.width, extent.height)
        let colour = sunColour(style)
        var output = sky

        for (inner, outer, strength) in [(0.012, 0.055, 1.0), (0.05, 0.55, 0.55)] {
            let glow = CIFilter.radialGradient()
            glow.center = centre
            glow.radius0 = Float(shortEdge * inner)
            glow.radius1 = Float(shortEdge * outer)
            glow.color0 = CIColor(red: colour.red, green: colour.green,
                                  blue: colour.blue, alpha: strength)
            glow.color1 = CIColor(red: colour.red, green: colour.green,
                                  blue: colour.blue, alpha: 0)

            guard let layer = glow.outputImage?.cropped(to: extent) else {
                continue
            }
            output = layer.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: output
            ]).cropped(to: extent)
        }

        return output
    }

    // MARK: Clouds

    private static func cloudAmount(_ style: SkyStyle) -> Double {
        switch style {
        // These are lower than they look like they should be, and that is
        // from looking at the renders rather than from the arithmetic: the
        // threshold has a soft edge either side, so a cloud reads as bigger
        // than the fraction it is thresholded at. 0.45 came out as a white
        // sheet with blue holes in it, which is not "soft clouds".
        case .clearBlue: return 0
        case .blueWithSun: return 0.18
        case .softClouds: return 0.26
        case .overcast: return 0.72
        case .goldenHour: return 0.20
        case .sunset: return 0.24
        // Not 0.95. At near-total coverage the dark cloud colour simply
        // becomes the picture, and a black rectangle is not a dramatic sky
        // — the gradient has to show through the gaps for it to read as
        // weather rather than as a fault.
        // ⚠️ Low, and it has to be. A DARK cloud colour over a mid-grey sky
        // is far less forgiving than a white one over blue: the soft
        // threshold edge spreads, and at 0.72 and again at 0.55 this
        // rendered as a black rectangle with a few grey holes. Measured by
        // looking at it three times.
        case .dramatic: return 0.30
        }
    }

    /// White for daylight, a warm underlit tone at sunset, near-black for
    /// the dramatic one — clouds are lit by the sky they are in, and a
    /// white cloud in a sunset is the giveaway that it was pasted.
    private static func cloudColour(_ style: SkyStyle) -> CIColor {
        switch style {
        case .dramatic: return CIColor(red: 0.31, green: 0.34, blue: 0.41, alpha: 1)
        case .sunset: return CIColor(red: 0.99, green: 0.72, blue: 0.55, alpha: 1)
        case .goldenHour: return CIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1)
        case .overcast: return CIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1)
        default: return CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    private static func addClouds(to sky: CIImage, style: SkyStyle, extent: CGRect) -> CIImage {
        guard let field = cloudField(extent: extent, amount: cloudAmount(style)) else {
            return sky
        }

        let colour = CIImage(color: cloudColour(style)).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = colour
        blend.backgroundImage = sky
        blend.maskImage = field
        return (blend.outputImage ?? sky).cropped(to: extent)
    }

    /// Two octaves of blurred noise, curved into billows.
    ///
    /// One octave alone is a smooth blob field that reads as fog; the
    /// second, three times finer and at a third of the weight, is what
    /// gives an edge something to break up on. `amount` moves the curve
    /// rather than scaling the result, so "more cloud" means more of the
    /// sky is covered, not that the same clouds get more opaque.
    private static func cloudField(extent: CGRect, amount: Double) -> CIImage? {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else {
            return nil
        }

        let longEdge = max(extent.width, extent.height)
        var field: CIImage?

        // Weights sum to 1 so the two octaves average rather than pile up.
        for (cells, weight) in [(14.0, 0.75), (42.0, 0.25)] {
            let cell = longEdge / cells
            let octave = noise
                .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
                .applyingFilter("CIColorMonochrome", parameters: [
                    kCIInputColorKey: CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                    kCIInputIntensityKey: 1
                ])
                .clampedToExtent()
                .applyingGaussianBlur(sigma: cell * 0.85)
                .cropped(to: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])

            field = field.map {
                octave.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: $0
                ]).cropped(to: extent)
            } ?? octave
        }

        guard let summed = field else {
            return nil
        }

        // ⚠️ MEASURED, TWICE, and wrong both of the first two times.
        //
        // Blurred CIRandomGenerator does not sit anywhere near 0...1. In
        // LINEAR space — the space these filters actually work in — it runs
        // p05 0.376, p50 0.494, p95 0.584. Narrow, and centred just under a
        // half.
        //
        // Attempt one used a 0-to-1 curve: everything mapped to full cloud
        // and five of seven skies came out a blank white sheet. Attempt two
        // corrected the band, but from numbers read out of an sRGB bitmap —
        // sRGB 0.73 is linear 0.49, so the band sat ABOVE the data and the
        // clouds vanished entirely. Both looked like colour bugs and were
        // the same distribution bug, measured in the wrong space.
        //
        // These two numbers come from a linear-space read (p05 and p95).
        // With them, `amount` lands within a couple of points of the
        // coverage it asks for: 0.18 → 0.16, 0.45 → 0.51, 0.85 → 0.88.
        let gain = 4.81
        let bias = -1.81
        let normalised = summed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ]).cropped(to: extent)

        // `amount` is now simply "how much of the sky is cloud": the
        // threshold is 1 minus it, with a soft edge either side so cloud
        // borders are billows rather than cut-outs. Clamped so the four
        // curve points stay strictly increasing at both ends.
        let threshold = min(max(1 - amount, 0.08), 0.88)
        return normalised.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.0, y: 0),
            "inputPoint1": CIVector(x: max(threshold - 0.14, 0.01), y: 0),
            "inputPoint2": CIVector(x: threshold, y: 0.5),
            "inputPoint3": CIVector(x: min(threshold + 0.14, 0.99), y: 1),
            "inputPoint4": CIVector(x: 1.0, y: 1)
        ]).cropped(to: extent)
    }
}

enum SkyMasker {

    /// White where sky is, black elsewhere, over `image`'s own extent.
    ///
    /// Returns nil when what it found is too small to be a sky — under 2%
    /// of the frame is a gap between leaves, not something anybody wants to
    /// replace, and handing back a mask like that would produce a Sky layer
    /// that appears to do nothing.
    static func skyMask(for image: CIImage, maxWorkingEdge: CGFloat = 900) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }

        // Small on purpose. Every test below is about broad regions, none of
        // them wants pixel detail, and the result is blurred hard at the end
        // anyway — running this on a 45MP RAW would buy nothing at all.
        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > maxWorkingEdge ? maxWorkingEdge / longEdge : 1
        let working = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let workingExtent = working.extent

        guard let blueness = bluenessScore(working, extent: workingExtent),
              let brightness = brightPaleScore(working, extent: workingExtent),
              let flatness = flatnessScore(working, extent: workingExtent)
        else {
            return nil
        }

        // Either kind of sky counts, so the two colour tests are a MAXIMUM
        // rather than a product — a deep blue sky scores nothing on
        // "bright and pale", and a white overcast sky scores nothing on
        // "blue". Multiplying them would reject both.
        let colourScore = blueness.applyingFilter("CIMaximumCompositing", parameters: [
            kCIInputBackgroundImageKey: brightness
        ]).cropped(to: workingExtent)

        // Flatness and height are both vetoes, so those DO multiply.
        var score = colourScore.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: flatness
        ]).cropped(to: workingExtent)

        score = score.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: heightWeight(extent: workingExtent)
        ]).cropped(to: workingExtent)

        // Blur wide, then pull hard: this is what turns a noisy per-pixel
        // score into regions. The blur radius is a fraction of the frame,
        // not a pixel count, so the same picture at a different working
        // size produces the same mask.
        let smoothed = score
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(workingExtent.width, workingExtent.height) * 0.012)
            .cropped(to: workingExtent)

        // ⚠️ THE TEST THAT MATTERS, and the first version did not have it.
        //
        // Measured on a real beach photograph: colour + flatness + height
        // alone marked the sky AND a wide strip of bright sand running down
        // the left of the frame, plus speckles on every face. Sand is
        // bright, flat and — at the left edge — reaches high enough for the
        // height weight to let it through. Every individual test was
        // working; the definition was simply not what a sky is.
        //
        // A sky is the part of the picture you reach by walking DOWN FROM
        // THE TOP without crossing anything that is not sky. Sand fails
        // that however bright it is, because the horizon is in the way.
        // nil here is not "no sky" but "this cannot be trusted" — see
        // isPlausibleHorizon. Both end up as the same refusal to the client,
        // and the message names both cases.
        guard let grown = growFromTop(smoothed, image: working, extent: workingExtent) else {
            return nil
        }

        // And people are never sky. Vision knows exactly where they are, so
        // there is no reason to leave the heuristic guessing about faces —
        // skin in bright sun is pale and smooth, which is the definition
        // being used, so it passed on merit.
        let hardened = subtractingPeople(grown, from: image, extent: workingExtent)

        guard coverage(hardened, extent: workingExtent) >= 0.02 else {
            return nil
        }

        // Back up to the photo's own extent, the same way personMask does.
        let sx = extent.width / workingExtent.width
        let sy = extent.height / workingExtent.height
        var mask = hardened.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        mask = mask.transformed(by: CGAffineTransform(
            translationX: extent.origin.x - mask.extent.origin.x,
            y: extent.origin.y - mask.extent.origin.y
        ))
        return mask.cropped(to: extent)
    }

    /// How blue a pixel is, as `B - max(R, G)`, scaled up so an ordinary
    /// sky lands near 1.
    private static func bluenessScore(_ image: CIImage, extent: CGRect) -> CIImage? {
        // max(R,G) in every channel.
        guard let redGreen = CIFilter(name: "CIMaximumComponent", parameters: [
            kCIInputImageKey: image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        ])?.outputImage else {
            return nil
        }

        let blueOnly = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        // Subtract by adding the inverse and pulling the bias back — CI has
        // no subtract-blend that clamps the way this needs.
        let difference = blueOnly.applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: redGreen.cropped(to: extent)
        ]).cropped(to: extent)

        // A clear sky sits around 0.10-0.20 of separation; ×5 puts that at
        // roughly 0.5-1.0, which is the range the vetoes below expect.
        return difference.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 5, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 5, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)
    }

    /// Bright AND colourless — the overcast and blown-out half of "sky".
    private static func brightPaleScore(_ image: CIImage, extent: CGRect) -> CIImage? {
        let grey = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1
        ])

        // Everything below 0.72 goes to nothing, 0.92 and up is full — the
        // band where a pale sky lives and a mid-grey road does not.
        let brightness = grey.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.00, y: 0),
            "inputPoint1": CIVector(x: 0.72, y: 0),
            "inputPoint2": CIVector(x: 0.82, y: 0.5),
            "inputPoint3": CIVector(x: 0.92, y: 1),
            "inputPoint4": CIVector(x: 1.00, y: 1)
        ]).cropped(to: extent)

        // ...and colourless, so a bright yellow wall does not qualify. The
        // same distance-from-grey measure the Colour Mixer uses, inverted.
        guard let colourful = CIFilter(name: "CIMaximumComponent", parameters: [
            kCIInputImageKey: image.applyingFilter("CIColorAbsoluteDifference", parameters: [
                "inputImage2": grey
            ])
        ])?.outputImage else {
            return brightness
        }

        let colourless = colourful
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 6, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 6, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIColorInvert")
            .cropped(to: extent)

        return brightness.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: colourless
        ]).cropped(to: extent)
    }

    /// 1 where the picture matches its own blur, 0 where it does not.
    ///
    /// This is the test that keeps buildings, foliage and text out. Sky is
    /// the flattest thing in almost any frame.
    private static func flatnessScore(_ image: CIImage, extent: CGRect) -> CIImage? {
        let sigma = max(extent.width, extent.height) * 0.004
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)

        guard let detail = CIFilter(name: "CIMaximumComponent", parameters: [
            kCIInputImageKey: image.applyingFilter("CIColorAbsoluteDifference", parameters: [
                "inputImage2": blurred
            ])
        ])?.outputImage else {
            return nil
        }

        // ×14 then inverted: a difference of about 0.07 is enough to veto a
        // pixel outright, which is well below anything a real edge produces
        // and well above sensor noise in a smooth sky.
        return detail
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 14, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 14, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 14, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIColorInvert")
            .cropped(to: extent)
    }

    /// Full weight across the top, easing to a floor at the bottom.
    ///
    /// A floor of 0.25 rather than 0 on purpose: sky reaches all the way
    /// down between buildings and behind a low horizon, and a hard cut
    /// would slice those off in a straight line across the picture — the
    /// single most obvious way a sky replacement announces itself as fake.
    private static func heightWeight(extent: CGRect) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: extent.maxY)
        gradient.point1 = CGPoint(x: extent.midX, y: extent.minY)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)
        return (gradient.outputImage ?? CIImage(color: .white)).cropped(to: extent)
    }

    /// Keeps, in each column, the run of sky that starts at the top of the
    /// frame — and drops everything below the first thing that is not sky.
    ///
    /// This is a column walk on the CPU rather than a filter chain, because
    /// "connected to the top" is not something a per-pixel filter can
    /// answer. It runs on the working copy (under a megapixel), so the cost
    /// is a few milliseconds once per button press.
    ///
    /// `runToStop` is 3 rather than 1 so a single dark row — a wire, a
    /// branch, one noisy line of pixels — does not cut the sky off above
    /// the horizon. Anything genuinely solid is thicker than three rows at
    /// this working size.
    /// The sky is what you reach by walking DOWN FROM THE TOP of each column
    /// without crossing out of the sky.
    ///
    /// ⚠️ TWO things stop it, and the second one is the whole fix:
    ///
    /// 1. **The score drops** — colour + flatness + height say "not sky".
    /// 2. **An edge, straight down** — this pixel differs sharply from the one
    ///    directly above it, in the PHOTOGRAPH rather than in the score.
    ///
    /// 2 exists because of one measured photograph. A white hotel facade under
    /// a pale sky passes every test in the score — bright, pale, flat once the
    /// score has been blurred into regions, and high in the frame — so the walk
    /// ran straight down through the building to the ground and marked it as
    /// sky in vertical stripes between the palms. The score cannot see that:
    /// by the time it is smooth enough to form regions, the roofline has been
    /// smeared away with everything else. The photograph still has the edge.
    ///
    /// ⚠️ THE LIMIT IS MEASURED. Across the client's three hardest frames the
    /// step between two rows INSIDE a sky is 0 at the median, 1 at p90, 1–4 at
    /// p98 and 2–26 at p99.9. 40 sits clear of all of it.
    ///
    /// ⚠️ AND BE HONEST ABOUT WHAT IT DOES NOT DO. It fires rarely, and it does
    /// NOT separate a white hotel facade from a white sky — measured, those are
    /// 241/249/255 and very nearly the same, so there is no step to find. That
    /// case is handled afterwards, by `withoutStripes`, and it has to be:
    /// locally the two really are the same thing.
    ///
    /// ⚠️ AND WHAT WAS TRIED AND DROPPED, so it is not tried again: a second
    /// per-row stop on how far the pixel had drifted from a running average of
    /// the sky above it. A sky with a gradient wanders a long way from where it
    /// started, so no limit separates it — and EVERY STOP HERE IS TERMINAL, so
    /// a test that is wrong on even 2% of rows kills a column of 600 rows with
    /// near certainty. A per-row test in a walk this long has to be nearly
    /// perfect or absent.
    private static func growFromTop(_ score: CIImage, image: CIImage, extent: CGRect) -> CIImage? {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 1, height > 1 else {
            return score
        }

        var scorePixels = [UInt8](repeating: 0, count: width * height * 4)
        skyMeasurementContext.render(
            score,
            toBitmap: &scorePixels,
            rowBytes: width * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // The photograph itself, at the same size and in the same space, so a
        // row index means the same pixel in both.
        var photoPixels = [UInt8](repeating: 0, count: width * height * 4)
        skyMeasurementContext.render(
            image,
            toBitmap: &photoPixels,
            rowBytes: width * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Core Image hands the bitmap back top row first, which is the
        // direction this wants anyway.
        let threshold: UInt8 = 110
        let runToStop = 3
        // How far down each column got. Written first, turned into a mask
        // afterwards — see the median filter below, which needs the whole
        // profile before it can say anything about any one column.
        var depth = [Int](repeating: 0, count: width)

        for x in 0..<width {
            var misses = 0
            var previousR = 0.0, previousG = 0.0, previousB = 0.0
            var haveRow = false

            for y in 0..<height {
                let index = (y * width + x) * 4

                // ⚠️ UN-PREMULTIPLIED, and this is not a formality.
                //
                // `.RGBA8` hands back PREMULTIPLIED colour, and the scaled
                // working copy has a fractional extent, so its very first row
                // is a half-covered antialiased edge: measured at alpha 141,
                // colour 133/137/141 — the same sky whose full value is
                // 241/249/255. Read raw, the step from row 0 to row 1 is 114,
                // which is a boundary by any threshold, so EVERY COLUMN STOPPED
                // AT ROW 1 and the mask came back empty. It looked exactly like
                // a limit that was too tight, and no amount of loosening the
                // limit would have found it — the numbers were describing an
                // artefact of the render, not the photograph.
                let alpha = Double(photoPixels[index + 3])
                guard alpha > 0 else {
                    // Nothing was drawn here. Not sky, not "not sky" — no data.
                    // Left unmarked, and deliberately not counted as a miss:
                    // this is the frame's own edge, not something in the
                    // picture.
                    continue
                }
                let unpremultiply = 255 / alpha
                let red = Double(photoPixels[index]) * unpremultiply
                let green = Double(photoPixels[index + 1]) * unpremultiply
                let blue = Double(photoPixels[index + 2]) * unpremultiply

                // The score carries the same partial coverage, so it gets the
                // same treatment — otherwise a half-covered edge row reads as
                // half the score it actually has.
                if Double(scorePixels[index]) * unpremultiply < Double(threshold) {
                    misses += 1
                    if misses >= runToStop {
                        break
                    }
                    // Still marked, and still allowed to continue: a single
                    // dark row — a wire, a branch — must not cut the sky above
                    // the horizon in half.
                    //
                    // ⚠️ AND THE REFERENCE IS NOT UPDATED HERE. It was, in the
                    // first version, and that single line undid the whole
                    // tolerance: the wire became the pixel the next row was
                    // compared against, so coming back OUT of the wire into the
                    // sky was itself a huge step and broke the column. Measured
                    // as "the mask nearly vanished" on all three test frames.
                    // The comparison has to be sky-to-sky across the
                    // interruption, which means keeping the last row that was
                    // actually sky.
                    depth[x] = y + 1
                    continue
                }

                if haveRow {
                    let verticalStep = max(abs(red - previousR),
                                           max(abs(green - previousG), abs(blue - previousB)))
                    if verticalStep > skyVerticalStepLimit {
                        break
                    }
                }

                misses = 0
                haveRow = true
                previousR = red; previousG = green; previousB = blue
                depth[x] = y + 1
            }
        }

        depth = withoutStripes(depth, height: height)

        guard isPlausibleHorizon(depth, height: height) else {
            // Deliberately empty rather than "the best we could do". See
            // isPlausibleHorizon: an unreliable sky mask is worse than none,
            // because the client only finds out after the replacement is on
            // the photograph.
            return nil
        }

        // ⚠️ THE BOUNDARY RUNS FROM ONE EDGE OF THE PICTURE TO THE OTHER, and
        // that is a requirement, not a nicety: *„granica mora da bude od jednog
        // kraja slike do drugog"*. The complaint behind it was a replaced sky
        // that covered the top-left and stopped halfway across a hotel, leaving
        // a cut in mid-air.
        //
        // A column can stop at the very top for two completely different
        // reasons, and the walk cannot tell them apart on its own:
        //
        //   - something OCCLUDES the sky there — a palm frond, a lamp post, a
        //     wire. The horizon is still behind it, exactly where its
        //     neighbours put it.
        //   - the horizon really is that high — a building that reaches the top
        //     of the frame.
        //
        // So the horizon is INTERPOLATED across the shallow columns, and the
        // per-pixel score is then applied above it. A frond keeps its own
        // pixels out of the mask because the score rejects them, while the sky
        // BEHIND it, above the horizon, is included — which is what a sky
        // replacement has to do. A building that genuinely reaches the top
        // keeps its pixels out for the same reason, so nothing is painted over
        // it either.
        let horizon = continuousHorizon(depth, width: width, height: height)

        // ⚠️ THE HORIZON EDGE IS FEATHERED, THE REST IS NOT, and the two have
        // to be told apart.
        //
        // Where the sky meets the horizon a replaced sky has to fade in, or the
        // seam is a drawn line across the photograph — asked for directly:
        // *„sa donjim delom kao feather"*. But where the sky meets a PALM or a
        // roof, softness is the opposite of what is wanted: a soft edge there
        // lets the old sky glow through around every frond.
        //
        // Both edges come from different places, which is what makes this
        // possible: the horizon is `horizon[x]`, and the frond is the score
        // test. So the ramp is applied to the horizon only, by row, and the
        // score keeps its hard yes/no.
        let feather = max(1, Int(Double(height) * skyHorizonFeather))
        var mask = [UInt8](repeating: 0, count: width * height)

        for x in 0..<width {
            let limit = min(height, horizon[x])
            for y in 0..<limit {
                let index = (y * width + x) * 4
                let alpha = Double(photoPixels[index + 3])
                guard alpha > 0 else { continue }
                // A lower bar than the walk's own: this is deciding whether a
                // pixel ABOVE a horizon we already trust is sky or something in
                // front of it, which is an easier question than deciding where
                // the horizon is.
                guard Double(scorePixels[index]) * (255 / alpha) >= Double(aboveHorizonThreshold) else {
                    continue
                }

                let toHorizon = limit - y
                mask[y * width + x] = toHorizon >= feather
                    ? 255
                    : UInt8(255 * toHorizon / feather)
            }
        }

        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else {
            return score
        }

        // ⚠️ NO BLUR AT THE END ANY MORE. There was one — 0.004 of the frame,
        // about 20px at full size — to take the staircase off the column edge.
        // It has become both redundant and harmful:
        //
        //   - redundant, because the horizon now carries its own explicit ramp
        //     (see the feather above), which is where softness was wanted;
        //   - harmful, because it softened the edge around PALMS AND ROOFS too,
        //     and a soft edge there is a 20px band of the ORIGINAL sky showing
        //     through the new one. Over a blown-out sky that band is a white
        //     halo tracing every frond — seen on the first real test.
        //
        // The staircase it was hiding is a working-resolution artefact and
        // belongs to the walk, not to the edge. It is far less visible than the
        // halo was.
        let grown = CIImage(cgImage: cgImage)
        let placed = grown.transformed(by: CGAffineTransform(
            translationX: extent.origin.x - grown.extent.origin.x,
            y: extent.origin.y - grown.extent.origin.y
        ))
        return placed.cropped(to: extent)
    }

    /// Cuts vertical stripes out of a depth profile with a running median.
    ///
    /// ⚠️ THIS IS WHAT A WHITE BUILDING UNDER A WHITE SKY NEEDS, and nothing
    /// local can do it. Measured on the client's hotel frame: sky is 241/249/255
    /// and the facade below it is very nearly the same, so the step between
    /// them is a few units where a real boundary is tens. There is no threshold
    /// there. Locally the two ARE the same thing — the difference is not in the
    /// pixels, it is in the SHAPE of the result.
    ///
    /// A column that runs down through a building is an impulse in the depth
    /// profile: it reaches the floor while the columns beside it stopped at the
    /// roof. A running median is the classic way to remove an impulse, and —
    /// unlike a blur, which is what every earlier version of this reached for —
    /// it does NOT round off a genuine step. That matters here more than
    /// usual: a roofline IS a step, and the complaint that started this work
    /// was a boundary that cut smoothly across buildings instead of following
    /// them.
    ///
    /// Clamped, never raised: `min` with the median, so this can only ever take
    /// sky away. A column is allowed to be shallower than its neighbours (a
    /// palm frond over it) without being pulled down to match them.
    ///
    /// The margin is what keeps a real gap of sky between two buildings alive.
    /// Such a gap is an impulse too, and an honest one; it comes back clipped a
    /// little rather than erased.
    private static func withoutStripes(_ depth: [Int], height: Int) -> [Int] {
        let width = depth.count
        guard width > 8 else { return depth }

        // Wide enough that a stripe is a minority inside it, narrow enough to
        // follow a sloping roofline rather than average the whole frame.
        let halfWindow = max(2, width / 16)
        let margin = Int(Double(height) * 0.06)

        var result = depth
        var window: [Int] = []
        window.reserveCapacity(halfWindow * 2 + 1)

        for x in 0..<width {
            window.removeAll(keepingCapacity: true)
            for k in max(0, x - halfWindow)...min(width - 1, x + halfWindow) {
                window.append(depth[k])
            }
            window.sort()
            let median = window[window.count / 2]
            result[x] = min(depth[x], median + margin)
        }
        return result
    }

    /// Turns column stops into one horizon that spans the whole width.
    ///
    /// Columns that stopped almost immediately are treated as OCCLUDED, not as
    /// "no sky here", and their horizon is taken from the nearest columns on
    /// either side that did see one. At the frame's own edges, where there is
    /// only one side to borrow from, the nearest known column is carried
    /// outward — an edge is not a reason for the horizon to collapse.
    ///
    /// Nothing here decides whether an individual pixel is sky; that is the
    /// score's job, applied afterwards. This only decides HOW FAR DOWN the sky
    /// can possibly reach in each column.
    private static func continuousHorizon(_ depth: [Int], width: Int, height: Int) -> [Int] {
        // Under 2% of the frame is not a horizon, it is something standing in
        // front of one.
        let occluded = Int(Double(height) * 0.02)
        var known = depth.map { $0 > occluded ? $0 : -1 }

        guard known.contains(where: { $0 >= 0 }) else {
            // Nothing anywhere saw a horizon. Leave the profile alone rather
            // than invent one across a frame with no sky in it.
            return depth
        }

        // Carry the first and last known values out to the edges.
        if let first = known.firstIndex(where: { $0 >= 0 }), first > 0 {
            for x in 0..<first { known[x] = known[first] }
        }
        if let last = known.lastIndex(where: { $0 >= 0 }), last < width - 1 {
            for x in (last + 1)..<width { known[x] = known[last] }
        }

        // Straight line between each pair of known columns.
        var x = 0
        while x < width {
            guard known[x] < 0 else { x += 1; continue }
            let start = x - 1
            var end = x
            while end < width, known[end] < 0 { end += 1 }
            let a = Double(known[start])
            let b = Double(known[end])
            let span = Double(end - start)
            for gap in (start + 1)..<end {
                let t = Double(gap - start) / span
                known[gap] = Int(a + (b - a) * t)
            }
            x = end
        }

        return known
    }

    /// How deep the fade at the horizon is, as a fraction of frame height.
    ///
    /// 4.5% — about 155px on a 3448px frame. Raised from 2.5% on the client's
    /// own words after the first real test: *„u suštini treba da se pripoji
    /// slici da se ne vidi da je dodato… sa transparencijom isto"*. The
    /// transparency they are describing IS this ramp — near the horizon the new
    /// sky thins out and the picture's own haze shows through it, which is
    /// where a real sky loses its colour too.
    ///
    /// Still short enough that a low horizon does not wash halfway up the
    /// picture. The seam, not the sky, is what fades.
    private static let skyHorizonFeather = 0.045

    /// How much score a pixel needs to count as sky once it is already known to
    /// be above the horizon. Lower than the walk's own threshold on purpose —
    /// see the comment at the call site.
    private static let aboveHorizonThreshold: Double = 90

    /// Whether a depth profile looks like a horizon at all.
    ///
    /// ⚠️ THIS IS THE APP ADMITTING IT CANNOT SEE. A sky boundary is roughly a
    /// line across the frame: it rises and falls over rooftops, but the deepest
    /// columns do not run half the picture below the typical ones. When they
    /// do, the walk is not tracing a horizon — it is leaking down through
    /// something as bright as the sky, in stripes.
    ///
    /// Measured across seven of the client's frames, as (p95 − p50) of column
    /// depth in fractions of frame height:
    ///
    ///     8947 0.030   8995 0.046   9011 0.069   8991 0.152
    ///     8939 0.160   8943 0.160        →   8987 **0.547**
    ///
    /// 8987 is the white-hotel frame, the one that comes back as stripes. Every
    /// other frame — including ones with low horizons and tall buildings — sits
    /// at 0.16 or below. 0.30 is the empty middle, not a compromise.
    ///
    /// ⚠️ TWO METRICS WERE TRIED AND REJECTED FIRST, so they are not tried
    /// again. Standard deviation of depth does not separate: 8987 is 0.190 and
    /// the perfectly good 8991 is 0.139. And "fraction of columns deeper than
    /// twice the median" looked ideal — 0.000 on five frames, 0.42 on 8987 —
    /// until 9011 came back at 0.34 with a MASK THAT IS CORRECT. Its median
    /// depth is 2% of the frame, so "twice the median" is 4%, and a bar that
    /// low means nothing. A ratio against a near-zero reference is not a
    /// measurement.
    ///
    /// A real sky seen down a narrow canyon between towers would fail this too.
    /// That is accepted: on such a frame the honest answer IS "I cannot tell,
    /// rope it yourself", which is what the client is told.
    private static func isPlausibleHorizon(_ depth: [Int], height: Int) -> Bool {
        guard depth.count > 8, height > 0 else { return true }

        let sorted = depth.sorted()
        let median = Double(sorted[sorted.count / 2]) / Double(height)
        let deep = Double(sorted[Int(Double(sorted.count - 1) * 0.95)]) / Double(height)
        return deep - median <= skyHorizonSpreadLimit
    }

    private static let skyHorizonSpreadLimit = 0.30

    /// The one stop limit, in 0...255 — measured, not chosen. See the walk
    /// above for the two populations it sits between, and `Tools/run-skymask.py`
    /// for how to measure it again.
    private static let skyVerticalStepLimit = 40.0

    /// Takes people back out of a sky mask.
    ///
    /// Cheap insurance, and it fixes something the heuristic cannot: skin
    /// in bright sun is pale, smooth and often high in the frame, so faces
    /// score as sky ON MERIT. Vision already knows where the people are.
    private static func subtractingPeople(_ mask: CIImage, from image: CIImage, extent: CGRect) -> CIImage {
        guard let people = SubjectMasker.personMask(for: image, maxWorkingEdge: max(extent.width, extent.height)) else {
            return mask
        }

        let scaled = people
            .transformed(by: CGAffineTransform(scaleX: extent.width / people.extent.width,
                                               y: extent.height / people.extent.height))
        let aligned = scaled
            .transformed(by: CGAffineTransform(translationX: extent.origin.x - scaled.extent.origin.x,
                                               y: extent.origin.y - scaled.extent.origin.y))
            .cropped(to: extent)
            // ⚠️ BARELY GROWN AT ALL — 0.0015, down from 0.006, and the four
            // times matters.
            //
            // Growing was itself a halo fix once: Vision traces a person
            // tightly and the rim just outside that trace is the person's own
            // rim light. But at 0.006 that is ~31px on a 5176px frame, and
            // every one of those pixels is a pixel where the ORIGINAL sky is
            // kept. Over a blown-out white sky that is a thick white glow
            // around each person, riding on top of the new sky — which is
            // exactly what came back from the first real test.
            //
            // The trade is unavoidable and this is the honest side of it: with
            // a blown-out sky, any imperfect matte shows white somewhere. A few
            // pixels of it in the hair is a fringe; thirty is a halo.
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(extent.width, extent.height) * 0.0015)
            .cropped(to: extent)

        return mask.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: aligned.applyingFilter("CIColorInvert")
        ]).cropped(to: extent)
    }

    /// Turns a soft score into something that behaves like a mask: a hard
    /// S-curve, so the middle ground picks a side instead of leaving a
    /// half-transparent sky.
    private static func hardenToMask(_ image: CIImage, extent: CGRect) -> CIImage {
        image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.00, y: 0),
            "inputPoint1": CIVector(x: 0.35, y: 0),
            "inputPoint2": CIVector(x: 0.50, y: 0.5),
            "inputPoint3": CIVector(x: 0.65, y: 1),
            "inputPoint4": CIVector(x: 1.00, y: 1)
        ]).cropped(to: extent)
    }

    /// What fraction of the frame the mask covers, 0...1.
    private static func coverage(_ mask: CIImage, extent: CGRect) -> Double {
        let average = CIFilter.areaAverage()
        average.inputImage = mask
        average.extent = extent

        guard let output = average.outputImage else {
            return 0
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        skyMeasurementContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Double(pixel[0]) / 255.0
    }
}

    private static func matchedToScene(_ sky: CIImage, scene: CIImage,
                                       mask: CIImage, extent: CGRect) -> CIImage {
        // The sky that is being replaced, and the one replacing it, each
        // averaged over the same region.
        guard let original = averageColour(of: scene, under: mask, extent: extent),
              let replacement = averageColour(of: sky, under: mask, extent: extent) else {
            return sky
        }

        func gain(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            // Guarded both ways: a near-black average would divide into a huge
            // gain, and a blown-out one (which a bright beach sky genuinely is)
            // would ask the new sky to be brighter than white. 0.6...1.7 is
            // enough to carry an evening light onto a midday sky without
            // turning it into a different picture.
            guard from > 0.02 else { return 1 }
            let raw = 1 + ((to / from) - 1) * skyMatchStrength
            return min(max(raw, 0.6), 1.7)
        }

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = sky
        matrix.rVector = CIVector(x: gain(replacement.red, original.red), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: gain(replacement.green, original.green), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: gain(replacement.blue, original.blue), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (matrix.outputImage ?? sky).cropped(to: extent)
    }

    private static func averageColour(of image: CIImage, under mask: CIImage, extent: CGRect) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        // Multiplying by the matte zeroes everything outside it, and dividing
        // the averages by the matte's OWN average takes the zeroes back out —
        // otherwise a sky covering a fifth of the frame would measure a fifth
        // as bright as it is.
        let masked = image.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ]).cropped(to: extent)

        guard let maskedMean = areaAverage(masked, extent: extent),
              let maskMean = areaAverage(mask, extent: extent) else {
            return nil
        }
        let coverage = max(maskMean.red, 0.001)
        return (maskedMean.red / coverage, maskedMean.green / coverage, maskedMean.blue / coverage)
    }

    private static func areaAverage(_ image: CIImage, extent: CGRect) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        skyMatchContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: briefEditsSRGBColorSpace
        )
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }
