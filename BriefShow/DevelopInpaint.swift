//  DevelopInpaint.swift
//  BriefShow
//
//  "Remove" — select the people in a photo and erase them, filling the hole
//  from the surrounding photo. Two independent halves, deliberately kept in
//  their own file rather than in Develop.swift (already ~6.6k lines) and
//  written as pure functions over buffers so both can be exercised by a
//  standalone `xcrun swift` script with no GUI:
//
//  1. SubjectMasker — Vision's person segmentation, turned into a mask in
//     the photo's own pixel space. This is the part Apple gives us for
//     free; there is NO public Apple API for the filling half (Photos'
//     "Clean Up" is app-private), which is why the second half exists.
//
//  2. ExemplarInpainter — Criminisi-style exemplar-based inpainting,
//     implemented here from the 2004 paper rather than taken from a
//     library. That is a deliberate licensing choice, not a
//     not-invented-here one: this app is sold, GIMP's resynthesizer is GPL
//     (incompatible with a closed commercial app), and PatchMatch — the
//     randomized-search algorithm most modern "content-aware fill" code
//     descends from — is covered by Adobe patents that run to the end of
//     the decade. Criminisi's priority-ordered, windowed-exhaustive search
//     predates both and carries neither problem, so everything here is
//     ours to ship. See BRIEFSHOW_DEVELOP_NOTES.md for the full reasoning
//     and for what a generative (model-based) upgrade would take.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Subject masking (Vision)

enum SubjectMasker {

    // A white-where-people, black-elsewhere mask covering `image`'s own
    // extent. Vision runs on a downscaled copy (segmentation is O(pixels)
    // and a 45MP RAW is pure waste for a mask that then gets blurred and
    // dilated anyway) and the resulting mask is scaled back up — a couple
    // of pixels of softness at the person's edge is exactly what the
    // dilation below adds on purpose.
    static func personMask(for image: CIImage, maxWorkingEdge: CGFloat = 1600) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }

        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > maxWorkingEdge ? maxWorkingEdge / longEdge : 1
        let working = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: working, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else {
            return nil
        }

        var mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else {
            return nil
        }

        // Vision hands back a single-channel buffer; copying R into G and B
        // (and forcing alpha to 1) makes it behave like every other mask in
        // this app — CIBlendWithMask and CIMultiplyBlendMode both read the
        // RGB level, so a mask with only R populated would multiply the
        // other two channels to zero and silently break an intersection.
        let normalize = CIFilter.colorMatrix()
        normalize.inputImage = mask
        normalize.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        normalize.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        normalize.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        normalize.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        normalize.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        // Cropped straight back to the mask's own extent: a CIColorMatrix
        // whose bias makes transparent black map to something non-zero
        // (here alpha 1) reports an INFINITE extent, and an infinite
        // extent poisons everything downstream — the scale factors below
        // collapse to zero and `mask.extent.origin` becomes -infinity, so
        // the mask silently renders as an empty image. Cost a real debug
        // session; see BRIEFSHOW_DEVELOP_NOTES.md.
        mask = (normalize.outputImage ?? mask).cropped(to: maskExtent)

        let sx = extent.width / maskExtent.width
        let sy = extent.height / maskExtent.height
        mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        mask = mask.transformed(by: CGAffineTransform(
            translationX: extent.origin.x - mask.extent.origin.x,
            y: extent.origin.y - mask.extent.origin.y
        ))
        return mask.cropped(to: extent)
    }

    // Vision traces a person tightly, which leaves a one-to-few-pixel rim
    // of that person's own colour just outside the mask — and exemplar
    // inpainting will happily read that rim as "surrounding photo" and
    // smear it back into the hole, producing a ghost outline exactly where
    // the removed object was. Growing the mask before filling is what
    // stops that, and costs nothing but a slightly larger hole.
    static func grown(_ mask: CIImage, by radius: CGFloat) -> CIImage {
        guard radius >= 1 else {
            return mask
        }
        let extent = mask.extent
        let dilated = mask
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        // Re-hardened after dilation: CIMorphologyMaximum on an already
        // soft-edged mask leaves a gradient, and every consumer here wants
        // a decision ("is this pixel a hole?"), not a blend weight.
        return dilated
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 4.0,
                kCIInputBrightnessKey: -0.2
            ])
            // Same infinite-extent trap as in personMask above: a
            // brightness/contrast pair that doesn't map transparent black
            // to itself reports an unbounded extent unless cropped back.
            .cropped(to: extent)
    }
}

