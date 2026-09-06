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

print("")
if failures == 0 {
    print("all checks passed")
} else {
    print("\(failures) FAILED")
    exit(1)
}
