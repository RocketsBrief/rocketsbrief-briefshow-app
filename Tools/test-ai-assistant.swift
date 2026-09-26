// AI Assistant (26.09): does solving every photo to one target look actually
// make a set of photos alike — and does it land on the target the client chose?
//
//     ai-assistant <folder> [count] [out-dir]
//
// Starts every photo from neutral settings (not the client's store), measures
// the set, moves the target by "Brighter", "More" contrast and background
// colour +30, solves each photo, and measures again. The spread of each measure
// across the set must fall, and the set must land near the target. Also checks
// the horizon sign, a crop, and prints the eye verdicts. Writes before/after
// contact sheets when an out-dir is given.
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("ai-assistant <folder> [count] [out]"); exit(2) }
let folder = URL(fileURLWithPath: first)
let count = args.count > 1 ? (Int(args[1]) ?? 12) : 12
let outDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil
let files = (try! FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
    .filter { ["nef", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.contains(" ") }
    .sorted { $0.path < $1.path }
let step = max(1, files.count / count)
let picked = stride(from: 0, to: files.count, by: step).prefix(count).map { files[$0] }
print("\(picked.count) photos from \(folder.lastPathComponent)")

var options = AIAssistantOptions()
options.brightness = .brighter
options.contrast = .more
options.backgroundColour = 30

struct Item { let url: URL; let base: PhotoBaseImage; let frame: AIAssistantMatcher.Frame; let before: AIAssistantLook }
var items: [Item] = []
for url in picked {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: AIAssistantMatcher.side) else { continue }
    let image = PhotoEditRenderer.render(PhotoEditSettings(), on: base, applyCrop: false)
    let frame = AIAssistantMatcher.frame(for: image)
    items.append(Item(url: url, base: base, frame: frame, before: AIAssistantMatcher.look(of: image, in: frame)))
}
let target = AIAssistantMatcher.adjusted(AIAssistantMatcher.median(of: items.map(\.before)), by: options)

var after: [AIAssistantLook] = []
var solved: [PhotoEditSettings] = []
let t0 = Date()
for item in items {
    var s = AIAssistantMatcher.match(PhotoEditSettings(), on: item.base, frame: item.frame, to: target,
                                     lift: options.brightness.lift, isCancelled: { false })
    s.contrast += options.contrast.amount
    s.backgroundSaturation += options.backgroundColour * 1.5 / 100
    solved.append(s)
    after.append(AIAssistantMatcher.look(of: PhotoEditRenderer.render(s, on: item.base, applyCrop: false), in: item.frame))
}
let perPhoto = Date().timeIntervalSince(t0) / Double(max(items.count, 1))

func sd(_ v: [Double]) -> Double {
    let m = v.reduce(0, +) / Double(max(v.count, 1))
    return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(v.count, 1))).squareRoot()
}
func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(v.count, 1)) }
var failures = 0
// Only the people are solved to one target (see AIAssistantMatcher.knobs).
let measures: [(String, (AIAssistantLook) -> Double, Double)] = [
    ("people L", { $0.subjectL }, 2.5), ("warmth b*", { $0.b }, 1.5), ("tint a*", { $0.a }, 1.5),
]
let people = items.filter { $0.before.hasPeople }.count
print("people found in \(people) of \(items.count)")
for (name, read, near) in measures {
    let usable = zip(items.map(\.before), after).filter { $0.0.hasPeople || !name.contains("background") && !name.contains("people") }
    let b = usable.map { read($0.0) }, a = usable.map { read($0.1) }
    let miss = abs(mean(a) - read(target))
    print(String(format: "%-18@ spread across the set %6.2f -> %5.2f   target %6.2f, set lands at %6.2f",
                 name as NSString, sd(b), sd(a), read(target), mean(a)))
    if sd(a) > max(sd(b) * 0.6, near) { print("  FAIL the photos did not come together"); failures += 1 }
    if miss > near { print("  FAIL the set missed the target"); failures += 1 }
}
// The background keeps its own brightness: lifted by at most half the
// client's Brightness, and never pushed past the ceiling by the solve.
for (item, a) in zip(items, after) where item.before.hasPeople {
    let allowed = max(item.before.backgroundL + options.brightness.lift / 2, AIAssistantMatcher.backgroundCeiling) + 2.5
    let note = a.backgroundL > allowed ? "  FAIL background pushed too far" : ""
    print(String(format: "  background %@: %.1f -> %.1f%@", item.url.lastPathComponent as NSString,
                 item.before.backgroundL, a.backgroundL, note as NSString))
    if !note.isEmpty { failures += 1 }
}
print(String(format: "solve: %.0f ms a photo at %.0f px", perPhoto * 1000, AIAssistantMatcher.side))
for (item, s) in zip(items, solved) {
    print(String(format: "  %@  Exp %+.2f  BgExp %+.2f  Con %+.2f  Temp %+.2f  Tint %+.2f  BgSat %+.2f",
                 item.url.lastPathComponent as NSString, s.exposure, s.backgroundExposure, s.contrast,
                 s.temperature, s.tint, s.backgroundSaturation))
}

