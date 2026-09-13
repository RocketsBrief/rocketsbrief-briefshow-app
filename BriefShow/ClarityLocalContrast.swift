//  ClarityLocalContrast.swift
//
//  Clarity as Lightroom's local (midtone) contrast, rather than as one
//  large-radius unsharp mask.
//
//  ⚠️ WHY THIS EXISTS. It is the fifth of the family — see ExposureCurve,
//  ContrastCurve, HighlightsCurve and ShadowsCurve — but the first one that is
//  NOT a curve. Every control before it maps a pixel to a pixel; this one cannot
//  be a lookup table at all, because what it does to a pixel depends on the
//  pixels around it. The client's specification of 13.09 asks for four things:
//
//    * separate the picture into a base and a detail layer with an
//      EDGE-PRESERVING filter, explicitly not a Gaussian blur, because a
//      Gaussian is what produces halos,
//    * weight the work by a midtone mask on perceptual lightness — strongest at
//      L≈0.5, nothing below L 0.15 or above L 0.85, so clouds do not blow out
//      and shadows do not block up,
//    * boost the MID frequencies and put them back on the base,
//    * and on the negative side soften those mid frequencies while leaving the
//      sharp high-frequency edges alone.
//
//  ⚠️ WHAT THE SHIPPING PATH DID, AND THE MEASUREMENT THAT CONDEMNED IT.
//  Clarity was `CIUnsharpMask` at a radius of 2% of the long edge, which is
//  base-plus-k-times-detail with a GAUSSIAN base. On a synthetic step edge with
//  fine texture on both sides — a real object edge next to the texture Clarity
//  is supposed to lift — measured as how far the brightest pixel beside the edge
//  overshoots the flat level it should settle at:
//
//      source                                 3.97 levels
//      CIUnsharpMask r=8 i=0.8               41.81 levels      <- the halo
//
//  Forty-two levels of white rim against the edge. That is the artefact the spec
//  names, and no amount of tuning the intensity removes it: it is what a
//  Gaussian base IS.
//
//  ⚠️ AND THE FILTER APPLE SHIPS FOR THIS DOES NOTHING — measured before any of
//  it was written, because the spec names it by name. `CIGuidedFilter`, fed its
//  own image as the guide or a separate one, at radii 1…40 and epsilons
//  0.0001…0.1, returns the input UNCHANGED: the texture it is meant to smooth
//  comes back at 14.37 levels of RMS, exactly what went in, while
//  `CIGaussianBlur` on the same image returns 0.08. It is a no-op on macOS 26.
//
//  What does work is `CIEdgePreserveUpsampleFilter` — a joint bilateral
//  upsample. Handed the picture itself as the guide and a downscaled copy as the
//  small image, it smooths like a large blur but keeps the edge where it is.
//  Same synthetic edge, texture RMS and the width of the step's 20%→80% rise:
//
//      source                      texture 10.74      edge width  0 px
//      CIGaussianBlur r=10         texture  0.00      edge width 15 px
//      edge-preserving base        texture  0.03      edge width  0 px
//
//  Same smoothing, and the edge does not move. That is the base this control is
//  built on.
//
//  ⚠️ ONE BASE, NOT TWO, AND THAT WAS A MEASUREMENT TOO. The first design split
//  the picture three ways — a big base, a small base, and the mid band between
//  them — so that the negative half could soften the mid frequencies and leave
//  the fine ones. It does not work, because this filter does not behave like a
//  blur with a radius: measured on the same plate, it takes the texture down to
//  0.26, 0.06, 0.04 and 0.01 levels at radii 2, 4, 8 and 32 — at EVERY radius
//  the texture is gone, so the two bases came out the same picture and the band
//  between them was empty. What the filter keeps is not "detail finer than r",
//  it is EDGES, at any r.
//
//  That turns out to be the better answer anyway. With one base, the detail
//  layer is everything that is not an edge, and the spec's *„očuvanje oštrih
//  visokih ivica"* on the negative half is then a property of the base rather
//  than of a second subtraction: at Clarity −100 the texture falls from 8.58 to
//  1.69 levels while the step's own rise stays at 66.0 of its original 69.0 —
//  where the old path, a mix toward a Gaussian, softened the texture only to
//  3.43 and smeared that same edge down to 46.9.
import Foundation
import CoreImage

enum ClarityLocalContrast {

    /// The radius of the base, as a fraction of the long edge.
    ///
    /// ⚠️ INHERITED FROM THE SHIPPING PATH, not re-chosen: 0.02 of the long edge
    /// is exactly the radius the old `CIUnsharpMask` ran at, which is what made
    /// this control read as "punch in the midtones" rather than "crisper edges"
    /// (that is Sharpness, one filter above). The fraction rather than a pixel
    /// count is also inherited, and for the reason the old comment gave: render
    /// runs at preview AND at export resolution, and a radius picked for one
    /// looks wrong at the other.
    static let baseRadiusFraction = 0.02
    static let minimumRadius = 8.0
    static let maximumRadius = 100.0

