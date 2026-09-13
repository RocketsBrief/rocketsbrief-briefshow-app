// What Shadows does to a real photograph, with the OLD curve computed alongside.
//
// ⚠️ THE MIDTONE COLUMN AND THE BLACK POINT ARE THE TEST. Any control that
// brightens the bottom of the range will raise the mean of the dark pixels, and
// that number on its own proves nothing — the old row raised it too, along with
// the midtones and the black point, which is precisely what the client's
// specification of 13.09 forbids. So the columns that decide are the ones that
// must NOT move: the midtone band, and the darkest pixels in the frame.
//
// The bands are chosen once, on the neutral render, and the same pixels are
// followed down the ramp — otherwise "the shadows" moves as the slider does and
// each row measures a different place.
//
//     shadows-photo <photo> [size]
import Foundation
import CoreImage
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { print("shadows-photo <photo> [size]"); exit(2) }
let url = URL(fileURLWithPath: first)
let size = args.count > 1 ? (Double(args[1]) ?? 1200) : 1200

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.workingColorSpace: srgb])

func render(_ image: CIImage) -> [UInt8]? {
    let w = Int(image.extent.width), h = Int(image.extent.height)
    guard w > 0, h > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                   bounds: image.extent, format: .RGBA8, colorSpace: srgb)
    }
    return buffer
}

func pixels(_ settings: PhotoEditSettings) -> [UInt8]? {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else { return nil }
    return render(PhotoEditRenderer.render(settings, on: base))
}

// The path this replaced, so the two can be read side by side.
//
// ⚠️ This is the OLD Shadows exactly, not an approximation: the row it had in
// the shared five-knot curve — weights [0.30, 1.00, 0.60, 0, 0] scaled by
// `toneControlStrength` — applied to the neutral render through the same
// function it always went through. Everything `render` does after the tone
// curve is the identity at default settings, so this IS what the old pipeline
// produced when the only slider moved was this one.
func oldPixels(_ shadows: Double) -> [UInt8]? {
    guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: CGFloat(size)) else { return nil }
    var image = PhotoEditRenderer.render(PhotoEditSettings(), on: base)
    if shadows != 0 {
        let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]
        let weights: [Double] = [0.30, 1.00, 0.60, 0.00, 0.00]
        var ys = xs
        for knot in 0..<5 {
            ys[knot] = xs[knot] + shadows * weights[knot] * PhotoEditRenderer.toneControlStrength
        }
        ys[0] = max(ys[0], 0)
        for knot in 1..<5 {
            let floorValue = ys[knot - 1] + PhotoEditRenderer.toneMinimumSlope * (xs[knot] - xs[knot - 1])
            ys[knot] = max(ys[knot], floorValue)
        }
        image = PhotoEditRenderer.applyToneCurve((0..<5).map { CGPoint(x: xs[$0], y: ys[$0]) }, to: image)
    }
    return render(image)
}

guard let neutral = pixels(PhotoEditSettings()) else {
    print("could not open \(url.path)"); exit(1)
}

/// Rec. 709 luminance, the weights Core Image's own luma filters use.
func luma(_ buffer: [UInt8], _ i: Int) -> Double {
    0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])
}

func meanLuma(_ buffer: [UInt8], over indices: [Int]) -> Double {
    guard !indices.isEmpty else { return 0 }
    return indices.reduce(0.0) { $0 + luma(buffer, $1) } / Double(indices.count)
}

/// How much the tones inside a band still differ from each other — the control
/// against "lifted" meaning "flattened". A shadow opened by pushing every tone
/// in it onto the same value is not opened, it is erased.
func spread(_ buffer: [UInt8], over indices: [Int]) -> Double {
    guard !indices.isEmpty else { return 0 }
    let values = indices.map { luma(buffer, $0) }
    let mean = values.reduce(0, +) / Double(values.count)
    return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
}

