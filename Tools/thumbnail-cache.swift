// Harness for ThumbnailDiskCache — the small JPEGs behind the filmstrip and
// the grid's tiles.
//
// ⚠️ The type under test is EXTRACTED FROM Develop.swift at build time by
// run-thumbnail-cache-test.py. Same rule as Tools/skymask.swift.
//
// The check that matters most is the LAST one: the cache must never be able to
// answer a request for more pixels than it holds. That is what keeps the
// client's rule — *„bitno je da rezolucija bude original… za slike koje su
// otvorene i u Create i u gridu"* — true, and it is a number, not a habit.

import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers

// __EXTRACTED__

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("  ok    \(label)") }
    else { failures += 1; print("  FAIL  \(label) \(detail)") }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("thumbnail-cache-test-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

// A stand-in "photo" on disk — the cache keys off its name, size and date.
let photo = scratch.appendingPathComponent("C4S_0001.NEF")
try! Data(repeating: 7, count: 4096).write(to: photo)

func makeImage(_ width: Int, _ height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

print("1. round trip")
check("nothing cached to begin with", ThumbnailDiskCache.image(for: photo) == nil)
ThumbnailDiskCache.store(makeImage(512, 341), for: photo)
let readBack = ThumbnailDiskCache.image(for: photo)
check("what was stored comes back", readBack != nil)
check("at the size it was stored", readBack?.width == 512 && readBack?.height == 341,
      "got \(readBack?.width ?? -1)x\(readBack?.height ?? -1)")

print("\n2. going stale")
ThumbnailDiskCache.invalidate([photo])
check("invalidate really removes it", ThumbnailDiskCache.image(for: photo) == nil)

ThumbnailDiskCache.store(makeImage(512, 341), for: photo)
check("stored again", ThumbnailDiskCache.image(for: photo) != nil)
// The file is replaced on disk at a DIFFERENT length — the key must move.
try! Data(repeating: 9, count: 8192).write(to: photo)
check("a photo replaced on disk does not get the old thumbnail",
      ThumbnailDiskCache.image(for: photo) == nil)

// …and at the same length but a later date.
try! Data(repeating: 3, count: 8192).write(to: photo)
ThumbnailDiskCache.store(makeImage(512, 341), for: photo)
check("stored for the replaced file", ThumbnailDiskCache.image(for: photo) != nil)
let later = Date().addingTimeInterval(120)
try! FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: photo.path)
check("a same-size file touched later does not either",
      ThumbnailDiskCache.image(for: photo) == nil)

print("\n3. ⚠️ the resolution rule")
check("the cache is big enough for the grid's tiles (420)", ThumbnailDiskCache.side >= 420,
      "side is \(ThumbnailDiskCache.side)")
check("and for the filmstrip (\(Int(filmstripThumbnailPixelSize)))",
      ThumbnailDiskCache.side >= filmstripThumbnailPixelSize,
      "side is \(ThumbnailDiskCache.side)")
// The gate makeEditedShowGridThumbnail applies, stated as the number it is.
check("a loupe-sized request is above the gate and so cannot be served from here",
      2000 > ThumbnailDiskCache.side)

print("")
if failures == 0 { print("all checks passed") } else { print("\(failures) FAILED"); exit(1) }
