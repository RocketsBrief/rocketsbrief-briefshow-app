// The Contrast curve, proved rather than looked at.
//
// `ContrastCurve.Shaper.apply` is a pure function of a pixel and a number, so
// every line of the client's specification of 12.09 is checkable. Each block
// below is one of its five demands, plus the two promises the implementation
// adds on top (the exact inverse, and the one place).
//
//     contrast-curve
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
let settings = [-1.0, -0.75, -0.5, -0.25, -0.1, 0.1, 0.25, 0.5, 0.75, 1.0]

print("\nContrast 0 changes nothing at all")
var identical = true
for v in samples {
    let out = ContrastCurve.apply(r: v, g: v * 0.6, b: v * 0.3, contrast: 0)
    if abs(out.r - v) > 1e-12 || abs(out.g - v * 0.6) > 1e-12 || abs(out.b - v * 0.3) > 1e-12 {
        identical = false
    }
}
check("the identity, exactly, not nearly", identical)

// ⚠️ The spec's first demand, and the one it states twice because it is the one
// an AI gets wrong: the pivot. A tone ON middle grey must not move, at any
// setting, or the picture changes brightness on its way to changing contrast.
print("\nthe pivot holds — middle grey does not move")
for c in settings {
    let grey = ContrastCurve.middleGrey
    let out = ContrastCurve.apply(r: grey, g: grey, b: grey, contrast: c)
    // 1e-6 for the reason given at the white point below — what moves here is
    // the colour space's own round trip, not the curve: the shaper leaves this
    // lightness exactly where it found it, which the next check proves without
    // any conversion in the way.
    check(String(format: "middle grey is untouched at %+.2f", c),
          abs(out.r - grey) < 1e-6 && abs(out.g - grey) < 1e-6 && abs(out.b - grey) < 1e-6,
          String(format: "%.9f vs %.9f", out.r, grey))
    check(String(format: "and the curve itself does not move it at all at %+.2f", c),
          ContrastCurve.Shaper(contrast: c).shapedLightness(ContrastCurve.pivot) == ContrastCurve.pivot)
}

print("\nboth ends are pinned")
for c in settings {
    let black = ContrastCurve.apply(r: 0, g: 0, b: 0, contrast: c)
    check(String(format: "black stays black at %+.2f", c),
          black.r == 0 && black.g == 0 && black.b == 0)
    let white = ContrastCurve.apply(r: 1, g: 1, b: 1, contrast: c)
    // ⚠️ 1e-6, and the looser bar is measured rather than convenient. OKLab's
    // published forward and inverse matrices are inverses of each other only to
    // about 2.6e-7 — the inverse is quoted rounded — so a colour that goes
    // through the space and back lands that far from where it started whatever
    // the curve does. Recomputing the inverse at full precision fixes the round
    // trip and breaks something worth more: its first column stops being exactly
    // 1, which is what keeps a NEUTRAL grey neutral. 2.6e-7 is a ten-thousandth
    // of a level at 8 bits and below what the Float cube can hold anyway; a
    // colour cast on every grey in the frame would not be.
    check(String(format: "white stays white at %+.2f", c),
          abs(white.r - 1) < 1e-6 && abs(white.g - 1) < 1e-6 && abs(white.b - 1) < 1e-6,
          String(format: "got %.9f", white.r))
}

print("\nnothing in range leaves the box")
var peak = 0.0
var floorHit = 1.0
for c in settings {
    for r in stride(from: 0.0, through: 1.0, by: 0.05) {
        for g in stride(from: 0.0, through: 1.0, by: 0.05) {
            for b in stride(from: 0.0, through: 1.0, by: 0.05) {
                // Display-encoded in, the way the cube's axes are.
                let out = ContrastCurve.apply(r: ExposureCube.toLinear(r),
                                              g: ExposureCube.toLinear(g),
                                              b: ExposureCube.toLinear(b),
                                              contrast: c)
                peak = max(peak, max(out.r, max(out.g, out.b)))
                floorHit = min(floorHit, min(out.r, min(out.g, out.b)))
            }
        }
    }
}
check("no channel ever exceeds 1", peak <= 1 + 1e-9, String(format: "peak %.9f", peak))
check("no channel ever goes below 0", floorHit >= -1e-9, String(format: "floor %.9f", floorHit))

// ⚠️ The inherited calibration. 1.4 is not a number anybody liked — it is the
// midtone slope of the five-knot curve that ran from 05.09, which is the only
// part of the old Contrast that had been scored against Lightroom.
print("\nthe midtones get exactly the slope that was calibrated")
for c in [0.25, 0.5, 0.75, 1.0] {
    let shaper = ContrastCurve.Shaper(contrast: c)
    let h = 1e-5
    let slope = (shaper.shapedLightness(ContrastCurve.pivot + h)
                 - shaper.shapedLightness(ContrastCurve.pivot - h)) / (2 * h)
    let wanted = 1 + (ContrastCurve.midtoneSlopeAtFullTravel - 1) * c
    check(String(format: "slope at the pivot is %.3f at %+.2f", wanted, c),
          abs(slope - wanted) < 1e-4, String(format: "%.6f", slope))
}

