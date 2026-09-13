//  DehazeAtmosphere.swift
//
//  Dehaze as the atmospheric scattering model it actually is, rather than as
//  contrast plus saturation plus a tone curve.
//
//  ⚠️ WHY THIS EXISTS. BRIEFSHOW_DEVELOP_NOTES.md has carried the same sentence
//  since August: *„Dehaze — an APPROXIMATION, not Lightroom's real algorithm
//  (which uses a dark-channel-prior atmospheric-scattering model — a much bigger
//  undertaking, explicitly deferred)"*. The client's specification of 13.09 asks
//  for the undertaking:
//
//    * estimate the atmospheric light A from the brightest pixels of the dark
//      channel,
//    * build a transmission map t(x) = 1 − ω · min_c( I_c(x) / A_c ) from the
//      Dark Channel Prior,
//    * refine t with a guided filter that uses the picture as its guide, so the
//      map follows edges instead of blocking up,
//    * recover the scene with J(x) = (I(x) − A) / max(t(x), t₀) + A, and on the
//      negative half put synthetic haze back by the same model,
//    * and correct chroma afterwards so a hard pull does not break the colours.
//
//  That is the physical model: a camera sees I = J·t + A·(1−t), where t falls
//  off with distance. Everything below is that equation and its inverse.
//
//  ⚠️ WHAT THE SHIPPING PATH DID. `CIColorControls` at contrast 1+0.35d and
//  saturation 1+0.25d, then a tone curve that crushed the black point. It reads
//  as "punchier" and it is not wrong to look at — but it has no idea where the
//  haze IS. It pulls the foreground exactly as hard as the mountain at the back,
//  which is the one thing the model is for.
//
//  ⚠️ AND THE FILTER THE SPEC NAMES FOR STEP THREE IS A NO-OP — the same finding
//  as KORAK 186, and this is the second control it has bitten. `CIGuidedFilter`
//  returns its input unchanged on macOS 26 at every radius and epsilon tried.
//  The refinement here is `CIEdgePreserveUpsampleFilter` instead, which is a
//  JOINT BILATERAL UPSAMPLE and is a better fit than a workaround: it takes the
//  coarse transmission map as its small image and the photograph as its guide,
//  which is exactly "smooth t, follow the picture's edges".
import Foundation
import CoreImage

enum DehazeAtmosphere {

    /// How much haze the transmission map is allowed to claim.
    ///
    /// ⚠️ ω IS NOT 1.0 ON PURPOSE, and the reason is in the model rather than in
    /// taste: at ω = 1 a distant object is reconstructed as if NO haze belonged
    /// there at all, and a photograph with no aerial perspective left in it
    /// reads as a cut-out. 0.95 is the value He, Sun and Tang's paper uses for
    /// the same reason — it keeps a little atmosphere at the far end.
    static let omega = 0.95

    /// The floor under the transmission map.
    ///
    /// `J = (I − A) / t + A` divides by t, so the densest haze — where t goes to
    /// zero — would multiply the noise there by everything. 0.1 caps the gain at
    /// ten, which is the standard floor and is what `max(t, t₀)` in the spec is.
    static let minimumTransmission = 0.1

    /// The patch the dark channel is taken over, as a fraction of the long edge.
    ///
    /// The Dark Channel Prior is a statement about a NEIGHBOURHOOD — "in a
    /// haze-free patch, some pixel is nearly black in some channel" — so it is
    /// a local minimum, not a per-pixel one. Too small and texture reads as
    /// haze; too large and the map blocks up around edges, which is what the
    /// guided refinement then has to undo.
    ///
    /// ⚠️ THE FLOOR IS THE PAPER'S 15×15 WINDOW, and it was raised from 3 after a
    /// measurement. On the synthetic plate — whose dark detail sits every 17
    /// pixels, which is what "some pixel in the patch is nearly black" means
    /// there — a radius of 4 gave windows that missed it, so the prior read haze
    /// in the clear foreground: t = 0.865 where the truth was 0.93. That 7% is
    /// multiplied by the distance from A, which is how it arrived as twenty
    /// levels of correction on a part of the picture that has no haze on it.
    /// With the floor at 7 every window contains its dark pixel and the map
    /// reads what it should.
    static let patchFraction = 0.01
    static let minimumPatchRadius = 7.0
    static let maximumPatchRadius = 24.0

