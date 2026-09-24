//
//  FaceDehaze.swift
//  BriefShow
//
//  Face Dehaze — takes the sun's white veil off FACES, and only off faces.
//
//  Asked for 24.09: *„još jedan slider … da se fokusira striktno na lica i oko
//  lica kada je slika bleda zbog sunca sa strane … dok se slide bar pomera
//  udesno … uklanja te bele cestice od zraka sunca da pravi sliku ostrijom i
//  bolje vidljivom"*.
//
//  Three steps, in this order:
//
//  1. FIND THE FACES. Vision's face rectangles, on a 768 px copy. Each face is
//     widened to an ellipse that takes in the hair, the ears and the neck —
//     the "oko lica" — and feathered, so nothing ends in a visible edge.
//  2. TAKE THE VEIL OFF. Side sun lifts every pixel near the face by the same
//     white wash, so the darkest thing nearby (an eye, a nostril, the hairline)
//     is no longer dark. The wash is read as that local floor — the dark
//     channel over a patch about a tenth of a face wide, smoothed — and taken
//     out as `(c − veil) / (1 − veil)`. That is a black point put back, locally:
//     tone and colour come back together and the hue does not move.
//  3. A LITTLE CLARITY on top, the photo's own `applyClarity`, for the "oštrije".
//
//  Then blended over the photo through the ellipses. Outside a face ellipse
//  this changes nothing, at any setting.
//
//  ⚠️ THE MUST (slider on a layer = slider on the photo): the photo and a
//  layer both call `PhotoEditRenderer.applyFaceDehaze`, the one function here.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

extension PhotoEditRenderer {

    /// `faces` is given by `render`, which knows the photo (see
    /// FaceDehazeFaces.faces(of:variant:in:)); a layer leaves it nil and the
    /// faces are found in its own pixels.
    static func applyFaceDehaze(_ amount: Double, to image: CIImage, faces known: [CGRect]? = nil) -> CIImage {
        let strength = min(max(amount, 0), 1)
        guard strength > 0 else { return image }
        let extent = image.extent
        guard extent.width > 8, extent.height > 8, extent.width.isFinite, extent.height.isFinite else {
            return image
        }

        let faces = known ?? FaceDehazeFaces.faces(in: image)
        guard !faces.isEmpty else { return image }

        // Faces in this image's pixels (Vision and Core Image are both y-up).
        let boxes = faces.map {
            CGRect(x: extent.minX + $0.minX * extent.width, y: extent.minY + $0.minY * extent.height,
                   width: $0.width * extent.width, height: $0.height * extent.height)
        }
        let faceWidth = boxes.map(\.width).sorted()[boxes.count / 2]

        guard let mask = FaceDehazeFaces.mask(for: boxes, extent: extent),
              let veil = FaceDehazeFaces.veil(of: image, faceWidth: faceWidth),
              let kernel = FaceDehazeFaces.veilKernel,
              let lifted = kernel.apply(extent: extent,
                                        arguments: [image, veil, strength * FaceDehazeFaces.veilShare])
        else { return image }

        let sharpened = applyClarity(strength * FaceDehazeFaces.clarityShare, to: lifted)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = sharpened
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}

enum FaceDehazeFaces {
    /// How much of the local floor is taken off at 100. Not all of it: taking
    /// the whole floor makes the darkest pixel beside every face pure black,
    /// which reads as a crushed eye rather than a clear one.
    static let veilShare: Double = 0.55
    /// Never more than this much wash is taken out, whatever the floor says —
    /// a white wall behind a head reads as "veil" too and must not go grey.
    static let maximumVeil: Double = 0.45
    /// Clarity at 100 Face Dehaze.
    static let clarityShare: Double = 0.35
    /// The longest side Vision is given.
    static let detectionSide: CGFloat = 768