// The spec's *„soft knee / rolloff pri vrhu (L>0.85) i dnu (L<0.15)"*. The S
// provides it by its shape, so what is checked is the consequence: the curve
// must be FLATTER out there than it is in the middle, at every positive
// setting. A curve that is steep at both ends is the thing that clips.
print("\nthe ends roll off — flatter out there than in the middle")
for c in [0.25, 0.5, 0.75, 1.0] {
    let shaper = ContrastCurve.Shaper(contrast: c)
    let h = 1e-5
    func slope(at L: Double) -> Double {
        (shaper.shapedLightness(L + h) - shaper.shapedLightness(L - h)) / (2 * h)
    }
    let middle = slope(at: ContrastCurve.pivot)
    check(String(format: "L 0.90 is flatter than the pivot at %+.2f", c),
          slope(at: 0.90) < middle, String(format: "%.4f vs %.4f", slope(at: 0.90), middle))
    check(String(format: "L 0.10 is flatter than the pivot at %+.2f", c),
          slope(at: 0.10) < middle, String(format: "%.4f vs %.4f", slope(at: 0.10), middle))
    check(String(format: "and neither end is steeper than 1:1 at %+.2f", c),
          slope(at: 0.95) < 1 && slope(at: 0.05) < 1,
          String(format: "%.4f / %.4f", slope(at: 0.95), slope(at: 0.05)))
}

print("\nmonotonic — in the picture, and in the slider")
var risingInInput = true
for c in settings {
    var previous = -1.0
    for v in samples {
        let linear = ExposureCube.toLinear(v)
        let out = ContrastCurve.apply(r: linear, g: linear, b: linear, contrast: c).r
        if out < previous - 1e-12 { risingInInput = false }
        previous = out
    }
}
check("a brighter tone never comes out darker than a darker one", risingInInput)

var slidesCorrectly = true
for v in stride(from: 0.05, through: 0.95, by: 0.05) {
    let linear = ExposureCube.toLinear(v)
    let abovePivot = OKLab.from(r: linear, g: linear, b: linear).L > ContrastCurve.pivot
    var previous = abovePivot ? -1.0 : 2.0
    for c in stride(from: -1.0, through: 1.0, by: 0.05) {
        let out = ContrastCurve.apply(r: linear, g: linear, b: linear, contrast: c).r
        if abovePivot {
            if out < previous - 1e-9 { slidesCorrectly = false }
        } else {
            if out > previous + 1e-9 { slidesCorrectly = false }
        }
        previous = out
    }
}
check("dragging right lifts everything above the pivot and drops everything below",
      slidesCorrectly)

// ⚠️ Worth having and free: the negative side is the exact inverse of the
// positive one, so a client who overshoots and drags back gets his photograph
// back rather than a flattened copy of it.
print("\n+c then −c gives the picture back")
var worstRoundTrip = 0.0
for c in [0.25, 0.5, 0.75, 1.0] {
    for v in stride(from: 0.02, through: 0.98, by: 0.02) {
        let linear = ExposureCube.toLinear(v)
        let up = ContrastCurve.apply(r: linear, g: linear, b: linear, contrast: c)
        let back = ContrastCurve.apply(r: up.r, g: up.g, b: up.b, contrast: -c)
        worstRoundTrip = max(worstRoundTrip, abs(back.r - linear))
    }
}
check("the round trip returns the original tone", worstRoundTrip < 1e-6,
      String(format: "%.12f", worstRoundTrip))

// And the same promise on the MATHS alone, where the colour space cannot blur
// it: this one is exact, and if it ever stops being exact the inverse branch of
// `s(_:)` is wrong rather than the matrices being rounded.
var worstLightnessTrip = 0.0
for c in [0.1, 0.25, 0.5, 0.75, 1.0] {
    let up = ContrastCurve.Shaper(contrast: c)
    let down = ContrastCurve.Shaper(contrast: -c)
    for L in stride(from: 0.0, through: 1.0, by: 0.01) {
        worstLightnessTrip = max(worstLightnessTrip,
                                 abs(down.shapedLightness(up.shapedLightness(L)) - L))
    }
}
check("and on the lightness curve alone it is exact", worstLightnessTrip < 1e-12,
      String(format: "%.15f", worstLightnessTrip))

// The spec's *„kako se nijansa (Hue) ne bi izmenila"*. In OKLab the hue is the
// DIRECTION of (a, b); the curve scales both by one number and moves L, so the
// direction cannot turn. This is the check that would catch the whole thing
// having been implemented per channel after all.
print("\nhue survives — the reason this runs on lightness")
var worstHueShift = 0.0
for c in settings {
    for colour in [(0.40, 0.20, 0.10), (0.10, 0.30, 0.50), (0.25, 0.25, 0.05),
                   (0.30, 0.10, 0.35), (0.18, 0.12, 0.09)] {
        let before = OKLab.from(r: colour.0, g: colour.1, b: colour.2)
        let out = ContrastCurve.apply(r: colour.0, g: colour.1, b: colour.2, contrast: c)
        let after = OKLab.from(r: out.r, g: out.g, b: out.b)
        worstHueShift = max(worstHueShift, abs(atan2(after.b, after.a) - atan2(before.b, before.a)))
    }
}
check("the hue angle does not move", worstHueShift < 1e-6,
      String(format: "%.9f rad", worstHueShift))

