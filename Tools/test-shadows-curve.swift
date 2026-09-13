// The Shadows curve, proved rather than looked at.
//
// Each block is one clause of the client's specification of 13.09, plus the two
// promises the implementation adds: that the range above white walks through
// this pass untouched, and that there is only one implementation of the control.
//
//     shadows-curve
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

let settings = [-1.0, -0.75, -0.5, -0.25, -0.1, 0.1, 0.25, 0.5, 0.75, 1.0]
let displaySamples = stride(from: 0.0, through: ShadowsCurve.headroom, by: 0.005).map { $0 }

func linear(_ display: Double) -> Double { ExposureCube.toLinear(display) }
func display(_ linearValue: Double) -> Double { ExposureCube.toDisplay(linearValue) }
/// A neutral grey of this OKLab lightness, as a display value — how the curve's
/// own axis reads on the 0…255 ramp every measurement in the notes speaks in.
func levels(ofLightness L: Double) -> Double { display(L * L * L) * 255 }

print("\nShadows 0 changes nothing at all")
var identical = true
for v in displaySamples {
    let l = linear(v)
    let out = ShadowsCurve.apply(r: l, g: l * 0.6, b: l * 0.3, shadows: 0)
    if abs(out.r - l) > 1e-12 || abs(out.g - l * 0.6) > 1e-12 || abs(out.b - l * 0.3) > 1e-12 {
        identical = false
    }
}
check("the identity, exactly, not nearly", identical)

// ⚠️ The spec's hardest two lines, and the pair the old five-knot row broke in
// opposite directions: *„Srednji i svetli tonovi (L>0.50) moraju ostati potpuno
// netaknuti"* and *„Apsolutna crna tačka (L≈0.0) mora ostati sidrena"*. The old
// row moved the midtone by 15.2 levels and the black point by 7.6.
print("\nnothing above middle grey moves, at any setting")
for s in settings {
    var worst = 0.0
    for l in stride(from: ShadowsCurve.ceiling, through: 1.0, by: 0.005) {
        worst = max(worst, abs(ShadowsCurve.shapedLightness(l, shadows: s) - l))
    }
    check(String(format: "L 0.50 … 1.00 is untouched at %+.2f", s), worst == 0,
          String(format: "%.12f", worst))
}
check("and the ceiling is where the spec puts it", ShadowsCurve.ceiling == 0.50)

print("\nthe black point is anchored — the whole reason for the shape")
for s in settings {
    check(String(format: "L 0.0 does not move at %+.2f", s),
          ShadowsCurve.shapedLightness(0, shadows: s) == 0)
}
// ⚠️ NOT MERELY "SMALL AT BLACK" — the window leaves zero with slope zero, so
// the lift dies away quadratically and the deepest tones keep their depth.
// Checked in LEVELS, because that is what the client sees: the old row put 7.6
// of them into a black that should not have moved at all.
var worstNearBlack = 0.0
for s in settings {
    for L in stride(from: 0.0, through: 0.05, by: 0.001) {
        worstNearBlack = max(worstNearBlack,
                             abs(levels(ofLightness: ShadowsCurve.shapedLightness(L, shadows: s))
                                 - levels(ofLightness: L)))
    }
}
check("and the deepest twentieth of the range moves under a level",
      worstNearBlack < 1.0, String(format: "%.3f levels, old row: 7.6", worstNearBlack))

print("\nthe work is where the spec puts it")
check("the peak of the window is between L 0.15 and L 0.20",
      ShadowsCurve.peak >= 0.15 && ShadowsCurve.peak <= 0.20,
      String(format: "%.3f", ShadowsCurve.peak))
var peakIsThePeak = true
for L in stride(from: 0.0, through: 1.0, by: 0.001) where L != ShadowsCurve.peak {
    if ShadowsCurve.weight(L) > ShadowsCurve.weight(ShadowsCurve.peak) + 1e-12 { peakIsThePeak = false }
}
check("and no lightness is weighted more heavily than it is", peakIsThePeak)
// The spec's *„od 0.05 do 0.40"* is where the control has to be PRESENT, not
// where it has to be strong — it names L 0.15–0.20 for that. So both ends of the
// band carry a real share of it (measured: 0.198 and 0.226 of the peak) and the
// weight is already falling away outside.
check("the band L 0.05…0.40 is where the control lives",
      ShadowsCurve.weight(0.05) > 0.15 && ShadowsCurve.weight(0.40) > 0.15
      && ShadowsCurve.weight(0.45) < ShadowsCurve.weight(0.40)
      && ShadowsCurve.weight(0.02) < ShadowsCurve.weight(0.05),
      String(format: "0.05 → %.3f, 0.40 → %.3f", ShadowsCurve.weight(0.05), ShadowsCurve.weight(0.40)))

