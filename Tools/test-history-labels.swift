// History: the name each step gets, read off what changed.
import Foundation
var failures = 0
func expect(_ got: String, _ want: String) { let ok = got == want; print("  \(ok ? "ok  " : "FAIL") \(got)\(ok ? "" : "   (wanted \(want))")"); if !ok { failures += 1 } }
let a = PhotoEditSettings()
var b = a; b.saturation = 0.15; expect(DevelopView.historyLabel(from: a, to: b), "Saturation +15")
b = a; b.exposure = 0.5; expect(DevelopView.historyLabel(from: a, to: b), "Exposure +0.50")
b = a; b.faceDehaze = 0.4; expect(DevelopView.historyLabel(from: a, to: b), "Face Dehaze +40")
b = a; b.clarity = 0.2; b.dehaze = 0.1; expect(DevelopView.historyLabel(from: a, to: b), "Clarity, Dehaze")
b = a; b.crop = EditCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5); expect(DevelopView.historyLabel(from: a, to: b), "Crop")
b = a; b.layers = [ImageLayer(name: "x", imageData: Data(), x: 0, y: 0, width: 1, height: 1)]; expect(DevelopView.historyLabel(from: a, to: b), "Layers")
print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) failed"); exit(failures == 0 ? 0 : 1)
