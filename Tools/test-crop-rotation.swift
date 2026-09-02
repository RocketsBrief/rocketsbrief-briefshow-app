import Foundation

// Exercises the REAL crop-frame geometry pulled out of Develop.swift by
// run-crop-rotation-test.py. Nothing here re-implements the maths — if a
// formula in the app changes, these numbers change with it.
//
// What is being defended, in order of what would hurt most:
//
//  1. A turned crop frame never leaves the photograph. That is what stops the
//     renderer producing transparent corners, and it is a claim about all four
//     corners at once, so it is checked corner by corner rather than by
//     re-deriving the bounding box the code itself uses.
//  2. At angle 0 nothing moved. The whole change is supposed to be invisible
//     until someone turns a frame.
//  3. Resizing a turned frame keeps the side you did NOT drag exactly where it
//     was on screen — the thing that would look obviously broken.
//  4. The screen↔frame conversions are inverses of each other.

var failures = 0

func check(_ condition: Bool, _ what: String) {
    if !condition {
        failures += 1
        print("FAIL  \(what)")
    }
}

func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
    abs(a - b) <= tol
}

// The frame's four corners in a space proportional to pixels (width = ratio,
// height = 1) — the same space constrainedToImage works in.
func corners(_ crop: EditCropRect, ratio: Double) -> [CGPoint] {
    let centre = CGPoint(x: (crop.x + crop.width / 2) * ratio,
                         y: crop.y + crop.height / 2)
    let halfWidth = crop.width * ratio / 2
    let halfHeight = crop.height / 2
    return [
        CGPoint(x: -halfWidth, y: -halfHeight),
        CGPoint(x: halfWidth, y: -halfHeight),
        CGPoint(x: halfWidth, y: halfHeight),
        CGPoint(x: -halfWidth, y: halfHeight)
    ].map { CropGeometry.cropFramePoint($0, centre: centre, degrees: crop.angle) }
}

// MARK: 1 — a turned frame stays on the photograph

let ratios: [Double] = [3.0 / 2.0, 1.0, 2.0 / 3.0, 16.0 / 9.0]
let angles: [Double] = [-45, -31.7, -12, -0.4, 0, 0.4, 12, 31.7, 45]
var containmentCases = 0

for ratio in ratios {
    let g = CropGeometry(imagePixelRatio: ratio)
    for angle in angles {
        for x in stride(from: 0.0, through: 0.8, by: 0.2) {
            for y in stride(from: 0.0, through: 0.8, by: 0.2) {
                for size in [0.15, 0.4, 0.75, 1.0] {
                    let raw = EditCropRect(x: x, y: y, width: size, height: size, angle: angle)
                    let fitted = g.constrainedToImage(raw)
                    containmentCases += 1

                    for corner in corners(fitted, ratio: ratio) {
                        // 1e-9 of slack: these are Doubles through a sine and
                        // a division, not exact arithmetic.
                        check(corner.x >= -1e-9 && corner.x <= ratio + 1e-9,
                              "corner off the photo horizontally: ratio \(ratio) angle \(angle) size \(size) -> x \(corner.x)")
                        check(corner.y >= -1e-9 && corner.y <= 1 + 1e-9,
                              "corner off the photo vertically: ratio \(ratio) angle \(angle) size \(size) -> y \(corner.y)")
                    }

                    // The shape is never changed, only its size and position:
                    // a locked 4:3 that came out 4:3.02 would be a silent
                    // betrayal of the ratio row.
                    if fitted.width > 0, fitted.height > 0, raw.width > 0, raw.height > 0 {
                        check(approx(fitted.width / fitted.height, raw.width / raw.height, 1e-9),
                              "aspect ratio changed by fitting: \(raw.width / raw.height) -> \(fitted.width / fitted.height)")
                    }
                    // Fitting only ever shrinks.
                    check(fitted.width <= raw.width + 1e-9 && fitted.height <= raw.height + 1e-9,
                          "fitting GREW the crop: \(raw.width)x\(raw.height) -> \(fitted.width)x\(fitted.height)")
                    check(approx(fitted.angle, raw.angle), "fitting changed the angle")
                }
            }
        }
    }
}

// MARK: 2 — at angle 0, an already-valid crop is returned untouched