print("\nit lifts to the right and compresses to the left, and only in the band")
for s in settings {
    let shaped = ShadowsCurve.shapedLightness(ShadowsCurve.peak, shadows: s)
    check(String(format: "a shadow tone goes the right way at %+.2f", s),
          s < 0 ? shaped < ShadowsCurve.peak : shaped > ShadowsCurve.peak,
          String(format: "L %.3f → %.4f", ShadowsCurve.peak, shaped))
}
// The spec's *„blago komprimuj senke nadole"* — the left half is the gentler one.
check("the compression is gentler than the lift",
      abs(ShadowsCurve.amount(for: -1)) < ShadowsCurve.amount(for: 1),
      String(format: "%.4f against %.4f", abs(ShadowsCurve.amount(for: -1)), ShadowsCurve.amount(for: 1)))

// ⚠️ THE STRENGTH IS INHERITED, NOT CHOSEN, and this is where that is held to.
// The old path was one row of the five-knot curve — weights [0.30, 1.00, 0.60,
// 0, 0] scaled by `toneControlStrength` — and it is the only version of this
// control that was ever scored by region against a Lightroom export (05.09). So
// the new curve must move the tone at the peak of its window by what the old one
// moved it there, and the checks below are that, computed from the old weights
// rather than from a number typed in.
print("\nthe strength is the old, scored one — measured at the window's peak")
func oldShadows(_ amount: Double, at displayValue: Double) -> Double {
    let xs: [Double] = [0, 0.25, 0.5, 0.75, 1]
    let weights: [Double] = [0.30, 1.00, 0.60, 0.00, 0.00]
    var ys = xs
    for knot in 0..<5 { ys[knot] = xs[knot] + amount * weights[knot] * PhotoEditRenderer.toneControlStrength }
    ys[0] = max(ys[0], 0)
    for knot in 1..<5 {
        ys[knot] = max(ys[knot], ys[knot - 1] + PhotoEditRenderer.toneMinimumSlope * (xs[knot] - xs[knot - 1]))
    }
    // Fritsch-Carlson, the same sampling `applyToneCurve` hands Core Image.
    let n = 5
    var h = [Double](repeating: 0, count: n - 1), delta = [Double](repeating: 0, count: n - 1)
    for i in 0..<(n - 1) { h[i] = xs[i + 1] - xs[i]; delta[i] = (ys[i + 1] - ys[i]) / h[i] }
    var m = [Double](repeating: 0, count: n)
    m[0] = delta[0]; m[n - 1] = delta[n - 2]
    for i in 1..<(n - 1) {
        if delta[i - 1] * delta[i] <= 0 { m[i] = 0 } else {
            let w1 = 2 * h[i] + h[i - 1], w2 = h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
        }
    }
    var i = 0
    while i < n - 2 && displayValue > xs[i + 1] { i += 1 }
    let t = (displayValue - xs[i]) / h[i], t2 = t * t, t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h[i] * m[i]
        + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h[i] * m[i + 1]
}

let peakDisplay = display(pow(ShadowsCurve.peak, 3))
for s in [1.0, -1.0] {
    let was = (oldShadows(s, at: peakDisplay) - peakDisplay) * 255
    let now = levels(ofLightness: ShadowsCurve.shapedLightness(ShadowsCurve.peak, shadows: s))
        - levels(ofLightness: ShadowsCurve.peak)
    check(String(format: "at %+.0f the tone at the peak moves as it always did", s * 100),
          abs(now - was) < 0.5,
          String(format: "%+.2f levels then, %+.2f now", was, now))
}
// And the two clauses the old row got wrong, stated as the difference it made.
let oldBlack = (oldShadows(1, at: 0) - 0) * 255
let oldMid = (oldShadows(1, at: 0.5) - 0.5) * 255
check("what changed is the black point and the midtone, and they are now zero",
      ShadowsCurve.shapedLightness(0, shadows: 1) == 0
      && ShadowsCurve.shapedLightness(0.6, shadows: 1) == 0.6,
      String(format: "the old row moved them %+.1f and %+.1f levels", oldBlack, oldMid))

