// Drives the REAL FaceFraming geometry, extracted from FaceFraming.swift.
//
// Run:  python3 Tools/run-face-framing-test.py
//
// Vision itself is not what can go wrong here. What can — and what this
// measures — is the arithmetic around it:
//
//   * Vision's rectangles have their origin at the BOTTOM-left and the crop's
//     focus point has it at the TOP-left. Flip that and the frame chases
//     people's feet, on every photo, quietly.
//   * A stranger in the background must not drag the frame off the couple.
//   * Nobody in the photo must leave the crop alone, not centre it.
import Foundation
import CoreGraphics

// A stand-in for the real struct, which lives in ContentView.swift among
// twenty thousand lines of SwiftUI. Only the three fields are needed here.
struct MagazinePhotoCrop: Equatable {
    var focusX: Double = 0.5
    var focusY: Double = 0.15
    var zoom: Double = 1

    static let `default` = MagazinePhotoCrop()
}

// ---- the real type, pasted in by the extractor at run time ----------------

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

/// A face rectangle the way Vision hands it over: normalised, origin at the
/// bottom-left. `topFromTop` is written the way a person reads a photo — 0 is
/// the top edge — and flipped here, so the test cases stay readable.
func face(x: CGFloat, topFromTop: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
    CGRect(x: x, y: 1 - topFromTop - height, width: width, height: height)
}

print("face framing geometry")

// 1. Nobody in the photo: the crop is left exactly as it was.
check("no faces leaves the crop alone",
      FaceFraming.focusPoint(forFaces: []) == nil)
check("…and a zero-sized detection counts as nobody",
      FaceFraming.focusPoint(forFaces: [CGRect(x: 0.4, y: 0.4, width: 0, height: 0)]) == nil)

// 2. THE FLIP. A head high in the picture has to give a SMALL focusY. This is
//    the one that is silently wrong if the coordinate systems are confused:
//    with the flip missing the answer comes out near 0.85 instead of 0.2 and
//    every portrait is framed on the chest.
let high = face(x: 0.40, topFromTop: 0.08, width: 0.20, height: 0.18)
guard let highPoint = FaceFraming.focusPoint(forFaces: [high]) else {
    print("  FAIL  a single face returned nothing")
    exit(1)
}
check("a head near the TOP gives a focus point near the top",
      highPoint.y < 0.35, String(format: "focusY %.3f", highPoint.y))
check("…and it is centred on the face horizontally",
      abs(highPoint.x - 0.50) < 0.001, String(format: "focusX %.3f", highPoint.x))

// 3. …and a head low in the picture gives a large focusY. Same maths, other
//    end — a test that only checked one end would pass with the flip inverted.
let low = face(x: 0.40, topFromTop: 0.70, width: 0.20, height: 0.18)
guard let lowPoint = FaceFraming.focusPoint(forFaces: [low]) else {
    print("  FAIL  a single low face returned nothing")
    exit(1)
}
check("a head near the BOTTOM gives a focus point near the bottom",
      lowPoint.y > 0.65, String(format: "focusY %.3f", lowPoint.y))

// 4. Headroom: the point that gets centred sits BELOW the face, which is what
//    lifts the face above the middle of the cell.
let faceCentreFromTop = 0.08 + 0.18 / 2
check("the focus point sits below the face, so the face rides high",
      highPoint.y > faceCentreFromTop,
      String(format: "face centre %.3f, focus %.3f", faceCentreFromTop, highPoint.y))

// 5. Two people side by side: the frame lands between them, not on one.
let left = face(x: 0.10, topFromTop: 0.20, width: 0.16, height: 0.16)
let right = face(x: 0.62, topFromTop: 0.20, width: 0.16, height: 0.16)
guard let pair = FaceFraming.focusPoint(forFaces: [left, right]) else {
    print("  FAIL  two faces returned nothing")
    exit(1)
}
check("two people are framed between them",
      abs(pair.x - 0.48) < 0.05, String(format: "focusX %.3f", pair.x))

// 6. A stranger far behind must not drag the frame. The couple is on the left;
//    a small face sits at the far right.
let stranger = face(x: 0.92, topFromTop: 0.30, width: 0.04, height: 0.04)
guard let withStranger = FaceFraming.focusPoint(forFaces: [left, right, stranger]) else {
    print("  FAIL  the group returned nothing")
    exit(1)
}
check("a small face in the background is ignored",
      abs(withStranger.x - pair.x) < 0.001,
      String(format: "focusX %.3f vs %.3f without them", withStranger.x, pair.x))

// …but a second person standing beside them is NOT background.
let beside = face(x: 0.74, topFromTop: 0.22, width: 0.13, height: 0.13)
guard let three = FaceFraming.focusPoint(forFaces: [left, right, beside]) else {
    print("  FAIL  three faces returned nothing")
    exit(1)
}
check("…while a third person standing with them still counts",
      three.x > pair.x + 0.01, String(format: "focusX %.3f vs %.3f", three.x, pair.x))

// 7. Always inside the picture. A face right at the bottom edge, plus the
//    headroom bias, must not produce a focus point past 1.
let atEdge = face(x: 0.80, topFromTop: 0.86, width: 0.30, height: 0.14)
guard let edgePoint = FaceFraming.focusPoint(forFaces: [atEdge]) else {
    print("  FAIL  an edge face returned nothing")
    exit(1)
}
check("a face at the very bottom still gives a point inside the photo",
      edgePoint.y <= 1 && edgePoint.y >= 0 && edgePoint.x <= 1 && edgePoint.x >= 0,
      String(format: "(%.3f, %.3f)", edgePoint.x, edgePoint.y))

// 8. The crop it builds never zooms. Deciding WHERE to look is framing;
//    cropping in tighter is editing somebody's photograph.
guard let crop = FaceFraming.crop(forFaces: [high]) else {
    print("  FAIL  crop(forFaces:) returned nothing for a face")
    exit(1)
}
check("the crop it makes never zooms in", crop.zoom == 1,
      String(format: "zoom %.2f", crop.zoom))
check("…and it carries the focus point through",
      abs(crop.focusY - Double(highPoint.y)) < 1e-9)
check("…and no faces means no crop at all",
      FaceFraming.crop(forFaces: []) == nil)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