for ratio in ratios {
    let g = CropGeometry(imagePixelRatio: ratio)
    for crop in [EditCropRect(x: 0, y: 0, width: 1, height: 1),
                 EditCropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6),
                 EditCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)] {
        let out = g.constrainedToImage(crop)
        check(approx(out.x, crop.x) && approx(out.y, crop.y)
                && approx(out.width, crop.width) && approx(out.height, crop.height),
              "upright crop was moved by the constraint: \(crop) -> \(out)")
    }
}

// MARK: 3 — resizing a turned frame pins the side that was not dragged

// Every handle, and what it must leave alone: the opposite corner, or the
// opposite edge's midpoint.
let handleCases: [(CropHandle, CGPoint)] = [
    (.topLeft, CGPoint(x: 1, y: 1)),
    (.topRight, CGPoint(x: -1, y: 1)),
    (.bottomLeft, CGPoint(x: 1, y: -1)),
    (.bottomRight, CGPoint(x: -1, y: -1)),
    (.top, CGPoint(x: 0, y: 1)),
    (.bottom, CGPoint(x: 0, y: -1)),
    (.left, CGPoint(x: 1, y: 0)),
    (.right, CGPoint(x: -1, y: 0))
]

for ratio in ratios {
    let g = CropGeometry(imagePixelRatio: ratio)
    for angle in [-40.0, -17.5, 3.0, 22.0, 44.0] {
        let start = EditCropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5, angle: angle)
        for (handle, sign) in handleCases {
            // A resize the anchoring step has to correct for: both sides
            // change, so the centre moves and a turned frame swings.
            let resized = EditCropRect(x: start.x, y: start.y, width: 0.3, height: 0.35, angle: angle)
            let placed = g.anchoredAfterResize(handle, start: start, resized: resized)

            func pin(_ crop: EditCropRect) -> CGPoint {
                let centre = CGPoint(x: (crop.x + crop.width / 2) * ratio,
                                     y: crop.y + crop.height / 2)
                let offset = CGPoint(x: sign.x * crop.width * ratio / 2,
                                     y: sign.y * crop.height / 2)
                return CropGeometry.cropFramePoint(offset, centre: centre, degrees: crop.angle)
            }

            let before = pin(start)
            let after = pin(placed)
            check(approx(before.x, after.x, 1e-9) && approx(before.y, after.y, 1e-9),
                  "handle \(handle) at \(angle)° moved the pinned point: \(before) -> \(after)")

            // The size the resize asked for is not touched by the anchoring.
            check(approx(placed.width, resized.width) && approx(placed.height, resized.height),
                  "anchoring changed the size")
        }
    }
}

// MARK: 4 — screen ↔ frame conversions are inverses

for angle in angles {
    for v in [CGSize(width: 10, height: 0), CGSize(width: 0, height: -7),
              CGSize(width: -3.5, height: 12.25)] {
        let along = CropGeometry.cropFrameTranslation(v, degrees: angle)
        // Turning it back by the same angle has to give the original vector.
        let back = CropGeometry.cropFramePoint(CGPoint(x: along.width, y: along.height),
                                               centre: .zero, degrees: angle)
        check(approx(Double(back.x), Double(v.width), 1e-9)
                && approx(Double(back.y), Double(v.height), 1e-9),
              "screen↔frame conversion is not an inverse at \(angle)°: \(v) -> \(along) -> \(back)")

        // Lengths survive a rotation. If they did not, a drag would resize by
        // a different amount depending on which way the frame was turned.
        check(approx(Double(along.width * along.width + along.height * along.height),
                     Double(v.width * v.width + v.height * v.height), 1e-9),
              "rotation changed the length of a drag")
    }
}

// MARK: 5 — the sign convention, stated once and checked

// A positive angle turns the frame CLOCKWISE ON SCREEN, where y grows
// downward. So the frame's own +x axis (which pointed right) must swing DOWN.
let right = CropGeometry.cropFramePoint(CGPoint(x: 1, y: 0), centre: .zero, degrees: 90)
check(approx(Double(right.x), 0, 1e-9) && approx(Double(right.y), 1, 1e-9),
      "a positive angle is not clockwise on screen: (1,0) at 90° -> \(right)")

if failures == 0 {
    print("checked \(containmentCases) fitted crops, every handle at five angles, and both conversions")
    print("RESULT: OK")
} else {
    print("RESULT: FAILED — \(failures) checks")
    exit(1)
}
