// Harness for the crop tool's hit zones and resize cursor angles.
//
// ⚠️ The functions under test are EXTRACTED FROM Develop.swift at build time
// by run-crop-zone-test.py, not copied here — the same rule Tools/skymask.swift
// follows. A harness holding its own copy of the maths passes forever while
// the app drifts away from it.
//
// What it checks is the pair that has been got wrong twice: the zone the
// pointer is IN (which decides the cursor) and the zone a press LANDS in
// (which decides what happens). They now come from one function; these cases
// pin down what it answers.

import Foundation
import CoreGraphics

// __EXTRACTED__

private var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) \(detail)")
    }
}

func checkDegrees(_ label: String, _ actual: Double, _ expected: Double) {
    // Folded to the axis: the glyph is a double-headed arrow, so a direction
    // and its opposite are the same picture.
    var difference = (actual - expected).truncatingRemainder(dividingBy: 180)
    if difference < 0 { difference += 180 }
    if difference > 90 { difference -= 180 }
    check(label, abs(difference) < 0.001, "got \(actual), wanted \(expected) (mod 180)")
}

let rect = CGRect(x: 100, y: 50, width: 400, height: 200)
let centre = CGPoint(x: rect.midX, y: rect.midY)

print("upright frame")
check("middle of the right edge is .right",
      cropHandle(at: CGPoint(x: rect.maxX, y: rect.midY), rect: rect, angle: 0) == .right)
check("a QUARTER of the way up the right edge is still .right — the whole line",
      cropHandle(at: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25),
                 rect: rect, angle: 0) == .right)
check("middle of the top edge is .top",
      cropHandle(at: CGPoint(x: rect.midX, y: rect.minY), rect: rect, angle: 0) == .top)
check("the top-left corner is .topLeft, not .top or .left",
      cropHandle(at: CGPoint(x: rect.minX, y: rect.minY), rect: rect, angle: 0) == .topLeft)
check("6pt inside the corner is STILL the corner",
      cropHandle(at: CGPoint(x: rect.minX + 6, y: rect.minY + 6), rect: rect, angle: 0) == .topLeft)
check("the middle of the frame is no handle at all (the hand lives there)",
      cropHandle(at: centre, rect: rect, angle: 0) == nil)
check("well outside is no handle (that is the rotation zone)",
      cropHandle(at: CGPoint(x: rect.maxX + 60, y: rect.midY), rect: rect, angle: 0) == nil)
check("just outside the right edge still catches it",
      cropHandle(at: CGPoint(x: rect.maxX + 8, y: rect.midY), rect: rect, angle: 0) == .right)

print("cursor axes")
checkDegrees("left/right edge is horizontal",
             cropResizeDegrees(.right, angle: 0, halfWidth: 200, halfHeight: 100), 0)
checkDegrees("top/bottom edge is vertical",
             cropResizeDegrees(.top, angle: 0, halfWidth: 200, halfHeight: 100), 90)
checkDegrees("a corner runs along its OWN diagonal, not a fixed 45°",
             cropResizeDegrees(.bottomRight, angle: 0, halfWidth: 200, halfHeight: 100),
             atan2(100.0, 200.0) * 180 / .pi)
checkDegrees("on a square crop that diagonal IS 45°",
             cropResizeDegrees(.bottomRight, angle: 0, halfWidth: 100, halfHeight: 100), 45)
checkDegrees("the two diagonals are not the same line",
             cropResizeDegrees(.topRight, angle: 0, halfWidth: 100, halfHeight: 100), -45)

print("turned frame (30°)")
// The right edge's midpoint, turned with the frame.
let angle = 30.0
let radians = angle * .pi / 180
func turned(_ point: CGPoint) -> CGPoint {
    let dx = point.x - centre.x
    let dy = point.y - centre.y
    return CGPoint(x: centre.x + dx * cos(radians) - dy * sin(radians),
                   y: centre.y + dx * sin(radians) + dy * cos(radians))
}
check("the turned right edge is found at its turned position",
      cropHandle(at: turned(CGPoint(x: rect.maxX, y: rect.midY)), rect: rect, angle: angle) == .right)
check("the turned top-left corner is found at its turned position",
      cropHandle(at: turned(CGPoint(x: rect.minX, y: rect.minY)), rect: rect, angle: angle) == .topLeft)
check("the UNturned right-edge point is no longer on that edge",
      cropHandle(at: CGPoint(x: rect.maxX, y: rect.midY), rect: rect, angle: angle) != .right)