// MARK: - Exemplar-based inpainting

enum ExemplarInpainter {

    // How much of the photo AROUND the hole the search is allowed to copy
    // from, as a multiple of the hole's own size. Big enough that a person
    // standing on sand has plenty of sand to be rebuilt from, small enough
    // that the working buffer stays a few hundred kilopixels rather than
    // the whole 45MP frame.
    static let regionPadding: CGFloat = 0.9

    // Working resolution cap for the region being repaired. The fill is
    // synthesized at this size and scaled back up if the region was bigger,
    // so a very large removal comes back slightly softer than its
    // surroundings — an accepted trade for keeping a removal interactive
    // (the search cost is quadratic in resolution).
    static let maxWorkingEdge = 1100

    // Hard ceiling on how many pixels a single removal has to synthesize.
    // Runtime is roughly (hole pixels) x (search window), so without a cap
    // a person filling half the frame would take minutes while a small
    // background figure takes a second. Above the cap the working image is
    // scaled down until the hole fits — a big removal comes back a little
    // softer, which is exactly the case where nobody can tell, and the
    // wait stays in the seconds either way.
    static let maxHolePixels = 45_000

    struct Buffers {
        var pixels: [UInt8]     // RGBA8, row-major, top-down
        var known: [UInt8]      // 1 = real photo, 0 = hole to fill
        var width: Int
        var height: Int
    }