    /// How far the coarse map is shrunk before the edge-preserving filter lifts
    /// it back up, as a fraction of the patch radius.
    ///
    /// ⚠️ THE PATCH SCALE, AND THE MEASUREMENT SAYS SO. The patch minimum leaves
    /// structure at exactly one scale — the patch's — so that is the resolution
    /// a coarse version of the map needs, and the refinement's job is to smooth
    /// that blockiness away and put the map back on the picture's edges. On the
    /// synthetic plate, where the true map is known, it reads t = 0.917 at the
    /// clear end (true 0.93) and 0.129 at the far end (true 0.12), and the
    /// recovery lands 31.2 levels from the clean scene; shrinking by a flat
    /// quarter instead reads 0.152 at the far end and lands at 41.4.
    ///
    /// ⚠️ AN EARLIER VERSION OF THIS NOTE BLAMED THIS CHOICE FOR SOMETHING IT
    /// DID NOT DO, and the correction is worth keeping. On a real frame the
    /// darkest pixels appeared to be moved hardest — which looked like the map
    /// losing them to their hazy neighbourhood — and the scale was changed to a
    /// flat quarter because of it. The bias was in the RULER: the model moves a
    /// pixel by (I − A)·(1/t − 1), so levels moved is the map's factor times the
    /// pixel's distance from A, and dark pixels sit furthest from A. Measured as
    /// a share of that distance, as Tools/test-dehaze-photo.swift does now, the
    /// hazy quarter is pulled five times harder than the clear one and there was
    /// never anything to fix.
    static let refineRadiusFraction = 1.0

    /// The long edge the atmospheric light is estimated at.
    ///
    /// ⚠️ A IS A GLOBAL NUMBER, so it does not need the full frame — and it must
    /// not pay for one. Estimating it means rendering the picture, and rendering
    /// it at 256 px costs milliseconds where the native frame costs hundreds.
    /// The brightest haze in a picture is a large region by nature; nothing that
    /// survives to 256 px is lost.
    static let estimateSize = 256.0

    /// What share of the dark channel's brightest pixels A is averaged over.
    ///
    /// The paper says the top 0.1%. That is a handful of pixels at 256 px, and a
    /// handful of pixels is a specular highlight as often as it is sky — so the
    /// floor below it is what actually decides on a small estimate.
    static let brightestShare = 0.001
    static let minimumSamples = 64

    /// A ceiling on the atmospheric light.
    ///
    /// ⚠️ A AT 1.0 MAKES THE RECOVERY DIVIDE BY ZERO IN SPIRIT: every tone at or
    /// above A comes back as A exactly, so a frame whose brightest haze is pure
    /// white would have its whole sky flattened onto one value. Clamping A just
    /// under white keeps the arithmetic honest, and the difference is invisible.
    static let maximumAtmosphericLight = 0.95
    static let minimumAtmosphericLight = 0.05

    // MARK: - The post-correction

    /// How much chroma is taken back off at Dehaze +100.
    ///
    /// The spec's last clause. Removing haze DIVIDES by a number smaller than
    /// one, so both the distance from A and the distance between the channels
    /// grow — the colour of a far-off roof can come back at three times the
    /// saturation it had. Small, and it only bites where the chroma is already
    /// high, so an ordinary scene is untouched.
    static let chromaRelief = 0.22
    static let chromaReliefFrom = 0.10

    /// How far above black the toe that protects the recovered shadows reaches.
    ///
    /// The same division drives dark pixels below zero — the spec's *„clipping u
    /// senkama"*. A toe on the bottom of the range catches them before the
    /// clamp does, so a recovered shadow keeps its separation instead of
    /// arriving as one flat black.
    static let shadowToe = 0.12