print("\nmonotonic — in the picture, and in the slider")
var risingInInput = true
var worstSlope = Double.infinity
for s in settings {
    var previous = -1.0
    for l in stride(from: 0.0, through: 1.0, by: 0.0005) {
        let out = ShadowsCurve.shapedLightness(l, shadows: s)
        if out < previous - 1e-12 { risingInInput = false }
        if previous >= 0 { worstSlope = min(worstSlope, (out - previous) / 0.0005) }
        previous = out
    }
}
// ⚠️ A LIFT INSIDE A WINDOW ALWAYS COSTS LOCAL CONTRAST SOMEWHERE — the tones
// on the way back to the untouched midtones are pushed together, and that is
// arithmetic, not a defect. What must not happen is the slope reaching zero,
// because that is a flat patch, and going below it, which is an inversion.
check("a brighter tone never comes out darker than a darker one", risingInInput)
check("and the curve never flattens out", worstSlope > 0.5,
      String(format: "flattest slope %.3f", worstSlope))

var risingInSlider = true
for l in stride(from: 0.0, through: ShadowsCurve.ceiling, by: 0.01) {
    var previous = -1.0
    for s in stride(from: -1.0, through: 1.0, by: 0.05) {
        let out = ShadowsCurve.shapedLightness(l, shadows: s)
        if out < previous - 1e-9 { risingInSlider = false }
        previous = out
    }
}
check("dragging the slider right never darkens a tone", risingInSlider)

// ⚠️ The spec's *„Prelaz ... je izuzetno gladak, čime se sprečavaju ružni oreoli
// (halos)"*. A halo is an edge between a treated and an untreated tone, so what
// is checked is that there is no edge: the slope matches on both sides, at the
// bottom of the window and at the top of it.
// ⚠️ MEASURED AT THE CEILING FROM BOTH SIDES, AND AT BLACK ONLY FROM ABOVE, and
// the first version of this check got that wrong: below L 0 there is no
// lightness to have a slope, and asking for one reads the `max(…, 0)` guard as a
// crease of 1.000. What black has to promise is that the curve LEAVES it as the
// identity — slope 1, because the window opens with slope 0 — and that is what
// is asked here.
print("\nno crease where the work starts, and none where it stops")
var worstKink = 0.0
var worstBlackSlope = 0.0
for s in settings {
    let step = 1e-6
    let edge = ShadowsCurve.ceiling
    let below = (ShadowsCurve.shapedLightness(edge - step, shadows: s)
                 - ShadowsCurve.shapedLightness(edge - 2 * step, shadows: s)) / step
    let above = (ShadowsCurve.shapedLightness(edge + 2 * step, shadows: s)
                 - ShadowsCurve.shapedLightness(edge + step, shadows: s)) / step
    worstKink = max(worstKink, abs(above - below))

    let outOfBlack = (ShadowsCurve.shapedLightness(2 * step, shadows: s)
                      - ShadowsCurve.shapedLightness(step, shadows: s)) / step
    worstBlackSlope = max(worstBlackSlope, abs(outOfBlack - 1))
}
check("the slope matches on both sides of the ceiling", worstKink < 0.01,
      String(format: "%.6f", worstKink))
check("and the curve leaves black as the identity", worstBlackSlope < 0.01,
      String(format: "%.6f off a slope of 1", worstBlackSlope))

