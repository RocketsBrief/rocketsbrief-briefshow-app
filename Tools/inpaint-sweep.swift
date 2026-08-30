// Runs the REAL InpaintPipeline against a real photo, headless, so a recipe
// change can be LOOKED AT instead of argued about.
//
// Built and driven by Tools/run-inpaint-sweep.py, which copies the app's own
// Develop*Inpaint.swift next to this file rather than keeping a second copy of
// them — same rule as run-layer-reorder-test.py: the harness cannot drift from
// what ships, because it compiles what ships.
//
// Why it exists: both models fail QUIETLY. SD in particular returns a
// confident, well-lit picture of the wrong thing, and no amount of reading the
// code tells you which. The only honest test is to run it and look, and doing
// that through the app needs a mouse, a folder, a login and thirteen seconds a
// go.
//
// Usage (see the runner for a worked example):
//   sweep <photo> <outdir> <ux> <uy> <uw> <uh> [lama]
// where ux/uy/uw/uh are the rectangle to repair, in unit coordinates with the
// origin TOP-LEFT — the same space the app stores brush strokes in.
//
//   SWEEP=1.0,3.5,7.5   guidance values to try (SD only)
//   PROMPTS=a|b|c       prompts to try, "@default" for the shipping one
//
// Each result is composited back onto the photo exactly the way the app's
// layer compositing does and written as a PNG cropped to a window around the
// repair, because a 3000px frame does not show a 400px mistake.
import Foundation
import CoreImage
import AppKit

// Headless driver for the REAL InpaintPipeline, so a recipe change can be
// measured on a real photo instead of argued about.
let args = CommandLine.arguments
guard args.count >= 7 else {
    print("usage: sdsweep <photo> <outdir> <ux> <uy> <uw> <uh> [engine]")
    exit(2)
}
let photoURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let ux = Double(args[3])!, uy = Double(args[4])!, uw = Double(args[5])!, uh = Double(args[6])!
let engine = args.count > 7 ? args[7] : "sd"

let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
guard let image = CIImage(contentsOf: photoURL) else { print("cannot read photo"); exit(1) }
let extent = image.extent
print("photo \(Int(extent.width))x\(Int(extent.height))")

// A rectangular mask, white where the repair should happen. Unit coords are
// top-left origin to match how the app stores strokes; CIImage is bottom-up.
let rect = CGRect(x: extent.minX + ux * extent.width,
                  y: extent.minY + (1 - uy - uh) * extent.height,
                  width: uw * extent.width, height: uh * extent.height)
let mask = CIImage(color: .white).cropped(to: rect)
    .composited(over: CIImage(color: .black).cropped(to: extent))
print("mask \(Int(rect.width))x\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY))")

func write(_ removal: InpaintPipeline.Removal, _ name: String) {
    // Composite the returned patch back onto the photo, exactly the way the
    // app's layer compositing does, so what is looked at is what would ship.
    guard let patch = CIImage(data: removal.pngData) else { return }
    let target = CGRect(x: extent.minX + removal.boundsUnit.minX * extent.width,
                        y: extent.minY + (1 - removal.boundsUnit.minY - removal.boundsUnit.height) * extent.height,
                        width: removal.boundsUnit.width * extent.width,
                        height: removal.boundsUnit.height * extent.height)
    let placed = patch
        .transformed(by: CGAffineTransform(scaleX: target.width / patch.extent.width,
                                           y: target.height / patch.extent.height))
        .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
    let composited = placed.composited(over: image)
    // Cropped to a window around the repair so the difference is actually
    // visible rather than three pixels of a 6000px frame.
    let window = target.insetBy(dx: -target.width * 0.8, dy: -target.height * 0.8).intersection(extent)
    let url = outDir.appendingPathComponent("\(name).png")
    try? context.writePNGRepresentation(of: composited.cropped(to: window),
                                        to: url, format: .RGBA8,
                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("  wrote \(url.lastPathComponent)")
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

if engine == "lama" {
    let start = Date()
    if let r = try? InpaintPipeline.quickAIRemoval(mask: mask, from: image, context: context) {
        print(String(format: "lama  %.1fs", Date().timeIntervalSince(start)))
        write(r, "lama")
    } else { print("lama returned nil") }
    exit(0)
}

let env = ProcessInfo.processInfo.environment
// Prompts are separated by "|" so a prompt can contain commas.
let prompts = (env["PROMPTS"] ?? "@default").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
for guidance in (env["SWEEP"] ?? "7.5").split(separator: ",") {
    setenv("BRIEFSHOW_SD_GUIDANCE", String(guidance), 1)
    for (n, raw) in prompts.enumerated() {
        // A non-default prompt has to go through the live TextEncoder; the
        // baked blob only covers the shipping one.
        if raw != "@default" { setenv("BRIEFSHOW_SD_NOBLOB", "1", 1) }
        let prompt = raw == "@default" ? SDInpaintPipeline.defaultPrompt : raw
        let label = "g\(guidance)-p\(n)"
        let start = Date()
        do {
            if let r = try InpaintPipeline.aiRemoval(
                mask: mask, from: image, context: context, prompt: prompt) {
                print(String(format: "%@  %.1fs   \"%@\"", label, Date().timeIntervalSince(start), prompt))
                write(r, "sd-\(label)")
            } else { print("\(label): nil") }
        } catch { print("\(label): \(error)") }
    }
}
