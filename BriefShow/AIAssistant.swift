import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import Vision

// MARK: - AI Assistant (26.09)
//
// Asked for on 26.09: *„da ai sam odradi od ponudjenog da rejectuje blinks …
// klijent moze da izabere kako ce backround da bude na svakoj slici vise
// saturation, manje, vise dehaze … da svaka slika izgleda indenticno, da
// equalizuje light … i naravno crop da se centriraju ljudi dok se kropuje …
// da fotograf ne mora ni da pipne"*, then: *„ali ne i duplikate duplikate
// sacuvaj i ovaj prozor da izadje kao modal na svaki prvi ulazak u create i
// da se odnosi za te slike sto su u filmstripu"*.
//
// ⚠️ NO NEW MODEL. Everything here is Apple Vision (face landmarks, face
// quality, person segmentation, horizon) plus this app's own renderer. Nothing
// to download, nothing to license, runs on Intel and fits in 8 GB. The locked
// AI section in BRIEFSHOW_DEVELOP_NOTES.md (LaMa, SD) is not touched.
//
// ⚠️ NOTHING IS DELETED AND NOTHING IS FINAL. A closed-eye photo gets the same
// Reject flag the client sets by hand; a look is ordinary slider values in the
// photo's record; a crop is an ordinary crop. The run keeps every photo's
// record and flag as they were, and Undo puts all of it back. Duplicates are
// never touched — asked for in as many words.

/// What the photographer ticks in the card.
///
/// ⚠️ THE LOOK IS CHOSEN, THEN EVERY PHOTO IS SOLVED TO IT (26.09): *„da ai
/// moze sam da isedituje slike a fotograf da izabere backround vise u boji
/// ljudi da budu youtify, vise kontrasta, da budu vise svetlije slike, srednje
/// svetlije manje svetlije, ali na kraju da svaka izgleda slicno ili isto"*.
/// The choices below move ONE target look — the open photo's, or the middle
/// of the whole set — and each photo's sliders are then solved to that same
/// target. That is what makes them come out alike rather than each merely
/// "a bit brighter" from wherever it started.
struct AIAssistantOptions: Equatable {
    var rejectClosedEyes = true
    var rejectBlurry = true
    var editLook = true
    var lookSource: AIAssistantLookSource = .wholeSet
    var brightness: AIAssistantBrightness = .asShot
    var contrast: AIAssistantContrast = .natural
    /// On the slider's own scale, −100…100, like every other slider in Create.
    var backgroundColour: Double = 0
    var backgroundDehaze: Double = 0
    var youthify = false
    var crop = false
    var cropShape: AIAssistantCropShape = .original
    var straighten = false

    var doesAnything: Bool {
        rejectClosedEyes || rejectBlurry || editLook || backgroundDehaze != 0 || youthify || crop || straighten
    }
}

enum AIAssistantLookSource: String, CaseIterable, Identifiable {
    case wholeSet, openPhoto
    var id: Self { self }
    var label: String { self == .wholeSet ? "AI look for the whole set" : "Like the photo open now" }
}

/// How bright the people and the background end up, in Lab lightness added to
/// the target — the same amount on every photo.
enum AIAssistantBrightness: String, CaseIterable, Identifiable {
    case asShot, littleBrighter, brighter, muchBrighter
    var id: Self { self }
    var label: String {
        switch self {
        case .asShot: return "As shot"
        case .littleBrighter: return "A little brighter"
        case .brighter: return "Brighter"
        case .muchBrighter: return "Much brighter"
        }
    }
    var lift: Double {
        switch self {
        case .asShot: return 0
        case .littleBrighter: return 3
        case .brighter: return 6
        case .muchBrighter: return 10
        }
    }
}

/// Added the same on every photo — contrast depends on the scene, so it is
/// never solved to one number (see AIAssistantMatcher.knobs).
enum AIAssistantContrast: String, CaseIterable, Identifiable {
    case soft, natural, more, muchMore
    var id: Self { self }
    var label: String {
        switch self {
        case .soft: return "Soft"
        case .natural: return "Natural"
        case .more: return "More"
        case .muchMore: return "Much more"
        }
    }
    /// Stored Contrast added to every photo: −10, 0, +10, +20 on the slider.
    var amount: Double {
        switch self {
        case .soft: return -0.15
        case .natural: return 0
        case .more: return 0.15
        case .muchMore: return 0.30
        }
    }
}

/// The crop shapes offered. 4:3 and 16:9 FOLLOW THE PHOTO: an upright photo
/// gets 3:4 / 9:16. Handing a portrait a landscape frame would throw away most
/// of it, and in a run of mixed frames nobody wants to pick twice.
enum AIAssistantCropShape: String, CaseIterable, Identifiable {
    case original, square, fourThree, sixteenNine

    var id: Self { self }

    var label: String {
        switch self {
        case .original: return "Photo's own"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        }
    }

    /// width / height for a photo of the given shape, and the option the crop
    /// tool shows for it.
    func ratio(forLandscape landscape: Bool, photoRatio: Double) -> (Double, CropAspectRatioOption) {
        switch self {
        case .original: return (photoRatio, .free)
        case .square: return (1, .square)
        case .fourThree: return landscape ? (4.0 / 3.0, .fourThree) : (3.0 / 4.0, .threeFour)
        case .sixteenNine: return landscape ? (16.0 / 9.0, .sixteenNine) : (9.0 / 16.0, .nineSixteen)
        }
    }
}

// MARK: - Eyes and sharpness

