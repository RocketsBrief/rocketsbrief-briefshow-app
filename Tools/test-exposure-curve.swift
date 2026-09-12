// The Exposure curve, proved rather than looked at.
//
// `ExposureCurve.apply` is a pure function of a pixel and a number, so every
// promise in its specification is checkable — and each of the checks below
// stands for a way the first two drafts of it were wrong.
//
//     exposure-curve
import Foundation

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }
let evs = [-1.0, -0.75, -0.5, -0.25, -0.1, 0.1, 0.25, 0.5, 0.75, 1.0]

print("\nEV 0 changes nothing at all")
var identical = true
for v in samples {
    let out = ExposureCurve.apply(r: v, g: v * 0.6, b: v * 0.3, ev: 0)
    if abs(out.r - v) > 1e-12 || abs(out.g - v * 0.6) > 1e-12 || abs(out.b - v * 0.3) > 1e-12 {
        identical = false
    }
}
check("the identity, exactly, not nearly", identical)

// ⚠️ THE BUG THE FIRST DRAFT HAD. A fixed knee squeezed the whole top of the
// range whatever the exposure, so +0.10 EV pulled white from 255 to 230 —
// a tenth of a stop doing a whole stop's work, and in the wrong direction.
print("\na small exposure does a small amount of work")
let tiny = ExposureCurve.apply(r: 1, g: 1, b: 1, ev: 0.001)
check("white at +0.001 EV is still white", abs(tiny.r - 1) < 0.001,
      "got \(tiny.r)")
let nudge = ExposureCurve.apply(r: 0.9, g: 0.9, b: 0.9, ev: 0.1)
check("a bright tone at +0.10 EV moves a little, not a lot",
      nudge.r > 0.9 && nudge.r < 1.0, "0.9 → \(nudge.r)")

print("\nthe ends are protected — the client's own words")
for ev in evs {
    let black = ExposureCurve.apply(r: 0, g: 0, b: 0, ev: ev)
    check(String(format: "black stays black at %+.2f EV", ev),
          black.r == 0 && black.g == 0 && black.b == 0)
}
for ev in evs where ev > 0 {
    let white = ExposureCurve.apply(r: 1, g: 1, b: 1, ev: ev)
    // Pure white is already white; brightening must not be able to take it
    // PAST white (there is nowhere to go) nor pull it back down (that would be
    // a darker picture from a brighter setting).
    check(String(format: "white is still exactly white at %+.2f EV", ev),
          abs(white.r - 1) < 1e-9, "got \(white.r)")
}

print("\nnothing in range can be pushed through white")
var overflow: Double = 0
for ev in evs where ev > 0 {
    for r in stride(from: 0.0, through: 1.0, by: 0.05) {
        for g in stride(from: 0.0, through: 1.0, by: 0.05) {
            for b in stride(from: 0.0, through: 1.0, by: 0.05) {
                let out = ExposureCurve.apply(r: r, g: g, b: b, ev: ev)
                overflow = max(overflow, max(out.r, max(out.g, out.b)))
            }
        }
    }
}
check("no channel ever exceeds 1", overflow <= 1 + 1e-9, String(format: "peak %.6f", overflow))

print("\nmidtones carry the full stop — the pivot the spec asks for")
for ev in [0.25, 0.5, 0.75, 1.0] {
    let shaped = ExposureCurve.shapedLuminance(ExposureCurve.middleGrey, ev: ev)
    let wanted = ExposureCurve.middleGrey * pow(2, ev)
    check(String(format: "middle grey at %+.2f EV is the whole gain", ev),
          abs(shaped - wanted) < 1e-9,
          String(format: "%.4f vs %.4f", shaped, wanted))
}

print("\nmonotonic — in the picture, and in the slider")
var risingInInput = true
for ev in evs {
    var previous = -1.0
    for v in samples {
        let out = ExposureCurve.apply(r: v, g: v, b: v, ev: ev).r
        if out < previous - 1e-12 { risingInInput = false }
        previous = out
    }
}
check("a brighter tone never comes out darker than a darker one", risingInInput)