    /// Where the transmission map is told to stop mattering, on the slider.
    ///
    /// Both halves of the control are the same map with the strength folded
    /// INTO it: `t' = 1 − |dehaze| · (1 − t)`. At 0 that is t' = 1 — the model
    /// says the picture is exactly what it is, and the whole chain is the
    /// identity by construction rather than by a guard.
    static func scaledTransmission(_ t: Double, strength: Double) -> Double {
        1 - min(abs(strength), 1) * (1 - t)
    }

    /// How much of the haze the LEFT half lays down everywhere, regardless of
    /// what the map says.
    ///
    /// ⚠️ THIS IS A LIMIT OF THE MODEL, NOT A FUDGE, and it is worth stating
    /// plainly: a haze-free photograph contains no depth information for the
    /// Dark Channel Prior to read. The prior finds haze by noticing that the
    /// dark channel has been LIFTED; in a clear picture it has not been, so the
    /// map comes back at nearly 1 everywhere — measured on the synthetic clean
    /// scene, t ≈ 0.96 across the whole frame. Running the forward model off
    /// that map adds four percent of haze and the slider looks dead.
    ///
    /// So the left half lays this much atmosphere uniformly and the rest by the
    /// map. On a clear picture that is a flat wash, which is what atmosphere
    /// looks like when there is no distance to grade it by; on a picture that
    /// already has some haze the map still carries most of it.
    static let uniformHaze = 0.35

    /// The mask the left half blends toward the atmospheric light with.
    static func hazeMask(_ t: Double, strength: Double) -> Double {
        let byTheMap = 1 - min(max(t, 0), 1)
        let amount = min(abs(strength), 1) * (uniformHaze + (1 - uniformHaze) * byTheMap)
        return 1 - min(max(amount, 0), 1)
    }
}

/// The reciprocal of the transmission map, as a lookup table.
///
/// ⚠️ ITS OUTPUT IS SCALED DOWN, and it has to be. The recovery multiplies by
/// 1/max(t, t₀), which runs from 1 to ten — and a colour cube clamps its output
/// at 1.0. So the table holds `t₀ / max(t, t₀)`, which lands in [t₀, 1], and
/// `applyDehaze` multiplies the 1/t₀ back out with a `CIColorMatrix` afterwards.
/// The same arrangement, and for the same reason, as `ShadowsCube`'s headroom.
enum TransmissionGainCube {