    // The core of the paper, in one pass:
    //
    //   while any hole pixel remains
    //     find the fill front (hole pixels touching known pixels)
    //     score each front pixel  priority = confidence x data
    //     take the highest-scoring one, find the best-matching fully-known
    //       patch near it, and copy that patch's pixels into the hole
    //
    // The *confidence* term prefers fronts surrounded by lots of original
    // photo (fill the easy, well-supported places first); the *data* term
    // prefers fronts where a strong edge runs INTO the hole, which is what
    // makes a railing or a horizon continue across the gap instead of
    // being smeared over. Dropping the data term is what makes naive
    // "onion peel" fills look like melted wax.
    //
    // Everything is bounded to the hole's own bounding box plus the search
    // window — the enclosing region is only there to be copied FROM, so
    // there is no reason to sweep it looking for work.
    static func fill(
        _ buffers: inout Buffers,
        patchRadius: Int = 4,
        searchRadius: Int = 80,
        shouldContinue: () -> Bool = { true }
    ) {
        let width = buffers.width
        let height = buffers.height
        guard width > 0, height > 0, buffers.pixels.count == width * height * 4, buffers.known.count == width * height else {
            return
        }

        var confidence = [Float](repeating: 0, count: width * height)
        var holeMinX = width, holeMinY = height, holeMaxX = -1, holeMaxY = -1
        var remaining = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if buffers.known[index] == 0 {
                    remaining += 1
                    holeMinX = min(holeMinX, x); holeMaxX = max(holeMaxX, x)
                    holeMinY = min(holeMinY, y); holeMaxY = max(holeMaxY, y)
                } else {
                    confidence[index] = 1
                }
            }
        }
        guard remaining > 0, holeMaxX >= holeMinX, holeMaxY >= holeMinY else {
            return
        }

        // The front can only ever move outward by one patch per step, so
        // the scan box is the hole's box grown by a patch — never the
        // whole buffer.
        let scanMinX = max(holeMinX - patchRadius - 1, 0)
        let scanMinY = max(holeMinY - patchRadius - 1, 0)
        let scanMaxX = min(holeMaxX + patchRadius + 1, width - 1)
        let scanMaxY = min(holeMaxY + patchRadius + 1, height - 1)

        // Source patches are taken from the ORIGINAL photo only, never from
        // already-synthesized pixels — Criminisi's own definition of the
        // source region, and it stops a fill from compounding its own
        // invented texture. Because that region never changes, "is this
        // candidate patch entirely real photo?" can be answered in four
        // lookups from a summed-area table built once here, instead of up
        // to 81 reads per candidate per step (which was over half the
        // search cost).
        var sourceIntegral = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum: Int32 = 0
            for x in 0..<width {
                rowSum += Int32(buffers.known[y * width + x])
                sourceIntegral[(y + 1) * (width + 1) + (x + 1)] =
                    sourceIntegral[y * (width + 1) + (x + 1)] + rowSum
            }
        }

        var gray = [Float](repeating: 0, count: width * height)
        buffers.pixels.withUnsafeBufferPointer { pixelBuffer in
            for index in 0..<(width * height) {
                let base = index * 4
                gray[index] = 0.299 * Float(pixelBuffer[base])
                    + 0.587 * Float(pixelBuffer[base + 1])
                    + 0.114 * Float(pixelBuffer[base + 2])
            }
        }

        // Guards against a pathological image pinning the app: every step
        // fills at least one pixel, so this can only be hit by a bug.
        var stepsLeft = remaining + 16

        while remaining > 0, stepsLeft > 0, shouldContinue() {
            stepsLeft -= 1

            var bestPriority: Float = -1
            var bestX = -1, bestY = -1

            for y in scanMinY...scanMaxY {
                for x in scanMinX...scanMaxX {
                    let index = y * width + x
                    guard buffers.known[index] == 0 else {
                        continue
                    }
                    // On the front only: a hole pixel with at least one
                    // known 4-neighbour (or the image edge, which acts as
                    // known for this purpose).
                    let left = x > 0 ? buffers.known[index - 1] : 1
                    let right = x < width - 1 ? buffers.known[index + 1] : 1
                    let up = y > 0 ? buffers.known[index - width] : 1
                    let down = y < height - 1 ? buffers.known[index + width] : 1
                    guard left == 1 || right == 1 || up == 1 || down == 1 else {
                        continue
                    }

                    let priority = frontPriority(
                        x: x, y: y, width: width, height: height,
                        patchRadius: patchRadius,
                        known: buffers.known, confidence: confidence, gray: gray
                    )
                    if priority > bestPriority {
                        bestPriority = priority
                        bestX = x
                        bestY = y
                    }
                }
            }

            guard bestX >= 0 else {
                break
            }

            let source = bestMatchingPatch(
                targetX: bestX, targetY: bestY,
                width: width, height: height,
                patchRadius: patchRadius, searchRadius: searchRadius,
                pixels: buffers.pixels, known: buffers.known,
                sourceIntegral: sourceIntegral
            )

            let patchConfidence = patchConfidenceValue(
                x: bestX, y: bestY, width: width, height: height,
                patchRadius: patchRadius, known: buffers.known, confidence: confidence
            )

            for dy in -patchRadius...patchRadius {
                let targetY = bestY + dy
                let sourceY = source.y + dy
                guard targetY >= 0, targetY < height, sourceY >= 0, sourceY < height else {
                    continue
                }
                for dx in -patchRadius...patchRadius {
                    let targetX = bestX + dx
                    let sourceX = source.x + dx
                    guard targetX >= 0, targetX < width, sourceX >= 0, sourceX < width else {
                        continue
                    }
                    let targetIndex = targetY * width + targetX
                    guard buffers.known[targetIndex] == 0 else {
                        continue
                    }
                    let sourceIndex = sourceY * width + sourceX
                    let targetBase = targetIndex * 4
                    let sourceBase = sourceIndex * 4
                    buffers.pixels[targetBase] = buffers.pixels[sourceBase]
                    buffers.pixels[targetBase + 1] = buffers.pixels[sourceBase + 1]
                    buffers.pixels[targetBase + 2] = buffers.pixels[sourceBase + 2]
                    buffers.pixels[targetBase + 3] = 255
                    gray[targetIndex] = gray[sourceIndex]
                    buffers.known[targetIndex] = 1
                    confidence[targetIndex] = patchConfidence
                    remaining -= 1
                }
            }
        }
    }

    // MARK: Priority terms

    private static func patchConfidenceValue(
        x: Int, y: Int, width: Int, height: Int, patchRadius: Int,
        known: [UInt8], confidence: [Float]
    ) -> Float {
        var total: Float = 0
        var count: Float = 0
        for dy in -patchRadius...patchRadius {
            let py = y + dy
            guard py >= 0, py < height else {
                continue
            }
            for dx in -patchRadius...patchRadius {
                let px = x + dx
                guard px >= 0, px < width else {
                    continue
                }
                let index = py * width + px
                count += 1
                if known[index] == 1 {
                    total += confidence[index]
                }
            }
        }
        return count > 0 ? total / count : 0
    }

    // priority = confidence x data, where data measures how strongly an
    // edge in the surviving photo points INTO the hole at this spot:
    // the isophote (the direction an edge runs, i.e. the gradient turned
    // 90°) dotted with the hole boundary's normal. A front pixel sitting on
    // the continuation of a strong line scores high and gets filled first,
    // so structure is carried across the gap before flat texture is.
    private static func frontPriority(
        x: Int, y: Int, width: Int, height: Int, patchRadius: Int,
        known: [UInt8], confidence: [Float], gray: [Float]
    ) -> Float {
        let confidenceTerm = patchConfidenceValue(
            x: x, y: y, width: width, height: height,
            patchRadius: patchRadius, known: known, confidence: confidence
        )
        guard confidenceTerm > 0 else {
            return 0
        }

        // Strongest gradient among the patch's KNOWN pixels — unknown
        // pixels hold whatever the buffer was initialized with and would
        // invent edges that aren't in the photo.
        var bestGradientX: Float = 0
        var bestGradientY: Float = 0
        var bestMagnitude: Float = 0
        for dy in -patchRadius...patchRadius {
            let py = y + dy
            guard py >= 1, py < height - 1 else {
                continue
            }
            for dx in -patchRadius...patchRadius {
                let px = x + dx
                guard px >= 1, px < width - 1 else {
                    continue
                }
                let index = py * width + px
                guard known[index] == 1,
                      known[index - 1] == 1, known[index + 1] == 1,
                      known[index - width] == 1, known[index + width] == 1 else {
                    continue
                }
                let gx = (gray[index + 1] - gray[index - 1]) * 0.5
                let gy = (gray[index + width] - gray[index - width]) * 0.5
                let magnitude = gx * gx + gy * gy
                if magnitude > bestMagnitude {
                    bestMagnitude = magnitude
                    bestGradientX = gx
                    bestGradientY = gy
                }
            }
        }

        // Normal of the fill front, taken as the gradient of the known/
        // unknown field itself (which is exactly "which way is out of the
        // hole").
        var normalX: Float = 0
        var normalY: Float = 0
        if x >= 1, x < width - 1 {
            normalX = Float(known[y * width + x + 1]) - Float(known[y * width + x - 1])
        }
        if y >= 1, y < height - 1 {
            normalY = Float(known[(y + 1) * width + x]) - Float(known[(y - 1) * width + x])
        }
        let normalLength = (normalX * normalX + normalY * normalY).squareRoot()
        guard normalLength > 0 else {
            // No usable normal (e.g. an isolated pixel): fall back to the
            // confidence alone plus a floor, so it still gets filled rather
            // than being skipped forever at priority 0.
            return confidenceTerm * 0.01
        }
        normalX /= normalLength
        normalY /= normalLength

        // Isophote = gradient rotated 90°.
        let isophoteX = -bestGradientY
        let isophoteY = bestGradientX
        let dataTerm = abs(isophoteX * normalX + isophoteY * normalY) / 255

        // The +0.01 floor keeps a completely flat, gradient-free area (a
        // clear sky) from scoring 0 everywhere, which would leave the
        // choice of front pixel arbitrary.
        return confidenceTerm * (dataTerm + 0.01)
    }

    // MARK: Patch search

    // Windowed exhaustive search: every fully-known patch whose centre lies
    // within `searchRadius` of the target, scored by sum-of-squared-
    // differences over the target patch's KNOWN pixels only. Exhaustive
    // rather than randomized on purpose (see this file's header note about
    // PatchMatch and patents); the window is what keeps it affordable, and
    // it doubles as a quality win — a patch copied from right next to the
    // hole matches the local lighting, one copied from across the frame
    // often doesn't.
    private static func bestMatchingPatch(
        targetX: Int, targetY: Int,
        width: Int, height: Int,
        patchRadius: Int, searchRadius: Int,
        pixels: [UInt8], known: [UInt8], sourceIntegral: [Int32]
    ) -> (x: Int, y: Int) {
        var bestScore = Int.max
        var bestX = targetX
        var bestY = targetY
        let patchSide = patchRadius * 2 + 1

        let minX = max(targetX - searchRadius, patchRadius)
        let maxX = min(targetX + searchRadius, width - 1 - patchRadius)
        let minY = max(targetY - searchRadius, patchRadius)
        let maxY = min(targetY + searchRadius, height - 1 - patchRadius)
        guard minX <= maxX, minY <= maxY else {
            return (bestX, bestY)
        }

        pixels.withUnsafeBufferPointer { pixelBuffer in
            known.withUnsafeBufferPointer { knownBuffer in
                for candidateY in minY...maxY {
                    for candidateX in minX...maxX {
                        // Only patches made entirely of ORIGINAL photo can
                        // be copied; four summed-area lookups answer that.
                        let x0 = candidateX - patchRadius
                        let y0 = candidateY - patchRadius
                        let x1 = candidateX + patchRadius + 1
                        let y1 = candidateY + patchRadius + 1
                        let stride = width + 1
                        let sum = sourceIntegral[y1 * stride + x1]
                            - sourceIntegral[y0 * stride + x1]
                            - sourceIntegral[y1 * stride + x0]
                            + sourceIntegral[y0 * stride + x0]
                        guard sum == Int32(patchSide * patchSide) else {
                            continue
                        }

                        var score = 0
                        compare: for dy in -patchRadius...patchRadius {
                            let targetRow = (targetY + dy) * width + targetX
                            let candidateRow = (candidateY + dy) * width + candidateX
                            let targetRowValid = targetY + dy >= 0 && targetY + dy < height
                            guard targetRowValid else {
                                continue
                            }
                            for dx in -patchRadius...patchRadius {
                                let targetIndex = targetRow + dx
                                guard targetX + dx >= 0, targetX + dx < width,
                                      knownBuffer[targetIndex] == 1 else {
                                    continue
                                }
                                let candidateIndex = candidateRow + dx
                                let targetBase = targetIndex * 4
                                let candidateBase = candidateIndex * 4
                                let dr = Int(pixelBuffer[targetBase]) - Int(pixelBuffer[candidateBase])
                                let dg = Int(pixelBuffer[targetBase + 1]) - Int(pixelBuffer[candidateBase + 1])
                                let db = Int(pixelBuffer[targetBase + 2]) - Int(pixelBuffer[candidateBase + 2])
                                score += dr * dr + dg * dg + db * db
                                // Abandoning a candidate the moment it is
                                // already worse than the incumbent is what
                                // makes an exhaustive search affordable —
                                // most candidates lose within a few pixels.
                                if score >= bestScore {
                                    break compare
                                }
                            }
                        }

                        if score < bestScore {
                            bestScore = score
                            bestX = candidateX
                            bestY = candidateY
                        }
                    }
                }
            }
        }

        return (bestX, bestY)
    }
}

