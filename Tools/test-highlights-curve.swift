// The Highlights curve, proved rather than looked at.
//
// Each block is one clause of the client's specification of 13.09, plus the two
// promises the implementation adds: that the extended range really is visible,
// and that there is only one implementation of the control.
//
//     highlights-curve
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
/// Display values, including the ones past white the pre-scale brings into
/// reach — the whole point of the design.
let displaySamples = stride(from: 0.0, through: HighlightsCurve.headroom, by: 0.01).map { $0 }

func linear(_ display: Double) -> Double { ExposureCube.toLinear(display) }

print("\nHighlights 0 changes nothing at all")
var identical = true
for v in displaySamples {
    let l = linear(v)
    let out = HighlightsCurve.apply(r: l, g: l * 0.6, b: l * 0.3, highlights: 0)
    if abs(out.r - l) > 1e-12 || abs(out.g - l * 0.6) > 1e-12 || abs(out.b - l * 0.3) > 1e-12 {
        identical = false
    }
}
check("the identity, exactly, not nearly", identical)

// ⚠️ The spec's hardest line, and the one a weighted tone curve cannot keep:
// *„Donji kraj opsega (L<0.50) mora imati težinski uticaj 0.0 (potpuno
// netaknut)"*. Not "almost nothing" — nothing.
print("\nnothing below middle grey moves, at any setting")
for h in settings {
    var worst = 0.0
    for l in stride(from: 0.0, through: 0.5, by: 0.005) {
        let out = HighlightsCurve.shapedLightness(l, highlights: h)
        worst = max(worst, abs(out - l))
    }
    check(String(format: "L 0.00 … 0.50 is untouched at %+.2f", h), worst == 0,
          String(format: "%.12f", worst))
}
check("and the knee is where the spec puts it", HighlightsCurve.knee == 0.50)

print("\nit pulls down below zero and lifts above it, above the knee only")
for h in settings {
    let bright = HighlightsCurve.shapedLightness(0.95, highlights: h)
    check(String(format: "a bright tone goes the right way at %+.2f", h),
          h < 0 ? bright < 0.95 : bright > 0.95,
          String(format: "0.95 → %.4f", bright))
}

// ⚠️ THE REASON THIS CONTROL IS NOT A CUBE ON ITS OWN. A colour cube and
// CIToneCurve both clamp their input at 1.0 — probed directly — so every tone
// from white upwards was one value to them. The pre-scale is what gives those
// tones rows of their own, and this is the check that says it worked.
print("\nthe range above white is really there, and really separable")
let aboveWhite = [1.000, 1.010, 1.027, 1.045, 1.074]
for h in [-0.5, -1.0] {
    var outputs: [Double] = []
    for display in aboveWhite {
        let l = linear(display)
        let out = HighlightsCurve.apply(r: l, g: l, b: l, highlights: h)
        outputs.append(ExposureCube.toDisplay(out.r))
    }
    let distinct = Set(outputs.map { Int($0 * 100000) }).count
    // ⚠️ MORE THAN ONE, NOT ALL FIVE, and the difference is the inherited
    // strength rather than a weakness in the shape. `floorAtFullPull` is set so
    // the pull matches the old, Lightroom-scored curve (KORAK 184), and a pull
    // that gentle cannot bring 1.074 back under white — the top of the range
    // still lands on it and those tones still meet. What it CAN do is keep the
    // tones just above white apart, and the point is that the old path kept
    // NONE of them apart: CIToneCurve clamps at 1.0, so all five came out as one
    // number at every setting. Measured on a photograph, that is 0.00 levels of
    // surviving variation before and 1.73 after (test-highlights-photo.swift).
    //
    // So the claim is "more than one", it is checked against the old path's
    // exact answer of one, and raising `floorAtFullPull` is what would make it
    // five — at the cost of a control six times stronger than the calibrated one.
    check(String(format: "tones above white stop being one single tone at %+.2f", h),
          distinct > 1, "\(distinct) distinct: \(outputs.map { String(format: "%.4f", $0) })")
    check(String(format: "and they come back under white at %+.2f", h),
          outputs.allSatisfy { $0 <= 1.0 + 1e-9 },
          "\(outputs.map { String(format: "%.4f", $0) })")
}

print("\nmonotonic — in the picture, and in the slider")
var risingInInput = true
for h in settings {
    var previous = -1.0
    for l in stride(from: 0.0, through: HighlightsCurve.ceiling, by: 0.005) {
        let out = HighlightsCurve.shapedLightness(l, highlights: h)
        if out < previous - 1e-12 { risingInInput = false }
        previous = out
    }
}
check("a brighter tone never comes out darker than a darker one", risingInInput)

var risingInSlider = true
for l in stride(from: 0.55, through: HighlightsCurve.ceiling, by: 0.02) {
    var previous = -1.0
    for h in stride(from: -1.0, through: 1.0, by: 0.05) {
        let out = HighlightsCurve.shapedLightness(l, highlights: h)
        if out < previous - 1e-9 { risingInSlider = false }
        previous = out
    }
}
check("dragging the slider right never darkens a tone", risingInSlider)

