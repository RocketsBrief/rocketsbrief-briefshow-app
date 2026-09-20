// Merging layers, measured in the pixels it produces.
//
// The real `ImageLayer`, `LayerBlendMode`, the merge rule and the two small
// helpers are pasted in out of Develop.swift by the runner, so nothing here is
// a copy of them.
//
// What is being held down:
//
//   1. the RULE — what may be merged and what may not, and that the reason is
//      a sentence the menu can show rather than a silent grey item,
//   2. the NAME — two merges do not both come back as "Merged 1",
//   3. the BYTES — a merged layer really is a PNG, and PNG is what a mostly
//      transparent frame costs almost nothing in.
//
// The composite itself is driven in the app (it needs the whole renderer); the
// checks here are the ones that decide whether the client loses work.
//
//     layer-merge
import Foundation
import AppKit
// ⚠️ SwiftUI is imported for ONE reason: ColorMixerBand carries a `swatch:
// Color` for its own button, and ImageLayer cannot be compiled without the
// chain that reaches it. Nothing in this test draws anything.
import SwiftUI
import CoreGraphics
import CoreImage
import ImageIO

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

// ---- the real types and rule, pasted in by the extractor at run time ------

func piece(_ name: String, blend: LayerBlendMode = .normal, mask: Data? = nil) -> ImageLayer {
    ImageLayer(name: name, imageData: Data([1, 2, 3]),
               x: 0.1, y: 0.1, width: 0.2, height: 0.2,
               blendMode: blend, maskData: mask)
}

// MARK: - What may be merged

print("\nthe rule the menu reads")

check("two ordinary pieces merge",
      briefShowLayerMergeRefusal([piece("a"), piece("b")]) == nil)
check("one on its own does not — there is nothing to merge it with",
      briefShowLayerMergeRefusal([piece("a")]) != nil)
check("and neither does an empty selection",
      briefShowLayerMergeRefusal([]) != nil)

do {
    // Client, 21.09: *„da moze people i backround da se spoje kad se odvoje"* —
    // putting back by hand what Select People took apart.
    let people = piece("People 1", mask: Data([9, 9, 9]))
    let background = piece("Background 1", mask: Data([7, 7, 7]))
    check("People and Background merge with each other",
          briefShowLayerMergeRefusal([people, background]) == nil)

    // ⚠️ But never with a pasted piece: one is a region of the photograph and
    // the other is bytes from somewhere else.
    let refusal = briefShowLayerMergeRefusal([piece("a"), people])
    check("a derived layer does not merge with a pasted one", refusal != nil)
    check("and the reason says what to do instead",
          refusal?.contains("Flatten Photo") == true, refusal ?? "nil")

    // A blend mode is a pixel-layer question; derived layers do not composite
    // over transparency at all, so the rule must not refuse them for it.
    let blended = piece("People 2", blend: .multiply, mask: Data([5, 5, 5]))
    check("a blend mode does not stop two derived layers",
          briefShowLayerMergeRefusal([people, blended]) == nil,
          briefShowLayerMergeRefusal([people, blended]) ?? "")
}

do {
    // A blend is defined against what is UNDER it, and a merged piece carries
    // nothing under it.
    let multiply = piece("b", blend: .multiply)
    let refusal = briefShowLayerMergeRefusal([piece("a"), multiply])
    check("a layer with a blend mode refuses", refusal != nil)
    check("and the reason says what would happen",
          refusal?.contains("change the photo") == true, refusal ?? "nil")
}

check("every refusal is a whole sentence the menu can print",
      [briefShowLayerMergeRefusal([]),
       briefShowLayerMergeRefusal([piece("a")]),
       briefShowLayerMergeRefusal([piece("a"), piece("b", mask: Data([1]))]),
       briefShowLayerMergeRefusal([piece("a"), piece("b", blend: .screen)])]
        .allSatisfy { ($0?.count ?? 0) > 20 })

// MARK: - The name

print("\nthe name a merge comes back under")

check("the first merge is Merged 1",
      briefShowNextMergedLayerNumber(in: [piece("People 1"), piece("Layer 2")]) == 1)
check("the second is Merged 2",
      briefShowNextMergedLayerNumber(in: [ImageLayer(name: "Merged 1", imageData: Data([1]),
                                                     x: 0, y: 0, width: 1, height: 1)]) == 2)
check("and it takes the highest, not the count",
      briefShowNextMergedLayerNumber(in: [
        ImageLayer(name: "Merged 1", imageData: Data([1]), x: 0, y: 0, width: 1, height: 1),
        ImageLayer(name: "Merged 7", imageData: Data([1]), x: 0, y: 0, width: 1, height: 1)
      ]) == 8)
check("a layer the client renamed himself is not counted",
      briefShowNextMergedLayerNumber(in: [
        ImageLayer(name: "Merged sunset", imageData: Data([1]), x: 0, y: 0, width: 1, height: 1)
      ]) == 1)

// MARK: - The bytes

print("\nwhat a merged layer is made of")

do {
    // A frame of mostly nothing with a small opaque square in it — which is
    // the shape every merged layer has.
    let width = 800, height = 600
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        check("a test canvas could be made", false)
        exit(1)
    }
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 100, y: 100, width: 120, height: 120))
    guard let image = context.makeImage(), let data = briefShowPNGData(image) else {
        check("the frame encodes", false)
        exit(1)
    }

    check("a merged layer is PNG bytes", data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    check("and it decodes back at its own size",
          CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            .map { $0.width == width && $0.height == height } == true)
    // The reason it is PNG and not TIFF: a full frame of transparency costs
    // almost nothing. 800×600 RGBA is 1.9 MB raw.
    check("a mostly empty frame costs almost nothing",
          data.count < 20_000, "\(data.count) bytes for \(width * height * 4) raw")
    check("and the transparency survives the trip",
          CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            .map { $0.alphaInfo != .none } == true)
}

print(failures == 0 ? "\nall passed\n" : "\n\(failures) FAILED\n")
exit(failures == 0 ? 0 : 1)