// MARK: - Whole-photo plumbing

enum InpaintPipeline {

    struct Removal {
        let pngData: Data       // the repaired patch, alpha-cut to the hole
        let boundsUnit: CGRect  // where it belongs, in the FULL (pre-crop) photo's unit space
    }

    // Turns "this mask, on this photo" into a ready-to-add ImageLayer
    // payload. Deliberately returns only the REPAIRED AREA, feathered at
    // its edge, rather than a whole modified photo: dropped in as a layer
    // it composites over the untouched original, so the removal stays as
    // non-destructive and as undoable as every other edit in Develop, and
    // the stored PNG is a few hundred kilobytes instead of the whole frame.
    //
    // `image` must be the FULL, PRE-CROP render (applyCrop: false) — that
    // is the space ImageLayer's x/y/width/height are interpreted in when
    // compositing (see PhotoEditRenderer.compositeLayers), and passing a
    // cropped render here would place the repair at the wrong spot on any
    // photo that has a crop.
    static func removal(
        mask: CIImage,
        from image: CIImage,
        context: CIContext,
        shouldContinue: @escaping () -> Bool = { true }
    ) -> Removal? {
        let extent = image.extent
        guard extent.width >= 8, extent.height >= 8 else {
            return nil
        }

        let grownMask = SubjectMasker.grown(mask, by: max(extent.width, extent.height) * 0.0025)

        guard let maskBox = maskBoundingBox(grownMask, extent: extent, context: context) else {
            return nil
        }

        // The region actually loaded into memory: the hole plus enough
        // surrounding photo to rebuild it from.
        let padX = max(maskBox.width * regionPaddingFraction, 24)
        let padY = max(maskBox.height * regionPaddingFraction, 24)
        let region = maskBox.insetBy(dx: -padX, dy: -padY).intersection(extent).integral
        guard region.width >= 8, region.height >= 8 else {
            return nil
        }

        let longEdge = max(region.width, region.height)
        let workScale = longEdge > CGFloat(ExemplarInpainter.maxWorkingEdge)
            ? CGFloat(ExemplarInpainter.maxWorkingEdge) / longEdge
            : 1
        let workWidth = max(Int((region.width * workScale).rounded()), 8)
        let workHeight = max(Int((region.height * workScale).rounded()), 8)

        guard var buffers = makeBuffers(
            image: image, mask: grownMask, region: region,
            width: workWidth, height: workHeight, context: context
        ) else {
            return nil
        }

        // Second pass at a smaller size if the hole came out bigger than
        // the budget (see maxHolePixels). Counting for real beats guessing
        // from the bounding box — a person is maybe half their own box.
        let holePixels = buffers.known.reduce(into: 0) { $0 += $1 == 0 ? 1 : 0 }
        if holePixels > ExemplarInpainter.maxHolePixels {
            let shrink = (CGFloat(ExemplarInpainter.maxHolePixels) / CGFloat(holePixels)).squareRoot()
            let retryWidth = max(Int((CGFloat(workWidth) * shrink).rounded()), 8)
            let retryHeight = max(Int((CGFloat(workHeight) * shrink).rounded()), 8)
            if let smaller = makeBuffers(
                image: image, mask: grownMask, region: region,
                width: retryWidth, height: retryHeight, context: context
            ) {
                buffers = smaller
            }
        }

        // fill() overwrites `known` as it works, so the shape of the
        // ORIGINAL hole — which is what the finished layer's alpha has to
        // follow — is kept aside first.
        let originalKnown = buffers.known

        ExemplarInpainter.fill(&buffers, shouldContinue: shouldContinue)
        guard shouldContinue() else {
            return nil
        }

        return package(
            buffers: buffers, originalKnown: originalKnown,
            region: region, imageExtent: extent
        )
    }

