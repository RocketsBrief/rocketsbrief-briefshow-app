//  ShadowsCurve.swift
//
//  Shadows the way Lightroom's slider behaves, rather than as one row of a
//  shared five-knot tone curve.
//
//  ⚠️ WHY THIS EXISTS. It is the fourth of the same family — see
//  ExposureCurve.swift, ContrastCurve.swift and HighlightsCurve.swift — and the
//  client's specification of 13.09 asks for four things a shared tone curve
//  cannot say:
//
//    * act ONLY on the dark band (L 0.05…0.40, the work at L≈0.15–0.20), with
//      the midtones and everything above them weighted exactly 0,
//    * hold the black point where it is, so opening the shadows does not wash
//      the picture grey,
//    * lift non-linearly when the slider goes right and compress gently when it
//      goes left,
//    * and tune the colour: put back what a lift takes out of saturation, and
//      hold it back again past +50 so a lifted shadow does not come up noisy.
//
//  ⚠️ WHAT THE OLD PATH ACTUALLY DID, MEASURED FIRST — and it is what decided
//  every constant below. Shadows was a row of `PhotoEditRenderer.toneCurvePoints`
//  with weights [0.30, 1.00, 0.60, 0, 0] × `toneControlStrength`. Read off the
//  shipping curve on the 0…255 ramp, at Shadows +100:
//
//      level     0     →  +7.6      the black point, lifted: the grey wash
//      level    16     → +12.9      the band the spec says this control owns
//      level   128     → +15.2      the midtone, which the spec says is 0.0
//      level   160     →  +7.0      still moving, three-quarters up the range
//
//  So two of the spec's four clauses were not merely missing, they were broken
//  in the opposite direction: the control's STRONGEST effect sat at levels 64–80
//  (+25) and it was still lifting the midtones by fifteen levels, while the
//  black point — the one place it must not move — moved the most visibly.
//
//  ⚠️ THIS CHANGES HOW AN ALREADY-SAVED SHADOWS RENDERS — the same accepted
//  tradeoff as Exposure, Contrast and Highlights before it.
import Foundation

enum ShadowsCurve {

    /// Where the window's influence is strongest, in OKLab lightness.
    ///
    /// The spec's *„vrhuncem uticaja oko L≈0.15 do 0.20"*. In display levels
    /// that is 16 of 255 — the deep shadow, not the quarter tone the old curve
    /// was actually centred on.
    static let peak = 0.175

    /// Above this lightness nothing happens at all.
    ///
    /// The spec's *„Srednji i svetli tonovi (L>0.50) moraju ostati potpuno
    /// netaknuti (težinski uticaj 0.0)"*, and it holds exactly rather than
    /// nearly: `weight` is zero there by construction, not by being small.
    static let ceiling = 0.50

    /// How far above white the curve can still see, as a DISPLAY value.
    ///
    /// ⚠️ THE SAME MEASURED NUMBER AS `HighlightsCurve.headroom`, and it is
    /// referenced rather than copied so the two cannot drift apart. Shadows has
    /// no work to do up there — but it renders through a colour cube, and a cube
    /// clamps its input at 1.0. Without the pre-scale in front of it this pass
    /// would quietly throw away the above-white range that KORAK 184 measured
    /// and went to some trouble to keep (0.04%–30.6% of the client's frames).
    /// The table is built knowing about the scale and undoes it on the way out.
    static let headroom = HighlightsCurve.headroom

    /// How far a tone at the peak of the window is lifted at Shadows +100, in
    /// OKLab lightness.
    ///
    /// ⚠️ MEASURED, NOT CHOSEN — and the anchor is the old, Lightroom-scored
    /// curve, the same discipline as KORAK 180 and 184. At the peak of the
    /// window (L 0.175, display level 16) the old curve lifted the tone by
    /// **+13.08 levels**; 0.058 is the lift that reproduces that to a tenth of a
    /// level. What is NOT inherited is the old control's reach — it also moved
    /// the midtones by fifteen levels and the black point by eight, and both of
    /// those are precisely what the spec removes.
    ///
    /// ⚠️ It is also under the ceiling monotonicity puts on it. The steepest the
    /// window rises is 1.5/`peak` = 8.57, so any lift at or above 0.1167 makes
    /// the curve turn over and a darker tone come out brighter than a lighter
    /// one. At 0.058 the flattest the curve ever gets is a slope of 0.73 — the
    /// transition back to the untouched midtones loses about a quarter of its
    /// local contrast at the extreme setting, and nothing anywhere inverts.
    static let liftAtFullPush = 0.058

