// The driver half of the sky-mask harness. The two maskers it calls are NOT
// here — run-skymask.py pulls them out of BriefShow/DevelopInpaint.swift and
// concatenates them in front of this file.
//
// ⚠️ They used to be here, copied by hand, and BRIEFSHOW_DEVELOP_NOTES.md said
// this tool "extracts them from the source at compile time". It did not. The
// copy happened to still be identical, which is the only reason nothing had
// been measured wrongly yet — change SkyMasker in the app, measure with this,
// and the numbers would have described the OLD code while looking like a
// measurement. The same class of mistake KORAK 66 already paid for three times.

let ctx = CIContext()
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let photo = CIImage(contentsOf: input) else { fatalError("no image") }
let extent = photo.extent
print("photo \(Int(extent.width))x\(Int(extent.height))")

guard let mask = SkyMasker.skyMask(for: photo) else { print("NO SKY FOUND"); exit(0) }

let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1)).cropped(to: extent)
let tint = red.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55)])
let blend = CIFilter.blendWithMask()
blend.inputImage = tint.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: photo])
blend.backgroundImage = photo
blend.maskImage = mask
let cg = ctx.createCGImage(blend.outputImage!.cropped(to: extent), from: extent)!
try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: output)
print("wrote", output.path)
