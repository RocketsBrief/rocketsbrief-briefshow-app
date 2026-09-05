// Exports every preset through LightroomPresetExport and reads it straight back
// through LightroomPresetImport, against the app's own sources.
//
// The point is not that the file looks like Adobe's. It is that the numbers
// survive: every scale, sign and baseline in the exporter is the inverse of one
// in the importer, and an inverse that is off by a sign or a factor of a
// hundred is invisible by inspection and obvious here.
//
//   roundtrip [an existing .xmp to start from]
import Foundation
import CoreImage
import AppKit

var failures = 0

func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.006) -> Bool {
    abs(a - b) <= tolerance
}

func check(_ label: String, _ got: Double, _ want: Double, _ tolerance: Double = 0.006) {
    let ok = near(got, want, tolerance)
    if !ok { failures += 1 }
    print(String(format: "  %@ %-34@ got %+.4f  want %+.4f",
                 ok ? "ok  " : "FAIL", label as NSString, got, want))
}

func roundTrip(_ preset: PhotoEditPreset, label: String) -> PhotoEditSettings? {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("roundtrip-\(UUID().uuidString).xmp")
    do {
        try LightroomPresetExport.write(preset, to: url)
    } catch {
        print("  FAIL \(label): could not write — \(error)")
        failures += 1
        return nil
    }
    defer { try? FileManager.default.removeItem(at: url) }

    guard let back = try? LightroomPresetImport.read(url) else {
        print("  FAIL \(label): the exported file could not be read back")
        failures += 1
        return nil
    }
    if back.preset.name != preset.name {
        print("  FAIL \(label): name came back as \"\(back.preset.name)\"")
        failures += 1
    }
    return back.preset.settings
}

func compare(_ a: PhotoEditSettings, _ b: PhotoEditSettings) {
    check("exposure", b.exposure, a.exposure)
    check("contrast", b.contrast, a.contrast)
    check("highlights", b.highlights, a.highlights)
    check("shadows", b.shadows, a.shadows)
    check("whites", b.whites, a.whites)
    check("blacks", b.blacks, a.blacks)
    check("texture", b.texture, a.texture)
    check("clarity", b.clarity, a.clarity)
    check("dehaze", b.dehaze, a.dehaze)
    check("vibrance", b.vibrance, a.vibrance)
    check("saturation", b.saturation, a.saturation)
    // Sharpness goes out through a divisor of 265 and comes back through it, so
    // one whole Lightroom step is the finest it can hold.
    check("sharpness", b.sharpness, a.sharpness, 1 / 265.0 + 0.0001)
    check("sharpenRadius", b.sharpenRadius, a.sharpenRadius, 0.06)
    check("vignette", b.vignette, a.vignette)
    check("vignetteMidpoint", b.vignetteMidpoint, a.vignetteMidpoint)
    check("vignetteFeather", b.vignetteFeather, a.vignetteFeather)
    check("vignetteRoundness", b.vignetteRoundness, a.vignetteRoundness)
    for band in ColorBand.allCases {
        let x = a.colorMixer[band] ?? ColorMixerBand()
        let y = b.colorMixer[band] ?? ColorMixerBand()
        check("\(band.title).hue", y.hue, x.hue)
        check("\(band.title).sat", y.saturation, x.saturation)
        check("\(band.title).lum", y.luminance, x.luminance)
    }
}