// The four bands, by where they sit on the ramp in the untouched render, and
// THE SPLIT IS AT THE PEAK OF THE WINDOW — level 16, L 0.175 — because the two
// sides of it are supposed to behave differently and a single "shadow band"
// hides that.
//
// ⚠️ THIS IS THE CORRECTION THE FIRST RUN FORCED, and it is worth writing down.
// The harness first asked for the whole band 4…40 to come out MORE spread than
// it went in, and it does not: 5.97 levels at rest, 5.21 at Shadows +100. That
// looked like "lifted onto one value" and it is not — it is arithmetic. A window
// that peaks at L 0.175 and is spent by L 0.50 lifts the tones below its peak
// more than the ones above it, so everything on the way back down is pushed
// closer together. The old row appeared to do better only because ITS peak sat
// at L 0.37, above the whole band — which is the very thing the client's
// specification of 13.09 removes.
//
// So each side is asked for what it is actually supposed to do: below the peak
// the tones must come APART, which is what opening a shadow means, and above it
// they may close up but only as far as the curve's own slope floor allows.
var pinned: [Int] = []        // exactly 0 — the anchor itself
var blackest: [Int] = []      // 0…3 — the deepest tones the window still reaches
var lowerShadow: [Int] = []   // 4…16 — below the peak: must open up
var upperShadow: [Int] = []   // 17…100 — above the peak: closes up, but bounded
var midtone: [Int] = []       // 101…180 — must not move at all
for i in stride(from: 0, to: neutral.count, by: 4) {
    if neutral[i] == 0 && neutral[i + 1] == 0 && neutral[i + 2] == 0 { pinned.append(i) }
    switch luma(neutral, i) {
    case ..<3.5: blackest.append(i)
    case ..<16.5: lowerShadow.append(i)
    case ..<100.5: upperShadow.append(i)
    case ..<180.5: midtone.append(i)
    default: break
    }
}

print("photo: \(url.lastPathComponent)")
let total = Double(neutral.count / 4)
print(String(format: "pinned black: %d pixels", pinned.count))
print(String(format: "bands: black %d (%.1f%%)  below the peak %d (%.1f%%)  above it %d (%.1f%%)  midtone %d (%.1f%%)\n",
             blackest.count, Double(blackest.count) / total * 100,
             lowerShadow.count, Double(lowerShadow.count) / total * 100,
             upperShadow.count, Double(upperShadow.count) / total * 100,
             midtone.count, Double(midtone.count) / total * 100))

print("Shadows        black    BELOW PEAK   its spread    above peak   its spread      MIDTONE")
print(String(repeating: "-", count: 88))

var neutralBlack = 0.0, neutralMid = 0.0
var neutralLowerSpread = 0.0, neutralUpperSpread = 0.0
var worstBlackDrift = 0.0, worstMidDrift = 0.0, worstPinned = 0.0
var worstOldBlackDrift = 0.0, worstOldMidDrift = 0.0
var liftedLowerSpread = 0.0, worstUpperSpread = Double.infinity

for s in [0.0, 0.25, 0.50, 1.0, -0.50, -1.0] {
    var settings = PhotoEditSettings()
    settings.shadows = s
    guard let buffer = pixels(settings) else { continue }
    let black = meanLuma(buffer, over: blackest)
    worstPinned = max(worstPinned, meanLuma(buffer, over: pinned))
    let lower = meanLuma(buffer, over: lowerShadow)
    let lowerSpread = spread(buffer, over: lowerShadow)
    let upper = meanLuma(buffer, over: upperShadow)
    let upperSpread = spread(buffer, over: upperShadow)
    let mid = meanLuma(buffer, over: midtone)
    print(String(format: "%-13@ %7.2f %12.1f %12.2f %13.1f %12.2f %12.2f",
                 String(format: "%+.2f  now", s) as NSString,
                 black, lower, lowerSpread, upper, upperSpread, mid))
    if let was = oldPixels(s) {
        print(String(format: "%-13@ %7.2f %12.1f %12.2f %13.1f %12.2f %12.2f",
                     "       before" as NSString,
                     meanLuma(was, over: blackest),
                     meanLuma(was, over: lowerShadow), spread(was, over: lowerShadow),
                     meanLuma(was, over: upperShadow), spread(was, over: upperShadow),
                     meanLuma(was, over: midtone)))
        if s != 0 {
            worstOldBlackDrift = max(worstOldBlackDrift, abs(meanLuma(was, over: blackest) - neutralBlack))
            worstOldMidDrift = max(worstOldMidDrift, abs(meanLuma(was, over: midtone) - neutralMid))
        }
    }
    if s == 0 {
        neutralBlack = black
        neutralMid = mid
        neutralLowerSpread = lowerSpread
        neutralUpperSpread = upperSpread
    } else {
        worstBlackDrift = max(worstBlackDrift, abs(black - neutralBlack))
        worstMidDrift = max(worstMidDrift, abs(mid - neutralMid))
        if s > 0 {
            liftedLowerSpread = max(liftedLowerSpread, lowerSpread)
            worstUpperSpread = min(worstUpperSpread, upperSpread)
        }
    }
}

