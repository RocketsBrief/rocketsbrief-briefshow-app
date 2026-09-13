//  HighlightsCurve.swift
//
//  Highlights the way Lightroom's slider behaves, rather than as one row of a
//  shared five-knot tone curve.
//
//  ⚠️ WHY THIS EXISTS. It is the third of the same family — see
//  ExposureCurve.swift and ContrastCurve.swift — and the client's
//  specification, 13.09, asks for four things a tone curve cannot say:
//
//    * act ONLY above middle grey (weight exactly 0 below L 0.50, the work
//      above 0.65),
//    * a soft knee rather than a cut, so no grey patch appears where a blown
//      area was,
//    * recover a channel that is past white from the ones that are not,
//    * and take a little colour out of the very brightest tones at the extreme,
//      so burnt areas do not come back dirty.
//
//  ⚠️ WHAT WAS MEASURED FIRST, BECAUSE IT DECIDED THE WHOLE DESIGN.
//
//  Highlights lived in `PhotoEditRenderer.toneCurvePoints` — one of four
//  controls folded into five knots, run through `CIToneCurve`. Two measurements
//  on Tools/run-highlights-headroom.py and a direct probe of the filters:
//
//  1. There is a LOT of light above white when Highlights gets the picture.
//     Across the 15 RAWs on this machine, the share of the frame with at least
//     one channel past 1.0 runs from 0.04% to **30.6%**, and the brightest
//     channel reaches **1.074**. Those are exactly the tones this control is
//     for.
//
//  2. `CIToneCurve` CANNOT SEE THEM. Fed flat patches built by scaling (not by
//     CIColor, which clamps at source), inputs of 1.00, 1.05 and 1.20 all came
//     out at the same number. So does `CIColorCubeWithColorSpace`: 1.00, 1.05,
//     1.20 and 1.60 all landed on its top entry.
//
//  So the shipping Highlights already treated a fifth of some frames as one
//  flat value, and moving to a cube loses nothing — both filters clamp. What
//  gets that range back is the pre-scale in `PhotoEditRenderer.applyHighlights`:
//  the picture is multiplied by 1/`headroom` FIRST, which brings 1.074 down to
//  0.977, and the cube's own curve is built knowing it. Probed end to end:
//  1.010, 1.027 and 1.045 come out as three different numbers instead of one.
//
//  ⚠️ This changes how an already-saved Highlights renders — the same accepted
//  tradeoff as Exposure and Contrast before it.
import Foundation

enum HighlightsCurve {

    /// How far above white the curve can still see, as a DISPLAY value.
    ///
    /// ⚠️ Measured, not picked. The brightest channel across the 15 RAWs on this
    /// machine is 1.074 (`C4S_5741.NEF`); 1.10 clears that by a third of what is
    /// there. Anything past it still clamps — which is what happens to all of it
    /// today, so a photograph with more headroom than this is no worse off than
    /// it was.
    ///
    /// ⚠️ It is a FIXED number rather than each photograph's own maximum, and
    /// that is deliberate. Measuring the maximum means a reduction pass
    /// (`CIAreaMaximum`) on every render and a cube rebuilt per photograph,
    /// which is the 2.6 ms table build turned into a per-photo cost — for a
    /// difference of a few hundredths at the very top of the range.
    static let headroom = 1.10

    /// Below this lightness, nothing happens at all. The spec's
    /// *„Donji kraj opsega (L<0.50) mora imati težinski uticaj 0.0"*, and it
    /// holds exactly rather than nearly: the curve below is the identity for
    /// x ≤ knee, by construction.
    static let knee = 0.50

