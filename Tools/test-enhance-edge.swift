// Does Background Enhanced draw a line around the people?
//
// Reported 23.09 with two photos (C4S Problem Screenshots 5 and 6): after the
// photo had been edited, Background Enhanced left a thin DARK outline around
// both subjects — round the hair, the arms, the shoulders. On an unedited photo
// it did not.
//
// This runs the recipe the way PortraitRecipeService.run does — render, Select
// People on that render, the recipe on the Background layer, render again — and
// measures the ring where the person matte is soft (0.15…0.85) against the two
// bands on either side of it. A line is the ring coming out darker than BOTH.
//
//     enhance-edge <photo> [size] [out-dir]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("enhance-edge <photo> [size] [out]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1600) : 1600
let outDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])
func load() -> PhotoBaseImage { PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size))! }

var edited = PhotoEditSettings()
// Close to the client's own panel in screenshot 7.
edited.texture = -0.48
edited.clarity = 0.20
edited.dehaze = 0.31
edited.blacks = -0.27
edited.saturation = 0.15
edited.contrast = 0.2
// ONLY=<name> keeps one of them, to find which one a failure follows.
if let only = ProcessInfo.processInfo.environment["ONLY"] {
    var one = PhotoEditSettings()
    switch only {
    case "texture": one.texture = edited.texture
    case "clarity": one.clarity = edited.clarity
    case "dehaze": one.dehaze = edited.dehaze
    case "blacks": one.blacks = edited.blacks
    case "saturation": one.saturation = edited.saturation
    case "contrast": one.contrast = edited.contrast
    default: break
    }
    edited = one
}

struct EdgeResult { let ring, inner, outer: Double; let image: CIImage }

func run(_ settings: PhotoEditSettings, label: String) -> EdgeResult {
    let base = load()
    let full = PhotoEditRenderer.render(settings, on: base, applyCrop: false)
    guard let made = PeopleLayerFactory.make(from: full, confinedTo: nil,
                                             backgroundName: "Background", peopleName: "Subjects") else {
        print("nobody in \(url.lastPathComponent)"); exit(1)
    }
    if ProcessInfo.processInfo.environment["DIAG"] == "1",
       let cut = CIImage(data: made.people.imageData) {
        // The stored cut-out against the photo it was cut from, where it is solid.
        let e = full.extent
        let px = e.minX + made.people.x * e.width
        let py = e.minY + (1 - made.people.y - made.people.height) * e.height
        let placed = cut.transformed(by: CGAffineTransform(translationX: px - cut.extent.minX, y: py - cut.extent.minY))
        let r = placed.extent.integral.intersection(e)
        let w = Int(r.width), h = Int(r.height)
        var a = [UInt8](repeating: 0, count: w * h * 4), b = a
        ctx.render(placed, toBitmap: &a, rowBytes: w * 4, bounds: r, format: .RGBA8, colorSpace: srgb)
        ctx.render(full, toBitmap: &b, rowBytes: w * 4, bounds: r, format: .RGBA8, colorSpace: srgb)
        var sum = 0.0, n = 0
        for i in stride(from: 0, to: a.count, by: 4) where a[i+3] == 255 {
            for c in 0..<3 { sum += Double(a[i+c]) - Double(b[i+c]) }
            n += 3
        }
        print(String(format: "  DIAG %@: cut-out minus photo where solid: %+.2f levels over %d px   cut extent %@  box %.1f,%.1f %.1fx%.1f",
                     label, sum / Double(max(n, 1)), n / 3, NSStringFromRect(cut.extent),
                     px, py, made.people.width * e.width, made.people.height * e.height))
    }
    var s = settings
    var people = made.people
    if ProcessInfo.processInfo.environment["FROZEN"] == "1" { people.liveSource = nil }
    s.layers = [made.background, people]
    s = PortraitRecipe.backgroundEnhanced.applied(to: s, backgroundID: made.background.id,
                                                  peopleID: made.people.id)
    // PEOPLE_ONLY=1: the People layer alone, no Background, no recipe — to
    // tell a fault in the layer from a fault in what the recipe does.
    if ProcessInfo.processInfo.environment["PEOPLE_ONLY"] == "1" { s = settings; s.layers = [people] }
    let out = PhotoEditRenderer.render(s, on: load(), applyCrop: false)

    let mask = SubjectMasker.personMask(for: full)!
    let e = full.extent
    let w = Int(e.width), h = Int(e.height)
    func rgba(_ i: CIImage) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(i.cropped(to: e), toBitmap: &b, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: srgb)
        return b
    }
    let m = rgba(mask), px = rgba(out), before = rgba(full)
    // Luminance CHANGE the recipe made, per band — the people should not move
    // at all, the ring should sit between inner and outer, never below both.
    var sums = [0.0, 0.0, 0.0], counts = [0, 0, 0]
    for i in stride(from: 0, to: px.count, by: 4) {
        let a = Double(m[i]) / 255
        let band: Int
        if a > 0.15 && a < 0.85 { band = 0 } else if a >= 0.85 && a < 0.97 { band = 1 } else if a > 0.03 && a <= 0.15 { band = 2 } else { continue }
        func lum(_ p: [UInt8]) -> Double { 0.2126 * Double(p[i]) + 0.7152 * Double(p[i+1]) + 0.0722 * Double(p[i+2]) }
        sums[band] += lum(px) - lum(before)
        counts[band] += 1
    }
    let r = EdgeResult(ring: sums[0] / Double(max(counts[0], 1)),
                   inner: sums[1] / Double(max(counts[1], 1)),
                   outer: sums[2] / Double(max(counts[2], 1)), image: out)
    print(String(format: "%-9@ change: inner band %+6.1f   RING %+6.1f   outer band %+6.1f",
                 label as NSString, r.inner, r.ring, r.outer))
    if let outDir, let png = ctx.pngRepresentation(of: out, format: .RGBA8, colorSpace: srgb) {
        try? png.write(to: outDir.appendingPathComponent("enhance-\(label).png"))
        if let before = ctx.pngRepresentation(of: full, format: .RGBA8, colorSpace: srgb) {
            try? before.write(to: outDir.appendingPathComponent("before-\(label).png"))
        }
    }
    return r
}

print("photo: \(url.lastPathComponent)\n")
let plain = run(PhotoEditSettings(), label: "original")
let worked = run(edited, label: "edited")

// A line: the ring drops further than the darker of its two neighbours.
func line(_ r: EdgeResult) -> Double { min(r.inner, r.outer) - r.ring }
print(String(format: "\nline depth (how far the ring falls below both sides): original %.1f   edited %.1f",
             line(plain), line(worked)))
let bad = line(worked) > 3 || line(plain) > 3
print(bad ? "RESULT: LINE around the subject" : "RESULT: OK")
exit(bad ? 1 : 0)