enum AIAssistantEyes {
    /// ⚠️ MEASURED, 26.09, not guessed. Openness = height / width of Vision's
    /// eye outline, averaged over both eyes, on a 2048 px image.
    ///
    /// 108 RAWs from a real shoot plus 561 phone photos. Genuinely closed eyes:
    /// 0.08–0.11. Looking down behind glasses, or laughing with the eyes nearly
    /// shut: 0.13–0.17. The smiles with squinted eyes from the shoot — which
    /// must NOT be rejected — sit at 0.17–0.20. So only below 0.12 is certain;
    /// up to 0.16 goes to "check", never to Reject.
    static let closedBelow = 0.12
    static let checkBelow = 0.16
    /// A face smaller than this on the 2048 px image has eye outlines of a
    /// few pixels, and the number is noise. Skipped, not judged.
    static let minimumFacePixels: CGFloat = 50
    /// Same rule as FaceFraming: a stranger far behind the couple does not
    /// decide whether the couple's photo is kept.
    static let minimumRelativeFace: CGFloat = 0.4

    static func openness(_ region: VNFaceLandmarkRegion2D?, in size: CGSize) -> Double? {
        guard let region, region.pointCount >= 6 else { return nil }
        let points = region.pointsInImage(imageSize: size)
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX > minX else { return nil }
        return Double((maxY - minY) / (maxX - minX))
    }
}

/// What one photo looked like to the first pass.
struct AIAssistantInspection {
    enum Eyes { case open, check, closed, nobody }
    var eyes: Eyes = .nobody
    /// Variance of the Laplacian over the faces (or the middle of the frame
    /// when there are none). Only meaningful against the rest of the set.
    var sharpness: Double = 0
    var sharpnessFromFaces = false
}

enum AIAssistantInspector {
    /// The camera's own preview for a RAW, the file itself otherwise — already
    /// the right way up. Eyes and focus need no edit applied, and this is ten
    /// times cheaper than a RAW decode.
    static func previewImage(of url: URL, side: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func inspect(_ url: URL) -> AIAssistantInspection {
        var result = AIAssistantInspection()
        guard let image = previewImage(of: url) else { return result }
        let size = CGSize(width: image.width, height: image.height)

        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([landmarks])
        let faces = landmarks.results ?? []
        let tallest = faces.map(\.boundingBox.height).max() ?? 0
        let judged = faces.filter {
            $0.boundingBox.height >= tallest * AIAssistantEyes.minimumRelativeFace
                && $0.boundingBox.height * size.height >= AIAssistantEyes.minimumFacePixels
        }

        var worst: Double?
        for face in judged {
            guard let left = AIAssistantEyes.openness(face.landmarks?.leftEye, in: size),
                  let right = AIAssistantEyes.openness(face.landmarks?.rightEye, in: size) else { continue }
            let both = (left + right) / 2
            worst = min(worst ?? both, both)
        }
        if let worst {
            result.eyes = worst < AIAssistantEyes.closedBelow ? .closed
                : worst < AIAssistantEyes.checkBelow ? .check : .open
        }

        // Focus is judged where it matters: the faces, if there are any.
        var region = CGRect(x: size.width * 0.2, y: size.height * 0.2,
                            width: size.width * 0.6, height: size.height * 0.6)
        if !judged.isEmpty {
            var union = judged[0].boundingBox
            for face in judged.dropFirst() { union = union.union(face.boundingBox) }
            region = CGRect(x: union.minX * size.width, y: (1 - union.maxY) * size.height,
                            width: union.width * size.width, height: union.height * size.height)
            result.sharpnessFromFaces = true
        }
        result.sharpness = laplacianVariance(image, in: region.integral)
        return result
    }

    /// Variance of a 4-neighbour Laplacian on grey, the usual focus measure.
    static func laplacianVariance(_ image: CGImage, in rect: CGRect) -> Double {
        let bounds = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard bounds.width >= 8, bounds.height >= 8, let crop = image.cropping(to: bounds) else { return 0 }
        let w = crop.width, h = crop.height
        var grey = [UInt8](repeating: 0, count: w * h)
        let drawn = grey.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let v = 4 * Double(grey[i]) - Double(grey[i - 1]) - Double(grey[i + 1])
                    - Double(grey[i - w]) - Double(grey[i + w])
                sum += v; sumSq += v * v; n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// ⚠️ RELATIVE TO THE SET, never an absolute number: a shoot on a long lens
    /// at f/1.8 and a group at f/8 have nothing in common, but a missed focus
    /// stands out against the photos around it. Only judged with five or more
    /// photos to compare with. A photo without faces is only ever "check" —
    /// a soft background may be the whole point of it.
    static let blurRejectShare = 0.2
    static let blurCheckShare = 0.35
}

// MARK: - Look matching

/// What a photo looks like, in numbers the sliders can be solved against.
/// Measured on a small render through the app's own renderer, so what is
/// matched is exactly what will be seen.
struct AIAssistantLook {
    var subjectL = 0.0
    var backgroundL = 0.0
    var medianL = 0.0
    var spread = 0.0
    var a = 0.0
    var b = 0.0
    var backgroundChroma = 0.0
    var chroma = 0.0
    var hasPeople = false
    /// How much of the frame the people fill, 0…1.
    var peopleShare = 0.0
    /// Lightness of the skin in the middle of the faces — what the people's
    /// brightness is judged by when there are faces (see `knobs`).
    var skinL = 0.0
    var hasSkin = false
}

enum AIAssistantMatcher {
    static let side: CGFloat = 512
    /// A person must fill at least this much of the frame for the people and
    /// the background to be matched separately.
    static let peopleShare = 0.03

    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    ])

    struct Frame {
        let width: Int
        let height: Int
        let extent: CGRect
        /// 0…255 per pixel, people white.
        let people: [UInt8]?
        /// true where a pixel is skin in the middle of a face — what white
        /// balance is read from (see `look`). Top-down rows, like `people`.
        let skin: [Bool]
    }