// The spec's last demand, and the one that is invisible in every check above:
// without it, a shadow pushed darker keeps its a/b and so its chroma RELATIVE
// to its lightness climbs — *„toxic saturation"* on skin in the shadows.
print("\nchroma is held back, and only where it was going to run away")
for c in [0.5, 1.0] {
    let colour = (0.09, 0.05, 0.035)          // a dark skin tone, in linear light
    let before = OKLab.from(r: colour.0, g: colour.1, b: colour.2)
    let out = ContrastCurve.apply(r: colour.0, g: colour.1, b: colour.2, contrast: c)
    let after = OKLab.from(r: out.r, g: out.g, b: out.b)

    let chromaBefore = hypot(before.a, before.b)
    let chromaAfter = hypot(after.a, after.b)
    check(String(format: "a darkened skin tone loses chroma at %+.2f", c),
          chromaAfter < chromaBefore, String(format: "%.5f → %.5f", chromaBefore, chromaAfter))

    // And the compensation is HALF, not all of it: relative chroma still rises,
    // because a contrastier picture should look contrastier.
    let relativeBefore = chromaBefore / before.L
    let relativeAfter = chromaAfter / after.L
    check(String(format: "but not so far that the colour goes flat at %+.2f", c),
          relativeAfter > relativeBefore,
          String(format: "%.5f → %.5f", relativeBefore, relativeAfter))
}

print("\nOKLab round-trips")
var worstLab = 0.0
for r in stride(from: 0.0, through: 1.0, by: 0.1) {
    for g in stride(from: 0.0, through: 1.0, by: 0.1) {
        for b in stride(from: 0.0, through: 1.0, by: 0.1) {
            let lab = OKLab.from(r: r, g: g, b: b)
            let back = OKLab.toLinear(L: lab.L, a: lab.a, b: lab.b)
            worstLab = max(worstLab, max(abs(back.r - r), max(abs(back.g - g), abs(back.b - b))))
        }
    }
}
// 1e-6 for the reason spelled out at the white-point check above: the published
// inverse matrix is a rounded one, and the alternative costs neutral greys.
check("linear sRGB → OKLab → linear sRGB", worstLab < 1e-6, String(format: "%.12f", worstLab))
check("middle grey's lightness is where the pivot says it is",
      abs(ContrastCurve.pivot - cbrt(ContrastCurve.middleGrey)) < 1e-6,
      String(format: "%.6f", ContrastCurve.pivot))

print("\nand the table the cube is built from says the same thing")
// The cube is what the app actually renders through, so a curve that is right
// and a table that is wrong would look identical in every check above.
let dimension = ContrastCube.dimension
let cube = ContrastCube.data(for: 0.5)
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
                let wanted = ContrastCurve.apply(r: r, g: g, b: b, contrast: 0.5)
                worst = max(worst, abs(Double(floats[index]) - ExposureCube.toDisplay(wanted.r)))
                worst = max(worst, abs(Double(floats[index + 1]) - ExposureCube.toDisplay(wanted.g)))
                worst = max(worst, abs(Double(floats[index + 2]) - ExposureCube.toDisplay(wanted.b)))
            }
        }
    }
    check("every entry is the curve, in the cube's own axes", worst < 1e-6,
          String(format: "%.8f", worst))
}

// ⚠️ THE MUST. A slider on a layer is the same slider as on the photo, and the
// way that is guaranteed here is that there is only one function. If a second
// implementation of Contrast ever appears in Develop.swift, this is what says
// so — before the pixels are compared, and without needing a photograph.
print("\nthe one place — Contrast has a single implementation")
let develop = (try? String(contentsOfFile: CommandLine.arguments.count > 1
                           ? CommandLine.arguments[1]
                           : "BriefShow/Develop.swift", encoding: .utf8)) ?? ""
if develop.isEmpty {
    check("Develop.swift could be read", false, "pass its path as argv[1]")
} else {
    let callSites = develop.components(separatedBy: "PhotoEditRenderer.applyContrast").count - 1
    check("the photo, the layer and the mask all call applyContrast",
          callSites >= 2, "\(callSites) call sites")
    check("no tone curve is bending contrast on its own any more",
          !develop.contains("settings.contrast * contrastMidtoneBend")
          && !develop.contains("local.contrast * PhotoEditRenderer.contrastMidtoneBend"))
}

print()
if failures == 0 {
    print("all good")
    exit(0)
}
print("\(failures) checks failed")
exit(1)
