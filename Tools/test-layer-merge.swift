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

// MARK: - Merging INTO the photograph (KORAK 208)

print("\nthe rule for Image + Template")
do {
    let bottom = piece("Bottom"), middle = piece("Middle"), top = piece("Top")
    let stack = [bottom, middle, top]   // bottom to top, as settings.layers stores it
    func refusal(_ image: Bool, _ template: Bool, _ ids: [UUID]) -> String? {
        briefShowPhotoMergeRefusal(imagePicked: image, templatePicked: template,
                                   pickedLayerIDs: Set(ids), layers: stack)
    }
    check("Image + Template merge", refusal(true, true, []) == nil)
    check("Image + Template + the bottom layer merge", refusal(true, true, [bottom.id]) == nil)
    check("Image + the two lowest layers merge", refusal(true, false, [bottom.id, middle.id]) == nil)
    check("the frame alone is refused, and says to tick Image",
          refusal(false, true, [])?.contains("tick Image") == true)
    check("Image alone is refused — nothing to merge into it", refusal(true, false, []) != nil)
    // ⚠️ The one that would change the picture: a ticked layer with an
    // unticked one under it would be pulled beneath it into the photo.
    let skipped = refusal(true, true, [middle.id])
    check("a ticked layer above an unticked one is refused", skipped != nil)
    check("  and the reason names both layers",
          skipped?.contains("Middle") == true && skipped?.contains("Bottom") == true, skipped ?? "nil")
    check("nothing ticked says what to tick", refusal(false, false, []) != nil)
}

print("\ntext in the merge into the photo")
do {
    let bottom = piece("Bottom"), top = piece("Top")
    let stack = [bottom, top]
    func refusal(_ image: Bool, _ template: Bool, _ ids: [UUID], texts: Int, hasTemplate: Bool) -> String? {
        briefShowPhotoMergeRefusal(imagePicked: image, templatePicked: template,
                                   pickedLayerIDs: Set(ids), layers: stack,
                                   pickedTextCount: texts, hasTemplate: hasTemplate)
    }
    check("Image + text merge on a photo with no layers left out",
          refusal(true, false, [bottom.id, top.id], texts: 1, hasTemplate: false) == nil)
    check("Image + Template + text + every layer merge",
          refusal(true, true, [bottom.id, top.id], texts: 2, hasTemplate: true) == nil)
    check("text alone says to tick Image",
          refusal(false, false, [], texts: 1, hasTemplate: false)?.contains("tick Image") == true)
    check("text on a print without the frame says to tick Template",
          refusal(true, false, [bottom.id, top.id], texts: 1, hasTemplate: true)?.contains("Template") == true)
    // ⚠️ The one that changes the picture: baked text goes to the bottom, and
    // a layer left live would be drawn over the letters.
    let left = refusal(true, true, [bottom.id], texts: 1, hasTemplate: true)
    check("text with a layer left live is refused, and names it",
          left?.contains("Top") == true, left ?? "nil")
}

print("\nwhich row a ⌘-click lands on")
do {
    let id = UUID()
    let frames: [MergeRowKey: CGRect] = [
        .text(id): CGRect(x: 0, y: 0, width: 200, height: 30),
        .template: CGRect(x: 0, y: 40, width: 200, height: 30),
        .image: CGRect(x: 0, y: 80, width: 200, height: 30),
    ]
    check("a click on a text row is that line", briefShowMergeRow(at: CGPoint(x: 50, y: 10), in: frames) == .text(id))
    check("a click on the frame's row is the frame", briefShowMergeRow(at: CGPoint(x: 150, y: 55), in: frames) == .template)
    check("a click on the photo's row is the photo", briefShowMergeRow(at: CGPoint(x: 5, y: 100), in: frames) == .image)
    check("a click in the gap between rows ticks nothing", briefShowMergeRow(at: CGPoint(x: 50, y: 35), in: frames) == nil)
}

print(failures == 0 ? "\nall passed\n" : "\n\(failures) FAILED\n")
exit(failures == 0 ? 0 : 1)
