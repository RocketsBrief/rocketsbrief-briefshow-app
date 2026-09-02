import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

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

/// Draws a sky to fill any extent.
///
/// Two properties matter more than how pretty the result is, and both are
/// easy to lose:
///
/// 1. **Deterministic.** `CIRandomGenerator` is a fixed function, not a
///    seeded RNG, so the same sky is drawn every render. Anything that
///    varied per call would mean the preview and the export were different
///    pictures.
/// 2. **Resolution-independent.** Every size in here is a fraction of the
///    extent, never a pixel count. The preview renders at 2600px and the
///    export at native, and a cloud measured in pixels would come out a
///    different size in each — the same trap `layerBlur` documents.
enum SkyPainter {

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


let out = URL(fileURLWithPath: CommandLine.arguments[1])
let ctx = CIContext()
let size = CGSize(width: 420, height: 260)
let extent = CGRect(origin: .zero, size: size)

let cols = 3
let rows = (SkyStyle.allCases.count + cols - 1) / cols
let sheet = NSImage(size: CGSize(width: size.width * CGFloat(cols),
                                 height: size.height * CGFloat(rows)))
sheet.lockFocus()
for (i, style) in SkyStyle.allCases.enumerated() {
    let ci = SkyPainter.image(style, extent: extent)
    guard let cg = ctx.createCGImage(ci, from: extent) else { print("FAIL \(style)"); continue }
    let x = CGFloat(i % cols) * size.width
    let y = CGFloat(rows - 1 - i / cols) * size.height
    NSImage(cgImage: cg, size: size).draw(in: CGRect(x: x, y: y, width: size.width, height: size.height))
    let label = NSString(string: style.label)
    label.draw(at: CGPoint(x: x + 10, y: y + 10), withAttributes: [
        .foregroundColor: NSColor.black,
        .font: NSFont.boldSystemFont(ofSize: 18)
    ])
}
sheet.unlockFocus()

let tiff = sheet.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote", out.path)
