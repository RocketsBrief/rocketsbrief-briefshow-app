//  ContrastCurve.swift
//
//  Contrast the way Lightroom's slider behaves, rather than as a stretch about
//  mid grey.
//
//  ⚠️ WHY THIS EXISTS. It is the second half of the same complaint Exposure
//  answered on 12.09 — see ExposureCurve.swift for the first — and the client's
//  specification, 12.09, names four things a plain stretch cannot do:
//
//    * a smooth S rather than a straight line, so the picture gains contrast in
//      the middle and not at the ends,
//    * a FIXED pivot on middle grey, so a tone that sits there does not move,
//    * a soft rolloff at both ends, so bright and dark detail approaches white
//      and black instead of arriving at them,
//    * and chroma held back at high contrast, so skin does not go orange and
//      a red jumper does not go neon — *„toxic saturation"* in his words.
//
//  What was here until now was already NOT a stretch: CIColorControls was
//  measured out on 05.09 (it dragged the white point, and a Contrast of −5 cost
//  the frame 20% of its highlights) and replaced with a five-knot tone curve
//  with both endpoints pinned. That curve is the thing this replaces, and it
//  was right about the endpoints and wrong about everything else:
//
//    * it bent the quarter and three-quarter knots by a fixed 0.10 and let the
//      spline decide the rest, so the "S" was whatever Core Image interpolated,
//    * it ran on DISPLAY sRGB per channel, so the three channels separated as
//      they climbed — which is exactly the oversaturation the client describes,
//    * and it had no pivot in the sense the spec means: the knot at 0.5 display
//      is linear 0.214, not middle grey.
//
//  This runs on the LIGHTNESS of OKLab and leaves hue alone by construction.
//
//  ⚠️ This changes how an already-saved Contrast renders — same accepted
//  tradeoff as Exposure and the Temperature sign before it. The old behaviour
//  is the thing being complained about.
//
//  ⚠️ THE ONE PLACE. The MUST in BRIEFSHOW_DEVELOP_NOTES.md is that a slider on
//  a layer is the same slider as on the photo. Contrast is the control that
//  broke that rule on 05.09 (the layer kept CIColorControls after the photo had
//  dropped it), so the photo, the layer and the mask all render through
//  `PhotoEditRenderer.applyContrast`, and there is no second implementation of
//  this curve anywhere to keep in step.
import Foundation

enum ContrastCurve {

    /// Middle grey in linear light — the pivot the spec asks for.
    static let middleGrey = 0.18

    /// The pivot, in the space the curve actually works in.
    ///
    /// ⚠️ 0.5646, not the 0.5 the spec also names, and the difference is units
    /// rather than disagreement — the same kind of unit slip ExposureCurve's
    /// shoulder knee documents. The spec gives the pivot twice, as *„0.18 u
    /// linearnom prostoru ili 0.5 perceptivno"*, and those are not the same
    /// tone: OKLab's lightness of linear 0.18 is 0.5646, while L 0.5 is linear
    /// 0.125 — two thirds of a stop DARKER than middle grey. Pivoting there
    /// would lift every midtone in the frame on the way to adding contrast,
    /// which is the "picture got thicker" mistake the spec itself warns about.
    ///
    /// Taken from the conversion rather than typed in, so it cannot drift away
    /// from the matrices below.
    static let pivot = OKLab.from(r: middleGrey, g: middleGrey, b: middleGrey).L

    /// How steep the middle of the range gets at Contrast +1, as a multiple of
    /// where it started.
    ///
    /// ⚠️ 1.4 is INHERITED, not newly chosen, and that is deliberate: the curve
    /// this replaces bent its quarter/three-quarter knots by `0.10` each at full
    /// travel, which is a slope of (0.85 − 0.15) / (0.75 − 0.25) = 1.4 across
    /// the midtones — and that constant is the one thing about the old curve
    /// that had been calibrated against Lightroom
    /// (Tools/run-lightroom-calibration.py). Keeping it means the client's saved
    /// edits and imported presets land on the same midtone contrast they landed
    /// on yesterday, and what changes is the SHAPE: the ends, the hue and the
    /// chroma. Changing the strength at the same time as the shape would make
    /// the two impossible to tell apart in a measurement.
    ///
    /// At the pivot the slope in OKLab and the slope in display sRGB are the
    /// same number (the tone does not move there, so the transfer between the
    /// two spaces cancels), which is why the inherited figure carries over
    /// without rescaling.
    static let midtoneSlopeAtFullTravel = 1.4

    /// How far chroma follows lightness at full travel. 0 leaves colour alone;
    /// 1 keeps chroma exactly proportional to lightness.
    ///
    /// This is the spec's *„Chroma / Saturation Compensation"*, and the half
    /// measure is on purpose. Darkening a tone while leaving its a/b untouched
    /// RAISES its chroma relative to its lightness — which is why shadows go
    /// toxic under contrast — and brightening lowers it, which is the washed-out
    /// highlight. Following lightness all the way (1.0) cancels both and reads
    /// flat, like the contrast never happened to the colours at all. Half keeps
    /// the punch and takes the poison out.
    static let chromaFollow = 0.5