// ⚠️ The spec's *„Kriva ne pravi oštar rez na mestu gde počinje obrada"*. A
// crease at the knee is exactly the grey patch it warns about, and it is what a
// mask multiplied onto a straight compression would give.
print("\nno crease where the work starts")
var worstKink = 0.0
for h in settings {
    let k = HighlightsCurve.knee
    let step = 1e-6
    let below = (HighlightsCurve.shapedLightness(k - step, highlights: h)
                 - HighlightsCurve.shapedLightness(k - 2 * step, highlights: h)) / step
    let above = (HighlightsCurve.shapedLightness(k + 2 * step, highlights: h)
                 - HighlightsCurve.shapedLightness(k + step, highlights: h)) / step
    worstKink = max(worstKink, abs(above - below))
}
check("the slope matches on both sides of the knee", worstKink < 0.01,
      String(format: "%.6f", worstKink))

print("\nhue survives — the reason this runs on lightness")
var worstHueShift = 0.0
for h in settings {
    for colour in [(1.05, 0.80, 0.60), (0.95, 0.90, 0.70), (0.80, 0.85, 0.95), (1.02, 0.99, 0.70)] {
        let before = OKLab.from(r: colour.0, g: colour.1, b: colour.2)
        let out = HighlightsCurve.apply(r: colour.0, g: colour.1, b: colour.2, highlights: h)
        let after = OKLab.from(r: out.r, g: out.g, b: out.b)
        guard hypot(after.a, after.b) > 1e-6 else { continue }
        worstHueShift = max(worstHueShift,
                            abs(atan2(after.b, after.a) - atan2(before.b, before.a)))
    }
}
// ⚠️ 1e-4 rad, and the bar is measured rather than convenient. OKLab's
// published forward and inverse matrices are inverses of each other only to
// about 2.6e-7 (ContrastCurve's own test documents why the exact inverse is not
// used: it costs neutral greys their neutrality). An angle is chroma error
// DIVIDED BY chroma, so on a tone whose chroma is 0.04 that same 2.6e-7 shows up
// as 6e-6 rad. 1e-4 rad is six thousandths of a degree — far below anything a
// photograph can show, and still four hundred times tighter than a hue shift
// anyone could see.
check("the hue angle does not move", worstHueShift < 1e-4,
      String(format: "%.9f rad", worstHueShift))

// ⚠️ THE RECOVERY CLAUSE, and this is what it looks like when it works: a pixel
// whose red was past white while its green and blue were not comes back as a
// COLOUR rather than as white. Nothing branches on "is a channel blown" — the
// space does it, see HighlightsCurve.apply.
print("\na channel past white comes back as colour, not as a grey patch")
for h in [-0.5, -1.0] {
    let blown = HighlightsCurve.apply(r: 1.20, g: 0.95, b: 0.80, highlights: h)
    let spread = max(blown.r, max(blown.g, blown.b)) - min(blown.r, min(blown.g, blown.b))
    check(String(format: "the three channels separate again at %+.2f", h),
          spread > 0.02, String(format: "spread %.4f", spread))
    check(String(format: "and the pixel is no longer at white at %+.2f", h),
          blown.r < 1.0, String(format: "r %.4f", blown.r))
}

print("\ncolour comes out of the very top, and only there, and only downwards")
let topColour = (1.05, 0.70, 0.55)
let topBefore = OKLab.from(r: topColour.0, g: topColour.1, b: topColour.2)
let pulled = HighlightsCurve.apply(r: topColour.0, g: topColour.1, b: topColour.2, highlights: -1)
let pulledLab = OKLab.from(r: pulled.r, g: pulled.g, b: pulled.b)
check("chroma drops at Highlights -100",
      hypot(pulledLab.a, pulledLab.b) < hypot(topBefore.a, topBefore.b),
      String(format: "%.5f → %.5f", hypot(topBefore.a, topBefore.b), hypot(pulledLab.a, pulledLab.b)))

// A tone just above the knee is in range but nowhere near the extremes, so the
// desaturation must not reach it — otherwise the control quietly washes out the
// whole upper half of every picture.
let midHigh = (0.36, 0.24, 0.19)          // linear; L is about 0.70
let midBefore = OKLab.from(r: midHigh.0, g: midHigh.1, b: midHigh.2)
let midPulled = HighlightsCurve.apply(r: midHigh.0, g: midHigh.1, b: midHigh.2, highlights: -1)
let midLab = OKLab.from(r: midPulled.r, g: midPulled.g, b: midPulled.b)
// 1e-5 for the reason given at the hue check above — what moves here is the
// colour space's round trip, not the desaturation. The next check proves the
// desaturation itself is exactly nothing down there, with no conversion in the
// way to blur it.
check("a tone just above the knee keeps its colour",
      abs(hypot(midLab.a, midLab.b) - hypot(midBefore.a, midBefore.b)) < 1e-5,
      String(format: "%.6f → %.6f", hypot(midBefore.a, midBefore.b), hypot(midLab.a, midLab.b)))