print("1. a preset with every control moved")
var busy = PhotoEditSettings()
busy.exposure = -0.10; busy.contrast = -0.05; busy.highlights = -0.77
busy.shadows = 0.70; busy.whites = 0.25; busy.blacks = -0.28
busy.texture = -0.14; busy.clarity = 0.07; busy.dehaze = 0.04
busy.vibrance = 0.10; busy.saturation = -0.20
busy.sharpness = 0.15; busy.sharpenRadius = 1.1
busy.vignette = 0.19; busy.vignetteMidpoint = 0.5
busy.vignetteFeather = 1.0; busy.vignetteRoundness = 0
for (i, band) in ColorBand.allCases.enumerated() {
    var m = ColorMixerBand()
    m.hue = Double(i) * 0.11 - 0.4
    m.saturation = 0.39 - Double(i) * 0.09
    m.luminance = -0.21 + Double(i) * 0.05
    busy.colorMixer[band] = m
}
busy.temperatureKelvin = 6339
busy.tintAbsolute = -10
if let back = roundTrip(PhotoEditPreset(id: UUID(), name: "Everything Moved", settings: busy),
                        label: "everything moved") {
    compare(busy, back)
    check("absolute Kelvin", back.temperatureKelvin ?? 0, 6339, 1)
    check("absolute tint", back.tintAbsolute ?? 0, -10, 1)
}

print("\n2. a neutral preset stays neutral, and keeps the photo's own white balance")
let neutral = PhotoEditSettings()
if let back = roundTrip(PhotoEditPreset(id: UUID(), name: "Neutral", settings: neutral),
                        label: "neutral") {
    compare(neutral, back)
    if back.temperatureKelvin != nil {
        print("  FAIL a neutral preset must not name a Kelvin — As Shot means leave it alone")
        failures += 1
    } else {
        print("  ok   white balance left As Shot")
    }
}

print("\n3. a temperature OFFSET survives as an offset")
var offset = PhotoEditSettings()
offset.temperature = 0.25
offset.tint = -0.10
if let back = roundTrip(PhotoEditPreset(id: UUID(), name: "Warmer", settings: offset),
                        label: "offset") {
    check("temperature offset", back.temperature, 0.25, 0.02)
    check("tint offset", back.tint, -0.10, 0.02)
}

let extra = Array(CommandLine.arguments.dropFirst())
if let path = extra.first, !path.isEmpty {
    print("\n4. the client's own preset: \(URL(fileURLWithPath: path).lastPathComponent)")
    if let first = try? LightroomPresetImport.read(URL(fileURLWithPath: path)) {
        if let back = roundTrip(first.preset, label: "the client's preset") {
            compare(first.preset.settings, back)
        }
    } else {
        print("  FAIL could not read \(path)")
        failures += 1
    }
}

// ⚠️ THE SETTINGS MATCHING IS NOT THE QUESTION THE CLIENT ASKED. His was
// *„taj preset kada exportujem i posle importujem u C4S u drugom macu radi
// ce?"* — will the PICTURE be the same. So when a photograph is given, both
// the original preset and the round-tripped one are rendered through the real
// pipeline and the two are compared pixel for pixel.
if extra.count > 1 {
    let photo = URL(fileURLWithPath: extra[1])
    print("\n5. the same photograph, before and after the round trip: \(photo.lastPathComponent)")
    let source = extra.first ?? "-"
    if let original = try? LightroomPresetImport.read(URL(fileURLWithPath: source)),
       let back = roundTrip(original.preset, label: "render check"),
       let base = PhotoEditRenderer.loadBaseImage(from: photo, maxPixelSize: 900) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: srgb])
        func bytes(_ s: PhotoEditSettings) -> [UInt8]? {
            let image = PhotoEditRenderer.render(s, on: base)
            guard let cg = ctx.createCGImage(image, from: image.extent,
                                             format: .RGBA8, colorSpace: srgb) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cg)
            return rep.representation(using: .png, properties: [:]).map { [UInt8]($0) }
        }
        if let a = bytes(original.preset.settings), let b = bytes(back) {
            let same = a == b
            if !same { failures += 1 }
            print("  \(same ? "ok  " : "FAIL") the rendered photograph is \(same ? "byte for byte identical" : "DIFFERENT")")
        }
    }
}

print(failures == 0 ? "\nRESULT: OK — 0 failures" : "\nRESULT: FAILED — \(failures)")
exit(failures == 0 ? 0 : 1)