    // MARK: - The shape

    /// Contrast at one setting, ready to run over as many pixels as needed.
    ///
    /// A value type rather than a free function because the steepness `k` is
    /// solved by bisection, and solving it once per PIXEL would put 1.6 million
    /// `tanh` calls in the way of every rebuild of the lookup table. Solved once
    /// per setting, it is free.
    struct Shaper {

        /// −1 … +1, the app's own scale. Lightroom's −100 … +100 imports
        /// straight onto it (DevelopLightroomPreset, `Contrast2012`).
        let contrast: Double

        /// The steepness of the S at the pivot, in the tanh family below.
        let k: Double

        /// Distance from the pivot up to white, and down to black. The two
        /// differ — the pivot is not in the middle of the range — and each side
        /// is normalised by its own, which is what pins BOTH endpoints.
        private let spanUp: Double
        private let spanDown: Double

        init(contrast: Double) {
            self.contrast = contrast
            self.k = Shaper.steepness(for: abs(contrast))
            self.spanUp = 1 - ContrastCurve.pivot
            self.spanDown = ContrastCurve.pivot
        }

        /// The one free parameter, solved rather than picked.
        ///
        /// The curve is `tanh(k·x) / tanh(k)` on the normalised distance from
        /// the pivot: it is odd (so it treats up and down alike), it lands
        /// exactly on ±1 at the ends (so white stays white and black stays
        /// black), its slope falls away smoothly toward those ends (the spec's
        /// soft rolloff, and it is the SHAPE providing it, not a knee bolted on
        /// afterwards), and its slope at the pivot is `k / tanh(k)`.
        ///
        /// That last identity is what is solved here: the caller asks for a
        /// midtone slope and gets the `k` that delivers exactly it. There is no
        /// constant in this function that anybody chose.
        static func steepness(for amount: Double) -> Double {
            let wanted = 1 + (ContrastCurve.midtoneSlopeAtFullTravel - 1) * min(max(amount, 0), 1)
            guard wanted > 1 + 1e-12 else { return 0 }

            var low = 1e-6
            var high = 8.0
            for _ in 0..<60 {
                let mid = (low + high) / 2
                if mid / tanh(mid) < wanted { low = mid } else { high = mid }
            }
            return (low + high) / 2
        }

        /// The S itself, on `[-1, 1]`, before it is put back on the tone scale.
        ///
        /// ⚠️ Negative contrast is the EXACT INVERSE of positive, not a second
        /// curve that happens to lean the other way. It costs nothing to write
        /// it that way — the inverse of `tanh(kx)/tanh(k)` is
        /// `atanh(x·tanh(k))/k`, which is bounded and smooth on the whole
        /// interval — and it buys a promise worth having: +c followed by −c
        /// returns the picture it started from, to the last decimal. A client
        /// who overshoots the slider and drags it back gets his photograph
        /// back, and Tools/run-contrast-curve-test.py checks it.
        func s(_ x: Double) -> Double {
            guard k > 0, x != 0 else { return x }
            let magnitude = min(abs(x), 1)
            let shaped: Double
            if contrast > 0 {
                shaped = tanh(k * magnitude) / tanh(k)
            } else {
                shaped = atanh(min(magnitude * tanh(k), 1 - 1e-15)) / k
            }
            return x < 0 ? -shaped : shaped
        }

        /// One OKLab lightness through the curve.
        func shapedLightness(_ L: Double) -> Double {
            guard k > 0 else { return L }
            if L >= ContrastCurve.pivot {
                guard spanUp > 0 else { return L }
                return ContrastCurve.pivot + s((L - ContrastCurve.pivot) / spanUp) * spanUp
            }
            guard spanDown > 0 else { return L }
            return ContrastCurve.pivot + s((L - ContrastCurve.pivot) / spanDown) * spanDown
        }

        /// A pixel, in LINEAR light, through the whole thing.
        ///
        /// Pure: no state, no image, no context — so it can be run a few
        /// thousand times in a test and proved rather than eyeballed.
        func apply(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
            guard k > 0 else { return (r, g, b) }

            let lab = OKLab.from(r: r, g: g, b: b)
            guard lab.L > 1e-9 else { return (r, g, b) }

            let shaped = shapedLightness(lab.L)

            // ⚠️ Only L moves. a and b are the hue and the chroma together, and
            // scaling them BOTH by one number cannot turn the hue — the spec's
            // *„kako se nijansa (Hue) ne bi izmenila"* holds by construction,
            // the same way ExposureCurve's single ratio does.
            let follow = ContrastCurve.chromaFollow * min(abs(contrast), 1)
            let chroma = follow > 0 ? pow(shaped / lab.L, follow) : 1

            return OKLab.toGamut(L: shaped, a: lab.a * chroma, b: lab.b * chroma)
        }
    }