// Horizon sign: a picture turned by +4° must be read as needing about −4°.
if let item = items.first {
    let plain = AIAssistantFraming.horizonCorrection(of: PhotoEditRenderer.render(PhotoEditSettings(), on: item.base, applyCrop: false))
    var turned = PhotoEditSettings(); turned.straightenDegrees = 4
    let read = AIAssistantFraming.horizonCorrection(of: PhotoEditRenderer.render(turned, on: item.base, applyCrop: false))
    print("horizon: plain \(plain.map { String(format: "%.2f", $0) } ?? "none"), after +4° \(read.map { String(format: "%.2f", $0) } ?? "none")")
    if let read, abs(read + 4 - (plain ?? 0)) > 1 { print("  FAIL horizon correction has the wrong sign or size"); failures += 1 }
}

// Eyes.
for url in picked {
    let found = AIAssistantInspector.inspect(url)
    print("  eyes \(url.lastPathComponent): \(found.eyes)  sharpness \(Int(found.sharpness))\(found.sharpnessFromFaces ? " (faces)" : "")")
}

if let outDir {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let ctx = AIAssistantMatcher.context
    func sheet(_ images: [CIImage], _ name: String) {
        let tile = 256.0
        let cols = 6, rows = (images.count + cols - 1) / cols
        let size = NSSize(width: tile * Double(cols), height: tile * 0.7 * Double(rows))
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
        for (i, img) in images.enumerated() {
            guard let cg = ctx.createCGImage(img, from: img.extent) else { continue }
            let r = img.extent, scale = min(tile / r.width, tile * 0.7 / r.height)
            let w = r.width * scale, h = r.height * scale
            let x = Double(i % cols) * tile + (tile - w) / 2
            let y = size.height - Double(i / cols + 1) * tile * 0.7 + (tile * 0.7 - h) / 2
            NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: x, y: y, width: w, height: h))
        }
        canvas.unlockFocus()
        if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])?.write(to: outDir.appendingPathComponent(name))
        }
    }
    sheet(items.map { PhotoEditRenderer.render(PhotoEditSettings(), on: $0.base, applyCrop: false) }, "before.jpg")
    sheet(zip(items, solved).map { PhotoEditRenderer.render($1, on: $0.base, applyCrop: false) }, "after.jpg")
    // One crop, drawn.
    var framed: [CIImage] = []
    for (item, s) in zip(items, solved) {
        let img = PhotoEditRenderer.render(s, on: item.base, applyCrop: false)
        if let c = AIAssistantFraming.crop(for: img, frame: item.frame, shape: .fourThree, allowed: .full) {
            var cs = s; cs.crop = c.rect; cs.cropAspect = c.aspect
            framed.append(PhotoEditRenderer.render(cs, on: item.base))
        }
    }
    sheet(framed, "cropped.jpg")
}
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) failed")
exit(failures == 0 ? 0 : 1)