    static let regionPaddingFraction: CGFloat = ExemplarInpainter.regionPadding

    // MARK: Steps

    // Where the mask actually is, so everything downstream works on a
    // region instead of the whole frame. Read off a small (256px) render of
    // the mask — locating a bounding box needs nothing like full
    // resolution, and rendering a 45MP mask to find it would cost more than
    // the repair itself.
    // Shared with the SD path in DevelopSDInpaint.swift, which reuses the
    // whole frame around the fill — region, buffers and packaging — and
    // only swaps out what synthesises the missing pixels.
    static func maskBoundingBox(_ mask: CIImage, extent: CGRect, context: CIContext) -> CGRect? {
        let probeEdge: CGFloat = 256
        let scale = min(probeEdge / extent.width, probeEdge / extent.height, 1)
        let probeWidth = max(Int((extent.width * scale).rounded()), 1)
        let probeHeight = max(Int((extent.height * scale).rounded()), 1)

        var bytes = [UInt8](repeating: 0, count: probeWidth * probeHeight)
        let scaled = mask
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let probeRect = CGRect(x: 0, y: 0, width: probeWidth, height: probeHeight)

        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            context.render(
                scaled.transformed(by: CGAffineTransform(
                    translationX: -scaled.extent.origin.x,
                    y: -scaled.extent.origin.y
                )),
                toBitmap: base,
                rowBytes: probeWidth,
                bounds: probeRect,
                format: .R8,
                colorSpace: nil
            )
        }