checkDegrees("a side of a turned frame gets a cursor turned with it",
             cropResizeDegrees(.right, angle: angle, halfWidth: 200, halfHeight: 100), angle)
checkDegrees("and so does the edge across it",
             cropResizeDegrees(.top, angle: angle, halfWidth: 200, halfHeight: 100), angle + 90)

// ⚠️ THE FRAME TRAVELS AGAINST THE POINTER. Asked for on 12.09 —
// *„if i move mouse to the right crop need to move on the left"* — because
// Lightroom's crop moves the PICTURE under a frame that stays put, and this
// overlay is a frame over a picture that stays put. Two minus signs are the
// whole feature, which is exactly the kind of thing a later tidy-up removes.
print("\nthe crop frame moves against the mouse")

let moveFrame = CGRect(x: 0, y: 0, width: 400, height: 200)

let right = cropMoveOffset(for: CGSize(width: 40, height: 0), frame: moveFrame)
check("mouse right moves the frame LEFT", right.dx < 0, "got \(right.dx)")
check("and does not move it vertically", right.dy == 0)

let down = cropMoveOffset(for: CGSize(width: 0, height: 20), frame: moveFrame)
check("mouse down moves the frame UP", down.dy < 0, "got \(down.dy)")
check("and does not move it horizontally", down.dx == 0)

let left = cropMoveOffset(for: CGSize(width: -40, height: -20), frame: moveFrame)
check("and the other way round on both axes", left.dx > 0 && left.dy > 0,
      "got \(left.dx), \(left.dy)")

// A fraction OF THE FRAME, not of the photograph: 40 px across a 400 px frame
// is a tenth, whatever the picture behind it is.
check("the distance is a fraction of the frame",
      abs(abs(right.dx) - 0.1) < 1e-12 && abs(abs(down.dy) - 0.1) < 1e-12,
      "got \(right.dx), \(down.dy)")

check("a frame with no area cannot divide by zero",
      cropMoveOffset(for: CGSize(width: 10, height: 10),
                     frame: CGRect(x: 0, y: 0, width: 0, height: 0)) == (0, 0))

// ---- the pointer rides the frame -----------------------------------------
//
// ⚠️ THE GESTURE'S TRANSLATION IS NOT THE USER'S MOVEMENT once the pointer is
// being warped: SwiftUI measures to where the pointer IS, and we have been
// moving it. Everything below is the drag of a hand that pushes steadily right
// in 10 pt steps, with the contaminated translation fed back in exactly as
// SwiftUI would report it — which is the one thing a reasoned argument gets
// wrong and a run does not.

print("\nthe pointer rides the frame")

var warp = CGSize.zero
var handMoved = 0.0
var frameMoved = 0.0
var ok = true
for _ in 0..<12 {
    handMoved += 10
    // What SwiftUI reports: the hand's total travel PLUS every warp so far.
    let reported = CGSize(width: handMoved + warp.width, height: warp.height)
    let step = cropCursorFollow(translation: reported, warpAlreadyApplied: warp)

    // The real translation recovered must be the hand's own travel, always.
    if abs(step.realTranslation.width - handMoved) > 1e-9 { ok = false }
    frameMoved = cropMoveOffset(for: step.realTranslation, frame: moveFrame).dx
    warp = step.warpAfter
}
check("the hand's own movement is recovered from a translation it has polluted",
      ok, "after \(Int(handMoved)) pt of hand")
check("so the frame still moves exactly as far as it did before the warp",
      abs(abs(frameMoved) - handMoved / moveFrame.width) < 1e-12,
      "got \(frameMoved)")
check("and the frame still goes the other way from the hand", frameMoved < 0)
check("the pointer is put where the frame went, not where the hand is",
      warp.width < 0 && abs(warp.width + handMoved) < 1e-9,
      "warp \(warp.width), hand +\(handMoved)")

// A drag that starts is a drag that has moved nothing yet.
let atRest = cropCursorFollow(translation: .zero, warpAlreadyApplied: .zero)
check("pressing without moving warps nothing",
      atRest.warpToApply == .zero && atRest.realTranslation == .zero)

// Both axes, and the vertical one is the axis the client named second.
let downward = cropCursorFollow(translation: CGSize(width: 0, height: 30),
                                warpAlreadyApplied: .zero)
check("pushing down sends the pointer up after the frame",
      downward.warpAfter.height == -30 && downward.realTranslation.height == 30)

print("")
if failures == 0 {
    print("all checks passed")
} else {
    print("\(failures) FAILED")
    exit(1)
}