    /// How much gentler the left half of the slider is than the right.
    ///
    /// ⚠️ ALSO MEASURED AGAINST THE OLD CURVE, and it is not 1.0 for a reason
    /// that only shows up in display levels: the same step in OKLab lightness
    /// costs more levels going down near black than it gains going up. At the
    /// peak of the window the old curve took **−7.17 levels** at Shadows −100,
    /// and a symmetric curve took −12.2 there. 0.59 is what matches the old —
    /// and it is also the spec's *„blago komprimuj senke nadole"*.
    static let crushScale = 0.59

    /// How much of the saturation a lift would wash out is put back.
    ///
    /// Raising L while `a` and `b` stay put lowers chroma RELATIVE to lightness,
    /// which is the washed-out look the spec warns about — so the chroma follows
    /// the lightness by this power, the same idiom (and the same value) as
    /// `ContrastCurve.chromaFollow`.
    static let chromaFollow = 0.5

    /// Where the spec's noise clause starts to bite, on the slider.
    ///
    /// *„kada se senke drastično podignu (shadows > +50), adaptivno prilagodi
    /// zasićenost u tom opsegu da se izbegnu prljavi ili 'šumoviti' tonovi"* —
    /// so past the halfway point of the push the compensation above is wound
    /// back, and at the very top it goes past neutral into a slight
    /// desaturation. The colour a big lift brings up out of a dark corner is
    /// mostly sensor noise, and this is what keeps it from arriving saturated.
    static let noiseReliefFrom = 0.50
    static let noiseRelief = 0.75

    // MARK: - The shape

    /// Smooth 0→1 ramp. Hermite, so it leaves and arrives with slope zero.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// How much of the control reaches a tone, by its lightness.
    ///
    /// ⚠️ THIS IS THE BLACK POINT PROTECTION, and it is the shape rather than a
    /// clamp. The window is two Hermite halves that meet at `peak`: it is zero
    /// AT black and leaves it with slope zero, so the deepest tones are not
    /// merely lifted less — the lift approaches black quadratically and the
    /// black point does not move at all. The spec's *„glatku Bezier ili Hermite
    /// knee krivu koja kreće od 0 na samom dnu"*, and it is the one thing the
    /// old five-knot row could not do, since its bottom knot WAS the lift.
    ///
    /// The upper half arrives at `ceiling` the same way — slope zero — so there
    /// is no crease where the control stops and the midtones begin. That is the
    /// halo the spec is guarding against: an edge between a treated and an
    /// untreated tone is exactly what draws an outline around a dark object.
    static func weight(_ L: Double) -> Double {
        guard L > 0, L < ceiling else { return 0 }
        return L < peak ? smoothstep(0, peak, L)
                        : 1 - smoothstep(peak, ceiling, L)
    }

    /// How far the window is moved, for a setting. Positive lifts, negative
    /// compresses, and the two halves are one expression so the control is
    /// monotonic in the slider by construction.
    static func amount(for shadows: Double) -> Double {
        shadows * liftAtFullPush * (shadows < 0 ? crushScale : 1)
    }

    /// One OKLab lightness through the curve.
    static func shapedLightness(_ L: Double, shadows: Double) -> Double {
        guard shadows != 0 else { return L }
        return max(L + amount(for: shadows) * weight(L), 0)
    }

    /// How much colour the tone keeps, given where its lightness ended up.
    ///
    /// One expression for both of the spec's colour clauses: the chroma follows
    /// the lightness by `chromaFollow` — which is what puts back the saturation
    /// a lift would otherwise wash out — and past `noiseReliefFrom` that
    /// following is wound back and then reversed, which is the noise clause.
    /// Below the halfway point of the slider the second term is exactly zero.
    static func chromaFollowing(for shadows: Double) -> Double {
        chromaFollow - noiseRelief * smoothstep(noiseReliefFrom, 1, shadows)
    }

    /// A pixel, in LINEAR light, through the whole thing.
    ///
    /// ⚠️ `r`, `g`, `b` MAY BE GREATER THAN 1 here — that is the above-white
    /// range the pre-scale in `PhotoEditRenderer.applyShadows` brings into the
    /// table's reach. Nothing up there is touched: `weight` is zero long before
    /// it, and the pixel comes back out unchanged.
    static func apply(r: Double, g: Double, b: Double, shadows: Double) -> (r: Double, g: Double, b: Double) {
        guard shadows != 0 else { return (r, g, b) }

        let lab = OKLab.from(r: r, g: g, b: b)
        let w = weight(lab.L)
        guard w > 0 else { return (r, g, b) }

        let shaped = max(lab.L + amount(for: shadows) * w, 0)
        guard shaped > 0, lab.L > 0 else { return OKLab.toGamut(L: shaped, a: lab.a, b: lab.b) }

        // ⚠️ The ratio is SAFE AT BLACK because of the window's shape, not
        // because of a guard: `weight` vanishes quadratically as L goes to zero,
        // so shaped/L goes to 1 there rather than to infinity. The colour of the
        // darkest pixels is left exactly alone, which is the other half of
        // anchoring the black point.
        let following = chromaFollowing(for: shadows)
        let chroma = following == 0 ? 1 : pow(shaped / lab.L, following)

        return OKLab.toGamut(L: shaped, a: lab.a * chroma, b: lab.b * chroma)
    }
}

