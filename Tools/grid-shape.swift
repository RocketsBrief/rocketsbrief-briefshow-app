// Harness for the tile shape read out of the file header.
//
// ⚠️ `photoAspectRatioFromHeader` is EXTRACTED FROM ContentView.swift at build
// time by run-grid-shape-test.py, so this measures the REAL function and not a
// copy that can drift away from it.
//
// What it has to prove:
//   1. the shape it reads matches the shape the real thumbnail turns out to be
//      — if it did not, the grid would reflow the moment pictures arrived,
//      which is the entire cost this exists to avoid;
//   2. a portrait frame is measured standing up, not on its side;
//   3. it is cheap enough to run over a whole folder before anything decodes.
import Foundation
import ImageIO
import AppKit

// EXTRACTED_FUNCTION

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: grid-shape <folder> [limit]")
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
let limit = args.count > 2 ? Int(args[2])! : 60

let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    .filter { ["jpg", "jpeg", "heic", "png", "nef", "cr2", "arw"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .prefix(limit)

if files.isEmpty {
    print("NO PHOTOS \(dir.path)")
    exit(3)
}

var measured = 0, refused = 0, mismatched = 0, portraits = 0
var worst = 0.0, worstName = ""
let start = CFAbsoluteTimeGetCurrent()
for f in files {
    guard let ratio = photoAspectRatioFromHeader(f) else { refused += 1; continue }
    measured += 1
    if ratio < 1 { portraits += 1 }
}
let elapsed = CFAbsoluteTimeGetCurrent() - start

// The shape the grid would END UP with: what ImageIO hands the real pass, already
// rotated. These two disagreeing is the reflow this whole thing exists to stop.
for f in files {
    guard let ratio = photoAspectRatioFromHeader(f),
          let src = CGImageSourceCreateWithURL(f as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 420,
              kCGImageSourceCreateThumbnailWithTransform: true
          ] as CFDictionary) else { continue }
    let real = Double(cg.width) / Double(max(cg.height, 1))
    let drift = abs(Double(ratio) - real) / real
    if drift > worst { worst = drift; worstName = f.lastPathComponent }
    if drift > 0.02 { mismatched += 1 }
}

print("files              \(files.count)")
print("measured           \(measured)   refused \(refused)")
print("portrait frames    \(portraits)")
print(String(format: "cost               %.3f ms a file", elapsed / Double(max(measured, 1)) * 1000))
print(String(format: "worst drift        %.4f  (%@)", worst, worstName))
print("mismatched         \(mismatched)")
