import AppKit
import Vision

/// Where the people in a photo are, turned into the one number the crop
/// already understands: `MagazinePhotoCrop.focusX/focusY`, the point of the
/// image that stays centred in whatever cell the photo lands in.
///
/// ⚠️ WHAT THIS DOES NOT TOUCH. Only the Kousei and Kirigami families crop a
/// photo to fill a 4:3/3:4 cell; Single Fade, Single Blink and Kanata show the
/// whole picture. Nothing here can change those, because nothing here changes
/// the image - it only moves which part of it survives a crop that was already
/// going to happen.
///
/// ⚠️ AND IT NEVER OVERRULES THE CLIENT. A photo the client has cropped by hand
/// keeps that crop; this is consulted only where there is no manual one, and
/// only while the client has the setting switched on. See ContentView's
/// `effectivePhotoCrops`.
enum FaceFraming {

    // MARK: - The geometry, with no Vision in it

    /// How small a face may be, relative to the biggest one found, and still
    /// count. A stranger twenty metres behind the couple should not drag the
    /// frame off the couple; a second person standing beside them should.
    static let minRelativeFaceHeight: CGFloat = 0.4

    /// How far below the faces the centred point sits, as a fraction of how
    /// tall the faces are together. Centring the faces exactly leaves a
    /// portrait looking bottom-heavy - the classic headroom rule puts a head
    /// slightly above the middle, and aiming slightly BELOW the faces is what
    /// lifts them there (the focus point is what ends up in the middle).
    static let headroomBias: CGFloat = 0.25

    /// Turns the faces found in a photo into the crop's focus point.
    ///
    /// Input rectangles are Vision's own: normalised 0...1 with the origin at
    /// the BOTTOM-left. The returned point is `MagazinePhotoCrop`'s: normalised
    /// 0...1 with the origin at the TOP-left. Getting that flip wrong reads as
    /// the frame chasing people's feet, so it is done in exactly one place.
    ///
    /// Returns nil when there is nobody to frame, which leaves the default
    /// crop - a blind 15% off the top - exactly as it was.
    static func focusPoint(forFaces faces: [CGRect]) -> CGPoint? {
        let usable = faces.filter { $0.width > 0 && $0.height > 0 }

        guard let tallest = usable.map({ $0.height }).max(), tallest > 0 else {
            return nil
        }

        let kept = usable.filter { $0.height >= tallest * minRelativeFaceHeight }

        guard var union = kept.first else {
            return nil
        }

        for face in kept.dropFirst() {
            union = union.union(face)
        }

        // Vision's y grows upward, the crop's grows downward.
        let centreFromTop = 1 - union.midY
        let biased = centreFromTop + union.height * headroomBias

        return CGPoint(
            x: min(1, max(0, union.midX)),
            y: min(1, max(0, biased))
        )
    }

    /// The crop a photo should get from where its faces are, or nil when there
    /// is nobody in it. `zoom` is deliberately left at 1: this decides WHERE to
    /// look, never how close - cropping in tighter than the client asked for is
    /// a change to their photograph, not a framing choice.
    static func crop(forFaces faces: [CGRect]) -> MagazinePhotoCrop? {
        guard let point = focusPoint(forFaces: faces) else {
            return nil
        }

        return MagazinePhotoCrop(focusX: Double(point.x), focusY: Double(point.y), zoom: 1)
    }

    // MARK: - Vision

    /// The longest side the detector is given. Faces are found by shape, not by
    /// pixel count, and a 5176px RAW preview costs memory this machine does not
    /// have to spare (8 GB - see the notes). 1024 finds a face that is 4% of the
    /// frame, which is far smaller than anything `minRelativeFaceHeight` keeps.
    static let detectionMaxSide: CGFloat = 1024

    /// Runs Vision over one photo. Empty means "nobody found", which the caller
    /// must treat as "leave the crop alone" rather than as a failure.
    ///
    /// ⚠️ Call this OFF the main thread. It is synchronous, and on a folder of
    /// two hundred photos it is two hundred detections.
    static func detectFaces(in image: NSImage) -> [CGRect] {
        guard let cgImage = downscaledCGImage(from: image) else {
            return []
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            // A photo Vision cannot read is not an error worth stopping for -
            // it simply keeps the crop it already had.
            return []
        }

        return (request.results ?? []).map { $0.boundingBox }
    }

    /// Both halves in one call, for the background pass in ContentView.
    static func crop(for image: NSImage) -> MagazinePhotoCrop? {
        crop(forFaces: detectFaces(in: image))
    }

    private static func downscaledCGImage(from image: NSImage) -> CGImage? {
        guard let full = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = CGFloat(full.width)
        let height = CGFloat(full.height)
        let longest = max(width, height)

        guard longest > detectionMaxSide, longest > 0 else {
            return full
        }

        let scale = detectionMaxSide / longest
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return full
        }

        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        return context.makeImage() ?? full
    }
}