    /// The frame everything is measured in, and the people in it — found once
    /// on the photo as it stands, since exposure and colour do not move people.
    static func frame(for image: CIImage) -> Frame {
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var people: [UInt8]?
        if let mask = SubjectMasker.personMask(for: image, maxWorkingEdge: side) {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes {
                context.render(mask.cropped(to: extent), toBitmap: $0.baseAddress!, rowBytes: w * 4,
                               bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            people = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
        }
        // The middle of every face: cheeks, nose, forehead — skin, not hair
        // and not the collar. Rows are counted from the bottom, as Core Image
        // renders them.
        var skin = [Bool](repeating: false, count: w * h)
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: image.cropped(to: extent), options: [:]).perform([faces])
        for face in faces.results ?? [] {
            let box = face.boundingBox
            let inner = CGRect(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.2,
                               width: box.width * 0.5, height: box.height * 0.5)
            let x0 = max(0, Int(inner.minX * CGFloat(w))), x1 = min(w, Int(inner.maxX * CGFloat(w)))
            let top = max(0, Int((1 - inner.maxY) * CGFloat(h))), bottom = min(h, Int((1 - inner.minY) * CGFloat(h)))
            guard x1 > x0, bottom > top else { continue }
            for y in top..<bottom { for x in x0..<x1 { skin[y * w + x] = true } }
        }
        return Frame(width: w, height: h, extent: extent, people: people, skin: skin)
    }

    static func look(of image: CIImage, in frame: Frame) -> AIAssistantLook {
        let w = frame.width, h = frame.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: frame.extent,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }

        let peopleCount = frame.people?.reduce(0) { $0 + ($1 > 127 ? 1 : 0) } ?? 0
        let hasPeople = Double(peopleCount) / Double(max(w * h, 1)) >= peopleShare
        let useSkin = frame.skin.reduce(0) { $0 + ($1 ? 1 : 0) } >= 30

        var all = [Double](), subject = [Double](), behind = [Double](), skinValues = [Double]()
        all.reserveCapacity(w * h)
        var aSum = 0.0, bSum = 0.0, abCount = 0.0
        var chromaSum = 0.0, bgChromaSum = 0.0, bgCount = 0.0
        for i in 0..<(w * h) {
            guard rgba[i * 4 + 3] > 0 else { continue }
            let lab = Self.lab(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2])
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            all.append(lab.l)
            chromaSum += c
            let isPerson = (frame.people?[i] ?? 0) > 127
            if hasPeople {
                if isPerson { subject.append(lab.l) } else { behind.append(lab.l); bgChromaSum += c; bgCount += 1 }
            }
            // ⚠️ White balance is read off SKIN (26.09). Read off the whole
            // people it followed their clothes: on a shoot in a blue dress and
            // a grey shirt, how much of each was in frame swung it photo to
            // photo. Faces, then people, then the mid-tones of the frame.
            let wbSource = useSkin ? frame.skin[i] : (hasPeople ? isPerson : true)
            if wbSource, lab.l > 15, lab.l < 95 {
                aSum += lab.a; bSum += lab.b; abCount += 1
            }
            if useSkin, frame.skin[i] { skinValues.append(lab.l) }
        }
        guard !all.isEmpty else { return AIAssistantLook() }
        all.sort(); subject.sort(); behind.sort(); skinValues.sort()
        func pick(_ values: [Double], _ q: Double) -> Double {
            values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count - 1) * q))]
        }
        var look = AIAssistantLook()
        look.hasPeople = hasPeople
        look.peopleShare = Double(peopleCount) / Double(max(w * h, 1))
        look.medianL = pick(all, 0.5)
        look.spread = pick(all, 0.95) - pick(all, 0.05)
        look.subjectL = hasPeople ? pick(subject, 0.5) : look.medianL
        look.backgroundL = hasPeople ? pick(behind, 0.5) : look.medianL
        look.hasSkin = useSkin
        look.skinL = useSkin ? pick(skinValues, 0.5) : look.subjectL
        look.a = abCount > 0 ? aSum / abCount : 0
        look.b = abCount > 0 ? bSum / abCount : 0
        look.chroma = chromaSum / Double(all.count)
        look.backgroundChroma = bgCount > 0 ? bgChromaSum / bgCount : look.chroma
        return look
    }

    /// sRGB bytes to CIE Lab (D65).
    /// sRGB byte to linear, once for all 256 values. The `pow` per pixel per
    /// channel was a third of every measurement (sample, 26.09).
    private static let linearTable: [Double] = (0..<256).map { v in
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func lab(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8) -> (l: Double, a: Double, b: Double) {
        let r = linearTable[Int(r8)], g = linearTable[Int(g8)], b = linearTable[Int(b8)]
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// One slider, the number it is solved against, where that number should
    /// end up, how close is close, and how far the slider may go.
    struct Knob {
        let key: WritableKeyPath<PhotoEditSettings, Double>
        let read: (AIAssistantLook) -> Double
        let goal: Double
        let tolerance: Double
        let range: ClosedRange<Double>
    }

    /// ⚠️ WHAT IS MADE THE SAME, AND WHAT IS NOT (26.09, measured on 12 photos
    /// of a real shoot). The first version solved EVERYTHING to one target —
    /// background brightness, background colour, contrast — and the contact
    /// sheet came back with the garden grey and the beach blown out: a garden
    /// simply has more colour than a white sky, and making them equal is
    /// wrong. What stays the same through a shoot are the PEOPLE: how bright
    /// the skin is and what colour the light on it is. So only those go to one
    /// target. The background keeps its own brightness relative to where it
    /// was (lifted by half the client's Brightness, never past `backgroundCeiling`),
    /// and contrast and background colour are the client's choice, added the
    /// same on every photo.
    static let backgroundCeiling = 88.0
    static let smallPeople = 0.12

    static func knobs(people: Bool, target: AIAssistantLook, own: AIAssistantLook, lift: Double) -> [Knob] {
        // ⚠️ THE PEOPLE'S BRIGHTNESS IS THEIR SKIN (26.09). Judged over the
        // whole person it was mostly clothes: a single woman in a dark blue
        // dress filling the frame measured dark, Exposure went up until the
        // DRESS reached the set's level, and face and background burned out —
        // reported with a screenshot. Groups far away were fine, which is why
        // the 12-photo ruler did not see it. Faces on both sides → skin;
        // otherwise the whole person, otherwise the frame.
        let skin = own.hasSkin && target.hasSkin
        let read: (AIAssistantLook) -> Double = skin ? { $0.skinL } : (people ? { $0.subjectL } : { $0.medianL })
        let goal = skin ? target.skinL : (people ? target.subjectL : target.medianL)
        var list: [Knob] = [
            Knob(key: \.exposure, read: read, goal: goal, tolerance: 1.0, range: -1.0...1.0),
        ]
        if people {
            let keep = min(own.backgroundL + lift / 2, max(own.backgroundL, backgroundCeiling))
            list.append(Knob(key: \.backgroundExposure, read: { $0.backgroundL },
                             goal: keep, tolerance: 1.5, range: -0.75...0.75))
        }
        // ⚠️ White balance read off a few small people is mostly their
        // clothes: measured 26.09, a couple inside a wicker ring (7 % of the
        // frame) pulled Tint to +0.57 and the whole photo went purple. So the
        // reach of both is narrow, and narrower still for small people.
        let reach = people && own.peopleShare < smallPeople ? 0.15 : 0.35
        list += [
            Knob(key: \.temperature, read: { $0.b }, goal: target.b, tolerance: 0.8, range: -reach...reach),
            Knob(key: \.tint, read: { $0.a }, goal: target.a, tolerance: 0.8, range: -reach...reach),
        ]
        return list
    }

    static let probe = 0.1
    static let maximumStep = 0.6
    static let rounds = 3

    /// Moves `settings`' light and white balance until the photo measures like
    /// `target` where it should (see `knobs`). Coordinate descent: one slider
    /// at a time, the slope read off a second render, three rounds. Every
    /// render is the real renderer at 512 px.
    static func match(_ start: PhotoEditSettings, on base: PhotoBaseImage, frame: Frame,
                      to target: AIAssistantLook, lift: Double,
                      isCancelled: () -> Bool) -> PhotoEditSettings {
        var settings = start
        func measure(_ s: PhotoEditSettings) -> AIAssistantLook {
            look(of: PhotoEditRenderer.render(s, on: base, applyCrop: false), in: frame)
        }
        var current = measure(settings)
        let own = current
        let people = current.hasPeople && target.hasPeople
        let knobs = knobs(people: people, target: target, own: own, lift: lift)
        for _ in 0..<rounds {
            var moved = false
            for knob in knobs {
                if isCancelled() { return settings }
                let error = knob.read(current) - knob.goal
                guard abs(error) > knob.tolerance else { continue }
                var probed = settings
                probed[keyPath: knob.key] = settings[keyPath: knob.key] + probe
                Self.forgetAbsoluteWhiteBalance(&probed, for: knob.key)
                let slope = (knob.read(measure(probed)) - knob.read(current)) / probe
                guard abs(slope) > 1e-3 else { continue }
                let step = min(max(-error / slope, -maximumStep), maximumStep)
                let value = min(max(settings[keyPath: knob.key] + step, knob.range.lowerBound), knob.range.upperBound)
                guard value != settings[keyPath: knob.key] else { continue }
                settings[keyPath: knob.key] = value
                Self.forgetAbsoluteWhiteBalance(&settings, for: knob.key)
                current = measure(settings)
                moved = true
            }
            if !moved { break }
        }
        return settings
    }

    /// Temperature and Tint may be held as absolute Kelvin copied from the
    /// reference; moving the offset means the offset is what counts — the same
    /// thing the sliders themselves do when dragged.
    static func forgetAbsoluteWhiteBalance(_ settings: inout PhotoEditSettings,
                                           for key: WritableKeyPath<PhotoEditSettings, Double>) {
        if key == \PhotoEditSettings.temperature { settings.temperatureKelvin = nil }
        if key == \PhotoEditSettings.tint { settings.tintAbsolute = nil }
    }

    /// The middle of the set, measure by measure — the "AI look" before the
    /// client's choices move it.
    static func median(of looks: [AIAssistantLook]) -> AIAssistantLook {
        func mid(_ read: (AIAssistantLook) -> Double) -> Double {
            let values = looks.map(read).sorted()
            return values.isEmpty ? 0 : values[values.count / 2]
        }
        var look = AIAssistantLook()
        let withPeople = looks.filter(\.hasPeople)
        look.hasPeople = withPeople.count * 2 >= looks.count && !withPeople.isEmpty
        let source = look.hasPeople ? withPeople : looks
        func midOf(_ read: (AIAssistantLook) -> Double) -> Double {
            let values = source.map(read).sorted()
            return values.isEmpty ? mid(read) : values[values.count / 2]
        }
        look.subjectL = midOf(\.subjectL)
        let withSkin = looks.filter(\.hasSkin)
        look.hasSkin = withSkin.count * 2 >= looks.count && !withSkin.isEmpty
        let skins = withSkin.map(\.skinL).sorted()
        look.skinL = skins.isEmpty ? look.subjectL : skins[skins.count / 2]
        look.backgroundL = midOf(\.backgroundL)
        look.medianL = mid(\.medianL)
        look.spread = mid(\.spread)
        look.a = midOf(\.a)
        look.b = midOf(\.b)
        look.backgroundChroma = midOf(\.backgroundChroma)
        look.chroma = mid(\.chroma)
        return look
    }

    /// The client's Brightness, applied to the target look. Contrast and
    /// background colour are not targets — see `knobs` — they go on as the
    /// same slider amount on every photo (`AIAssistantOptions.fixedAmounts`).
    static func adjusted(_ look: AIAssistantLook, by options: AIAssistantOptions) -> AIAssistantLook {
        var out = look
        out.subjectL += options.brightness.lift
        out.skinL += options.brightness.lift
        out.medianL += options.brightness.lift
        return out
    }

    /// What the reference carries to every photo before the solve starts: its
    /// whole look — tone, colour, mixer, detail, effects — but none of the
    /// per-photograph work (crop, rotation, straighten, masks, template, text).
    static let carriedLook: SyncItem = SyncItem.all
        .subtracting([.crop, .rotation, .straighten, .masks, .template, .text])
}

// MARK: - Framing

enum AIAssistantFraming {
    /// Room left around the people, as a share of the crop, so nobody's
    /// elbow touches the edge.
    static let margin = 0.04
    /// Where the faces' centre sits, from the top of the crop — slightly above
    /// the middle, the ordinary headroom rule (see FaceFraming.headroomBias).
    static let faceLine = 0.38
    /// With the photo's own shape the crop must be SMALLER than the photo, or
    /// there is nothing to move and "centre the people" means nothing.
    static let ownShapeScale = 0.9

    /// Horizon angle in degrees for `straightenDegrees`, or nil when there is
    /// no clear horizon or it is already level. Beyond 8° it is taken to be
    /// meant (a tilted shot), not a mistake.
    static func horizonCorrection(of image: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        guard let horizon = request.results?.first else { return nil }
        let degrees = Double(horizon.angle) * 180 / .pi
        guard abs(degrees) >= 0.5, abs(degrees) <= 8 else { return nil }
        // ⚠️ MEASURED, not reasoned (26.09, Tools/run-ai-assistant-test.py):
        // a picture turned by straightenDegrees +4 reads +4.13 here. So the
        // correction is the reading with its sign turned.
        return -degrees
    }

    /// The crop, in the record's own fractions (top-down), for a photo whose
    /// uncropped render is `image`, or nil when nobody is found. `allowed` is
    /// the part of the frame without transparent corners after a straighten.
    /// `cutsSomeone` is true when the people do not fit the chosen shape.
    static func crop(for image: CIImage, frame: AIAssistantMatcher.Frame, shape: AIAssistantCropShape,
                     allowed: EditCropRect) -> (rect: EditCropRect, aspect: CropAspectRatioOption, cutsSomeone: Bool)? {
        let w = Double(frame.width), h = Double(frame.height)
        guard w > 0, h > 0, let people = frame.people else { return nil }

        // The people's box, in pixels, top-down.
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<frame.height {
            for x in 0..<frame.width where people[y * frame.width + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Vision's buffer is bottom-up like Core Image; the record is top-down.
        let peopleBox = CGRect(x: Double(minX), y: h - Double(maxY) - 1,
                               width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))

        // The faces decide where the centre goes; the people's box is the
        // fallback for someone facing away.
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([faces])
        let faceBoxes = (faces.results ?? []).map {
            CGRect(x: $0.boundingBox.minX * w, y: (1 - $0.boundingBox.maxY) * h,
                   width: $0.boundingBox.width * w, height: $0.boundingBox.height * h)
        }
        let tallest = faceBoxes.map(\.height).max() ?? 0
        let kept = faceBoxes.filter { $0.height >= tallest * FaceFraming.minRelativeFaceHeight }

        let area = CGRect(x: allowed.x * w, y: allowed.y * h, width: allowed.width * w, height: allowed.height * h)
        let landscape = w >= h
        let (ratio, aspect) = shape.ratio(forLandscape: landscape, photoRatio: w / h)
        var cropW = area.width, cropH = cropW / ratio
        if cropH > area.height { cropH = area.height; cropW = cropH * ratio }
        if shape == .original { cropW *= ownShapeScale; cropH *= ownShapeScale }

        let centreX: Double
        let centreY: Double
        if let first = kept.first {
            let union = kept.dropFirst().reduce(first) { $0.union($1) }
            centreX = (union.midX + peopleBox.midX) / 2
            centreY = union.midY + (0.5 - faceLine) * cropH
        } else {
            centreX = peopleBox.midX
            centreY = peopleBox.midY
        }
        var x = centreX - cropW / 2, y = centreY - cropH / 2
        x = min(max(x, area.minX), area.maxX - cropW)
        y = min(max(y, area.minY), area.maxY - cropH)

        let inner = CGRect(x: x, y: y, width: cropW, height: cropH).insetBy(dx: cropW * margin, dy: cropH * margin)
        let cutsSomeone = !inner.contains(peopleBox.insetBy(dx: 1, dy: 1))
        return (EditCropRect(x: x / w, y: y / h, width: cropW / w, height: cropH / h), aspect, cutsSomeone)
    }
}

// MARK: - The run

final class AIAssistantRun: ObservableObject {
    enum Stage: Equatable { case idle, running, finished, undone }

    struct Report {
        var rejectedEyes: [URL] = []
        var rejectedBlur: [URL] = []
        var check: [(url: URL, why: String)] = []
        var matched = 0
        var cropped = 0
        var straightened = 0
        var youthified = 0
        var total = 0
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var phase = ""
    @Published private(set) var report = Report()

    private let lock = NSLock()
    private var cancelled = false
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Everything the run changed, as it was before — so Undo is exact.
    private var before: [URL: (settings: PhotoEditSettings, rejected: Bool)] = [:]

    private static let queue = DispatchQueue(label: "com.rocketsbrief.briefshow.aiassistant", qos: .userInitiated)

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func start(targets: [URL], reference: URL?, options: AIAssistantOptions) {
        guard stage == .idle, !targets.isEmpty else { return }
        stage = .running
        total = targets.count
        done = 0
        report = Report()
        report.total = targets.count
        for url in targets {
            before[url] = (PhotoEditStore.settings(for: url), PhotoLabelStore.isRejected(url))
        }
        let startSettings = Dictionary(uniqueKeysWithValues: targets.map { ($0, PhotoEditStore.settings(for: $0)) })

        Self.queue.tracked("AI Assistant") { [weak self] in
            self?.work(targets: targets, reference: reference, options: options, startSettings: startSettings)
        }
    }

    private func publish(_ phase: String, done: Int) {
        DispatchQueue.main.async {
            self.phase = phase
            self.done = done
        }
    }

    /// Runs `body` over `items` on MachineBudget's workers, in order of
    /// completion, counting as it goes.
    private func parallel(_ items: [URL], label: String, _ body: @escaping (URL) -> Void) {
        let group = DispatchGroup()
        let limit = DispatchSemaphore(value: max(1, MachineBudget.decodeWorkers))
        let counter = NSLock()
        var finished = 0
        publish("\(label) 1 of \(items.count)", done: 0)
        for url in items {
            if isCancelled { break }
            limit.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { limit.signal(); group.leave() }
                if !self.isCancelled { autoreleasepool { body(url) } }
                counter.lock(); finished += 1; let n = finished; counter.unlock()
                self.publish("\(label) \(min(n + 1, items.count)) of \(items.count)", done: n)
            }
        }
        group.wait()
    }

    private func work(targets: [URL], reference: URL?, options: AIAssistantOptions,
                      startSettings: [URL: PhotoEditSettings]) {
        // 1. Eyes and focus.
        var inspections: [URL: AIAssistantInspection] = [:]
        let inspectLock = NSLock()
        if options.rejectClosedEyes || options.rejectBlurry {
            parallel(targets, label: "Looking at eyes and focus") { url in
                let found = AIAssistantInspector.inspect(url)
                inspectLock.lock(); inspections[url] = found; inspectLock.unlock()
            }
        }

        var rejectEyes: [URL] = [], rejectBlur: [URL] = [], check: [(URL, String)] = []
        if options.rejectClosedEyes {
            for url in targets {
                switch inspections[url]?.eyes {
                case .closed?: rejectEyes.append(url)
                case .check?: check.append((url, "eyes may be closed"))
                default: break
                }
            }
        }
        if options.rejectBlurry, targets.count >= 5 {
            let values = targets.compactMap { inspections[$0]?.sharpness }.filter { $0 > 0 }.sorted()
            if !values.isEmpty {
                let median = values[values.count / 2]
                for url in targets where !rejectEyes.contains(url) {
                    guard let found = inspections[url], found.sharpness > 0 else { continue }
                    if found.sharpness < median * AIAssistantInspector.blurRejectShare, found.sharpnessFromFaces {
                        rejectBlur.append(url)
                    } else if found.sharpness < median * AIAssistantInspector.blurCheckShare {
                        check.append((url, "may be out of focus"))
                    }
                }
            }
        }
        DispatchQueue.main.async {
            for url in rejectEyes + rejectBlur { PhotoLabelStore.setRejected(true, for: url) }
            self.report.rejectedEyes = rejectEyes
            self.report.rejectedBlur = rejectBlur
            self.report.check = check.map { (url: $0.0, why: $0.1) }
        }
        if isCancelled { return finish() }

        // 2. The look: every photo measured once, the target set, then each
        // photo solved to that same target.
        guard options.editLook || options.backgroundDehaze != 0 || options.youthify
                || options.crop || options.straighten else { return finish() }

        var frames: [URL: AIAssistantMatcher.Frame] = [:]
        var looks: [URL: AIAssistantLook] = [:]
        var target: AIAssistantLook?
        let referenceSettings: PhotoEditSettings? = options.lookSource == .openPhoto
            ? reference.flatMap { startSettings[$0] } : nil
        if options.editLook {
            let measureLock = NSLock()
            parallel(targets, label: "Reading the light") { url in
                guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: AIAssistantMatcher.side)
                else { return }
                let image = PhotoEditRenderer.render(startSettings[url] ?? PhotoEditStore.settings(for: url),
                                                     on: base, applyCrop: false)
                let frame = AIAssistantMatcher.frame(for: image)
                let look = AIAssistantMatcher.look(of: image, in: frame)
                measureLock.lock(); frames[url] = frame; looks[url] = look; measureLock.unlock()
            }
            if isCancelled { return finish() }
            let base: AIAssistantLook?
            if options.lookSource == .openPhoto, let reference, let own = looks[reference] {
                base = own
            } else {
                base = looks.isEmpty ? nil : AIAssistantMatcher.median(of: Array(looks.values))
            }
            target = base.map { AIAssistantMatcher.adjusted($0, by: options) }
        }

        let countLock = NSLock()
        var matched = 0, cropped = 0, straightened = 0
        var framingChecks: [(URL, String)] = []
        parallel(targets, label: "Editing") { url in
            guard let base = PhotoEditRenderer.loadBaseImage(from: url, maxPixelSize: AIAssistantMatcher.side) else { return }
            let stored = startSettings[url] ?? PhotoEditStore.settings(for: url)
            var settings = stored
            var didMatch = false, didStraighten = false, didCrop = false
            var framingNote: String?

            if let target {
                // Like the open photo: its whole look comes along first
                // (clarity, mixer, vignette…), then the light is solved.
                if let referenceSettings, url != reference {
                    settings = DevelopView.mergedSyncSettings(source: referenceSettings, target: settings,
                                                              items: AIAssistantMatcher.carriedLook)
                }
                let frame = frames[url] ?? AIAssistantMatcher.frame(
                    for: PhotoEditRenderer.render(settings, on: base, applyCrop: false))
                settings = AIAssistantMatcher.match(settings, on: base, frame: frame, to: target,
                                                    lift: options.brightness.lift,
                                                    isCancelled: { self.isCancelled })
                settings.contrast = min(max(settings.contrast + options.contrast.amount, -1.5), 1.5)
                settings.backgroundSaturation = min(max(settings.backgroundSaturation
                    + options.backgroundColour * 1.5 / 100, -1.5), 1.5)
                didMatch = settings != stored
            }

            // Background Dehaze has no measure to solve against; it goes on
            // top, the same amount on every photo.
            let scale = 1.5 / 100
            if options.backgroundDehaze != 0 {
                settings.backgroundDehaze = min(max(settings.backgroundDehaze
                    + options.backgroundDehaze * scale, -1.5), 1.5)
            }

            if options.straighten {
                var level = PhotoEditSettings()
                level.rotationQuarterTurns = settings.rotationQuarterTurns
                if let degrees = AIAssistantFraming.horizonCorrection(
                    of: PhotoEditRenderer.render(level, on: base, applyCrop: false)) {
                    settings.straightenDegrees = degrees
                    didStraighten = true
                }
            }

            if options.crop || didStraighten {
                let uncropped = PhotoEditRenderer.render(settings, on: base, applyCrop: false)
                let extent = uncropped.extent
                var width = Double(extent.width), height = Double(extent.height)
                if !width.isFinite || !height.isFinite { width = 0; height = 0 }
                // The part of the frame that is still picture after a turn.
                var baseW = width, baseH = height
                if settings.straightenDegrees != 0 {
                    let theta = abs(settings.straightenDegrees) * .pi / 180
                    let c = cos(theta), s = sin(theta)
                    // Undo the bounding box to get the photo's own size back.
                    let det = c * c - s * s
                    if det > 0.01 {
                        baseW = (width * c - height * s) / det
                        baseH = (height * c - width * s) / det
                    }
                }
                let allowed = PhotoEditRenderer.autoStraightenCrop(imageWidth: baseW, imageHeight: baseH,
                                                                   angleDegrees: settings.straightenDegrees)
                if options.crop {
                    let frame = AIAssistantMatcher.frame(for: uncropped)
                    if let framed = AIAssistantFraming.crop(for: uncropped, frame: frame,
                                                            shape: options.cropShape, allowed: allowed) {
                        settings.crop = framed.rect
                        settings.cropAspect = framed.aspect
                        didCrop = true
                        if framed.cutsSomeone { framingNote = "someone is close to the edge of the crop" }
                    } else {
                        framingNote = "nobody found to frame"
                        if didStraighten { settings.crop = allowed == .full ? nil : allowed }
                    }
                } else if didStraighten {
                    settings.crop = allowed == .full ? nil : allowed
                }
            }

            guard settings != stored else { return }
            countLock.lock()
            if didMatch { matched += 1 }
            if didCrop { cropped += 1 }
            if didStraighten { straightened += 1 }
            if let framingNote { framingChecks.append((url, framingNote)) }
            countLock.unlock()
            DispatchQueue.main.async { PhotoEditStore.setSettings(settings, for: url) }
        }

        DispatchQueue.main.async {
            self.report.matched = matched
            self.report.cropped = cropped
            self.report.straightened = straightened
            self.report.check += framingChecks.map { (url: $0.0, why: $0.1) }
        }
        if isCancelled { return finish() }

        // 3. Youthify — the very same recipe as the AI Portrait button, and
        // LAST: the people layer it makes holds the pixels as they are at that
        // moment, so it has to be cut from the finished look, not the old one.
        if options.youthify {
            let rejected = Set(rejectEyes + rejectBlur)
            let kept = targets.filter { !rejected.contains($0) }
            let wait = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                PhotoEditStore.flushNow()
                PortraitRecipeService.run([.youthify], on: kept) { done, total in
                    self.phase = "Youthify \(min(done + 1, total)) of \(total)"
                    self.done = done
                } completion: { outcome in
                    self.report.youthified = outcome.settingsByURL.count
                    wait.signal()
                }
            }
            wait.wait()
        }
        finish()
    }

    private func finish() {
        DispatchQueue.main.async {
            PhotoEditStore.flushNow()
            self.stage = .finished
        }
    }

    /// Everything back as it was before the run: records and Reject flags.
    func undo() {
        guard stage == .finished else { return }
        for (url, old) in before {
            if PhotoEditStore.settings(for: url) != old.settings {
                PhotoEditStore.setSettings(old.settings, for: url)
            }
            if PhotoLabelStore.isRejected(url) != old.rejected {
                PhotoLabelStore.setRejected(old.rejected, for: url)
            }
        }
        PhotoEditStore.flushNow()
        stage = .undone
    }
}

