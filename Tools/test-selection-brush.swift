// The Cut brush (Circle since 24.09): does Cut/Copy take exactly what was painted?
// Two spots painted on a 1000×600 frame; the PNG must cover both, be opaque on
// the paint and transparent between the spots.
import Foundation
import CoreImage
import AppKit

let extent = CGRect(x: 0, y: 0, width: 1000, height: 600)
let image = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.2)).cropped(to: extent)
var sel = SelectionGeometry(shape: .circle)
sel.strokes = [BrushStroke(points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.3, y: 0.3)], size: 0.05, hardness: 1),
               BrushStroke(points: [CGPoint(x: 0.7, y: 0.6)], size: 0.05, hardness: 1)]
var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") { print("  \(ok ? "ok  " : "FAIL") \(what) \(detail)"); if !ok { failures += 1 } }
check("a painted selection is not empty", !sel.isEmpty)
check("an unpainted one is", SelectionGeometry(shape: .circle).isEmpty)
guard let out = PhotoEditRenderer.extractSelectionPNG(sel, from: image),
      let rep = NSBitmapImageRep(data: out.data) else { print("no PNG"); exit(1) }
let b = out.boundsUnit
check("the box spans both spots", b.minX < 0.18 && b.maxX > 0.72 && b.minY < 0.28 && b.maxY > 0.62,
      String(format: "(%.3f, %.3f)–(%.3f, %.3f)", b.minX, b.minY, b.maxX, b.maxY))
func alpha(_ ux: Double, _ uy: Double) -> CGFloat {
    let x = Int((ux - b.minX) / b.width * Double(rep.pixelsWide)), y = Int((uy - b.minY) / b.height * Double(rep.pixelsHigh))
    return rep.colorAt(x: min(max(x, 0), rep.pixelsWide - 1), y: min(max(y, 0), rep.pixelsHigh - 1))?.alphaComponent ?? -1
}
check("opaque on the first spot", alpha(0.25, 0.3) > 0.95, "\(alpha(0.25, 0.3))")
check("opaque on the second spot", alpha(0.7, 0.6) > 0.95, "\(alpha(0.7, 0.6))")
check("transparent between them", alpha(0.5, 0.45) < 0.05, "\(alpha(0.5, 0.45))")
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) failed")
exit(failures == 0 ? 0 : 1)
