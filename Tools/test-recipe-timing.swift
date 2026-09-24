// How long one Background Enhanced takes at full size, step by step — the
// same steps PortraitRecipeService.run does, minus writing the TIFF.
import Foundation
import CoreImage
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])
var t = Date()
func lap(_ what: String) { print(String(format: "%-34@ %6.0f ms", what as NSString, Date().timeIntervalSince(t) * 1000)); t = Date() }
guard let base = PhotoEditRenderer.loadBaseImage(from: url) else { exit(1) }
lap("load")
var s = PhotoEditSettings()
let full = PhotoEditRenderer.render(s, on: base, applyCrop: false)
lap("render (lazy)")
guard let made = PeopleLayerFactory.make(from: full, confinedTo: nil, backgroundName: "B", peopleName: "P") else { print("nobody"); exit(1) }
lap("Select People (make layers)")
s.layers.append(made.background); s.layers.append(made.people)
s = PortraitRecipe.backgroundEnhanced.applied(to: s, backgroundID: made.background.id, peopleID: made.people.id)
let rendered = PhotoEditRenderer.render(s, on: base, applyCrop: false)
let cg = ctx.createCGImage(rendered, from: rendered.extent)
lap("render with the recipe, to pixels")
print("size \(cg?.width ?? 0)×\(cg?.height ?? 0)")
