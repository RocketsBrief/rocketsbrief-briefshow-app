// One step back for the portrait recipes, proved on real files.
//
// ⚠️ WHY A TEST AND NOT A LOOK. Asked for on 12.09: *„When i want to undo
// enhanced backround i need to be able to do so. No to be forces to restart all
// settings from the image!"* — and an undo that only half works is worse than
// none, because the client presses it and keeps the damage. Three things have to
// go back together (the settings record, the flattened pixels, and the
// "before the first flatten" snapshot Unflatten reads), and the interesting
// cases are the ones nobody clicks through by hand: a recipe on a photo that was
// ALREADY baked, and a recipe run twice.
//
// Everything here is done to a throwaway file in a temporary directory, and the
// stores are emptied of it at the end — this runs against the same Application
// Support directory the shipping app uses.
//
//     recipe-undo
import Foundation
import CoreImage
import AppKit

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

// A photograph-shaped file. Its CONTENT does not matter — nothing here decodes
// it — but its name and size do, because that pair is how every store in the
// app keys a photo.
let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("recipe-undo-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
let photo = temporary.appendingPathComponent("C4S_undo_test.NEF")
try! Data(repeating: 0x42, count: 4096).write(to: photo)

defer {
    PortraitRecipeUndoStore.forget(photo)
    _ = FlattenedImageStore.unflatten(photo)
    try? FileManager.default.removeItem(at: temporary)
}

let context = CIContext()

/// Writes a flattened copy whose pixels are a flat shade, so which copy is on
/// disk can be told apart by reading one byte back.
///
/// ⚠️ Returns what landed on disk rather than what was asked for. `flatten`
/// writes through the app's sRGB colour space, so a request for 0.50 comes back
/// as 145 and not 128 — and the question these checks ask is never "what shade
/// is this" but "WHICH of the two copies is this", so the recorded value is the
/// thing to compare against.
@discardableResult
func bakeFlattened(shade: Double, settings: PhotoEditSettings) -> Int {
    let colour = CIImage(color: CIColor(red: shade, green: shade, blue: shade))
        .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    try! FlattenedImageStore.flatten(colour, settings: settings, for: photo, context: context)
    return flattenedShade() ?? -1
}

func flattenedShade() -> Int? {
    guard let url = FlattenedImageStore.flattenedURL(for: photo),
          let image = NSImage(contentsOf: url),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let colour = rep.colorAt(x: 0, y: 0) else {
        return nil
    }
    return Int((colour.usingColorSpace(.deviceRGB)?.redComponent ?? 0) * 255)
}

func settings(contrast: Double) -> PhotoEditSettings {
    var s = PhotoEditSettings()
    s.contrast = contrast
    return s
}

// ───────────────────────────────────────────────────────────────────────────
print("\na recipe on a photo that was never baked")

PortraitRecipeUndoStore.forget(photo)
_ = FlattenedImageStore.unflatten(photo)

let before = settings(contrast: 0.20)
PortraitRecipeUndoStore.record([.backgroundEnhanced], for: photo, settings: before)
bakeFlattened(shade: 0.25, settings: settings(contrast: 0.20))

check("the photo is flattened after the recipe", FlattenedImageStore.isFlattened(photo))
check("and there is an undo to offer", PortraitRecipeUndoStore.canUndo(photo))
check("named after the recipe that ran",
      PortraitRecipeUndoStore.undoableTitle(for: [photo]) == "Background Enhanced",
      PortraitRecipeUndoStore.undoableTitle(for: [photo]) ?? "nil")

let restored = PortraitRecipeUndoStore.undo(photo)
check("undo hands back the record from before the recipe",
      restored?.contrast == 0.20, "\(restored?.contrast ?? -99)")
check("the flattened copy is gone — there was nothing under it",
      !FlattenedImageStore.isFlattened(photo))
// ⚠️ The recipe's flatten wrote this, because it was the FIRST flatten. Left
// behind, Unflatten would offer to restore a state that no longer exists.
check("and Unflatten's snapshot is gone with it",
      FlattenedImageStore.snapshot(for: photo) == nil)
check("the undo is spent, not offered twice",
      !PortraitRecipeUndoStore.canUndo(photo))

// ───────────────────────────────────────────────────────────────────────────
// ⚠️ THE CASE THE CLIENT'S COMPLAINT IS ABOUT. He works on a photo, bakes it
// (an AI Clean Up, say), then runs the recipe. Unflatten would take him back
// past BOTH and hand him the recipe's own layers; this must take back only the
// recipe and leave the earlier bake exactly where it was.
print("\na recipe on a photo that was already baked")

PortraitRecipeUndoStore.forget(photo)
_ = FlattenedImageStore.unflatten(photo)

let earlierShade = bakeFlattened(shade: 0.50, settings: settings(contrast: 0.10))
let earlierSnapshot = FlattenedImageStore.snapshot(for: photo)
check("the earlier bake recorded its own snapshot", earlierSnapshot?.contrast == 0.10,
      "\(earlierSnapshot?.contrast ?? -99)")
check("and its pixels are on disk", earlierShade > 0, "\(earlierShade)")

PortraitRecipeUndoStore.record([.backgroundEnhanced], for: photo,
                               settings: settings(contrast: 0.35))
check("the earlier copy is moved aside, not left to be overwritten",
      !FlattenedImageStore.isFlattened(photo))

let recipeShade = bakeFlattened(shade: 0.90, settings: settings(contrast: 0.35))
check("the recipe's pixels are the ones on disk now",
      recipeShade != earlierShade && flattenedShade() == recipeShade,
      "\(recipeShade) vs \(earlierShade)")
check("and the earlier snapshot was NOT overwritten by the second flatten",
      FlattenedImageStore.snapshot(for: photo)?.contrast == 0.10,
      "\(FlattenedImageStore.snapshot(for: photo)?.contrast ?? -99)")

let back = PortraitRecipeUndoStore.undo(photo)
check("undo hands back the record from before the recipe", back?.contrast == 0.35,
      "\(back?.contrast ?? -99)")
check("the photo is still flattened — the earlier bake survived",
      FlattenedImageStore.isFlattened(photo))
check("and the pixels are the EARLIER bake's, not the recipe's",
      flattenedShade() == earlierShade,
      "\(flattenedShade() ?? -1), wanted \(earlierShade) not \(recipeShade)")
check("Unflatten still offers the state from before the first bake",
      FlattenedImageStore.snapshot(for: photo)?.contrast == 0.10,
      "\(FlattenedImageStore.snapshot(for: photo)?.contrast ?? -99)")

// ───────────────────────────────────────────────────────────────────────────
// One step, per photo, and this is where that is nailed down: the second run's
// entry must replace the first one, and the 142 MB sidecar from the first must
// not be left on disk forever.
print("\nrun twice — one step back, and no pile of sidecars")

PortraitRecipeUndoStore.forget(photo)
_ = FlattenedImageStore.unflatten(photo)

PortraitRecipeUndoStore.record([.backgroundEnhanced], for: photo,
                               settings: settings(contrast: 0.11))
let firstRunShade = bakeFlattened(shade: 0.30, settings: settings(contrast: 0.11))
PortraitRecipeUndoStore.record([.backgroundEnhanced], for: photo,
                               settings: settings(contrast: 0.22))
let secondRunShade = bakeFlattened(shade: 0.70, settings: settings(contrast: 0.22))
check("the two runs really wrote different pixels", firstRunShade != secondRunShade,
      "\(firstRunShade) vs \(secondRunShade)")

let twice = PortraitRecipeUndoStore.undo(photo)
check("undo goes back one run, not to the beginning", twice?.contrast == 0.22,
      "\(twice?.contrast ?? -99)")
check("and the pixels are the FIRST run's", flattenedShade() == firstRunShade,
      "\(flattenedShade() ?? -1), wanted \(firstRunShade)")

// ───────────────────────────────────────────────────────────────────────────
print("\na photo nobody has run a recipe on")

let untouched = temporary.appendingPathComponent("C4S_no_recipe.NEF")
try! Data(repeating: 0x7, count: 2048).write(to: untouched)
check("has nothing to undo", !PortraitRecipeUndoStore.canUndo(untouched))
check("and offers no menu item", PortraitRecipeUndoStore.undoableTitle(for: [untouched]) == nil)
check("undoing it changes nothing and says so",
      PortraitRecipeUndoStore.undo(untouched) == nil)

// A mixed selection is allowed — the menu offers the undo whenever ANY photo
// carries one, so the title has to survive a list with gaps in it.
PortraitRecipeUndoStore.record([.backgroundEnhanced], for: photo,
                               settings: settings(contrast: 0.5))
check("a mixed selection is named by the recipe the others carry",
      PortraitRecipeUndoStore.undoableTitle(for: [untouched, photo]) == "Background Enhanced",
      PortraitRecipeUndoStore.undoableTitle(for: [untouched, photo]) ?? "nil")
PortraitRecipeUndoStore.forget(photo)

print()
if failures == 0 {
    print("all good")
    exit(0)
}
print("\(failures) checks failed")
exit(1)
