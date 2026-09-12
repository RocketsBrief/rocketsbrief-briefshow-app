//  ExposureCurve.swift
//
//  Exposure the way Lightroom's slider behaves, rather than as a plain gain.
//
//  ⚠️ WHY THIS EXISTS, and it is a measurement, not a preference.
//
//  Until 12.09 Exposure was a flat multiply: the number went straight into
//  `CIRAWFilter.exposure` on a RAW and into `CIExposureAdjust` otherwise, and
//  both multiply linear light by 2^EV. Reported: *„jel lightroomov expose radi
//  drugacije nego nas? nekako bude bas lepo, a ovde malo pomerim — sve se
//  zapali!"*
//
//  Measured on C4S_7891.NEF through the shipping pipeline
//  (Tools/run-exposure-curve-test.py keeps this table honest):
//
//      Exposure     at 255, detail gone
//      +0.00 EV           19.83%
//      +0.25 EV           21.85%
//      +0.50 EV           24.54%
//      +1.00 EV           29.87%
//
//  A tenth of the frame burnt out over one stop, and "at 255" does not come
//  back by pulling the slider down again — the values are equal up there, so
//  the cloud and the shirt are one flat shape.
//
//  A second measurement decided WHERE the fix had to go. Asked how much light
//  survives above white in the finished render:
//
//      +0.00 EV   max linear 1.043   above white 3.63%
//      +0.50 EV   max linear 1.057   above white 3.51%
//      +1.00 EV   max linear 1.060   above white 3.39%
//
//  The headroom SHRINKS as Exposure rises — the RAW decoder is doing the
//  burning itself, before anything downstream can see it. So a roll-off
//  applied after the decode could only darken highlights that were already
//  gone. The gain had to come OUT of the decoder, which is what
//  `PhotoEditRenderer.render` now does, and land here instead.
//
//  ⚠️ This changes how an already-saved Exposure renders. Same class of
//  accepted tradeoff as the Temperature sign fix — the old behaviour was the
//  thing being complained about.
//
//  The shape, from the client's own specification, 12.09:
//
//    * midtones carry the full stop (middle grey is 0.18 in linear light),
//    * the top is compressed with a soft knee so bright detail approaches
//      white instead of arriving at it,
//    * the bottom is compressed the same way, mirrored, so pulling Exposure
//      down does not clog the blacks,
//    * the correction rides on LUMINANCE, so hue survives,
//    * and chroma is given a little back where the knee would otherwise wash
//      a bright colour out.
import Foundation
import CoreImage

enum ExposureCurve {

    /// Middle grey in linear light. The pivot the spec asks for: whatever the
    /// knees do at the ends, a tone here moves by the full 2^EV.
    static let middleGrey = 0.18

    /// Where the shoulder starts, in linear light.
    ///
    /// ⚠️ 0.5 linear, not the 0.7 the spec names, and the difference is units
    /// rather than disagreement: 0.7 in DISPLAY sRGB is 0.448 in linear light,
    /// and this curve works in linear. 0.5 leaves middle grey (0.18) and a stop
    /// above it untouched, which is what "primarno midtonovi" means in numbers.
    static let shoulderKnee = 0.5

    /// Where the toe starts, in linear light — the spec's 0.15.
    static let toeKnee = 0.15