var risingInEV = true
for v in stride(from: 0.05, through: 0.95, by: 0.05) {
    var previous = -1.0
    for ev in stride(from: -1.0, through: 1.0, by: 0.05) {
        let out = ExposureCurve.apply(r: v, g: v, b: v, ev: ev).r
        if out < previous - 1e-9 { risingInEV = false }
        previous = out
    }
}
check("dragging the slider right never darkens a tone", risingInEV)

// ⚠️ The knee takes over at 0.5 and there must be no crease there — a visible
// edge in a sky is exactly what a discontinuous derivative looks like.
print("\nno crease where the knee takes over")
var worstKink = 0.0
for ev in evs where ev > 0 {
    let knee = ExposureCurve.shoulderKnee
    let h = 1e-6
    let below = (ExposureCurve.kneeMap(knee - h, knee: knee, whitepoint: pow(2, ev))
                 - ExposureCurve.kneeMap(knee - 2 * h, knee: knee, whitepoint: pow(2, ev))) / h
    let above = (ExposureCurve.kneeMap(knee + 2 * h, knee: knee, whitepoint: pow(2, ev))
                 - ExposureCurve.kneeMap(knee + h, knee: knee, whitepoint: pow(2, ev))) / h
    worstKink = max(worstKink, abs(above - below))
}
check("the slope matches on both sides of the knee", worstKink < 0.01,
      String(format: "%.4f", worstKink))

print("\nhue survives — the reason this rides on luminance")
var worstHueShift = 0.0
for ev in evs {
    // Colours chosen well inside the range, where the per-channel guard rail
    // does not fire, so what is measured is the luminance path on its own.
    for colour in [(0.4, 0.2, 0.1), (0.1, 0.3, 0.5), (0.25, 0.25, 0.05), (0.3, 0.1, 0.35)] {
        let out = ExposureCurve.apply(r: colour.0, g: colour.1, b: colour.2, ev: ev)
        // Same hue means the same proportions between the channels.
        let before = colour.0 / colour.1
        let after = out.r / out.g
        worstHueShift = max(worstHueShift, abs(after - before))
    }
}
check("the channels keep their proportions", worstHueShift < 1e-9,
      String(format: "%.9f", worstHueShift))

print("\nand the table the cube is built from says the same thing")
// The cube is what the app actually renders through, so a curve that is right
// and a table that is wrong would look identical in every check above.
let dimension = ExposureCube.dimension
let cube = ExposureCube.data(for: 0.5)
check("the table is the size CIColorCube expects",
      cube.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size)

cube.withUnsafeBytes { raw in
    let floats = raw.bindMemory(to: Float.self)
    var worst = 0.0
    for blue in stride(from: 0, to: dimension, by: 7) {
        for green in stride(from: 0, to: dimension, by: 7) {
            for red in stride(from: 0, to: dimension, by: 7) {
                let index = ((blue * dimension + green) * dimension + red) * 4
                let r = ExposureCube.toLinear(Double(red) / Double(dimension - 1))
                let g = ExposureCube.toLinear(Double(green) / Double(dimension - 1))
                let b = ExposureCube.toLinear(Double(blue) / Double(dimension - 1))
                let wanted = ExposureCurve.apply(r: r, g: g, b: b, ev: 0.5)
                worst = max(worst, abs(Double(floats[index]) - ExposureCube.toDisplay(wanted.r)))
                worst = max(worst, abs(Double(floats[index + 1]) - ExposureCube.toDisplay(wanted.g)))
                worst = max(worst, abs(Double(floats[index + 2]) - ExposureCube.toDisplay(wanted.b)))
            }
        }
    }
    check("every entry is the curve, in the cube's own axes", worst < 1e-6,
          String(format: "%.8f", worst))
}

// ⚠️ sRGB in and back out again, since the cube converts both ways per entry
// and a transfer function written by hand is easy to get subtly wrong.
var worstRoundTrip = 0.0
for v in samples {
    worstRoundTrip = max(worstRoundTrip, abs(ExposureCube.toDisplay(ExposureCube.toLinear(v)) - v))
}
check("the sRGB transfer round-trips", worstRoundTrip < 1e-12,
      String(format: "%.14f", worstRoundTrip))

print()
if failures == 0 {
    print("all good")
    exit(0)
}
print("\(failures) checks failed")
exit(1)