print("\nhue survives — the reason this runs on lightness")
var worstHueShift = 0.0
for s in settings {
    for colour in [(0.02, 0.012, 0.008), (0.006, 0.009, 0.02), (0.05, 0.03, 0.02), (0.002, 0.0015, 0.0011)] {
        let before = OKLab.from(r: colour.0, g: colour.1, b: colour.2)
        let out = ShadowsCurve.apply(r: colour.0, g: colour.1, b: colour.2, shadows: s)
        let after = OKLab.from(r: out.r, g: out.g, b: out.b)
        guard hypot(after.a, after.b) > 1e-6 else { continue }
        worstHueShift = max(worstHueShift,
                            abs(atan2(after.b, after.a) - atan2(before.b, before.a)))
    }
}
// 1e-4 rad, for the reason the Highlights test gives at the same check: OKLab's
// published matrices are inverses of each other to about 2.6e-7, and an angle is
// chroma error divided by chroma.
check("the hue angle does not move", worstHueShift < 1e-4,
      String(format: "%.9f rad", worstHueShift))

// The spec's colour clause, both halves of it. A moderate lift must put back
// the saturation it would otherwise wash out; a drastic one must hold it back
// again, so what comes up out of a dark corner does not arrive as coloured noise.
print("\nthe colour is tuned, and in both directions")
let shadowColour = (0.012, 0.007, 0.004)
let atRest = OKLab.from(r: shadowColour.0, g: shadowColour.1, b: shadowColour.2)
func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double {
    let lab = OKLab.from(r: c.r, g: c.g, b: c.b)
    return hypot(lab.a, lab.b)
}
let restChroma = hypot(atRest.a, atRest.b)
let moderate = chroma(ShadowsCurve.apply(r: shadowColour.0, g: shadowColour.1, b: shadowColour.2, shadows: 0.4))
let drastic = chroma(ShadowsCurve.apply(r: shadowColour.0, g: shadowColour.1, b: shadowColour.2, shadows: 1.0))
check("a moderate lift puts saturation back rather than washing it out",
      moderate > restChroma, String(format: "%.5f → %.5f", restChroma, moderate))
check("and a drastic one holds it back again",
      ShadowsCurve.chromaFollowing(for: 1.0) < ShadowsCurve.chromaFollowing(for: 0.4),
      String(format: "following %.3f at +0.4, %.3f at +1.0 (chroma %.5f → %.5f)",
             ShadowsCurve.chromaFollowing(for: 0.4), ShadowsCurve.chromaFollowing(for: 1.0),
             moderate, drastic))
var reachesDown = false
for s in stride(from: 0.0, through: ShadowsCurve.noiseReliefFrom, by: 0.01) {
    if ShadowsCurve.chromaFollowing(for: s) != ShadowsCurve.chromaFollow { reachesDown = true }
}
check("and the noise clause is exactly nothing below +50, as the spec says",
      !reachesDown)

// ⚠️ THE PROMISE THE IMPLEMENTATION ADDS, and the one a colour cube breaks by
// default: this control has no business above white, so a tone that arrives
// there must LEAVE there. KORAK 184 measured that range as 0.04%–30.6% of the
// client's frames, and a bare cube would flatten all of it onto 1.0 in passing.
print("\nthe range above white walks through untouched")
var worstAboveWhite = 0.0
for s in settings {
    for value in [1.0, 1.01, 1.045, ShadowsCurve.headroom] {
        let l = linear(value)
        let out = ShadowsCurve.apply(r: l, g: l, b: l, shadows: s)
        worstAboveWhite = max(worstAboveWhite, abs(display(out.r) - value))
    }
}
check("a tone at or past white comes out exactly where it went in",
      worstAboveWhite < 1e-12, String(format: "%.12f", worstAboveWhite))

print("\nand the table the cube is built from says the same thing")
let dimension = ShadowsCube.dimension
let started = Date()
let cube = ShadowsCube.data(for: 0.5)
let buildMilliseconds = Date().timeIntervalSince(started) * 1000
check("the table is the size CIColorCube expects",
      cube.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size)
// ⚠️ THE PRICE OF THE LARGER DIMENSION, PRINTED NEXT TO WHAT IT IS LARGER THAN.
// A table is built once per value of the slider and then cached, so this is what
// a drag pays on each new number — against a render measured at 60 ms on the
// 2600 px preview (Tools/run-layer-edit-parity-test.py).
let contrastStarted = Date()
_ = ContrastCube.data(for: 0.5)
let contrastMilliseconds = Date().timeIntervalSince(contrastStarted) * 1000
print(String(format: "  ..    %d³ built in %.1f ms   (ContrastCube, %d³: %.1f ms)",
             dimension, buildMilliseconds, ContrastCube.dimension, contrastMilliseconds))