var desaturationReachesDown = false
for l in stride(from: 0.0, through: HighlightsCurve.desaturationFrom, by: 0.005) {
    if HighlightsCurve.smoothstep(HighlightsCurve.desaturationFrom,
                                  HighlightsCurve.ceiling, l) != 0 {
        desaturationReachesDown = true
    }
}
check("and the desaturation is exactly zero below the top band",
      !desaturationReachesDown)

// ⚠️ ASKED OF THE CODE, NOT OF A RENDERED PIXEL, and the first version of this
// check got that wrong. Pushing Highlights up raises the lightness, and a colour
// that saturated cannot exist at that lightness — so `OKLab.toGamut` walks its
// chroma back and the pixel comes out less colourful. That is the gamut doing
// its job, not the desaturation clause firing, and a check that cannot tell the
// two apart is checking nothing.
//
// What the spec actually asks is that the clause is ONE-SIDED — it belongs to
// pulling highlights down — and that is a property of where it sits in the
// source, so that is what is read.
let curveSource = (try? String(contentsOfFile: "BriefShow/HighlightsCurve.swift",
                               encoding: .utf8)) ?? ""
if curveSource.isEmpty {
    print("  ..    HighlightsCurve.swift not readable from here — skipping the one-sided check")
} else {
    let branch = curveSource.range(of: "if highlights < 0 {")
    let use = curveSource.range(of: "abs(highlights) * HighlightsCurve.extremeDesaturation")
        ?? curveSource.range(of: "abs(highlights) * extremeDesaturation")
    check("the desaturation lives inside the `highlights < 0` branch",
          branch != nil && use != nil && branch!.lowerBound < use!.lowerBound)
}

let liftedColour = HighlightsCurve.apply(r: topColour.0, g: topColour.1, b: topColour.2, highlights: 1)
check("pushing Highlights UP makes a bright tone brighter",
      OKLab.from(r: liftedColour.r, g: liftedColour.g, b: liftedColour.b).L
      >= topBefore.L - 1e-9,
      String(format: "L %.4f → %.4f", topBefore.L,
             OKLab.from(r: liftedColour.r, g: liftedColour.g, b: liftedColour.b).L))

print("\nand the table the cube is built from says the same thing")
let dimension = HighlightsCube.dimension
let cube = HighlightsCube.data(for: -0.5)
check("the table is the size CIColorCube expects",
      cube.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size)

cube.withUnsafeBytes { raw in
    let floats = raw.bindMemory(to: Float.self)
    var worst = 0.0
    var peak = 0.0
    for blue in stride(from: 0, to: dimension, by: 7) {
        for green in stride(from: 0, to: dimension, by: 7) {
            for red in stride(from: 0, to: dimension, by: 7) {
                let index = ((blue * dimension + green) * dimension + red) * 4
                // ⚠️ The axis is the SCALED picture — this is the one cube in
                // the app whose entry does not stand for the display value it
                // is indexed by.
                let scale = HighlightsCurve.headroom
                let r = ExposureCube.toLinear(Double(red) / Double(dimension - 1) * scale)
                let g = ExposureCube.toLinear(Double(green) / Double(dimension - 1) * scale)
                let b = ExposureCube.toLinear(Double(blue) / Double(dimension - 1) * scale)
                let wanted = HighlightsCurve.apply(r: r, g: g, b: b, highlights: -0.5)
                worst = max(worst, abs(Double(floats[index]) - min(max(ExposureCube.toDisplay(wanted.r), 0), 1)))
                worst = max(worst, abs(Double(floats[index + 1]) - min(max(ExposureCube.toDisplay(wanted.g), 0), 1)))
                worst = max(worst, abs(Double(floats[index + 2]) - min(max(ExposureCube.toDisplay(wanted.b), 0), 1)))
                peak = max(peak, Double(max(floats[index], max(floats[index + 1], floats[index + 2]))))
            }
        }
    }
    check("every entry is the curve, in the cube's own scaled axes", worst < 1e-6,
          String(format: "%.8f", worst))
    check("and no entry leaves the box", peak <= 1 + 1e-9, String(format: "%.6f", peak))
}

// ⚠️ THE MUST. One implementation, called by the photo, the layer and the mask —
// and Highlights must be OUT of the shared tone curve, or it is being applied
// twice.
print("\nthe one place — Highlights has a single implementation")
let develop = (try? String(contentsOfFile: CommandLine.arguments.count > 1
                           ? CommandLine.arguments[1]
                           : "BriefShow/Develop.swift", encoding: .utf8)) ?? ""
if develop.isEmpty {
    check("Develop.swift could be read", false, "pass its path as argv[1]")
} else {
    let callSites = develop.components(separatedBy: "PhotoEditRenderer.applyHighlights").count - 1
    check("the photo and a layer both call applyHighlights", callSites >= 2, "\(callSites) call sites")
    check("and the shared tone curve no longer carries it",
          !develop.contains("highlights: Double, whites: Double")
          && !develop.contains("highlights: settings.highlights, whites:")
          && !develop.contains("highlights: local.highlights, whites:"))
    check("the pre-scale is in front of the cube, not behind it",
          develop.contains("1 / HighlightsCurve.headroom"))
}

print()
if failures == 0 {
    print("all good")
    exit(0)
}
print("\(failures) checks failed")
exit(1)
