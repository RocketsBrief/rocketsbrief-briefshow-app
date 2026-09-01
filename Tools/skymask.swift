import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

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

enum SkyMasker {

    /// White where sky is, black elsewhere, over `image`'s own extent.
    ///
    /// Returns nil when what it found is too small to be a sky — under 2%
    /// of the frame is a gap between leaves, not something anybody wants to
    /// replace, and handing back a mask like that would produce a Sky layer
    /// that appears to do nothing.
    static func skyMask(for image: CIImage, maxWorkingEdge: CGFloat = 900) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }

        // Small on purpose. Every test below is about broad regions, none of
        // them wants pixel detail, and the result is blurred hard at the end
        // anyway — running this on a 45MP RAW would buy nothing at all.
        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > maxWorkingEdge ? maxWorkingEdge / longEdge : 1
        let working = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let workingExtent = working.extent

        guard let blueness = bluenessScore(working, extent: workingExtent),
              let brightness = brightPaleScore(working, extent: workingExtent),
              let flatness = flatnessScore(working, extent: workingExtent)
        else {
            return nil
        }

        // Either kind of sky counts, so the two colour tests are a MAXIMUM
        // rather than a product — a deep blue sky scores nothing on
        // "bright and pale", and a white overcast sky scores nothing on
        // "blue". Multiplying them would reject both.
        let colourScore = blueness.applyingFilter("CIMaximumCompositing", parameters: [
            kCIInputBackgroundImageKey: brightness
        ]).cropped(to: workingExtent)

        // Flatness and height are both vetoes, so those DO multiply.
        var score = colourScore.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: flatness
        ]).cropped(to: workingExtent)

        score = score.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: heightWeight(extent: workingExtent)
        ]).cropped(to: workingExtent)

        // Blur wide, then pull hard: this is what turns a noisy per-pixel
        // score into regions. The blur radius is a fraction of the frame,
        // not a pixel count, so the same picture at a different working
        // size produces the same mask.
        let smoothed = score
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(workingExtent.width, workingExtent.height) * 0.012)
            .cropped(to: workingExtent)

        // ⚠️ THE TEST THAT MATTERS, and the first version did not have it.
        //
        // Measured on a real beach photograph: colour + flatness + height
        // alone marked the sky AND a wide strip of bright sand running down
        // the left of the frame, plus speckles on every face. Sand is
        // bright, flat and — at the left edge — reaches high enough for the
        // height weight to let it through. Every individual test was
        // working; the definition was simply not what a sky is.
        //
        // A sky is the part of the picture you reach by walking DOWN FROM
        // THE TOP without crossing anything that is not sky. Sand fails
        // that however bright it is, because the horizon is in the way.
        let grown = growFromTop(smoothed, extent: workingExtent)

        // And people are never sky. Vision knows exactly where they are, so
        // there is no reason to leave the heuristic guessing about faces —
        // skin in bright sun is pale and smooth, which is the definition
        // being used, so it passed on merit.
        let hardened = subtractingPeople(grown, from: image, extent: workingExtent)

        guard coverage(hardened, extent: workingExtent) >= 0.02 else {
            return nil
        }

        // Back up to the photo's own extent, the same way personMask does.
        let sx = extent.width / workingExtent.width
        let sy = extent.height / workingExtent.height
        var mask = hardened.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        mask = mask.transformed(by: CGAffineTransform(
            translationX: extent.origin.x - mask.extent.origin.x,
            y: extent.origin.y - mask.extent.origin.y
        ))
        return mask.cropped(to: extent)
    }

    /// How blue a pixel is, as `B - max(R, G)`, scaled up so an ordinary
    /// sky lands near 1.
    private static func bluenessScore(_ image: CIImage, extent: CGRect) -> CIImage? {
        // max(R,G) in every channel.
        guard let redGreen = CIFilter(name: "CIMaximumComponent", parameters: [
            kCIInputImageKey: image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        ])?.outputImage else {
            return nil
        }

        let blueOnly = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        // Subtract by adding the inverse and pulling the bias back — CI has
        // no subtract-blend that clamps the way this needs.
        let difference = blueOnly.applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: redGreen.cropped(to: extent)
        ]).cropped(to: extent)

        // A clear sky sits around 0.10-0.20 of separation; ×5 puts that at
        // roughly 0.5-1.0, which is the range the vetoes below expect.
        return difference.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 5, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 5, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).cropped(to: extent)
    }

    /// Bright AND colourless — the overcast and blown-out half of "sky".
    private static func brightPaleScore(_ image: CIImage, extent: CGRect) -> CIImage? {
        let grey = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1
        ])

        // Everything below 0.72 goes to nothing, 0.92 and up is full — the
        // band where a pale sky lives and a mid-grey road does not.
        let brightness = grey.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.00, y: 0),
            "inputPoint1": CIVector(x: 0.72, y: 0),
            "inputPoint2": CIVector(x: 0.82, y: 0.5),
            "inputPoint3": CIVector(x: 0.92, y: 1),
            "inputPoint4": CIVector(x: 1.00, y: 1)
        ]).cropped(to: extent)

        // ...and colourless, so a bright yellow wall does not qualify. The
        // same distance-from-grey measure the Colour Mixer uses, inverted.
        guard let colourful = CIFilter(name: "CIMaximumComponent", parameters: [
            kCIInputImageKey: image.applyingFilter("CIColorAbsoluteDifference", parameters: [
                "inputImage2": grey
            ])
        ])?.outputImage else {
            return brightness
        }

        let colourless = colourful
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 6, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 6, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIColorInvert")
            .cropped(to: extent)

        return brightness.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: colourless
        ]).cropped(to: extent)
    }

    /// 1 where the picture matches its own blur, 0 where it does not.
    ///
    /// This is the test that keeps buildings, foliage and text out. Sky is
    /// the flattest thing in almost any frame.
    private static func flatnessScore(_ image: CIImage, extent: CGRect) -> CIImage? {
        let sigma = max(extent.width, extent.height) * 0.004
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)

        guard let detail = CIFilter(name: "CIMaximumComponent", parameters: [
            kCIInputImageKey: image.applyingFilter("CIColorAbsoluteDifference", parameters: [
                "inputImage2": blurred
            ])
        ])?.outputImage else {
            return nil
        }

        // ×14 then inverted: a difference of about 0.07 is enough to veto a
        // pixel outright, which is well below anything a real edge produces
        // and well above sensor noise in a smooth sky.
        return detail
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 14, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 14, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 14, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIColorInvert")
            .cropped(to: extent)
    }

    /// Full weight across the top, easing to a floor at the bottom.
    ///
    /// A floor of 0.25 rather than 0 on purpose: sky reaches all the way
    /// down between buildings and behind a low horizon, and a hard cut
    /// would slice those off in a straight line across the picture — the
    /// single most obvious way a sky replacement announces itself as fake.
    private static func heightWeight(extent: CGRect) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: extent.maxY)
        gradient.point1 = CGPoint(x: extent.midX, y: extent.minY)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)
        return (gradient.outputImage ?? CIImage(color: .white)).cropped(to: extent)
    }

    /// Keeps, in each column, the run of sky that starts at the top of the
    /// frame — and drops everything below the first thing that is not sky.
    ///
    /// This is a column walk on the CPU rather than a filter chain, because
    /// "connected to the top" is not something a per-pixel filter can
    /// answer. It runs on the working copy (under a megapixel), so the cost
    /// is a few milliseconds once per button press.
    ///
    /// `runToStop` is 3 rather than 1 so a single dark row — a wire, a
    /// branch, one noisy line of pixels — does not cut the sky off above
    /// the horizon. Anything genuinely solid is thicker than three rows at
    /// this working size.
    private static func growFromTop(_ score: CIImage, extent: CGRect) -> CIImage {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 1, height > 1 else {
            return score
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        skyMeasurementContext.render(
            score,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Core Image hands the bitmap back top row first, which is the
        // direction this wants anyway.
        let threshold: UInt8 = 110
        let runToStop = 3
        var mask = [UInt8](repeating: 0, count: width * height)

        for x in 0..<width {
            var misses = 0
            for y in 0..<height {
                let value = pixels[(y * width + x) * 4]
                if value < threshold {
                    misses += 1
                    if misses >= runToStop {
                        break
                    }
                } else {
                    misses = 0
                }
                mask[y * width + x] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else {
            return score
        }

        // The walk produces a hard, ragged column edge. A short blur turns
        // it into something that can sit against a horizon without showing
        // a staircase — the same softness the old hardenToMask produced,
        // arrived at honestly.
        let grown = CIImage(cgImage: cgImage)
        let placed = grown.transformed(by: CGAffineTransform(
            translationX: extent.origin.x - grown.extent.origin.x,
            y: extent.origin.y - grown.extent.origin.y
        ))
        return placed
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(extent.width, extent.height) * 0.004)
            .cropped(to: extent)
    }

    /// Takes people back out of a sky mask.
    ///
    /// Cheap insurance, and it fixes something the heuristic cannot: skin
    /// in bright sun is pale, smooth and often high in the frame, so faces
    /// score as sky ON MERIT. Vision already knows where the people are.
    private static func subtractingPeople(_ mask: CIImage, from image: CIImage, extent: CGRect) -> CIImage {
        guard let people = SubjectMasker.personMask(for: image, maxWorkingEdge: max(extent.width, extent.height)) else {
            return mask
        }

        let scaled = people
            .transformed(by: CGAffineTransform(scaleX: extent.width / people.extent.width,
                                               y: extent.height / people.extent.height))
        let aligned = scaled
            .transformed(by: CGAffineTransform(translationX: extent.origin.x - scaled.extent.origin.x,
                                               y: extent.origin.y - scaled.extent.origin.y))
            .cropped(to: extent)
            // Grown a little first: Vision traces a person tightly and the
            // rim just outside that trace is the person's own light, which
            // is exactly the halo that showed round the couple.
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(extent.width, extent.height) * 0.006)
            .cropped(to: extent)

        return mask.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: aligned.applyingFilter("CIColorInvert")
        ]).cropped(to: extent)
    }

    /// Turns a soft score into something that behaves like a mask: a hard
    /// S-curve, so the middle ground picks a side instead of leaving a
    /// half-transparent sky.
    private static func hardenToMask(_ image: CIImage, extent: CGRect) -> CIImage {
        image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.00, y: 0),
            "inputPoint1": CIVector(x: 0.35, y: 0),
            "inputPoint2": CIVector(x: 0.50, y: 0.5),
            "inputPoint3": CIVector(x: 0.65, y: 1),
            "inputPoint4": CIVector(x: 1.00, y: 1)
        ]).cropped(to: extent)
    }

    /// What fraction of the frame the mask covers, 0...1.
    private static func coverage(_ mask: CIImage, extent: CGRect) -> Double {
        let average = CIFilter.areaAverage()
        average.inputImage = mask
        average.extent = extent

        guard let output = average.outputImage else {
            return 0
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        skyMeasurementContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Double(pixel[0]) / 255.0
    }
}

/// Its own small context, for the one-pixel reads above.
///
/// Not the shared editing context: that one is configured for the editor's
/// heavy renders, and reading a single averaged pixel through it drags a
/// full pipeline setup along for no reason. Same reasoning as
/// `sharedExtractionContext` in Develop.swift.
private let skyMeasurementContext = CIContext(options: [.useSoftwareRenderer: false])

let ctx = CIContext()
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let photo = CIImage(contentsOf: input) else { fatalError("no image") }
let extent = photo.extent
print("photo \(Int(extent.width))x\(Int(extent.height))")

guard let mask = SkyMasker.skyMask(for: photo) else { print("NO SKY FOUND"); exit(0) }

let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1)).cropped(to: extent)
let tint = red.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55)])
let blend = CIFilter.blendWithMask()
blend.inputImage = tint.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: photo])
blend.backgroundImage = photo
blend.maskImage = mask
let cg = ctx.createCGImage(blend.outputImage!.cropped(to: extent), from: extent)!
try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: output)
print("wrote", output.path)