cube.withUnsafeBytes { raw in
    let floats = raw.bindMemory(to: Float.self)
    var worst = 0.0
    for blue in stride(from: 0, to: dimension, by: 11) {
        for green in stride(from: 0, to: dimension, by: 11) {
            for red in stride(from: 0, to: dimension, by: 11) {
                let index = ((blue * dimension + green) * dimension + red) * 4
                let scale = ShadowsCurve.headroom
                let r = ExposureCube.toLinear(Double(red) / Double(dimension - 1) * scale)
                let g = ExposureCube.toLinear(Double(green) / Double(dimension - 1) * scale)
                let b = ExposureCube.toLinear(Double(blue) / Double(dimension - 1) * scale)
                let wanted = ShadowsCurve.apply(r: r, g: g, b: b, shadows: 0.5)
                // ⚠️ The table holds the SCALED value — the matrix behind the
                // cube puts it back, which is what keeps the pass transparent
                // to the range above white.
                worst = max(worst, abs(Double(floats[index]) - min(max(display(wanted.r) / scale, 0), 1)))
                worst = max(worst, abs(Double(floats[index + 1]) - min(max(display(wanted.g) / scale, 0), 1)))
                worst = max(worst, abs(Double(floats[index + 2]) - min(max(display(wanted.b) / scale, 0), 1)))
            }
        }
    }
    check("every entry is the curve, in the cube's own scaled axes", worst < 1e-6,
          String(format: "%.8f", worst))

    // ⚠️ THE ENTRIES ARE NOT THE QUESTION — Core Image reads BETWEEN them, and
    // this control does all of its work in the bottom eighth of the range where
    // a cube's entries are furthest apart in perceptual terms. So the check is
    // what a photograph actually gets: the table interpolated the way Core Image
    // interpolates it, against the exact curve, in levels. 32³ measured 1.46
    // here, which is why the dimension is not the neighbours'.
    var worstBetween = 0.0
    for step in 0...2000 {
        let value = Double(step) / 2000 * ShadowsCurve.headroom
        let axis = value / ShadowsCurve.headroom * Double(dimension - 1)
        let low = min(max(Int(axis), 0), dimension - 2)
        let fraction = axis - Double(low)
        func entry(_ k: Int) -> Double {
            Double(floats[((k * dimension + k) * dimension + k) * 4])
        }
        let interpolated = (entry(low) + (entry(low + 1) - entry(low)) * fraction) * ShadowsCurve.headroom
        let l = linear(value)
        let exact = display(ShadowsCurve.apply(r: l, g: l, b: l, shadows: 0.5).r)
        worstBetween = max(worstBetween, abs(interpolated - exact) * 255)
    }
    check("and between the entries it is still the curve, to under a level",
          worstBetween < 1.0, String(format: "%.2f levels", worstBetween))
}

// ⚠️ THE MUST. One implementation, called by the photo, the layer and the mask —
// and Shadows must be OUT of the shared tone curve, or it is being applied twice.
print("\nthe one place — Shadows has a single implementation")
let develop = (try? String(contentsOfFile: CommandLine.arguments.count > 1
                           ? CommandLine.arguments[1]
                           : "BriefShow/Develop.swift", encoding: .utf8)) ?? ""
if develop.isEmpty {
    check("Develop.swift could be read", false, "pass its path as argv[1]")
} else {
    let callSites = develop.components(separatedBy: "PhotoEditRenderer.applyShadows").count - 1
    check("the photo and a layer both call applyShadows", callSites >= 2, "\(callSites) call sites")
    check("and the shared tone curve no longer carries it",
          !develop.contains("blacks: Double, shadows: Double")
          && !develop.contains("blacks: settings.blacks, shadows:")
          && !develop.contains("blacks: local.blacks, shadows:"))
    check("the scale in front of the cube is undone behind it",
          develop.contains("scaled(image, by: 1 / headroom)")
          && develop.contains("scaled(shaped, by: headroom)"))
}

print()
if failures == 0 {
    print("all good")
    exit(0)
}
print("\(failures) checks failed")
exit(1)