    /// Where the very brightest tone in the range lands at Highlights −100.
    ///
    /// ⚠️ THE ONE NUMBER HERE THAT IS A JUDGEMENT, and it is named so it can be
    /// argued with. 0.90 in OKLab lightness puts pure white at about 211 of 255
    /// at full pull — a light grey with structure in it, which is what recovery
    /// is meant to look like. It has NOT been scored against a Lightroom export,
    /// because that needs a pair of files with only Highlights moved, and this
    /// document already records why a preset that moves ten sliders cannot
    /// calibrate one (Tools/run-lightroom-calibration.py).
    static let floorAtFullPull = 1.046

    /// How much colour comes out of the very top at Highlights −100.
    ///
    /// The spec's last clause: *„blago smanjuje zasićenost u tim najsvetlijim
    /// zonama kako sprženi delovi ne bi dobili prljavu ili neprirodnu nijansu"*.
    /// Small, and it only bites in the band above `desaturationFrom` — the point
    /// is a burnt sky that does not come back magenta, not a picture that loses
    /// its colour when the slider moves.
    static let extremeDesaturation = 0.15
    static let desaturationFrom = 0.90

    /// The lightness the top of the extended range sits at.
    ///
    /// Taken from `headroom` through the same two conversions the cube uses, so
    /// it cannot drift away from the pre-scale that puts the picture there.
    static let ceiling = OKLab.from(r: ExposureCube.toLinear(headroom),
                                    g: ExposureCube.toLinear(headroom),
                                    b: ExposureCube.toLinear(headroom)).L

    // MARK: - The shape

    /// Maps `[knee, from]` onto `[knee, to]` with slope exactly 1 at the knee.
    ///
    /// ⚠️ The same rational curve `ExposureCurve.kneeMap` uses, with the
    /// landing point freed: there it always lands on white, and Highlights is
    /// the control whose whole job is to land somewhere else. `x / (1 + c·x)`
    /// is the one shape with slope 1 where it takes over — so there is no
    /// crease at the knee, which is the spec's *„Kriva ne pravi oštar rez"* —
    /// that also hits a chosen point exactly. `c` falls out of those two
    /// conditions; nobody chose it.
    ///
    /// Works in both directions: `to` above `from` gives `c < 0` and expands,
    /// which is the positive half of the slider.
    static func kneeMapTo(_ x: Double, knee: Double, from: Double, to: Double) -> Double {
        guard x > knee else { return x }
        let span = from - knee
        let landing = to - knee
        guard span > 0, landing > 0 else { return x }
        let c = (span - landing) / (landing * span)
        let over = x - knee
        let denominator = 1 + c * over
        guard denominator > 1e-9 else { return x }
        return knee + over / denominator
    }

    /// Where the top of the range is asked to land, for a setting.
    ///
    /// One expression for both halves, which is what makes the control
    /// monotonic in the slider by construction rather than by hope: at 0 it is
    /// the ceiling itself (so the map is the identity), below 0 it falls toward
    /// `floorAtFullPull`, above 0 it rises past the ceiling by the same amount
    /// — and tones pushed past white then clip, which is what Highlights +100
    /// is supposed to do.
    static func landing(for highlights: Double) -> Double {
        ceiling + highlights * (ceiling - floorAtFullPull)
    }

    /// One OKLab lightness through the curve.
    static func shapedLightness(_ L: Double, highlights: Double) -> Double {
        guard highlights != 0 else { return L }
        return kneeMapTo(L, knee: knee, from: ceiling, to: landing(for: highlights))
    }

