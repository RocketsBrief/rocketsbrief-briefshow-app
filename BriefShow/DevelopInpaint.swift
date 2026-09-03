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

    // MARK: Background people only

    // `VNGeneratePersonSegmentationRequest` returns ONE mask covering
    // everybody, with no notion of separate people — so "remove the
    // strangers behind us, keep us" cannot be asked of Vision directly, on
    // any macOS version. What it CAN be asked of is the mask's own shape:
    // split the white area into connected blobs and the couple in front is
    // one big blob while the strangers down the beach are several small
    // ones.
    //
    // Two people standing shoulder to shoulder merge into a single blob.
    // That is a FEATURE here, not the usual connected-components caveat:
    // the pair in front is exactly the thing that must survive as one
    // subject. The same merging is the limitation when it happens the
    // other way round — a stranger standing right against the subject
    // joins their blob and gets kept — which is what the Brush is for and
    // what the panel tells the user.

    // A blob counts as background when its area is below this share of the
    // largest blob's. 0.35 rather than something tighter because
    // perspective does most of the work already: a person ten metres back
    // covers a QUARTER of the pixels of one at three metres, so anything
    // in that band is comfortably separated, while a value near 1 would
    // start eating the subject's own second person.
    static let backgroundBlobShare: Double = 0.35

    // Vision's mask has occasional single-pixel speckle along a hard edge;
    // below this many probe pixels a blob is that, not a person. Scaled to
    // the probe buffer so it means the same thing regardless of probe size.
    private static func minimumBlobPixels(width: Int, height: Int) -> Int {
        max(3, (width * height) / 60_000)
    }

    // The pure half, so it can be exercised without Vision, Core Image or a
    // GUI: 8-connected labelling of `bytes` (>127 is "person"), returning a
    // buffer with only the background blobs left white — or nil when every
    // blob belongs to the main subject, which is the "nobody else is in
    // this photo" answer the caller has to show as a message rather than an
    // empty mask.
    static func backgroundBlobs(
        mask bytes: [UInt8], width: Int, height: Int,
        share: Double = backgroundBlobShare
    ) -> [UInt8]? {
        let count = width * height
        guard width > 0, height > 0, bytes.count == count else {
            return nil
        }

        // -1 = not yet visited, -2 = background pixel, >= 0 = blob index.
        var labels = [Int32](repeating: -1, count: count)
        var areas: [Int] = []
        // One explicit stack, reused across blobs: recursion here would be
        // a stack overflow on any real photo (a blob can be a million
        // pixels), and a per-blob allocation would be the only cost that
        // scaled with the number of people.
        var stack: [Int] = []
        stack.reserveCapacity(1024)

        for start in 0..<count {
            if labels[start] != -1 {
                continue
            }
            guard bytes[start] > 127 else {
                labels[start] = -2
                continue
            }

            let label = Int32(areas.count)
            var area = 0
            labels[start] = label
            stack.removeAll(keepingCapacity: true)
            stack.append(start)

            while let index = stack.popLast() {
                area += 1
                let x = index % width
                let y = index / width
                let minDX = x > 0 ? -1 : 0
                let maxDX = x < width - 1 ? 1 : 0
                let minDY = y > 0 ? -1 : 0
                let maxDY = y < height - 1 ? 1 : 0
                for dy in minDY...maxDY {
                    for dx in minDX...maxDX where !(dx == 0 && dy == 0) {
                        let neighbour = index + dy * width + dx
                        guard labels[neighbour] == -1 else {
                            continue
                        }
                        if bytes[neighbour] > 127 {
                            labels[neighbour] = label
                            stack.append(neighbour)
                        } else {
                            labels[neighbour] = -2
                        }
                    }
                }
            }
            areas.append(area)
        }

        guard let largest = areas.max(), largest > 0 else {
            return nil
        }
        let ceiling = Double(largest) * share
        let floor = minimumBlobPixels(width: width, height: height)
        // The largest blob itself is never background even if the share
        // arithmetic would let it through (it can, at share >= 1), because
        // "everything except the subject" is the whole point.
        let largestIndex = areas.firstIndex(of: largest) ?? -1
        var keep = [Bool](repeating: false, count: areas.count)
        var kept = 0
        for (index, area) in areas.enumerated()
        where index != largestIndex && area >= floor && Double(area) <= ceiling {
            keep[index] = true
            kept += 1
        }
        guard kept > 0 else {
            return nil
        }

        var out = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let label = labels[index]
            if label >= 0, keep[Int(label)] {
                out[index] = 255
            }
        }
        return out
    }

    // The Core Image wrapper around `backgroundBlobs`. The labelling runs on
    // a small probe copy (a blob's identity survives downscaling; its edge
    // detail is irrelevant to which blob it is) and the result is used as a
    // SELECTOR multiplied back over the full-resolution mask, so the people
    // that survive keep Vision's own sharp outline rather than a 768px
    // stair-stepped one.
    static func backgroundPeople(
        in mask: CIImage, extent: CGRect, context: CIContext,
        probeEdge: CGFloat = 768, share: Double = backgroundBlobShare
    ) -> CIImage? {
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }
        let scale = min(probeEdge / extent.width, probeEdge / extent.height, 1)
        let probeWidth = max(Int((extent.width * scale).rounded()), 1)
        let probeHeight = max(Int((extent.height * scale).rounded()), 1)

        var bytes = [UInt8](repeating: 0, count: probeWidth * probeHeight)
        let scaled = mask
            .transformed(by: CGAffineTransform(
                translationX: -extent.origin.x, y: -extent.origin.y
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let probeRect = CGRect(x: 0, y: 0, width: probeWidth, height: probeHeight)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            context.render(
                scaled, toBitmap: base, rowBytes: probeWidth,
                bounds: probeRect, format: .R8, colorSpace: nil
            )
        }

        guard let selected = backgroundBlobs(
            mask: bytes, width: probeWidth, height: probeHeight, share: share
        ) else {
            return nil
        }
        guard let selectorCG = makeGrayscaleImage(selected, width: probeWidth, height: probeHeight) else {
            return nil
        }

        // Rows out of `context.render(toBitmap:)` are top-down and
        // CIImage(cgImage:) reads them back the same way round, so the
        // probe survives the round trip without a Y flip. Hardened after
        // the upscale for the same reason `grown` hardens: the selector
        // answers "is this pixel one of the kept people?", and a bilinear
        // ramp there would multiply the mask's own edge down below the
        // 0.5 threshold every consumer uses.
        var selector = CIImage(cgImage: selectorCG)
        selector = selector.transformed(by: CGAffineTransform(
            scaleX: extent.width / CGFloat(probeWidth),
            y: extent.height / CGFloat(probeHeight)
        ))
        selector = selector.transformed(by: CGAffineTransform(
            translationX: extent.origin.x - selector.extent.origin.x,
            y: extent.origin.y - selector.extent.origin.y
        ))
        selector = selector
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 4.0,
                kCIInputBrightnessKey: -0.2
            ])
            .cropped(to: extent)

        return mask
            .applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: selector
            ])
            .cropped(to: extent)
    }

    // RGBA rather than a one-component grey image on purpose: every mask in
    // this app is read at its RGB level (CIMultiplyBlendMode and
    // CIBlendWithMask both do), and an opaque alpha keeps the multiply from
    // knocking the result out entirely.
    private static func makeGrayscaleImage(_ values: [UInt8], width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let value = values[index]
            rgba[index * 4] = value
            rgba[index * 4 + 1] = value
            rgba[index * 4 + 2] = value
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
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
    // Raised from 1100 on 30.08.2026, to answer "make the Quick working area
    // bigger without it going white/smeary".
    //
    // The smear was never about the hole's size in the PHOTO — it was about how
    // far the region had to be scaled down to fit this cap. A 1550px hole meant
    // a ~4400px region squeezed into 1100, so every copied patch was stretched
    // back over four real pixels. 1600 cuts that stretch by a third at the same
    // hole size, which is what buys the larger working area rather than simply
    // permitting the failure at a bigger number.
    //
    // The cost is real and quadratic: the patch search is O(resolution^2), so
    // this is roughly 4x the work per removal against the old 1100. That is the
    // whole price of the larger working area, and it is paid on every removal,
    // not just the big ones — see the timing in the notes before raising it
    // again.
    static let maxWorkingEdge = 2200

    // Hard ceiling on how many pixels a single removal has to synthesize.
    // Runtime is roughly (hole pixels) x (search window), so without a cap
    // a person filling half the frame would take minutes while a small
    // background figure takes a second. Above the cap the working image is
    // scaled down until the hole fits — a big removal comes back a little
    // softer, which is exactly the case where nobody can tell, and the
    // wait stays in the seconds either way.
    // Raised with maxWorkingEdge, and it HAS to be: this cap counts the hole in
    // the WORKING buffer, so enlarging that buffer grows the same hole past the
    // old ceiling and the shrink-and-retry below would have scaled it straight
    // back down — quietly cancelling the change above.
    static let maxHolePixels = 180_000

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
            region: region, imageExtent: extent,
            // This path copies real pixels already, so on a region small
            // enough to run unscaled the detail pass finds nothing missing and
            // returns without touching anything. It earns its place on the big
            // ones, where even this path is working on a shrunk copy.
            detailSource: (image, context)
        )
    }

    /// How far the model's colours drifted, measured rather than guessed.
    ///
    /// The patch comes back a shade darker than the photo — the VAE round trip
    /// and the sampler each shift tone a little — and against a flat area like
    /// a sky that reads as a visibly darker rectangle, which no amount of edge
    /// feathering hides. The measurement is free: the decoder also rebuilt the
    /// KNOWN pixels in the ring around the hole, and there the right answer is
    /// already on hand, so comparing its ring against the real one gives the
    /// exact per-channel gain and offset needed to put the patch back on the
    /// photo's own scale.
    ///
    /// Returns identity when there is too little ring to measure from.
    static func toneMatch(
        decoded: [Float],
        buffers: ExemplarInpainter.Buffers,
        side: Int
    ) -> [(gain: Float, offset: Float)] {
        let identity = Array(repeating: (gain: Float(1), offset: Float(0)), count: 3)
        guard ProcessInfo.processInfo.environment["BRIEFSHOW_SD_TONEMATCH"] != "off" else { return identity }

        // The ring: known pixels near the hole, not the whole frame. Near,
        // because a sunset sky three hundred pixels away is not the tone the
        // patch has to match — the pixels it actually touches are.
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where buffers.known[y * side + x] == 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return identity }
        let band = 48
        let x0 = max(minX - band, 0), x1 = min(maxX + band, side - 1)
        let y0 = max(minY - band, 0), y1 = min(maxY + band, side - 1)

        let pixelCount = side * side
        var result = identity
        for channel in 0..<3 {
            var count = 0
            var sumReal: Double = 0, sumModel: Double = 0
            var sumRealSquared: Double = 0, sumModelSquared: Double = 0
            for y in y0...y1 {
                for x in x0...x1 {
                    let index = y * side + x
                    guard buffers.known[index] == 1 else { continue }
                    let real = Double(buffers.pixels[index * 4 + channel])
                    let model = Double(decoded[channel * pixelCount + index])
                    sumReal += real; sumModel += model
                    sumRealSquared += real * real; sumModelSquared += model * model
                    count += 1
                }
            }
            // A thousand pixels is enough for a mean to be steady; below that
            // the ring is mostly hole and the correction would be noise.
            guard count > 1000 else { return identity }

            let n = Double(count)
            let meanReal = sumReal / n, meanModel = sumModel / n
            let varianceReal = max(sumRealSquared / n - meanReal * meanReal, 0)
            let varianceModel = max(sumModelSquared / n - meanModel * meanModel, 0)

            // Gain is clamped hard and deliberately: the drift being corrected
            // is essentially a bias, and a contrast ratio measured on a nearly
            // flat ring is a small number over a small number. The offset does
            // the real work; the gain only trims what is left.
            var gain = 1.0
            if varianceModel > 4, varianceReal > 4 {
                let measured = varianceReal.squareRoot() / varianceModel.squareRoot()
                // Hitting the BOTTOM of that clamp is not a near miss to be
                // rounded off — it is the signature of a ring that cannot be
                // measured at all, and applying the fit anyway is what put a
                // white patch on a sunlit beach.
                //
                // Measured on C4S_7891 (numbers in KORAK 41): a healthy ring
                // fits at gain 0.94-1.00 with an offset of +1 to +12. Over
                // blown highlights all three channels pin at exactly 0.850
                // with an offset of +39. The reason is physical: where the
                // photo is clipped, the real pixels are pegged near 255 and
                // have almost NO variance, while the model's version of the
                // same ring still has gradation — so the honest ratio is far
                // below the floor. Clamping it up leaves the offset to make up
                // the difference, and an offset that large lifts every
                // mid-tone in the patch toward white. That IS the white patch.
                //
                // There is nothing to recover here: the true values were never
                // written to the file. So the correction is abandoned rather
                // than approximated, and the model's own pixels are used as-is.
                guard measured >= 0.85 else {
                    if SDInpaintPipeline.isDebugging {
                        print(String(format: "  [sd] tone match ABANDONED — ring is clipped (channel %d fits at x%.3f)",
                                     channel, measured))
                    }
                    return identity
                }
                gain = min(measured, 1.18)
            }
            let offset = Float(meanReal - gain * meanModel)
            // A non-finite fit is not a small error to be clamped — it is the
            // whole correction being meaningless, and applying it paints the
            // hole PURE WHITE. See the guard at the bottom of this function for
            // where that came from and why it is worth this much care.
            guard gain.isFinite, offset.isFinite else {
                return identity
            }
            result[channel] = (gain: Float(gain), offset: offset)
        }

        if SDInpaintPipeline.isDebugging {
            let text = result.map { String(format: "x%.3f %+.1f", $0.gain, $0.offset) }.joined(separator: "  ")
            print("  [sd] tone match  \(text)")
        }
        return result
    }

    /// Converts a model's float pixel into a byte, refusing to invent white.
    ///
    /// `UInt8(max(0, min(255, value.rounded())))` looks safe and is not. Swift's
    /// `min(255, x)` is `x < 255 ? x : 255`, and every comparison against NaN
    /// is false — so a NaN arrives at the clamp and leaves it as **255**. Every
    /// channel of every affected pixel then writes pure white.
    ///
    /// That is not hypothetical. It is the white blotch, caught in the client's
    /// own run with BRIEFSHOW_SD_DEBUG on:
    ///
    ///     [sd] tone match  x1.000 nan  x1.000 nan  x1.000 nan
    ///
    /// one operation in four, and that one produced the blotch. The NaN came
    /// out of the model's decode and rode the tone-match offset into the
    /// clamp. The correction is now refused when it is non-finite (see
    /// `toneMatch`), and a stray non-finite PIXEL is refused here.
    ///
    /// Returns nil rather than a substitute colour, so callers keep whatever
    /// was already in the buffer. For the generative path that is LaMa's fill,
    /// which is the right answer; for LaMa it is the untouched photograph.
    /// Both are better than white.
    static func byteFromModel(_ value: Float) -> UInt8? {
        guard value.isFinite else { return nil }
        return UInt8(max(0, min(255, value.rounded())))
    }

    static func featherRadius(_ feather: Double, originalKnown: [UInt8], side: Int) -> Int {
        // The ramp is capped against the hole's own size, and that cap is the
        // point: a fixed radius that looks right on a large removal will, on a
        // small one, blur away every fully-opaque pixel — and a patch with no
        // solid core does not remove anything, it just veils it. Divided by
        // five because `package` blurs twice, so the band it produces is about
        // twice the radius wide on each side.
        var holeMinX = Int.max, holeMinY = Int.max, holeMaxX = -1, holeMaxY = -1
        for y in 0..<side {
            for x in 0..<side where originalKnown[y * side + x] == 0 {
                holeMinX = min(holeMinX, x); holeMaxX = max(holeMaxX, x)
                holeMinY = min(holeMinY, y); holeMaxY = max(holeMaxY, y)
            }
        }
        let holeEdge = min(holeMaxX - holeMinX + 1, holeMaxY - holeMinY + 1)
        let widest = Double(max(holeEdge, 20)) / 5
        let radius = Int((2 + min(max(feather, 0), 1) * (widest - 2)).rounded())
        return radius
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
        blurRadius: Int = 3,
        detailSource: (image: CIImage, context: CIContext)? = nil
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

        // ⚠️ Up to here everything is at the WORKING resolution the fill ran
        // at — 512 for SD, up to 1100 for LaMa — not the photo's. On a 5176px
        // frame an 828px hole means a 1325px region, so every pixel the fill
        // produced is about to be stretched 2.6x on its way back onto the
        // photograph, and a client's grass hole measured 4.1x. That stretch is
        // the whole of "the patch is blurrier than the sand around it", and it
        // is arithmetic: no prompt, and no refine strength, can undo it (KORAK
        // 109 measured the strengths, and the only thing raising them bought
        // was an invented rock).
        //
        // So the grain is put back here, at the photo's own resolution, out of
        // the photograph itself. See restoreFineDetail.
        var pixels = buffers.pixels
        var outWidth = width
        var outHeight = height
        if let source = detailSource,
           let native = nativeDetailPass(
               fill: buffers.pixels, known: originalKnown, alpha: alpha,
               width: width, height: height, region: region,
               image: source.image, context: source.context) {
            pixels = native.pixels
            alpha = native.alpha
            outWidth = native.width
            outHeight = native.height
        }

        var rgba = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for index in 0..<(outWidth * outHeight) {
            let a = Int(alpha[index])
            let base = index * 4
            // Premultiplied, to match the bitmapInfo below.
            rgba[base] = UInt8(Int(pixels[base]) * a / 255)
            rgba[base + 1] = UInt8(Int(pixels[base + 1]) * a / 255)
            rgba[base + 2] = UInt8(Int(pixels[base + 2]) * a / 255)
            rgba[base + 3] = alpha[index]
        }

        guard let cgImage = makeCGImage(rgba: rgba, width: outWidth, height: outHeight) else {
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

    // MARK: - Putting the photograph's own grain back
    //
    // KORAK 109. The client's report was "the sand is blurrier, not like the
    // beach" and "the grass is thinner than the grass around it", with the
    // pointed observation that QUICK DOES THE SAME THING — which is the clue
    // that mattered, because it rules the model out. Both paths are soft for
    // one shared reason: neither runs on the photograph. SD's converted
    // checkpoint takes a fixed 512, LaMa runs at up to 1100, and whatever they
    // produce is scaled back up onto a 5176px frame.
    //
    // Measured before any of this was written (Tools/run-inpaint-sweep.py, on
    // the client's own C4S_7891 beach frame): the patch carries 0.33 of the
    // surrounding photo's fine detail. Raising SD's refine strength — the
    // thing that was actually asked for — does NOT fix it. It reaches 0.77,
    // but by INVENTING: at 0.6 a rock formation appears on the beach where
    // there was nothing, and at 0.8 and above it is unmistakable. On grass,
    // where there is no object for it to reach for, every strength from 0.3 to
    // full gives the same 0.28-0.30. The number only moves when the model
    // makes something up. That is KORAK 40's wall, measured again from the
    // other side.
    //
    // So the grain is not asked for from a model. It is taken from the
    // photograph, which is the same reason the exemplar path is sharp, in this
    // file's own words further up: it "COPIES real pixels out of the
    // surrounding photo instead of synthesizing them, so what it puts back is
    // as sharp as what it took."
    //
    // Structure — what is in the hole — is left exactly as the fill decided.
    // Only the fine band is topped up. Measured after: beach 0.33 -> 0.61,
    // the client's own grass frame 0.35 -> 0.94, in milliseconds, with nothing
    // invented.
    //
    // ⚠️ It is an improvement, NOT a cure, and the difference matters. On the
    // client's grass the hole is 1449x1310 — a quarter of the frame, stretched
    // 4.1x — and under the restored grain the fill is still a smooth blob. The
    // texture comes back; the blob does not become a lawn. The only thing that
    // would is running the model over overlapping tiles at native resolution,
    // which is 6 to 16 model passes instead of one (see squareRegion's comment
    // in DevelopSDInpaint.swift). The client ruled that out on time.

    /// The edge this pass works at.
    ///
    /// The region can be most of a 3448px frame and this holds two float
    /// planes of it, so it is capped rather than unbounded. At 2048 the
    /// client's 2364px grass region is still only stretched 1.15x instead of
    /// 4.1x — which is the part that is visible — without holding 130 MB of
    /// scratch to chase the last sliver.
    static let maxDetailEdge = 2048

    private struct NativePatch {
        var pixels: [UInt8]
        var alpha: [UInt8]
        var width: Int
        var height: Int
    }

    /// Re-renders the region at (close to) the photo's own resolution, lifts
    /// the fill up to it, and puts the photograph's grain back into the hole.
    /// Returns nil when there was no stretch to undo, which is the one case
    /// where this would be pure cost.
    private static func nativeDetailPass(
        fill: [UInt8], known: [UInt8], alpha: [UInt8],
        width: Int, height: Int, region: CGRect,
        image: CIImage, context: CIContext
    ) -> NativePatch? {
        let longest = max(region.width, region.height)
        guard longest > CGFloat(max(width, height)) else { return nil }

        let scale = min(1, CGFloat(maxDetailEdge) / longest)
        let nativeWidth = max(1, Int((region.width * scale).rounded()))
        let nativeHeight = max(1, Int((region.height * scale).rounded()))
        guard nativeWidth > width, nativeHeight > height else { return nil }

        let photo = renderRegion(
            image, region: region, width: nativeWidth, height: nativeHeight, context: context)
        var pixels = upscale(fill, srcW: width, srcH: height,
                             dstW: nativeWidth, dstH: nativeHeight, components: 4)
        let bigAlpha = upscale(alpha, srcW: width, srcH: height,
                               dstW: nativeWidth, dstH: nativeHeight, components: 1)
        let bigKnown = upscale(known, srcW: width, srcH: height,
                               dstW: nativeWidth, dstH: nativeHeight, components: 1)

        restoreFineDetail(fill: &pixels, photo: photo, known: bigKnown,
                          width: nativeWidth, height: nativeHeight)

        return NativePatch(pixels: pixels, alpha: bigAlpha,
                           width: nativeWidth, height: nativeHeight)
    }

    private static func renderRegion(
        _ source: CIImage, region: CGRect, width: Int, height: Int, context: CIContext
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let placed = source
            .cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.origin.x, y: -region.origin.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / region.width,
                                               y: CGFloat(height) / region.height))
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                placed, toBitmap: base, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8, colorSpace: briefInpaintColorSpace)
        }
        return bytes
    }

    /// Tops the fill's fine detail up to the level of the photograph around
    /// the hole, using grain borrowed from the photograph itself.
    private static func restoreFineDetail(
        fill: inout [UInt8], photo: [UInt8], known: [UInt8], width: Int, height: Int
    ) {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where known[row + x] == 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return }

        var photoDetail = lumaPlane(photo, width: width, height: height)
        var fillDetail = lumaPlane(fill, width: width, height: height)

        // Row averages across the hole's columns, taken while these are still
        // brightness rather than detail. They are what lets a hole row be
        // matched to the untouched row that actually LOOKS like it — see the
        // donor choice below.
        let columns = Float(maxX - minX + 1)
        var photoRowLuma = [Float](repeating: 0, count: height)
        var fillRowLuma = [Float](repeating: 0, count: height)
        for y in 0..<height {
            let row = y * width
            var photoSum: Float = 0
            var fillSum: Float = 0
            for x in minX...maxX {
                photoSum += photoDetail[row + x]
                fillSum += fillDetail[row + x]
            }
            photoRowLuma[y] = photoSum / columns
            fillRowLuma[y] = fillSum / columns
        }

        // The band the stretch destroyed: everything finer than a couple of
        // pixels. Two box passes stand in for a Gaussian.
        var scratch = photoDetail
        boxBlur(&scratch, width: width, height: height, radius: 2)
        boxBlur(&scratch, width: width, height: height, radius: 2)
        for i in 0..<photoDetail.count { photoDetail[i] -= scratch[i] }

        scratch = fillDetail
        boxBlur(&scratch, width: width, height: height, radius: 2)
        boxBlur(&scratch, width: width, height: height, radius: 2)
        for i in 0..<fillDetail.count { fillDetail[i] -= scratch[i] }

        let block = 16
        let gridWidth = (width + block - 1) / block
        let gridHeight = (height + block - 1) / block
        let photoEnergy = energyGrid(photoDetail, width: width, height: height, block: block)
        let fillEnergy = energyGrid(fillDetail, width: width, height: height, block: block)

        // A ramp that fades the borrowed grain in from the hole's edge, so it
        // does not begin on a line. `scratch` is finished with, so it is
        // reused rather than holding a third plane of a 2048px region.
        for i in 0..<scratch.count { scratch[i] = known[i] == 0 ? 1 : 0 }
        boxBlur(&scratch, width: width, height: height, radius: 10)
        boxBlur(&scratch, width: width, height: height, radius: 10)

        // The untouched rows this can borrow from at all.
        var candidates: [Int] = []
        candidates.reserveCapacity(height - (maxY - minY + 1))
        for y in 0..<height where y < minY || y > maxY { candidates.append(y) }
        guard !candidates.isEmpty else { return }

        // ⚠️ Grain has to match the CONTENT, not just its strength, and it
        // cannot be chosen by POSITION. Reflecting the nearest rows into the
        // hole — which is what this did first — puts sand ripples across the
        // water on the client's beach frame, because the rows nearest the
        // hole's bottom half are sand while part of that half is sea. It was
        // plainly visible on screen and the measurement did not catch it: the
        // score went UP, to 0.82, precisely because wrong grain is still grain.
        //
        // So the donor is chosen by how the row LOOKS. The fill is a plausible
        // continuation of the scene, so its brightness across the hole says
        // which band a row belongs to; the untouched row with the closest
        // brightness is the one whose grain belongs there. Sky matches sky,
        // water matches water, sand matches sand, with no notion of "above" or
        // "below" needed.
        // ⚠️ Two ways of choosing the donor were built and thrown away, and
        // both are worth knowing about, because BOTH scored better than what is
        // here while looking worse on screen:
        //
        //   - matching every hole row to the untouched row it most resembles
        //     scored 1.48 and produced a hard regular COMB, because
        //     consecutive rows then pull from unrelated places and the vertical
        //     continuity that makes grain read as grain is gone;
        //   - letting that match walk, and re-matching on a brightness
        //     threshold, produced vertical STREAKS, because near a gradient the
        //     threshold fires on every row and stamps one donor row down the
        //     whole hole.
        //
        // Continuity is the property that cannot be given up. So the donor is
        // simply the nearest untouched band, reflected in and advancing one row
        // at a time — grain stays grain — and the band-mismatch problem (sand
        // ripples appearing over the sea, which the first version of this did)
        // is handled by WEIGHT rather than by jumping: where the donor does not
        // look like what it is being asked to grain, it fades out. The worst
        // this can do is restore nothing, which is where this started; it
        // cannot invent a texture that was never there.
        let above = minY
        let below = height - 1 - maxY

        func pingPong(_ step: Int, _ span: Int) -> Int {
            guard span > 1 else { return 0 }
            let m = step % (2 * span)
            return m < span ? m : 2 * span - 1 - m
        }

        func donorRow(_ y: Int) -> Int {
            let preferBelow = (y - minY) * 2 >= (maxY - minY)
            if preferBelow, below > 0 { return maxY + 1 + pingPong(maxY - y, below) }
            if above > 0 { return minY - 1 - pingPong(y - minY, above) }
            return maxY + 1 + pingPong(maxY - y, below)
        }

        for y in minY...maxY {
            let row = y * width
            let gridRow = min(y / block, gridHeight - 1) * gridWidth
            let source = donorRow(y)
            let donorGridRow = min(source / block, gridHeight - 1) * gridWidth

            // How much the donor row looks like what the fill put here. Sand
            // over sand is ~1; sand under a blown-out sea falls away to 0.
            let mismatch = (photoRowLuma[source] - fillRowLuma[y]) / 24
            let similarity = exp(-mismatch * mismatch)
            guard similarity > 0.02 else { continue }

            for x in minX...maxX where known[row + x] == 0 {
                let gridX = min(x / block, gridWidth - 1)

                // The donor row says both what the grain looks like and how
                // much of it there should be, so the two can no longer
                // disagree. Blown sky matches a blown row, reads ~0, and gets
                // ~nothing added.
                let want = photoEnergy[donorGridRow + gridX]
                let have = fillEnergy[gridRow + gridX]
                guard want > have else { continue }
                let gain = min((want - have) / max(want, 0.5), 1) * similarity

                let add = gain * photoDetail[source * width + x] * scratch[row + x]
                let base = (row + x) * 4
                for channel in 0..<3 {
                    let value = Float(fill[base + channel]) + add
                    fill[base + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }
    }

    private static func lumaPlane(_ rgba: [UInt8], width: Int, height: Int) -> [Float] {
        var plane = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let base = i * 4
            plane[i] = 0.2126 * Float(rgba[base])
                + 0.7152 * Float(rgba[base + 1])
                + 0.0722 * Float(rgba[base + 2])
        }
        return plane
    }

    private static func energyGrid(
        _ detail: [Float], width: Int, height: Int, block: Int
    ) -> [Float] {
        let gridWidth = (width + block - 1) / block
        let gridHeight = (height + block - 1) / block
        var grid = [Float](repeating: 0, count: gridWidth * gridHeight)
        var counts = [Float](repeating: 0, count: gridWidth * gridHeight)
        for y in 0..<height {
            let gridRow = (y / block) * gridWidth
            let row = y * width
            for x in 0..<width {
                let cell = gridRow + x / block
                grid[cell] += abs(detail[row + x])
                counts[cell] += 1
            }
        }
        for i in 0..<grid.count where counts[i] > 0 { grid[i] /= counts[i] }
        return grid
    }

    /// Separable box blur on a float plane, clamped at the edges.
    private static func boxBlur(_ plane: inout [Float], width: Int, height: Int, radius: Int) {
        guard radius > 0, width > 0, height > 0 else { return }
        var temp = [Float](repeating: 0, count: plane.count)
        let window = Float(radius * 2 + 1)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for x in -radius...radius { sum += plane[row + min(max(x, 0), width - 1)] }
            for x in 0..<width {
                temp[row + x] = sum / window
                sum += plane[row + min(x + radius + 1, width - 1)]
                    - plane[row + max(x - radius, 0)]
            }
        }
        for x in 0..<width {
            var sum: Float = 0
            for y in -radius...radius { sum += temp[min(max(y, 0), height - 1) * width + x] }
            for y in 0..<height {
                plane[y * width + x] = sum / window
                sum += temp[min(y + radius + 1, height - 1) * width + x]
                    - temp[max(y - radius, 0) * width + x]
            }
        }
    }

    /// Bilinear resample of an interleaved 8-bit buffer.
    private static func upscale(
        _ src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int, components: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: dstW * dstH * components)
        let stepX = Float(srcW) / Float(dstW)
        let stepY = Float(srcH) / Float(dstH)
        for y in 0..<dstH {
            let fy = min(max((Float(y) + 0.5) * stepY - 0.5, 0), Float(srcH - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, srcH - 1)
            let wy = fy - Float(y0)
            for x in 0..<dstW {
                let fx = min(max((Float(x) + 0.5) * stepX - 0.5, 0), Float(srcW - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, srcW - 1)
                let wx = fx - Float(x0)
                let base = (y * dstW + x) * components
                for c in 0..<components {
                    let p00 = Float(src[(y0 * srcW + x0) * components + c])
                    let p10 = Float(src[(y0 * srcW + x1) * components + c])
                    let p01 = Float(src[(y1 * srcW + x0) * components + c])
                    let p11 = Float(src[(y1 * srcW + x1) * components + c])
                    let top = p00 + (p10 - p00) * wx
                    let bottom = p01 + (p11 - p01) * wx
                    out[base + c] = UInt8(max(0, min(255, (top + (bottom - top) * wy).rounded())))
                }
            }
        }
        return out
    }

    // Square dilation and a separable box blur, both on the 8-bit alpha
    // only — a couple of hundred kilopixels, so the simple version is
    // quicker than reaching for Core Image and rendering twice more.
    /// Separable maximum filter. Max is associative, so a pass across and a
    /// pass down give the same result as the square window did, at 2(2r+1)
    /// comparisons per pixel instead of (2r+1)².
    private static func grow(_ buffer: inout [UInt8], width: Int, height: Int, radius: Int) {
        guard radius > 0 else {
            return
        }
        var horizontal = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var maximum: UInt8 = 0
                for dx in max(x - radius, 0)...min(x + radius, width - 1) {
                    maximum = max(maximum, buffer[row + dx])
                }
                horizontal[row + x] = maximum
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var maximum: UInt8 = 0
                for dy in max(y - radius, 0)...min(y + radius, height - 1) {
                    maximum = max(maximum, horizontal[dy * width + x])
                }
                buffer[y * width + x] = maximum
            }
        }
    }

    /// Box blur with a RUNNING SUM, so the cost per pixel does not depend on
    /// the radius.
    ///
    /// This used to re-add every value in the window for every pixel: with the
    /// two passes here, and `package` calling it twice, that is
    /// 4 × w × h × (2r+1) additions. On a 512×512 patch with the radius a
    /// generous feather asks for, it was the single most expensive thing in a
    /// removal — measured in the client's own run at **6.9 s of an 8.0 s
    /// "Quick" Clean Up**, against 1.14 s for the model itself. The button is
    /// called Quick.
    ///
    /// The window is the same window and the edges behave the same way: the
    /// average is over the valid pixels only, so `count` shrinks at the
    /// borders exactly as it did when they were skipped by a guard.
    private static func blur(_ buffer: inout [UInt8], width: Int, height: Int, radius: Int) {
        guard radius > 0 else {
            return
        }

        var horizontal = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            var total = 0
            var count = 0
            for px in 0...min(radius, width - 1) {
                total += Int(buffer[row + px])
                count += 1
            }
            for x in 0..<width {
                horizontal[row + x] = UInt8(total / max(count, 1))
                let leaving = x - radius
                if leaving >= 0 {
                    total -= Int(buffer[row + leaving])
                    count -= 1
                }
                let entering = x + radius + 1
                if entering < width {
                    total += Int(buffer[row + entering])
                    count += 1
                }
            }
        }

        for x in 0..<width {
            var total = 0
            var count = 0
            for py in 0...min(radius, height - 1) {
                total += Int(horizontal[py * width + x])
                count += 1
            }
            for y in 0..<height {
                buffer[y * width + x] = UInt8(total / max(count, 1))
                let leaving = y - radius
                if leaving >= 0 {
                    total -= Int(horizontal[leaving * width + x])
                    count -= 1
                }
                let entering = y + radius + 1
                if entering < height {
                    total += Int(horizontal[entering * width + x])
                    count += 1
                }
            }
        }
    }

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

        // Rose, matching the hand-painted overlay in Develop.swift — the two
        // have to agree, because a Select People mask and hand-painted strokes
        // become ONE selection that gets erased in one go. Changed from blue on
        // request.
        //
        // The earlier note here is still worth keeping, because it is why this
        // is rose and not plain red: pure red reads as a WARNING on a photo
        // rather than "this is what is selected", and on the warm frames this
        // tool is used on (skin, sand, sunset) both red and white are the
        // hardest things to pick out. Pushing the hue toward magenta keeps the
        // pink cast that was asked for while staying off the orange-red axis
        // those photos are largely built from.
        // Bytes are premultiplied, hence each channel scaled by alpha.
        let colour = (r: 255, g: 90, b: 130)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let alpha = Int(maskBytes[index]) * 45 / 100
            let base = index * 4
            rgba[base] = UInt8(colour.r * alpha / 255)
            rgba[base + 1] = UInt8(colour.g * alpha / 255)
            rgba[base + 2] = UInt8(colour.b * alpha / 255)
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