    /// Rec. 709 luminance, the weights Core Image's own luma filters use.
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Squeezes `[knee, whitepoint]` into `[knee, 1]`, leaving everything below
    /// the knee exactly alone.
    ///
    /// ⚠️ THE WHITEPOINT IS THE WHOLE DESIGN, and the first version of this file
    /// did not have it — it applied a fixed Reinhard knee to the gained value,
    /// which measured beautifully (clipping 19.83% → 0.00%) and was wrong:
    /// nudging Exposure to +0.10 pulled pure white down to 230 in one step. A
    /// tenth of a stop must do a tenth of a stop's worth of work.
    ///
    /// With the whitepoint it is continuous in the exposure: the curve squeezes
    /// exactly the range the gain created and nothing more, so
    ///
    ///     whitepoint 1 (no gain)  →  c = 0  →  the identity, everywhere
    ///
    /// and the squeeze grows smoothly from there.
    ///
    /// The shape is `u / (1 + c·u)` past the knee — the one rational curve with
    /// slope exactly 1 where it takes over (so there is no crease) that also
    /// lands exactly on white at the whitepoint (so white is still white, not
    /// nearly-white). `c` falls out of those two conditions; there is no
    /// constant here that anybody chose.
    static func kneeMap(_ x: Double, knee: Double, whitepoint: Double) -> Double {
        guard x > knee else { return x }
        let headroom = 1 - knee
        let span = whitepoint - knee
        guard span > headroom else { return min(x, 1) }   // nothing to squeeze
        let c = (span - headroom) / (span * headroom)
        let over = x - knee
        return knee + over / (1 + c * over)
    }

    /// One luminance through the curve.
    static func shapedLuminance(_ y: Double, ev: Double) -> Double {
        guard ev != 0, y > 0 else { return y }
        let gain = pow(2, ev)
        let gained = y * gain

        if ev > 0 {
            // The gain takes [0, 1] to [0, gain]; the knee brings the part of
            // that above `shoulderKnee` back under white.
            return kneeMap(gained, knee: shoulderKnee, whitepoint: gain)
        }

        // ⚠️ Darkening cannot clip — the range only shrinks — so there is
        // nothing to squeeze and a mirror of the shoulder would be a solution
        // to a problem that is not there. What darkening DOES do is press the
        // bottom of the range together, which is the *„začepljenje"* half of
        // the client's note. So the deep shadows keep a little of where they
        // started, weighted so the lift is nil at the toe and greatest at
        // black, and nil at EV 0 in every case (`gained` is `y` there).
        guard gained < toeKnee else { return gained }
        let depth = 1 - gained / toeKnee            // 0 at the knee, 1 at black
        return gained + (y - gained) * depth * depth * 0.5
    }

    /// A pixel, in LINEAR light, through the whole thing.
    ///
    /// This is the function the client asked for, and everything else in this
    /// file exists to serve it. It is pure: no state, no image, no context — so
    /// it can be run a few thousand times in a test and proved rather than
    /// eyeballed.
    ///
    /// ⚠️ The correction is a RATIO on luminance, not a curve per channel. Bent
    /// channel by channel, a saturated red bends further than the blue beside
    /// it and the hue turns on its way up — the classic "sunset goes orange
    /// then yellow" artefact. Scaling all three by one number cannot change
    /// their proportions, so the hue is preserved by construction.
    static func apply(r: Double, g: Double, b: Double, ev: Double) -> (r: Double, g: Double, b: Double) {
        guard ev != 0 else { return (r, g, b) }

        let y = luminance(r, g, b)
        guard y > 1e-9 else { return (r, g, b) }

        let shaped = shapedLuminance(y, ev: ev)
        let ratio = shaped / y

        var out = (r: r * ratio, g: g * ratio, b: b * ratio)

        // ⚠️ A ratio alone can still push ONE channel through white while the
        // luminance sits comfortably below it — a saturated yellow is the usual
        // offender, its red and green far above its average. That channel is
        // brought back under white, and only that case is touched.
        //
        // ⚠️ `> 1`, NOT `> shoulderKnee`, and the difference was measured. With
        // the knee as the threshold this squeezed a SECOND time everything the
        // luminance curve had already shaped: pure white came out at 0.944, so
        // a photograph's whites went grey the moment Exposure left zero, and
        // the clipping table read a triumphant 0.03% because the top of the
        // range had simply been vacated. The luminance curve is what shapes the
        // picture; this is a guard rail, and a guard rail must do nothing at
        // all until something reaches it.
        let peak = max(out.r, max(out.g, out.b))
        if ev > 0, peak > 1 {
            // The whitepoint is this pixel's own peak when that is higher than
            // the gain's, so the peak lands exactly on white rather than past
            // it — kneeMap only promises that for its whitepoint.
            let squeezed = kneeMap(peak, knee: shoulderKnee, whitepoint: max(pow(2, ev), peak))
            let pull = squeezed / peak
            out = (out.r * pull, out.g * pull, out.b * pull)

            // Chroma compensation, the last item in the spec: the squeeze moves
            // every channel toward each other as well as down, which is what
            // "isprano" looks like. Half of what was taken is pushed back
            // toward the pre-squeeze proportions — as long as that still leaves
            // the peak under white, which is the thing that must not be traded
            // away.
            let recovered = 1 - (1 - pull) * 0.5
            let restored = (r: out.r / pull * recovered,
                            g: out.g / pull * recovered,
                            b: out.b / pull * recovered)
            if max(restored.r, max(restored.g, restored.b)) <= 1 {
                out = restored
            }
        }

        return out
    }
}