    /// Smooth 0→1 ramp, used only for where the desaturation bites.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A pixel, in LINEAR light, through the whole thing.
    ///
    /// ⚠️ `r`, `g`, `b` MAY BE GREATER THAN 1 here, and that is the point of the
    /// pre-scale that puts them in reach. Everything else in this file is an
    /// ordinary pure function of them.
    ///
    /// ⚠️ THE RECOVERY CLAUSE IS ANSWERED BY THE SPACE, NOT BY A BRANCH, and
    /// that is a measurement rather than a shortcut. Working in OKLab and moving
    /// only L leaves `a` and `b` alone, so a pixel whose red sat at 1.05 while
    /// its green and blue were well under keeps its hue and simply becomes
    /// VISIBLE as the lightness comes down — the reconstruction the spec asks
    /// for, out of the channels that were not blown. What no arithmetic can do
    /// is reconstruct a pixel where all three channels are blown, since there is
    /// no colour left to reconstruct from. Counted on the client's own frames
    /// (Tools/run-highlights-headroom.py): of the pixels at or past white,
    /// **0.07% to 1.21%** have one channel blown and the rest do not, while
    /// **23% to 29%** have all three. So a special case for the first would be
    /// code for a hundredth of the frame, and the space already handles it.
    static func apply(r: Double, g: Double, b: Double, highlights: Double) -> (r: Double, g: Double, b: Double) {
        guard highlights != 0 else { return (r, g, b) }

        let lab = OKLab.from(r: r, g: g, b: b)
        guard lab.L > knee else { return (r, g, b) }

        let shaped = shapedLightness(lab.L, highlights: highlights)

        // The spec's desaturation, and only at the top, and only on the way
        // down. Pushing highlights UP does not make a burnt tone dirty — it is
        // the recovery that lifts colour out of what used to be flat white, and
        // some of that colour is noise.
        var chroma = 1.0
        if highlights < 0 {
            let bite = smoothstep(desaturationFrom, ceiling, lab.L)
            chroma = 1 - abs(highlights) * extremeDesaturation * bite
        }

        return OKLab.toGamut(L: shaped, a: lab.a * chroma, b: lab.b * chroma)
    }
}

/// The lookup table `PhotoEditRenderer` renders the highlights curve through.
///
/// ⚠️ ITS AXES ARE NOT THE PICTURE'S. Every other cube in this app is indexed by
/// a display value in `[0, 1]`; this one is indexed by that value DIVIDED BY
/// `HighlightsCurve.headroom`, because `applyHighlights` scales the picture by
/// 1/headroom before handing it over. So entry `a` stands for the display value
/// `a × headroom`, which is how a tone that was sitting at 1.045 — past white,
/// and invisible to every filter in Core Image that takes a table — gets a row
/// of its own.
///
/// The OUTPUT is an ordinary display value in `[0, 1]`: the table undoes the
/// scale as well as shaping, so nothing downstream has to know this happened.
enum HighlightsCube {

    static let dimension = 32

    /// Four entries, for the reason ExposureCube's own comment gives: the photo
    /// has its own Highlights and so does each layer and the mask, and one slot
    /// would have them evicting each other on every pass.
    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(highlights: Double, data: Data)] = []

    static func data(for highlights: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.highlights == highlights }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(highlights)

        lock.lock()
        cache.removeAll { $0.highlights == highlights }
        cache.insert((highlights, built), at: 0)
        if cache.count > capacity {
            cache.removeLast(cache.count - capacity)
        }
        lock.unlock()
        return built
    }

    private static func build(_ highlights: Double) -> Data {
        let size = dimension
        let scale = HighlightsCurve.headroom
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    // The axis is the SCALED picture, so multiply back out to
                    // the display value this entry really stands for — which is
                    // allowed to be greater than 1, and for the top third of the
                    // table it is.
                    let r = ExposureCube.toLinear(Double(red) / Double(size - 1) * scale)
                    let g = ExposureCube.toLinear(Double(green) / Double(size - 1) * scale)
                    let b = ExposureCube.toLinear(Double(blue) / Double(size - 1) * scale)

                    let shaped = HighlightsCurve.apply(r: r, g: g, b: b, highlights: highlights)

                    table[offset + 0] = Float(min(max(ExposureCube.toDisplay(shaped.r), 0), 1))
                    table[offset + 1] = Float(min(max(ExposureCube.toDisplay(shaped.g), 0), 1))
                    table[offset + 2] = Float(min(max(ExposureCube.toDisplay(shaped.b), 0), 1))
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