    static let veilKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 briefFaceVeil(__sample s, __sample v, float k) {
            float a = s.a;
            vec3 c = a > 0.0 ? s.rgb / a : vec3(0.0);
            float veil = clamp(v.r * k, 0.0, \(maximumVeil));
            vec3 o = (c - veil) / (1.0 - veil);
            // The division grows the colour along with the tone — at 100 the
            // first version turned skin red. Part of that growth is handed
            // back, in proportion to how much veil came off.
            float l = dot(o, vec3(0.2126, 0.7152, 0.0722));
            o = l + (o - l) * (1.0 - 0.4 * veil / \(maximumVeil));
            return vec4(o * a, a);
        }
        """)

    /// The white wash near each face: the dark channel over a small patch,
    /// smoothed so it has no blocks in it.
    ///
    /// ⚠️ COMPUTED ON A SMALL COPY (24.09, the client's *„bas je kasnilo …
    /// zablokiralo"*). At native size a patch minimum of up to 80 px and a
    /// 120 px blur cost 500–800 ms a render on this machine and a lot of GPU
    /// memory. The veil is smooth by construction, so it is measured at most
    /// `veilSide` px long and scaled back up — the blur has already removed
    /// everything the smaller copy cannot hold.
    static let veilSide: CGFloat = 768

    static func veil(of image: CIImage, faceWidth: CGFloat) -> CIImage? {
        let extent = image.extent
        let scale = min(veilSide / max(extent.width, extent.height), 1)
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let smallExtent = CGRect(x: 0, y: 0, width: extent.width * scale, height: extent.height * scale)
        let radius = Float(min(max(faceWidth * 0.1, 3), 80) * scale)
        let minimum = CIFilter.minimumComponent()
        minimum.inputImage = small.cropped(to: smallExtent)
        let patch = CIFilter.morphologyMinimum()
        patch.inputImage = minimum.outputImage?.clampedToExtent()
        patch.radius = max(radius, 1)
        let smooth = CIFilter.gaussianBlur()
        smooth.inputImage = patch.outputImage
        smooth.radius = max(radius * 1.5, 1)
        // Opaque: this is a lookup map, read by its red channel.
        let opaque = CIFilter.colorMatrix()
        opaque.inputImage = smooth.outputImage?.cropped(to: smallExtent)
        opaque.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        opaque.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return opaque.outputImage?
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// One feathered ellipse per face, joined. Wider than the face and
    /// reaching down past the chin: the hair, the ears and the neck are in the
    /// same light and have to come back with it.
    static func mask(for boxes: [CGRect], extent: CGRect) -> CIImage? {
        var joined: CIImage?
        for box in boxes {
            let rx = box.width * 1.15
            let ry = box.height * 1.35
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = Float(rx * 0.45)
            gradient.radius1 = Float(rx)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
            guard let circle = gradient.outputImage else { continue }
            let ellipse = circle
                .transformed(by: CGAffineTransform(scaleX: 1, y: ry / rx))
                .transformed(by: CGAffineTransform(translationX: box.midX, y: box.midY - box.height * 0.12))
            if let current = joined {
                let union = CIFilter.maximumCompositing()
                union.inputImage = ellipse
                union.backgroundImage = current
                joined = union.outputImage
            } else {
                joined = ellipse
            }
        }
        return joined?.cropped(to: extent)
    }

    // MARK: - Finding faces, remembered

    /// The last few photos' faces. A render runs on every slider step, and the
    /// faces do not move when a slider does — so the detector should run once
    /// per photo, and the key has to survive a tone change.
    ///
    /// ⚠️ RANKS, NOT LEVELS. The first key was a normalised thumbnail (mean
    /// and spread taken out) and missed on every step — Exposure, Contrast and
    /// Dehaze are curves, not straight lines. A curve that only brightens or
    /// darkens keeps the ORDER of the pixels, so each cell of a 16×12 thumbnail
    /// is keyed by which sixth of the frame's brightness ranking it falls in,
    /// and two keys match when 85 % of the cells agree. A different photo does
    /// not come close; a miss costs one detection, nothing worse.
    private static let lock = NSLock()
    private static var remembered: [(key: [UInt8], faces: [CGRect])] = []
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false
    ])
    static let keyAgreement = 0.85

    /// Face rectangles in unit space, y-up. Empty when there is nobody.
    static func faces(in image: CIImage) -> [CGRect] {
        guard let key = key(for: image) else { return [] }
        lock.lock()
        if let index = remembered.firstIndex(where: { matches($0.key, key) }) {
            let hit = remembered.remove(at: index)
            remembered.insert(hit, at: 0)
            lock.unlock()
            return hit.faces
        }
        lock.unlock()

        let found = detect(in: image)
        lock.lock()
        remembered.insert((key, found), at: 0)
        if remembered.count > 8 { remembered.removeLast() }
        lock.unlock()
        return found
    }

    private static func matches(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, a.count > 2, a[0] == b[0], a[1] == b[1] else { return false }
        var same = 0
        for i in 2..<a.count where a[i] == b[i] { same += 1 }
        return Double(same) / Double(a.count - 2) >= keyAgreement
    }

    private static func key(for image: CIImage) -> [UInt8]? {
        let extent = image.extent
        let w = 16, h = 12
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width,
                                               y: CGFloat(h) / extent.height))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: w * 4,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let luma = (0..<(w * h)).map {
            0.3 * Double(bytes[$0 * 4]) + 0.59 * Double(bytes[$0 * 4 + 1]) + 0.11 * Double(bytes[$0 * 4 + 2])
        }
        let order = luma.indices.sorted { luma[$0] < luma[$1] }
        var rank = [UInt8](repeating: 0, count: luma.count)
        for (position, index) in order.enumerated() {
            rank[index] = UInt8(position * 6 / luma.count)
        }
        let size = [UInt8(truncatingIfNeeded: Int(extent.width) & 0xff),
                     UInt8(truncatingIfNeeded: Int(extent.height) & 0xff)]
        return size + rank
    }

    /// The photo's faces, found ONCE per photo and orientation.
    ///
    /// ⚠️ THE PHOTO'S PATH, and why it is not `faces(in:)`. That one keys on a
    /// thumbnail of the image it is handed, and on the photo that image is the
    /// whole chain from the RAW decoder up — reading 16×12 pixels of it made
    /// Core Image run the lot a second time on every render, +260–340 ms at
    /// native size, and the client felt it (*„bas je kasnilo … zablokiralo"*,
    /// 24.09). Faces do not move when a slider does, so here they are keyed by
    /// the decoder object itself (held weakly — a new photo is a new object)
    /// and the rotation, and found in `geometry`: the picture turned but not
    /// yet toned, which Vision reads just as well.
    private static var byPhoto: [(owner: Weak, variant: String, faces: [CGRect])] = []
    final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }

    static func faces(of owner: AnyObject, variant: String, in geometry: CIImage) -> [CGRect] {
        lock.lock()
        byPhoto.removeAll { $0.owner.object == nil }
        if let hit = byPhoto.first(where: { $0.owner.object === owner && $0.variant == variant }) {
            lock.unlock()
            return hit.faces
        }
        lock.unlock()
        let found = detect(in: geometry)
        lock.lock()
        byPhoto.insert((Weak(owner), variant, found), at: 0)
        if byPhoto.count > 8 { byPhoto.removeLast() }
        lock.unlock()
        return found
    }

    /// How many times Vision actually ran — read by Tools/test-face-dehaze.swift.
    private(set) static var detectionCount = 0

    private static func detect(in image: CIImage) -> [CGRect] {
        detectionCount += 1
        let extent = image.extent
        let scale = min(detectionSide / max(extent.width, extent.height), 1)
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: (extent.width * scale).rounded(.down),
                            height: (extent.height * scale).rounded(.down))
        guard let cg = context.createCGImage(small, from: bounds) else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            return []
        }
        // Tiny faces in a crowd far away are left alone: the ellipse would be
        // a few pixels and the veil read over it meaningless.
        return (request.results ?? []).map(\.boundingBox).filter { $0.height > 0.03 }
    }
}