// MARK: - The card

/// Comes up every time Create opens, over the photos in the filmstrip — see
/// DevelopView's `showAIAssistant`.
struct AIAssistantCard: View {
    let targets: [URL]
    let reference: URL?
    let onSelectPhoto: (URL) -> Void
    let onClose: () -> Void

    @State private var options = AIAssistantOptions()
    @StateObject private var run = AIAssistantRun()
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch run.stage {
            case .idle: choices
            case .running: progress
            case .finished, .undone: summary
            }
            footer
        }
        .padding(18)
        .frame(width: 500)
        // ⚠️ The system controls in here (the three pop-up menus, the
        // checkboxes, the sliders) draw in the WINDOW's appearance, and a sheet
        // does not get the app's theme — their text came out near black on this
        // dark panel (reported 26.09). Told the theme explicitly.
        .environment(\.colorScheme, theme.current == .dark ? .dark : .light)
        .background(AppColors.panel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("AI")
                    .font(.custom("Figtree", size: 10).weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppColors.ink, lineWidth: 1))
                Text("Assistant")
                    .font(.custom("Figtree", size: 15).weight(.semibold))
            }
            .foregroundColor(AppColors.ink)
            Text("For the \(targets.count) photo\(targets.count == 1 ? "" : "s") in the filmstrip. Nothing is deleted and duplicates are kept — every change is an ordinary edit you can undo.")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.custom("Figtree", size: 10).weight(.semibold))
            .foregroundColor(AppColors.inkSecondary)
            .padding(.top, 2)
    }

    private func tick(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.custom("Figtree", size: 12).weight(.medium)).foregroundColor(AppColors.ink)
                Text(detail).font(.custom("Figtree", size: 10)).foregroundColor(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func amount(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.custom("Figtree", size: 12)).foregroundColor(AppColors.ink)
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: -100...100, step: 5)
            Text(value.wrappedValue == 0 ? "0" : String(format: "%+.0f", value.wrappedValue))
                .font(.custom("Figtree", size: 11).monospacedDigit())
                .foregroundColor(AppColors.inkSecondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func choice<T: CaseIterable & Identifiable & Hashable & RawRepresentable>(
        _ title: String, _ value: Binding<T>
    ) -> some View where T.AllCases: RandomAccessCollection, T.RawValue == String {
        HStack(spacing: 10) {
            Text(title).font(.custom("Figtree", size: 12)).foregroundColor(AppColors.ink)
                .frame(width: 150, alignment: .leading)
            Picker("", selection: value) {
                ForEach(T.allCases) { item in Text(Self.label(of: item)).tag(item) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private static func label<T>(of item: T) -> String {
        switch item {
        case let x as AIAssistantLookSource: return x.label
        case let x as AIAssistantBrightness: return x.label
        case let x as AIAssistantContrast: return x.label
        default: return "\(item)"
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 9) {
            section("Pick")
            tick("Reject closed eyes", "Photos where someone blinked get Reject. Unsure ones are only listed for you to look at.",
                 $options.rejectClosedEyes)
            tick("Reject out of focus", "Compared with the other photos here, not with a fixed number.",
                 $options.rejectBlurry)

            section("Look — every photo ends up the same")
            tick("Edit the light and colour",
                 "The people get the same brightness and the same light colour on every photo; the background keeps its own and is kept from burning out.",
                 $options.editLook)
            Group {
                choice("Start from", $options.lookSource)
                choice("Brightness", $options.brightness)
                choice("Contrast", $options.contrast)
                amount("Background colour", $options.backgroundColour)
            }
            .disabled(!options.editLook)
            .opacity(options.editLook ? 1 : 0.5)
            amount("Background Dehaze", $options.backgroundDehaze)
            tick("Youthify the people", "The same Youthify as in AI Portrait — smoother skin, the layers stay live.",
                 $options.youthify)

            section("Frame")
            tick("Straighten the horizon", "Only a small tilt that looks like a mistake — up to 8°.", $options.straighten)
            tick("Crop with the people in the centre", "Faces a little above the middle, room around everyone.",
                 $options.crop)
            // Own pills, not a segmented Picker: the system control draws its
            // unselected labels in the system's colour, which on this app's
            // dark panel came out black (reported 26.09 with a screenshot).
            HStack(spacing: 6) {
                ForEach(AIAssistantCropShape.allCases) { shape in
                    let picked = options.cropShape == shape
                    Button { options.cropShape = shape } label: {
                        Text(shape.label)
                            .font(.custom("Figtree", size: 11).weight(picked ? .semibold : .regular))
                            .foregroundColor(picked ? AppColors.ink : AppColors.inkSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(picked ? AppColors.panelAlt : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(AppColors.border.opacity(picked ? 0.9 : 0.5), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainHoverButtonStyle())
                }
            }
            .disabled(!options.crop)
            .opacity(options.crop ? 1 : 0.5)
            .padding(.leading, 20)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
            Text(run.phase.isEmpty ? "Starting…" : run.phase + "…")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.inkSecondary)
        }
        .padding(.vertical, 8)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if run.stage == .undone {
                Text("Undone — every photo is back as it was.")
                    .font(.custom("Figtree", size: 12)).foregroundColor(AppColors.ink)
            } else {
                let r = run.report
                line("Rejected, eyes closed", r.rejectedEyes.count)
                line("Rejected, out of focus", r.rejectedBlur.count)
                line("Light and colour edited", r.matched)
                line("Youthify", r.youthified)
                line("Straightened", r.straightened)
                line("Cropped", r.cropped)
                if !r.check.isEmpty {
                    section("Worth a look (\(r.check.count))")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(r.check.enumerated()), id: \.offset) { _, item in
                                Button {
                                    onSelectPhoto(item.url)
                                } label: {
                                    HStack {
                                        Text(item.url.lastPathComponent).foregroundColor(AppColors.ink)
                                        Text("— " + item.why).foregroundColor(AppColors.inkSecondary)
                                        Spacer()
                                    }
                                    .font(.custom("Figtree", size: 11))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainHoverButtonStyle())
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }

    private func line(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title).font(.custom("Figtree", size: 12)).foregroundColor(AppColors.ink)
            Spacer()
            Text("\(count)").font(.custom("Figtree", size: 12).monospacedDigit()).foregroundColor(AppColors.ink)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch run.stage {
            case .idle:
                Spacer()
                Button("Skip", action: onClose)
                    .buttonStyle(CardButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Run on \(targets.count) photo\(targets.count == 1 ? "" : "s")") {
                    run.start(targets: targets, reference: reference, options: options)
                }
                .buttonStyle(CardButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!options.doesAnything)
            case .running:
                Spacer()
                Button("Stop") { run.cancel() }
                    .buttonStyle(CardButtonStyle())
            case .finished:
                Button("Undo All") { run.undo() }
                    .buttonStyle(CardButtonStyle())
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(CardButtonStyle(isProminent: true))
                    .keyboardShortcut(.defaultAction)
            case .undone:
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(CardButtonStyle(isProminent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