/// The lookup table `PhotoEditRenderer` renders the shadows curve through.
///
/// ⚠️ ITS AXES ARE NOT THE PICTURE'S — the same arrangement as `HighlightsCube`
/// and for the same reason, so read that file's note too. Entry `a` stands for
/// the display value `a × ShadowsCurve.headroom`, because `applyShadows` scales
/// the picture by 1/headroom before handing it over. Shadows itself has no
/// interest in the range above white; the pre-scale is there so this pass does
/// not DESTROY it on the way past, which a bare colour cube would.
///
/// ⚠️ AND NEITHER IS ITS OUTPUT — this is the one difference from
/// `HighlightsCube`, and it is what makes this pass TRANSPARENT to the range
/// above white instead of merely able to read it. Highlights is allowed to hand
/// back an ordinary `[0, 1]` display value because bringing those tones back
/// under white is its whole job. Shadows has no business up there at all, so it
/// must give back what it was given: the table stores the shaped display value
/// DIVIDED by headroom, and `applyShadows` multiplies it out again afterwards.
/// Without that second matrix a tone at 1.045 would leave this pass at exactly
/// 1.0 — the cube clamps — and KORAK 184's headroom would be gone by the time
/// anything downstream looked for it.
enum ShadowsCube {

    /// ⚠️ 48 RATHER THAN 32, and it is the one place in this family where the
    /// dimension is not the neighbours'. A cube's entries are evenly spaced in
    /// DISPLAY value, and this control does all of its work in the bottom eighth
    /// of that range — where the curve also bends the most. Measured as the
    /// worst gap between the table read back with Core Image's own linear
    /// interpolation and the exact curve, at Shadows +100:
    ///
    ///     32³   1.11 levels        48³   0.60 levels        64³   0.51 levels
    ///
    /// 64³ is eight times the build of 32³ for a tenth of a level more, and the
    /// build happens while a slider is being dragged. 48³ is where that stops
    /// paying.
    static let dimension = 48

    /// Four entries, for the reason `ExposureCube` and `ContrastCube` give: the
    /// photo has its own Shadows and so does each layer and the mask, and one
    /// slot would have them evicting each other on every pass.
    private static let lock = NSLock()
    private static let capacity = 4
    private static var cache: [(shadows: Double, data: Data)] = []

    static func data(for shadows: Double) -> Data {
        lock.lock()
        if let hit = cache.first(where: { $0.shadows == shadows }) {
            lock.unlock()
            return hit.data
        }
        lock.unlock()

        let built = build(shadows)

        lock.lock()
        cache.removeAll { $0.shadows == shadows }
        cache.insert((shadows, built), at: 0)
        if cache.count > capacity {
            cache.removeLast(cache.count - capacity)
        }
        lock.unlock()
        return built
    }

    private static func build(_ shadows: Double) -> Data {
        let size = dimension
        let scale = ShadowsCurve.headroom
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    // The axis is the SCALED picture, so multiply back out to
                    // the display value this entry really stands for.
                    let r = ExposureCube.toLinear(Double(red) / Double(size - 1) * scale)
                    let g = ExposureCube.toLinear(Double(green) / Double(size - 1) * scale)
                    let b = ExposureCube.toLinear(Double(blue) / Double(size - 1) * scale)

                    let shaped = ShadowsCurve.apply(r: r, g: g, b: b, shadows: shadows)

                    // Stored SCALED DOWN, and the matrix behind the cube puts
                    // it back — see this type's own note. A tone that arrived
                    // above white leaves here above white.
                    table[offset + 0] = Float(min(max(ExposureCube.toDisplay(shaped.r) / scale, 0), 1))
                    table[offset + 1] = Float(min(max(ExposureCube.toDisplay(shaped.g) / scale, 0), 1))
                    table[offset + 2] = Float(min(max(ExposureCube.toDisplay(shaped.b) / scale, 0), 1))
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
