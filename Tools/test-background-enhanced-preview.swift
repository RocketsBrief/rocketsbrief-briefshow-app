// Does the Background Enhanced card's preview CHANGE when a number moves?
// Reported 24.09: *„kada pomeram recimo saturation … uopste ne vidim da se menja
// … backround"*. Same steps as BackgroundEnhancedCard.prepare/rerender.
import Foundation
import CoreImage
import AppKit

extension BackgroundEnhancedTuning.Control {
    var photoKeyPath: WritableKeyPath<PhotoEditSettings, Double> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .shadows: return \.shadows
        case .saturation: return \.saturation
        case .clarity: return \.clarity
        case .dehaze: return \.dehaze
        }
    }
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: 900) else { exit(1) }
var settings = PhotoEditSettings()
let full = PhotoEditRenderer.render(settings, on: base, applyCrop: false)
guard let made = PeopleLayerFactory.make(from: full, confinedTo: nil, backgroundName: "Background", peopleName: "Subjects") else {
    print("nobody"); exit(1)
}
settings.layers.append(made.background); settings.layers.append(made.people)
func pixels(_ t: BackgroundEnhancedTuning) -> ([UInt8], Double) {
    let s = PortraitRecipe.backgroundEnhanced.applied(to: settings, backgroundID: made.background.id,
                                                      peopleID: made.people.id, tuning: t)
    let t0 = Date()
    let image = PhotoEditRenderer.render(s, on: base, applyCrop: true)
    let e = image.extent.integral, w = Int(e.width), h = Int(e.height)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: srgb) }
    return (out, Date().timeIntervalSince(t0) * 1000)
}
// For scale: the same move on the PHOTO, no layers at all.
func photoPixels(_ edit: (inout PhotoEditSettings) -> Void) -> [UInt8] {
    var s = PhotoEditSettings(); edit(&s)
    let image = PhotoEditRenderer.render(s, on: base, applyCrop: true)
    let e = image.extent.integral, w = Int(e.width), h = Int(e.height)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: srgb) }
    return out
}
func mean(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var d = 0.0
    for i in stride(from: 0, to: min(a.count, b.count), by: 4) { d += abs(Double(a[i]) - Double(b[i])) + abs(Double(a[i+1]) - Double(b[i+1])) + abs(Double(a[i+2]) - Double(b[i+2])) }
    return d / Double(a.count / 4 * 3)
}
let (a, ms) = pixels(BackgroundEnhancedTuning())
print(String(format: "one preview render: %.0f ms", ms))
var failures = 0
for control in BackgroundEnhancedTuning.Control.allCases {
    var t = BackgroundEnhancedTuning()
    t[control] = control.range.upperBound
    let (b, _) = pixels(t)
    var diff = 0.0
    for i in stride(from: 0, to: a.count, by: 4) { diff += abs(Double(a[i]) - Double(b[i])) + abs(Double(a[i+1]) - Double(b[i+1])) + abs(Double(a[i+2]) - Double(b[i+2])) }
    let moved = diff / Double(a.count / 4 * 3)
    // The same move on the whole photo, for scale: Shadows on a frame with no
    // shadows moves nothing anywhere, and that is not the card's fault.
    let base0 = BackgroundEnhancedTuning()[control]
    let onPhoto = mean(photoPixels { $0[keyPath: control.photoKeyPath] = base0 },
                       photoPixels { $0[keyPath: control.photoKeyPath] = control.range.upperBound })
    print(String(format: "%-11@ at %+.2f: preview moved %.2f levels   (whole photo: %.2f)",
                 control.title as NSString, control.range.upperBound, moved, onPhoto))
    if onPhoto > 0.5 && moved < onPhoto * 0.15 { failures += 1; print("  FAIL — the preview does not follow") }
}
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) controls do nothing to the preview")
exit(failures == 0 ? 0 : 1)