        var minX = probeWidth, minY = probeHeight, maxX = -1, maxY = -1
        for y in 0..<probeHeight {
            for x in 0..<probeWidth where bytes[y * probeWidth + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        // Probe rows are top-down; the returned rect is in Core Image's
        // bottom-up extent space, hence the Y flip.
        let scaleBackX = extent.width / CGFloat(probeWidth)
        let scaleBackY = extent.height / CGFloat(probeHeight)
        let box = CGRect(
            x: extent.origin.x + CGFloat(minX) * scaleBackX,
            y: extent.origin.y + CGFloat(probeHeight - 1 - maxY) * scaleBackY,
            width: CGFloat(maxX - minX + 1) * scaleBackX,
            height: CGFloat(maxY - minY + 1) * scaleBackY
        )
        return box.integral.intersection(extent)
    }

    // Shared with the SD path in DevelopSDInpaint.swift, which reuses the
    // whole frame around the fill — region, buffers and packaging — and
    // only swaps out what synthesises the missing pixels.
    static func makeBuffers(
        image: CIImage, mask: CIImage, region: CGRect,
        width: Int, height: Int, context: CIContext
    ) -> ExemplarInpainter.Buffers? {
        let scaleX = CGFloat(width) / region.width
        let scaleY = CGFloat(height) / region.height
        let target = CGRect(x: 0, y: 0, width: width, height: height)

        func rendered(_ source: CIImage, format: CIFormat, bytesPerPixel: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
            let placed = source
                .cropped(to: region)
                .transformed(by: CGAffineTransform(translationX: -region.origin.x, y: -region.origin.y))
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else {
                    return
                }
                context.render(
                    placed, toBitmap: base, rowBytes: width * bytesPerPixel,
                    bounds: target, format: format, colorSpace: format == .RGBA8 ? briefInpaintColorSpace : nil
                )
            }
            return bytes
        }

        let pixels = rendered(image, format: .RGBA8, bytesPerPixel: 4)
        let maskBytes = rendered(mask, format: .R8, bytesPerPixel: 1)

        var known = [UInt8](repeating: 1, count: width * height)
        var holePixels = 0
        for index in 0..<(width * height) where maskBytes[index] > 127 {
            known[index] = 0
            holePixels += 1
        }
        guard holePixels > 0, holePixels < width * height else {
            return nil
        }

        return ExemplarInpainter.Buffers(pixels: pixels, known: known, width: width, height: height)
    }