    static let dimension = 32

    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(strength: Double, data: Data)] = []

    static func data(for strength: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.strength == strength }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(strength)

        lock.lock()
        cache.removeAll { $0.strength == strength }
        cache.insert((strength, built), at: 0)
        if cache.count > capacity { cache.removeLast(cache.count - capacity) }
        lock.unlock()
        return built
    }

    private static func build(_ strength: Double) -> Data {
        let size = dimension
        let floor = DehazeAtmosphere.minimumTransmission
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    // The map is grey — every channel carries t — so the red
                    // axis is the map's own value. The other two are along for
                    // the ride, which is what makes this a 1-D transfer wearing
                    // a cube's clothes.
                    let t = DehazeAtmosphere.scaledTransmission(Double(red) / Double(size - 1),
                                                                strength: strength)
                    let gain = Float(floor / max(t, floor))

                    table[offset + 0] = gain
                    table[offset + 1] = gain
                    table[offset + 2] = gain
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// The chroma and shadow correction that runs after the recovery.
///
/// One cube, parameterised by how hard the slider was pulled, doing the spec's
/// last clause: chroma that has grown past `chromaReliefFrom` is walked back,
/// and the bottom of the range gets a toe so the tones the division pushed under
/// black keep their separation instead of arriving as one flat black.
enum DehazeReliefCube {

    static let dimension = 32

    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(strength: Double, data: Data)] = []

    static func data(for strength: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.strength == strength }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(strength)

        lock.lock()
        cache.removeAll { $0.strength == strength }
        cache.insert((strength, built), at: 0)
        if cache.count > capacity { cache.removeLast(cache.count - capacity) }
        lock.unlock()
        return built
    }

    private static func build(_ strength: Double) -> Data {
        let size = dimension
        let pull = min(max(strength, 0), 1)
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let r = ExposureCube.toLinear(Double(red) / Double(size - 1))
                    let g = ExposureCube.toLinear(Double(green) / Double(size - 1))
                    let b = ExposureCube.toLinear(Double(blue) / Double(size - 1))

                    let lab = OKLab.from(r: r, g: g, b: b)
                    let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()

                    // Only what has grown past the threshold is walked back, and
                    // only in proportion to how far past it went.
                    let over = max(chroma - DehazeAtmosphere.chromaReliefFrom, 0)
                    let relief = 1 - pull * DehazeAtmosphere.chromaRelief
                        * min(over / DehazeAtmosphere.chromaReliefFrom, 1)

                    // The toe: a lightness under the toe is lifted back toward
                    // it, by less and less as it rises, so the order of the
                    // tones is kept and only the crush is undone.
                    let toe = DehazeAtmosphere.shadowToe
                    var L = lab.L
                    if pull > 0, L < toe, toe > 0 {
                        let t = L / toe
                        L = toe * (t * (2 - t) * pull + t * (1 - pull))
                    }

                    let out = OKLab.toGamut(L: L, a: lab.a * relief, b: lab.b * relief)

                    table[offset + 0] = Float(min(max(ExposureCube.toDisplay(out.r), 0), 1))
                    table[offset + 1] = Float(min(max(ExposureCube.toDisplay(out.g), 0), 1))
                    table[offset + 2] = Float(min(max(ExposureCube.toDisplay(out.b), 0), 1))
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// The transmission map turned into the mask that ADDS haze.
///
/// The left half of the slider runs the model forwards, `I·t + A·(1−t)`, and
/// `CIBlendWithMask` is that expression exactly when the mask is t. So this
/// table is only the strength being folded in — `t' = 1 − |dehaze|·(1 − t)` —
/// which at 0 is a mask of 1 everywhere, and a mask of 1 is the picture
/// untouched.
///
/// ⚠️ It is a second table rather than a second use of `TransmissionGainCube`
/// because that one holds a RECIPROCAL, scaled. Two different functions of the
/// same map, and naming them apart is cheaper than remembering which is which.
enum HazeDepthCube {

    static let dimension = 32

    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(strength: Double, data: Data)] = []

    static func data(for strength: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.strength == strength }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(strength)

        lock.lock()
        cache.removeAll { $0.strength == strength }
        cache.insert((strength, built), at: 0)
        if cache.count > capacity { cache.removeLast(cache.count - capacity) }
        lock.unlock()
        return built
    }

    private static func build(_ strength: Double) -> Data {
        let size = dimension
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let value = Float(DehazeAtmosphere.hazeMask(Double(red) / Double(size - 1),
                                                                strength: strength))

                    table[offset + 0] = value
                    table[offset + 1] = value
                    table[offset + 2] = value
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// The transmission map as a plain mask, for the correction to follow.
///
/// `applyDehaze` blends the corrected picture back under this: where t' is 1 —
/// no haze, nothing recovered — the mask keeps the uncorrected pixel, and where
/// t' is small the correction is taken in full. It is the map itself, scaled by
/// the slider the same way everything else is; the arithmetic is one line and it
/// gets its own table only because a cube is how this pipeline reads a map.
enum TransmissionMaskCube {

    static let dimension = 32

    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(strength: Double, data: Data)] = []

    static func data(for strength: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.strength == strength }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(strength)

        lock.lock()
        cache.removeAll { $0.strength == strength }
        cache.insert((strength, built), at: 0)
        if cache.count > capacity { cache.removeLast(cache.count - capacity) }
        lock.unlock()
        return built
    }

    private static func build(_ strength: Double) -> Data {
        let size = dimension
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let t = DehazeAtmosphere.scaledTransmission(Double(red) / Double(size - 1),
                                                                strength: strength)
                    let value = Float(min(max(t, 0), 1))

                    table[offset + 0] = value
                    table[offset + 1] = value
                    table[offset + 2] = value
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