    /// Convenience for the tests and for one-off calls; the cube builds a
    /// `Shaper` once and keeps it.
    static func apply(r: Double, g: Double, b: Double, contrast: Double) -> (r: Double, g: Double, b: Double) {
        guard contrast != 0 else { return (r, g, b) }
        return Shaper(contrast: contrast).apply(r: r, g: g, b: b)
    }
}

/// OKLab, Björn Ottosson's 2020 perceptual space, written out here.
///
/// The spec asks for "OKLab, ACEScg or ICtCp" and OKLab is the one of the three
/// that is a dozen lines of arithmetic with no profile, no LUT and no framework
/// call — which matters because every entry of the lookup table runs it twice,
/// on the CPU, while a slider is being dragged.
enum OKLab {

    static func from(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)

        return (L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    static func toLinear(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b

        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_

        return (r:  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Back to linear sRGB, and inside the box, by taking the colour out rather
    /// than the light.
    ///
    /// ⚠️ A lightness that is safely under white can still put ONE channel
    /// through it if the colour is saturated enough — ExposureCurve documents
    /// the same trap and answers it by scaling all three channels down, which
    /// is the right answer THERE because Exposure is a statement about light.
    /// Contrast is a statement about where a tone sits, so here it is the
    /// CHROMA that gives way: the colour is walked back toward the neutral of
    /// the same lightness until it fits. The tone the curve decided on is
    /// exactly the tone that comes out, and the hue is unchanged on the way —
    /// a per-channel clamp would have moved both.
    static func toGamut(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let direct = toLinear(L: L, a: a, b: b)
        if fits(direct) { return clamped(direct) }

        var low = 0.0          // known to fit: the neutral of this lightness
        var high = 1.0         // known not to: the colour as asked for
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if fits(toLinear(L: L, a: a * mid, b: b * mid)) { low = mid } else { high = mid }
        }
        return clamped(toLinear(L: L, a: a * low, b: b * low))
    }

    private static func fits(_ c: (r: Double, g: Double, b: Double)) -> Bool {
        c.r >= -1e-9 && c.g >= -1e-9 && c.b >= -1e-9
            && c.r <= 1 + 1e-9 && c.g <= 1 + 1e-9 && c.b <= 1 + 1e-9
    }

    /// The bisection lands just inside the box, not on its face; this takes the
    /// last thousandth off so nothing downstream sees 1.0000000004.
    private static func clamped(_ c: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        (r: min(max(c.r, 0), 1), g: min(max(c.g, 0), 1), b: min(max(c.b, 0), 1))
    }
}

/// The lookup table `PhotoEditRenderer` renders the contrast curve through.
///
/// The same shape as `ExposureCube` next door, for the same reasons: one
/// CIColorCube pass costs the same whatever it holds, 32³ entries do not depend
/// on the size of the photograph, and per-pixel Swift over a 45-megapixel frame
/// is not an option.
///
/// ⚠️ The cube's axes are the working colour space, which is sRGB — so each
/// axis is DISPLAY-encoded, while the curve is defined on linear light. Every
/// entry converts in, shapes, and converts back. The sRGB transfer itself is
/// `ExposureCube`'s rather than a second copy written out here: it is the same
/// function, Tools/run-exposure-curve-test.py already proves it round-trips,
/// and two copies of a transfer function are two chances to get a magic number
/// wrong.
enum ContrastCube {

    static let dimension = 32

    /// FOUR entries, and the reason is the MUST in the notes — the photo has
    /// its own Contrast and so does each layer and the mask, and all of them
    /// render through this table. With one slot a photo at +0.3 under a layer
    /// at −0.2 evicts the other's table on every pass and both rebuild on every
    /// frame. Measured for Exposure at 2.6 ms a rebuild against a ~20 ms frame;
    /// this curve is dearer per entry (six cube roots against one), which makes
    /// the cache matter more here, not less.
    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(contrast: Double, data: Data)] = []

    static func data(for contrast: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.contrast == contrast }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(contrast)

        lock.lock()
        // Newest first, oldest dropped — the tables in use are the ones asked
        // for most recently, which is what a render pass does.
        cache.removeAll { $0.contrast == contrast }
        cache.insert((contrast, built), at: 0)
        if cache.count > capacity {
            cache.removeLast(cache.count - capacity)
        }
        lock.unlock()
        return built
    }

    private static func build(_ contrast: Double) -> Data {
        let size = dimension
        let shaper = ContrastCurve.Shaper(contrast: contrast)
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let r = ExposureCube.toLinear(Double(red) / Double(size - 1))
                    let g = ExposureCube.toLinear(Double(green) / Double(size - 1))
                    let b = ExposureCube.toLinear(Double(blue) / Double(size - 1))

                    let shaped = shaper.apply(r: r, g: g, b: b)

                    // CIColorCube wants the table premultiplied, and every
                    // entry here is opaque — same as ExposureCube's.
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