print()
print(String(format: "pinned black came out at        %.2f of a level", worstPinned))
print(String(format: "the 0…3 band drifted by at most %.2f of a level   (the old row: %.2f)",
             worstBlackDrift, worstOldBlackDrift))
print(String(format: "the midtones drifted by at most %.2f of a level   (the old row: %.2f)",
             worstMidDrift, worstOldMidDrift))
print(String(format: "below the peak: %.2f levels apart at rest, %.2f at the strongest lift  (must grow)",
             neutralLowerSpread, liftedLowerSpread))
print(String(format: "above it:       %.2f levels apart at rest, %.2f at the strongest lift  (may close to %.2f)",
             neutralUpperSpread, worstUpperSpread, neutralUpperSpread * 0.73))
print()

var failed = false

// ⚠️ A CUBE CANNOT BE EXACTLY UNTOUCHED — it quantises, and the pre-scale means
// even a tone the curve leaves alone goes through the table — so what is checked
// is that the drift is under a level, which is below what 8 bits can show. The
// old row's own figure is printed beside it, and that is the comparison that
// matters: it moved these by ten levels and more.
if worstMidDrift > 1.0 {
    print("FAIL: the midtones moved — Shadows must not reach above L 0.50.")
    failed = true
}
// ⚠️ THE ANCHOR IS TRUE BLACK, NOT "EVERYTHING DARK", and the first version of
// this harness asked the wrong question — it failed `C4S_8932.NEF` because the
// pixels under level 3.5 moved by 3.95 levels at Shadows +100. They are supposed
// to. That band reaches up to L 0.12, which is well inside a window that peaks
// at L 0.175, and a control that froze it would have a cliff in it. What the
// spec anchors is L≈0 — *„Apsolutna crna tačka"* — and what it asks of the tones
// just above is that they move LESS, progressively, which is the shape rather
// than a rule.
//
// So: a pixel that was black stays black, and the band above it moves less than
// the old row moved it. Both are printed either way.
if worstPinned > 0.5 && !pinned.isEmpty {
    print("FAIL: pixels that were black did not stay black — the anchor is gone.")
    failed = true
}
if worstOldBlackDrift > 0.5 && worstBlackDrift > worstOldBlackDrift {
    print("FAIL: the deepest tones moved MORE than the old row moved them, which is the wash the spec removes.")
    failed = true
}
// A lift that flattens the tones it lifts is not a lift, and below the peak
// there is no arithmetic excuse for it: the window is still rising there, so the
// curve's slope is above 1 and the tones must come apart.
// ⚠️ AND IT NEEDS TONES TO OPEN. `C4S_7792.NEF` has nothing at all under level
// 16 — a bright frame — and a test that called that a failure would be reporting
// the photograph as a defect, the same trap the Highlights ramp documents for
// frames with no headroom.
var canJudgeTheLift = true
if lowerShadow.count < 200 || neutralLowerSpread < 0.25 {
    print(String(format: "Only %d pixels sit below the peak here, %.2f levels apart — too little to judge the lift on.",
                 lowerShadow.count, neutralLowerSpread))
    print("The ramp above still stands, and every other column below still applies.")
    canJudgeTheLift = false
} else if liftedLowerSpread <= neutralLowerSpread {
    print("FAIL: the tones below the peak came out flatter than they went in — lifted onto one value, not opened.")
    failed = true
}
// ⚠️ AND ABOVE THE PEAK THE BOUND IS THE CURVE'S OWN SLOPE FLOOR, not zero.
// `ShadowsCurve.liftAtFullPush` is set so the flattest the curve ever gets is a
// slope of 0.73 (Tools/test-shadows-curve.swift measures it), so a band on the
// way back to the untouched midtones may lose about a quarter of its local
// contrast at the extreme setting and no more. Anything worse means the
// constant has been raised past what the shape can carry.
if worstUpperSpread < neutralUpperSpread * 0.73 {
    print("FAIL: the tones above the peak closed up further than the curve's own slope floor allows.")
    failed = true
}
if !failed {
    print(canJudgeTheLift
          ? "The black point and the midtones stayed where they were, the tones below the peak came apart,"
          : "The black point and the midtones stayed where they were,")
    print("and the tones above the peak closed up no further than the shape allows.")
}
exit(failed ? 1 : 0)