    /// How strictly the base follows an edge.
    ///
    /// ⚠️ THIS IS THE WHOLE CONTROL, AND THE FILTER'S OWN DEFAULT IS WRONG FOR
    /// IT. `lumaSigma` is the brightness difference the filter treats as one
    /// surface rather than as an edge: below it the base smooths across, above
    /// it the base follows. Since the detail layer is everything the base did
    /// NOT keep, a base that smooths across an edge puts that edge into the
    /// detail — and adding detail back is then exactly the bright rim an unsharp
    /// mask leaves.
    ///
    /// Measured on a step edge with the texture kept AWAY from it, so the rim
    /// beside the edge is halo and nothing else. Texture gain and halo, in
    /// levels, at Clarity +100:
    ///
    ///     the old CIUnsharpMask       texture 8.58 → 15.44      halo 23.46
    ///     lumaSigma 0.40              texture 8.58 → 15.44      halo 21.83
    ///     lumaSigma 0.15 (default)    texture 8.58 → 15.46      halo 15.68
    ///     lumaSigma 0.05              texture 8.58 → 15.46      halo  1.73
    ///
    /// Same gain in all four — the texture this control is for does not care —
    /// and a halo of 1.73 against 23.46. ⚠️ The first version of this file used
    /// the filter's default of 0.15 and kept two thirds of the halo, which is
    /// the whole defect it was written to remove.
    ///
    /// ⚠️ It cannot go arbitrarily low either, and that is the tradeoff to know:
    /// the smaller it is, the more the base treats TEXTURE as edges too and
    /// keeps it — at which point there is nothing left in the detail layer to
    /// lift. 0.05 still gives the full gain on texture whose excursions are
    /// under it, which real texture's are.
    static let lumaSigma = 0.05

    /// How far the upsample looks for its neighbours, in pixels of the small
    /// image. Left at the filter's own default: the scale of the smoothing is
    /// set by how far the small image is downscaled — `baseRadiusFraction` — and
    /// moving both is two ways of saying one thing.
    static let spatialSigma = 3.0

    /// How much of the detail layer is added at Clarity ±100.
    ///
    /// ⚠️ INHERITED, NOT CHOSEN — the same discipline as KORAKs 180, 184 and 185.
    /// The old path was `CIUnsharpMask` at `intensity` 0.8, which is literally
    /// `base + 0.8 x (picture - base)`; this is the same arithmetic with the same
    /// 0.8 and a different base. So at the tone where the midtone mask is at its
    /// full weight — L 0.50, the middle of the range — the new control is exactly
    /// as strong as the shipped one, and everywhere else it is weaker by the
    /// mask, which is what the client asked for. Measured on the plate: texture
    /// 8.58 → 15.44 through the old path with no mask at all, 8.58 → 11.35 here
    /// on a tone the mask weights at about four tenths.
    ///
    /// ⚠️ NEVER ABOVE 1.0, AND THAT IS A PROPERTY RATHER THAN A PREFERENCE. The
    /// negative half subtracts this much of the mid-frequency layer, so at 1.0 it
    /// removes it exactly; anything above would push it past flat and INVERT the
    /// local contrast — texture coming back inside out. The bound is checked in
    /// Tools/run-clarity-test.py.
    static let strength = 0.80

    // MARK: - The midtone mask

    /// Where the mask is at its strongest, and where it has died away.
    ///
    /// The spec, literally: *„Maska mora imati maksimum u srednjim tonovima
    /// (L≈0.5) i padati ka 0.0 na ekstremima (L<0.15 i L>0.85)"*. Those are OKLab
    /// lightnesses, so they are read on the same axis as every other control in
    /// this family.
    static let maskPeak = 0.50
    static let maskFloor = 0.15
    static let maskCeiling = 0.85

    /// How much colour comes back out at the extreme.
    ///
    /// The spec's last clause in prose: pushing Clarity up deepens the local
    /// shadows, and the edges can come back over-saturated. Small, and weighted
    /// by the same midtone mask, so it is a correction and not a colour control.
    static let chromaRelief = 0.12

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// How much of the control reaches a tone, by its lightness. Zero outside
    /// the band by construction, and it arrives at both ends with slope zero, so
    /// there is no edge in the mask itself to draw an outline of its own.
    static func midtoneWeight(_ L: Double) -> Double {
        guard L > maskFloor, L < maskCeiling else { return 0 }
        return L < maskPeak ? smoothstep(maskFloor, maskPeak, L)
                            : 1 - smoothstep(maskPeak, maskCeiling, L)
    }
}

/// The lookup table the midtone mask is drawn with.
///
/// It turns a picture into a GREY IMAGE of its own midtone weights — the mask
/// `CIBlendWithMask` then reads. A cube rather than a curve because the weight is
/// a function of OKLab lightness, which is a function of all three channels; a
/// tone curve would have to be told a luminance first and would get the
/// perceptual axis wrong.
///
/// One entry, built once: unlike every other cube in this app it takes no
/// parameter, because the mask does not depend on the slider — only on where the
/// tone sits.
enum ClarityMaskCube {

    static let dimension = 32

    private static let lock = NSLock()
    private static var cached: Data?

    static func data() -> Data {
        lock.lock()
        if let hit = cached { lock.unlock(); return hit }
        lock.unlock()

        let built = build()

        lock.lock()
        cached = built
        lock.unlock()
        return built
    }

    private static func build() -> Data {
        let size = dimension
        var table = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0

        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let r = ExposureCube.toLinear(Double(red) / Double(size - 1))
                    let g = ExposureCube.toLinear(Double(green) / Double(size - 1))
                    let b = ExposureCube.toLinear(Double(blue) / Double(size - 1))

                    let weight = Float(ClarityLocalContrast.midtoneWeight(OKLab.from(r: r, g: g, b: b).L))

                    table[offset + 0] = weight
                    table[offset + 1] = weight
                    table[offset + 2] = weight
                    table[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
