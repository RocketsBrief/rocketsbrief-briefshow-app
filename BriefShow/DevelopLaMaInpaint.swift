import CoreImage
import CoreML
import Foundation

// LaMa (big-lama, Samsung Research, Apache-2.0) as "Quick AI Clean Up".
//
// The counterpart to the Stable Diffusion path, and deliberately nothing like
// it: LaMa is not a diffusion model. One forward pass, no sampler, no prompt,
// no guidance — so it finishes in about a second instead of thirteen, and it
// runs on machines that have no Neural Engine at all. That last part is the
// reason it exists here: on an Intel Mac, SD takes minutes and is not a
// feature anyone would use, while this stays instant.
//
// It ships INSIDE the app (99 MB), so unlike the SD path it needs no download
// and works the moment BriefShow is installed.
//
// Everything around it is the same frame the other two erases use — mask,
// region, alpha-cut ImageLayer — so all three produce an identical kind of
// layer and the render pipeline never learns which one ran.

final class LaMaInpaintPipeline {

    enum Failure: Error, LocalizedError {
        case modelMissing
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "The Quick AI Clean Up model is missing from this build."
            case .badOutput(let detail):
                return "The Quick AI Clean Up model returned unexpected output (\(detail))."
            }
        }
    }

    // Fixed by the conversion, same as the SD models: Core ML wants a shape.
    // LaMa itself is fully convolutional and would take any size, so this is
    // the one place a future version could get cheaply better.
    static let imageSide = 512

    static let shared = LaMaInpaintPipeline()
    private init() {}

    private var model: MLModel?
    private let loadLock = NSLock()

    /// Compiled into the app bundle by Xcode from LaMa.mlpackage. The
    /// development copy under CoreMLModels is only a fallback so the model can
    /// be swapped and tested without a rebuild.
    private static func modelURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc") {
            return bundled
        }
        let development = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/BriefShow/CoreMLModels/LaMa/LaMa.mlmodelc")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    static var isAvailable: Bool { modelURL() != nil }

    func prepare() throws {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard model == nil else { return }
        guard let url = Self.modelURL() else { throw Failure.modelMissing }

        let configuration = MLModelConfiguration()
        // Not .cpuAndNeuralEngine: LaMa's fast Fourier convolutions have no
        // Neural Engine implementation (the compiler says so out loud during
        // conversion), so asking for the ANE only buys a failed compile and a
        // fallback. The GPU is where this belongs on every Mac that has one,
        // and Core ML drops to the CPU by itself on the ones that do not.
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    func warmUp() {
        guard Self.isAvailable else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.prepare()
        }
    }

    /// Repairs `buffers` in place: every pixel the mask marks as hole
    /// (`known == 0`) is replaced with model output, everything else is left
    /// byte-identical so the caller's alpha cut still lands on real photo.
    func fill(_ buffers: inout ExemplarInpainter.Buffers) throws {
        try prepare()
        guard let model else { throw Failure.modelMissing }
        let side = Self.imageSide
        guard buffers.width == side, buffers.height == side else {
            throw Failure.badOutput("buffers are \(buffers.width)x\(buffers.height), expected \(side)x\(side)")
        }
        let pixelCount = side * side

        // The photo as-is, in 0...1. The traced model does the masking itself —
        // multiplying the hole out and concatenating the mask as a fourth
        // channel — precisely so this side cannot get the convention backwards.
        let image = try MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let mask = try MLMultiArray(
            shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        image.withUnsafeMutableBytes { raw, _ in
            let destination = raw.bindMemory(to: Float.self)
            for index in 0..<pixelCount {
                for channel in 0..<3 {
                    destination[channel * pixelCount + index] =
                        Float(buffers.pixels[index * 4 + channel]) / 255
                }
            }
        }
        mask.withUnsafeMutableBytes { raw, _ in
            let destination = raw.bindMemory(to: Float.self)
            // 1 = repaint, which is the opposite of `known`.
            for index in 0..<pixelCount {
                destination[index] = buffers.known[index] == 0 ? 1 : 0
            }
        }

        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: image),
            "mask": MLFeatureValue(multiArray: mask)
        ]))
        guard let output = prediction.featureValue(for: "output")?.multiArrayValue,
              output.count == 3 * pixelCount else {
            throw Failure.badOutput("no usable output")
        }

        var pixels = [Float](repeating: 0, count: 3 * pixelCount)
        output.withUnsafeBufferPointer(ofType: Float.self) { source in
            for index in 0..<(3 * pixelCount) { pixels[index] = source[index] * 255 }
        }

        // Same correction as the SD path, for the same reason: the model
        // rebuilds the known pixels too, so how far its version of them drifted
        // from the real ones is exactly how far to pull the patch back.
        let correction = InpaintPipeline.toneMatch(decoded: pixels, buffers: buffers, side: side)
        for index in 0..<pixelCount where buffers.known[index] == 0 {
            for channel in 0..<3 {
                let (gain, offset) = correction[channel]
                let value = gain * pixels[channel * pixelCount + index] + offset
                if let byte = InpaintPipeline.byteFromModel(value) {
                    buffers.pixels[index * 4 + channel] = byte
                }
            }
            buffers.pixels[index * 4 + 3] = 255
        }
    }
}

// MARK: - The Remove tool's fast button

extension InpaintPipeline {

    /// The LaMa counterpart to `aiRemoval`, returning the same `Removal` so the
    /// two AI buttons are interchangeable at every call site.
    ///
    /// Same contract as the others: `image` must be the FULL, PRE-CROP render.
    static func quickAIRemoval(
        mask: CIImage,
        from image: CIImage,
        context: CIContext,
        feather: Double = SDInpaintPipeline.defaultFeather,
        shouldContinue: @escaping () -> Bool = { true }
    ) throws -> Removal? {
        let extent = image.extent
        guard extent.width >= 8, extent.height >= 8 else { return nil }
        let grownMask = SubjectMasker.grown(mask, by: max(extent.width, extent.height) * 0.0025)
        guard let maskBox = maskBoundingBox(grownMask, extent: extent, context: context),
              let region = squareRegion(around: maskBox, in: extent) else {
            return nil
        }

        let side = LaMaInpaintPipeline.imageSide
        guard var buffers = makeBuffers(
            image: image, mask: grownMask, region: region,
            width: side, height: side, context: context
        ) else {
            return nil
        }

        let originalKnown = buffers.known
        try LaMaInpaintPipeline.shared.fill(&buffers)
        guard shouldContinue() else { return nil }

        return package(
            buffers: buffers, originalKnown: originalKnown,
            region: region, imageExtent: extent,
            growRadius: 2, blurRadius: featherRadius(feather, originalKnown: originalKnown, side: side),
            // The client's own observation was that Quick is soft in exactly
            // the same way Generative is, which is what pointed at the shared
            // cause: this path runs at 1100 and is stretched back too.
            detailSource: (image, context))
    }
}