/// The lookup table `PhotoEditRenderer` renders the exposure curve through.
///
/// The same shape as `ColorMixerCube` next door, and for the same reason: one
/// CIColorCube pass costs the same whatever it holds, and building 32³ entries
/// does not depend on the size of the photograph. Per-pixel Swift over a
/// 45-megapixel frame is not an option, and a Metal kernel would be a second
/// build system for one function.
///
/// ⚠️ The cube's axes are the working colour space, which is sRGB here — so
/// each axis is DISPLAY-encoded, while the curve is defined on linear light.
/// Every entry converts in, shapes, and converts back out. Getting that wrong
/// does not crash, it just quietly applies the wrong curve, which is why the
/// test checks a handful of entries against `ExposureCurve.apply` directly.
enum ExposureCube {

    static let dimension = 32

    /// ⚠️ FOUR entries, not one, and the reason is the MUST in the notes.
    ///
    /// `ColorMixerCube` next door holds a single table, which is right for it:
    /// one photograph has one mixer. Exposure does not — the photo has its own
    /// and so does each layer, and after 12.09 both render through THIS table.
    /// With one slot, a photo at +0.3 under a layer at −0.2 evicts the other's
    /// table on every pass and both rebuild on every frame.
    ///
    /// Measured: a rebuild is **2.6 ms**, a hit is nil, and a render while a
    /// slider is dragged comes round about every 20 ms. One rebuild is a
    /// noticeable slice of that; two is a quarter of the frame. Four slots
    /// cover the photo, two layers and a mask, and cost 512 KB each — which on
    /// the 8 GB machine this is developed on is still nothing.
    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(ev: Double, data: Data)] = []

    static func data(for ev: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.ev == ev }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(ev)

        lock.lock()
        // Newest first, oldest dropped — the tables in use are the ones asked
        // for most recently, which is exactly what a render pass does.
        cache.removeAll { $0.ev == ev }
        cache.insert((ev, built), at: 0)
        if cache.count > capacity {
            cache.removeLast(cache.count - capacity)
        }
        lock.unlock()
        return built
    }

    /// sRGB transfer function, both ways. Written out rather than taken from a
    /// colour space object because the cube is built on the CPU, one entry at a
    /// time, and this is the only place it is needed.
    static func toLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func toDisplay(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func build(_ ev: Double) -> Data {
        let size = dimension
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let r = toLinear(Double(red) / Double(size - 1))
                    let g = toLinear(Double(green) / Double(size - 1))
                    let b = toLinear(Double(blue) / Double(size - 1))

                    let shaped = ExposureCurve.apply(r: r, g: g, b: b, ev: ev)

                    // CIColorCube wants the table premultiplied, and every
                    // entry here is opaque — same as ColorMixerCube's.
                    table[offset + 0] = Float(min(max(toDisplay(shaped.r), 0), 1))
                    table[offset + 1] = Float(min(max(toDisplay(shaped.g), 0), 1))
                    table[offset + 2] = Float(min(max(toDisplay(shaped.b), 0), 1))
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
