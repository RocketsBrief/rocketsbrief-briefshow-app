// Drives the REAL EditSliderDrag extracted from Develop.swift.
//
// Run:  python3 Tools/run-slider-drag-test.py
//
// The report: *„kada malo povećam exposure on baš dosta pokaže expose… da ne
// skoči odma baš expose"*. The exposure MATHS was measured first and cleared —
// on the client's own C4S_5744.NEF, +0.05 EV moves the picture by 0.6% and
// +1.00 EV by 11.5%, which is gentle. The slider was the problem: it set its
// value from the ABSOLUTE press position, so the thumb teleported under the
// pointer and the photo jumped before the pointer had moved at all.
//
// So what is measured here is what a press and a nudge actually do, in EV, on
// a track the width the panel really gives it.
import Foundation
import CoreGraphics

// ---- the real type, pasted in by the extractor at run time ----------------

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

// The Exposure slider as the panel really builds it: ±3 EV, a 16pt thumb, and
// a track the width of the panel at its default size less the padding.
let range = -3.0...3.0
let thumbSize: CGFloat = 16
let trackWidth: CGFloat = 286
let usable = trackWidth - thumbSize
let span = range.upperBound - range.lowerBound

/// Where the thumb's leading edge sits for a value.
func thumbX(_ value: Double) -> CGFloat {
    usable * CGFloat((value - range.lowerBound) / span)
}

/// One press-and-drag: press at `pressX`, end at `pressX + moved`.
func drag(from value: Double, pressX: CGFloat, moved: CGFloat) -> Double {
    let grab = EditSliderDrag.begin(pressX: pressX, thumbX: thumbX(value),
                                    thumbSize: thumbSize, usable: usable,
                                    range: range, value: value)
    return EditSliderDrag.value(at: pressX + moved, grab: grab, usable: usable, range: range)
}

print("exposure slider, ±3 EV over a \(Int(trackWidth))pt track")

// 1. Press the thumb, move nothing. This is the whole complaint: the picture
//    must not change the instant the mouse goes down.
let centre = thumbX(0) + thumbSize / 2
let pressOnly = drag(from: 0, pressX: centre, moved: 0)
check("pressing the thumb changes NOTHING", abs(pressOnly) < 1e-9,
      String(format: "%+.4f EV", pressOnly))

// 2. Press slightly off the thumb's centre — a real hand is never exact.
for off in [CGFloat(-7), -4, 4, 7] {
    let v = drag(from: 0, pressX: centre + off, moved: 0)
    check(String(format: "pressing %+.0fpt off the thumb's centre changes nothing", off),
          abs(v) < 1e-9, String(format: "%+.4f EV", v))
}

// 3. A small nudge is a small change.
let nudge = drag(from: 0, pressX: centre, moved: 3)
check("a 3pt nudge is a small change", abs(nudge) < 0.08,
      String(format: "%+.3f EV", nudge))

// 4. The travel is honest: moving the thumb a third of the track moves a
//    third of the range, wherever the drag started from.
// A third of the TRACK is a third of the SPAN — 6 EV / 3 = 2 EV. Written as
// span/6 at first, which is a third of one HALF of the range; the harness
// caught the arithmetic, not the code, and the code's +2.000 was right.
let third = drag(from: 0, pressX: centre, moved: usable / 3)
check("a third of the track is a third of the range",
      abs(third - span / 3) < 0.01, String(format: "%+.3f EV", third))

// 5. Starting from a value that is NOT zero still moves relatively.
let fromHalf = drag(from: 0.5, pressX: thumbX(0.5) + thumbSize / 2, moved: 10)
let expected = 0.5 + Double(10 / usable) * span
check("a nudge from +0.50 EV moves by the same amount",
      abs(fromHalf - expected) < 1e-9, String(format: "%+.3f EV", fromHalf))

// 6. Clamped at the ends, not wrapped or overshot.
let hardRight = drag(from: 0, pressX: centre, moved: usable * 5)
check("dragging far past the end stops at the maximum", hardRight == range.upperBound,
      String(format: "%+.2f EV", hardRight))

// 7. A press on the EMPTY track still goes there — that is what a track is
//    for, and it is the one jump that is asked for rather than suffered.
let farPress = thumbX(0) + thumbSize / 2 + 60
let jumped = drag(from: 0, pressX: farPress, moved: 0)
check("a press 60pt away on the bare track does jump there", jumped > 1.0,
      String(format: "%+.2f EV — this is the OLD behaviour, kept only for a deliberate press", jumped))

// 8. …and after that jump the drag is relative, not absolute again.
let afterJump = drag(from: 0, pressX: farPress, moved: 5)
check("after that jump the rest of the drag is relative",
      abs((afterJump - jumped) - Double(5 / usable) * span) < 1e-9,
      String(format: "%+.3f EV further", afterJump - jumped))

print("\nwhat the old code did, for the record")
let old = EditSliderDrag.valueAt(centre + 60, thumbSize: thumbSize, usable: usable, range: range)
print(String(format: "  a press 60pt right of centre used to set %+.2f EV outright", old))
print(String(format: "  the same press now sets %+.2f EV, and 0.00 if it lands on the thumb", jumped))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