    // The repaired region, cut back down to just what actually changed:
    // the RGB comes from the filled buffer, the alpha from the original
    // hole (grown a little and softened), so the layer covers the removed
    // object and nothing else. The few pixels of ramp fall on repaired-
    // region pixels that fill() never touched — they are byte-identical to
    // the photo underneath — so the blend is invisible rather than a
    // visible rectangle seam.
    // Shared with the SD path in DevelopSDInpaint.swift, which reuses the
    // whole frame around the fill — region, buffers and packaging — and
    // only swaps out what synthesises the missing pixels.
    static func package(
        buffers: ExemplarInpainter.Buffers,
        originalKnown: [UInt8],
        region: CGRect,
        imageExtent: CGRect,
        growRadius: Int = 2,
        blurRadius: Int = 3
    ) -> Removal? {
        let width = buffers.width
        let height = buffers.height
        guard width > 0, height > 0 else {
            return nil
        }

        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) where originalKnown[index] == 0 {
            alpha[index] = 255
        }
        // `grow` pushes the solid part of the alpha a little OUTSIDE the hole
        // so the removed object is fully covered; `blur` then ramps across
        // that edge. Because the ramp is centred a couple of pixels outside
        // the hole, a blur radius bigger than the grow is what carries the
        // ramp back INTO the hole — and that inward part is the only part
        // that does anything, since outside the hole the layer's pixels are
        // the photo blending over itself. Hence a wide blur against a small
        // grow, rather than scaling both.
        grow(&alpha, width: width, height: height, radius: growRadius)
        // Twice: one box blur is a linear ramp with a visible kink at each
        // end, two is a smooth curve. Both passes are separable, so the
        // second one is nearly free.
        blur(&alpha, width: width, height: height, radius: blurRadius)
        blur(&alpha, width: width, height: height, radius: blurRadius)

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let a = Int(alpha[index])
            let base = index * 4
            // Premultiplied, to match the bitmapInfo below.
            rgba[base] = UInt8(Int(buffers.pixels[base]) * a / 255)
            rgba[base + 1] = UInt8(Int(buffers.pixels[base + 1]) * a / 255)
            rgba[base + 2] = UInt8(Int(buffers.pixels[base + 2]) * a / 255)
            rgba[base + 3] = alpha[index]
        }

        guard let cgImage = makeCGImage(rgba: rgba, width: width, height: height) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        // Unit space is top-down (ImageLayer.y is the TOP edge) while the
        // Core Image extent is bottom-up — same conversion as everywhere
        // else in this app that turns an extent rect into layer coords.
        let boundsUnit = CGRect(
            x: (region.origin.x - imageExtent.origin.x) / imageExtent.width,
            y: (imageExtent.maxY - region.maxY) / imageExtent.height,
            width: region.width / imageExtent.width,
            height: region.height / imageExtent.height
        )
        return Removal(pngData: png, boundsUnit: boundsUnit)
    }

    // Square dilation and a separable box blur, both on the 8-bit alpha
    // only — a couple of hundred kilopixels, so the simple version is
    // quicker than reaching for Core Image and rendering twice more.
    private static func grow(_ buffer: inout [UInt8], width: Int, height: Int, radius: Int) {
        guard radius > 0 else {
            return
        }
        let source = buffer
        for y in 0..<height {
            for x in 0..<width {
                var maximum: UInt8 = 0
                for dy in -radius...radius {
                    let py = y + dy
                    guard py >= 0, py < height else {
                        continue
                    }
                    for dx in -radius...radius {
                        let px = x + dx
                        guard px >= 0, px < width else {
                            continue
                        }
                        maximum = max(maximum, source[py * width + px])
                    }
                }
                buffer[y * width + x] = maximum
            }
        }
    }

    private static func blur(_ buffer: inout [UInt8], width: Int, height: Int, radius: Int) {
        guard radius > 0 else {
            return
        }
        var horizontal = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var total = 0
                var count = 0
                for dx in -radius...radius {
                    let px = x + dx
                    guard px >= 0, px < width else {
                        continue
                    }
                    total += Int(buffer[y * width + px])
                    count += 1
                }
                horizontal[y * width + x] = UInt8(total / max(count, 1))
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var total = 0
                var count = 0
                for dy in -radius...radius {
                    let py = y + dy
                    guard py >= 0, py < height else {
                        continue
                    }
                    total += Int(horizontal[py * width + x])
                    count += 1
                }
                buffer[y * width + x] = UInt8(total / max(count, 1))
            }
        }
    }

    // A red, semi-transparent picture of the mask for the canvas — the
    // same "here is what I selected" affordance Lightroom paints over a
    // mask. Built at preview size (nobody inspects a selection overlay at
    // 45MP) and returned in the FULL, pre-crop image's own aspect so the
    // caller can hang it on the same frame every other overlay uses.
    static func overlayImage(for mask: CIImage, context: CIContext, maxEdge: CGFloat = 1200) -> NSImage? {
        let extent = mask.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }
        let scale = min(maxEdge / extent.width, maxEdge / extent.height, 1)
        let width = max(Int((extent.width * scale).rounded()), 1)
        let height = max(Int((extent.height * scale).rounded()), 1)

        var maskBytes = [UInt8](repeating: 0, count: width * height)
        let placed = mask
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        maskBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            context.render(
                placed, toBitmap: base, rowBytes: width,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .R8, colorSpace: nil
            )
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let alpha = Int(maskBytes[index]) * 45 / 100
            let base = index * 4
            rgba[base] = UInt8(230 * alpha / 255)
            rgba[base + 1] = UInt8(60 * alpha / 255)
            rgba[base + 2] = UInt8(60 * alpha / 255)
            rgba[base + 3] = UInt8(alpha)
        }

        guard let cgImage = makeCGImage(rgba: rgba, width: width, height: height) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static func makeCGImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        // CFData owns a copy of the bytes, so the image stays valid after
        // this function's local array goes away.
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: briefInpaintColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

private let briefInpaintColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
