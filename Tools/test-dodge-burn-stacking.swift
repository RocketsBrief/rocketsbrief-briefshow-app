// Dodge & Burn builds up (18.09). Client: "burn i dodge rade do jedne granice!
// ne rade kada vise puta kliknem da dopunjuju". Runs the app's own renderer on
// a flat grey frame - no photograph needed.
import CoreImage
import Foundation

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])
let grey = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
let base = PhotoBaseImage.standard(grey)

func centre(_ adjustments: [LocalAdjustment]) -> Double {
    var settings = PhotoEditSettings()
    settings.localAdjustments = adjustments
    let image = PhotoEditRenderer.render(settings, on: base)
    var px = [UInt8](repeating: 0, count: 4)
    ctx.render(image, toBitmap: &px, rowBytes: 4,
               bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
               format: .RGBA8, colorSpace: srgb)
    return Double(px[0])
}

func stroke(erase: Bool = false) -> BrushStroke {
    BrushStroke(points: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)], size: 0.2, hardness: 0.9, isErase: erase)
}

func mask(_ name: String, _ exposure: Double, _ strokes: [BrushStroke]) -> LocalAdjustment {
    var a = LocalAdjustment.brush(name: name)
    a.settings.exposure = exposure
    a.brush?.strokes = strokes
    return a
}

var failed = false
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "PASS" : "FAIL")  \(label) — \(detail)")
    if !ok { failed = true }
}

let none = centre([])
let d1 = centre([mask("Dodge 1", 0.3, [stroke()])])
let d2 = centre([mask("Dodge 1", 0.3, [stroke(), stroke()])])
let d3 = centre([mask("Dodge 1", 0.3, [stroke(), stroke(), stroke()])])
let b1 = centre([mask("Burn 1", -0.3, [stroke()])])
let b2 = centre([mask("Burn 1", -0.3, [stroke(), stroke()])])
let plain1 = centre([mask("Brush 1", 0.3, [stroke()])])
let plain2 = centre([mask("Brush 1", 0.3, [stroke(), stroke()])])
let erased = centre([mask("Dodge 1", 0.3, [stroke(), stroke(), stroke(erase: true)])])

print("untouched \(none) | dodge 1/2/3 passes \(d1)/\(d2)/\(d3) | burn 1/2 \(b1)/\(b2) | plain brush 1/2 \(plain1)/\(plain2) | dodge x2 then erase \(erased)")
check("one Dodge pass lightens", d1 > none + 2, "\(none) -> \(d1)")
check("a second Dodge pass lightens MORE", d2 > d1 + 2, "\(d1) -> \(d2)")
check("a third one more again", d3 > d2 + 2, "\(d2) -> \(d3)")
check("Burn darkens, and a second pass darkens more", b1 < none - 2 && b2 < b1 - 2, "\(none) -> \(b1) -> \(b2)")
check("a plain Brush mask is unchanged: two strokes = one", abs(plain2 - plain1) <= 1, "\(plain1) vs \(plain2)")
check("one Dodge pass equals one plain-brush stroke at the same number", abs(d1 - plain1) <= 1, "\(d1) vs \(plain1)")
check("an erase stroke takes back the passes before it", abs(erased - none) <= 1, "\(erased) vs \(none)")
// A click with no drag is one point. It has to paint a dab, and two clicks more.
let click = BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], size: 0.2, hardness: 0.9, isErase: false)
let c1 = centre([mask("Dodge 1", 0.3, [click])])
let c2 = centre([mask("Dodge 1", 0.3, [click, click])])
check("a single CLICK dodges, and a second click adds to it", c1 > none + 2 && c2 > c1 + 2, "\(none) -> \(c1) -> \(c2)")
exit(failed ? 1 : 0)
