import CoreImage
import CoreML
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Stable Diffusion 1.5 inpainting, on the machine, as the "Erase (AI)" half
// of the Remove tool.
//
// This file is deliberately ONLY the middle of the job. Everything around it
// — growing the mask, finding its bounding box, cutting the working region,
// and packing the result into an alpha-cut ImageLayer — already exists in
// DevelopInpaint.swift and is shared with the exemplar path, so the two
// erases produce the same kind of layer and the render pipeline never learns
// that a model was involved. What SD replaces is exactly one call:
// ExemplarInpainter.fill().
//
// The prompt is normally invisible: AI Remove is one button, and the default
// prompt below is what it always asks for. A gear in the panel reveals it for
// anyone who wants to say what should be behind the thing they removed.
//
// The default pair's CLIP embedding is still BAKED, by
// CoreMLModels/dump_prompt_embeds.swift, into a 231 KB blob — so the ordinary
// one-button path never loads the 235 MB text encoder at all. Editing the
// prompt is what pulls it (and DevelopCLIPTokenizer.swift) into play.

// MARK: - Where the weights live

enum SDModelStore {

    static let folderName = "SD15-Inpainting"
    static let embedsName = "sd_prompt_embeds.bin"

    // Where a first-run download will put them. Sandboxed, so this is the
    // container's Application Support, not the user's real one.
    static var installedDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BriefShow/CoreMLModels/\(folderName)", isDirectory: true)
    }

    // Development only: the converted bundle sitting next to the repo, kept
    // out of BriefShow/BriefShow/ on purpose (that folder is a file system
    // synchronized group, so anything inside it would be copied into the app
    // bundle and make a 2 GB app). Checked SECOND, so an installed copy
    // always wins and this quietly stops mattering once downloading works.
    static var developmentDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/BriefShow/CoreMLModels/\(folderName)", isDirectory: true)
    }

    // A directory only counts if every model that can be needed is in it.
    // TextEncoder is on the list because the prompt is editable — text the
    // user typed has no baked embedding — but it is only ever LOADED when the
    // prompt actually differs from the default; see `embeddings(prompt:)`.
    private static func isComplete(_ directory: URL) -> Bool {
        ["Unet.mlmodelc", "VAEEncoder.mlmodelc", "VAEDecoder.mlmodelc", "TextEncoder.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func resolve() -> URL? {
        [installedDirectory, developmentDirectory].first(where: isComplete)
    }

    static var isAvailable: Bool { resolve() != nil }

    // Ships in the app bundle (it is our content, not the model's), with the
    // model directory as a fallback so a freshly converted bundle can be
    // tested without a rebuild.
    static func promptEmbedsURL(modelDirectory: URL) -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "sd_prompt_embeds", withExtension: "bin"),
            modelDirectory.appendingPathComponent(embedsName),
            developmentDirectory.deletingLastPathComponent().appendingPathComponent(embedsName)
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

// MARK: - Scheduler

// DDIM, which is the whole of the sampler in about forty lines. Chosen over
// PNDM (the diffusers default for this checkpoint) and DPM-Solver++ because
// at the 30 steps this tool runs the three are visually indistinguishable for
// inpainting, and DDIM is the one whose correctness can be read off the page.
// With eta = 0 it is also deterministic, which is what makes a fixed seed
// reproduce a removal exactly. If step count ever needs to come down for
// speed, DPM-Solver++ 2M is the upgrade that buys it.
struct DDIMScheduler {

    static let trainSteps = 1000
    private static let betaStart = 0.00085
    private static let betaEnd = 0.012

    let timesteps: [Int]
    private let alphasCumprod: [Double]
    private let stride: Int

    init(steps: Int) {
        // "scaled_linear": SD interpolates the SQUARE ROOT of beta, not beta.
        // Getting this wrong still produces an image, just a subtly wrong one,
        // which is the worst kind of bug to chase — hence spelling it out.
        var cumulative = 1.0
        var table = [Double]()
        table.reserveCapacity(Self.trainSteps)
        for index in 0..<Self.trainSteps {
            let position = Double(index) / Double(Self.trainSteps - 1)
            let root = Foundation.sqrt(Self.betaStart)
                + position * (Foundation.sqrt(Self.betaEnd) - Foundation.sqrt(Self.betaStart))
            cumulative *= (1 - root * root)
            table.append(cumulative)
        }
        alphasCumprod = table

        stride = max(Self.trainSteps / max(steps, 1), 1)
        timesteps = Self.schedule(steps: steps)
    }

    // "Trailing" timestep spacing, and it is what makes a low step count
    // possible at all. The obvious "leading" spacing (i * 1000/steps + 1)
    // STARTS BELOW the top of the schedule — at 30 steps it begins at t=958,
    // at 15 at t=925 — while the latent it is handed is pure standard normal,
    // which belongs at t=999. The model is told the noise is milder than it
    // is, and with few steps it never recovers: the result collapses into
    // black-and-white crackle. Trailing always starts at 999, so the first
    // step is honest and 12 steps hold where 15 leading ones did not.
    static func schedule(steps: Int) -> [Int] {
        let count = max(steps, 1)
        return (0..<count).map {
            max(Int((1000.0 - Double($0) * 1000.0 / Double(count)).rounded()) - 1, 0)
        }
    }

    // x_t -> x_{t-1}, eta = 0. `noise` is the guided epsilon prediction.
    func step(sample: [Float], noise: [Float], timestep: Int) -> [Float] {
        let alpha = alphasCumprod[min(max(timestep, 0), Self.trainSteps - 1)]
        // With trailing spacing the gap between the last two timesteps is the
        // same `stride`, so stepping back by it still lands on the right rung.
        let previous = timestep - stride
        // set_alpha_to_one = false for this checkpoint: below the first
        // timestep the schedule falls back to alphas_cumprod[0], not 1.0.
        let alphaPrevious = previous >= 0 ? alphasCumprod[previous] : alphasCumprod[0]

        let sqrtAlpha = Float(Foundation.sqrt(alpha))
        let sqrtOneMinusAlpha = Float(Foundation.sqrt(1 - alpha))
        let sqrtAlphaPrevious = Float(Foundation.sqrt(alphaPrevious))
        let sqrtOneMinusAlphaPrevious = Float(Foundation.sqrt(1 - alphaPrevious))

        var output = [Float](repeating: 0, count: sample.count)
        for index in 0..<sample.count {
            // No sample clipping: clip_sample is false for SD 1.5.
            let original = (sample[index] - sqrtOneMinusAlpha * noise[index]) / sqrtAlpha
            output[index] = sqrtAlphaPrevious * original + sqrtOneMinusAlphaPrevious * noise[index]
        }
        return output
    }
}

// DPM-Solver++ (2M), the reason a removal takes ~8 seconds instead of ~17.
//
// DDIM needs about 30 steps here: at 20 it still holds, and at 15 it collapses
// into high-frequency black-and-white noise — an under-converged denoise, and
// a cliff rather than a slope, which is exactly what you cannot ship. This
// solver reuses the previous step's x0 estimate to take a second-order step,
// so it reaches the same place in roughly half the model calls.
//
// It works in the log-SNR variable lambda = log(alpha / sigma), where the
// diffusion ODE is semi-linear and the alpha/sigma part can be integrated
// exactly; only the x0 term is approximated, and 2M approximates it with a
// line through the last two estimates instead of a point.
struct DPMSolverMultistep {

    static let trainSteps = 1000
    private static let betaStart = 0.00085
    private static let betaEnd = 0.012

    let timesteps: [Int]
    private let alpha: [Double]      // sqrt(alphas_cumprod), per step
    private let sigma: [Double]      // sqrt(1 - alphas_cumprod), per step
    private let lambda: [Double]     // log(alpha / sigma)
    private var previousX0: [Float]?

    init(steps: Int) {
        // Same "scaled_linear" schedule as DDIM — SD interpolates the SQUARE
        // ROOT of beta — and the same leading-offset timesteps, so switching
        // solvers changes only how the trajectory is integrated.
        var cumulative = 1.0
        var table = [Double]()
        table.reserveCapacity(Self.trainSteps)
        for index in 0..<Self.trainSteps {
            let position = Double(index) / Double(Self.trainSteps - 1)
            let root = Foundation.sqrt(Self.betaStart)
                + position * (Foundation.sqrt(Self.betaEnd) - Foundation.sqrt(Self.betaStart))
            cumulative *= (1 - root * root)
            table.append(cumulative)
        }

        let schedule = DDIMScheduler.schedule(steps: steps)
        timesteps = schedule
        alpha = schedule.map { Foundation.sqrt(table[$0]) }
        sigma = schedule.map { Foundation.sqrt(1 - table[$0]) }
        lambda = zip(alpha, sigma).map { Foundation.log($0) - Foundation.log($1) }
    }

    /// One step, from the sample at `timesteps[index]` to the next one.
    /// `noise` is the guided epsilon prediction.
    mutating func step(sample: [Float], noise: [Float], index: Int) -> [Float] {
        let count = sample.count
        let alphaNow = Float(alpha[index]), sigmaNow = Float(sigma[index])

        // The solver works on x0 estimates, not on epsilon.
        var x0 = [Float](repeating: 0, count: count)
        for i in 0..<count { x0[i] = (sample[i] - sigmaNow * noise[i]) / alphaNow }

        let isLast = index == timesteps.count - 1
        // First order on the first step (no history yet) and on the last one.
        // The last step lands on sigma = 0, where the second-order term
        // divides by an infinite log-SNR gap — diffusers calls this
        // `lower_order_final` and it is not optional.
        let firstOrder = isLast || previousX0 == nil

        var output = [Float](repeating: 0, count: count)
        if isLast {
            // sigma_next = 0, alpha_next = 1: the step reduces to the estimate.
            output = x0
        } else {
            let gap = lambda[index + 1] - lambda[index]
            let carry = Float(sigma[index + 1] / sigma[index])
            let weight = Float(alpha[index + 1] * (1 - Foundation.exp(-gap)))

            if firstOrder {
                for i in 0..<count { output[i] = carry * sample[i] + weight * x0[i] }
            } else {
                let previousGap = lambda[index] - lambda[index - 1]
                // The slope of x0 in lambda, from the last two estimates.
                let slope = Float(0.5 * (gap / previousGap))
                let previous = previousX0!
                for i in 0..<count {
                    let corrected = x0[i] + slope * (x0[i] - previous[i])
                    output[i] = carry * sample[i] + weight * corrected
                }
            }
        }
        previousX0 = x0
        return output
    }
}

// MARK: - Deterministic gaussian noise

// Its own generator rather than SystemRandomNumberGenerator so a seed
// reproduces a removal. It does NOT reproduce torch's randn, so a Core ML
// result will differ in detail from the Python prototype's even at the same
// seed — same distribution, different draw.
struct SeededGaussian {

    private var state: UInt64
    private var spare: Float?

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    private mutating func nextUniform() -> Double {
        // SplitMix64
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        // (0, 1]: Box-Muller takes a log of this, so zero must not appear.
        return (Double(z >> 11) + 1) / 9007199254740993.0
    }

    mutating func next() -> Float {
        if let value = spare {
            spare = nil
            return value
        }
        let radius = Foundation.sqrt(-2 * Foundation.log(nextUniform()))
        let angle = 2 * Double.pi * nextUniform()
        spare = Float(radius * Foundation.sin(angle))
        return Float(radius * Foundation.cos(angle))
    }

    mutating func fill(_ count: Int) -> [Float] {
        var values = [Float](repeating: 0, count: count)
        for index in 0..<count { values[index] = next() }
        return values
    }
}

// MARK: - The pipeline

final class SDInpaintPipeline {

    enum Failure: Error, LocalizedError {
        case modelsMissing
        case promptEmbedsMissing
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .modelsMissing:
                return "The AI erase model is not installed yet."
            case .promptEmbedsMissing:
                return "The AI erase model is installed but its prompt data is missing."
            case .badOutput(let detail):
                return "The AI erase model returned unexpected output (\(detail))."
            }
        }
    }

    // Fixed by the conversion: this checkpoint was converted at one size and
    // the .mlmodelc input shapes are not flexible, so every removal is done
    // on a 512x512 view of the region regardless of the photo's resolution.
    static let imageSide = 512
    static let latentSide = 64
    static let latentChannels = 4
    static let contextLength = 77
    static let embedWidth = 768

    /// What AI Remove asks for when the user has not changed anything. It reads
    /// oddly for a removal tool, and that is the point: CLIP has no notion of
    /// an instruction, so the prompt must NAME WHAT SHOULD BE THERE rather than
    /// describe the edit. Instruction-shaped text ("remove the selected object,
    /// match the lighting...") is read as a list of things to paint, and SD
    /// duly paints them -- measured, it produces signage and stock textures.
    static let defaultPrompt = "empty background, seamless continuation, no people"

    /// Pushed AGAINST, not for. Keeps the model from filling a person-shaped
    /// hole with another person, which is its first instinct.
    static let defaultNegativePrompt = "person, people, human, face, text, watermark"

    // 0.18215 is SD 1.5's VAE scaling constant; guidance 7.5 and 30 steps are
    // the prototype's recipe, confirmed on the user's own photos.
    static let latentScale: Float = 0.18215
    static let guidanceScale: Float = 7.5
    /// Twelve, not the thirty the prototype used, because DPM-Solver++ with
    /// trailing timesteps gets there in far fewer model calls — verified
    /// against the 30-step result on the user's own photos, and still clean at
    /// 8, so this leaves margin rather than sitting on the edge.
    static let defaultSteps = 12

    /// How far the repaired patch fades into the photo at its edge, 0...1.
    /// Wider than the exemplar path's fixed 3 pixels on purpose: that path
    /// copies real pixels out of the same photo, so its edges already match,
    /// while SD regenerates the area and lands a hair off in tone — which a
    /// hard edge turns into a visible rectangle.
    static let defaultFeather = 0.35

    // Loading the 1.6 GB UNet is ~18 seconds of Neural Engine compilation, so
    // the models are loaded once and kept. `warmUp()` moves that cost to the
    // moment Develop opens, where nobody is waiting on it, instead of onto
    // the first click of AI Remove, where everybody is.
    static let shared = SDInpaintPipeline()
    private init() {}

    private var unet: MLModel?
    private var vaeEncoder: MLModel?
    private var vaeDecoder: MLModel?
    private var promptEmbeds: MLMultiArray?
    // Loaded only if someone edits the prompt; the default's embedding is
    // baked, so the common path never pulls 235 MB of text encoder into RAM.
    private var textEncoder: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var encodedPrompts: [String: MLMultiArray] = [:]
    private let loadLock = NSLock()

    var isModelInstalled: Bool { SDModelStore.isAvailable }

    /// Loads the models in the background if they are installed and not loaded
    /// yet. Safe to call repeatedly and safe to call when nothing is
    /// installed — it simply does nothing, so no caller has to check first.
    func warmUp() {
        guard SDModelStore.isAvailable else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.prepare()
        }
    }

    // Set BRIEFSHOW_SD_DEBUG=1 to have every stage print its range. Diffusion
    // fails silently — a wrong sign or a bad scale still produces AN image —
    // so the only cheap way to tell a working pipeline from a plausible-
    // looking broken one is to watch the numbers.
    private static let debugging = !(ProcessInfo.processInfo.environment["BRIEFSHOW_SD_DEBUG"] ?? "").isEmpty

    // Diagnostic only: the whole 512x512 working buffer, before it is cut down
    // to the hole, written next to the models so a round trip can be looked at.
    fileprivate static func dumpDebugPNG(_ buffers: ExemplarInpainter.Buffers, named name: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        var pixels = buffers.pixels
        guard let provider = CGDataProvider(data: Data(bytes: &pixels, count: pixels.count) as CFData),
              let cgImage = CGImage(
                width: buffers.width, height: buffers.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: buffers.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        print("  [sd] wrote \(url.path)")
    }

    private static func report(_ label: String, _ values: [Float]) {
        guard debugging, !values.isEmpty else { return }
        let mean = values.reduce(0, +) / Float(values.count)
        let deviation = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)).squareRoot()
        print(String(format: "  [sd] %@  min %.3f  max %.3f  mean %.3f  sd %.3f",
                     label, values.min() ?? 0, values.max() ?? 0, mean, deviation))
    }

    func prepare() throws {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard unet == nil else { return }

        guard let directory = SDModelStore.resolve() else { throw Failure.modelsMissing }

        // The UNet is converted ANE-friendly and is ~95% of the compute; the
        // VAE passes run once each and are quicker on the GPU.
        let aneConfiguration = MLModelConfiguration()
        aneConfiguration.computeUnits = ProcessInfo.processInfo.environment["BRIEFSHOW_SD_UNET"] == "gpu"
            ? .cpuAndGPU : .cpuAndNeuralEngine
        let gpuConfiguration = MLModelConfiguration()
        gpuConfiguration.computeUnits = .cpuAndGPU

        func model(_ name: String, _ configuration: MLModelConfiguration) throws -> MLModel {
            try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: configuration)
        }

        let loadedUnet = try model("Unet.mlmodelc", aneConfiguration)
        let loadedEncoder = try model("VAEEncoder.mlmodelc", gpuConfiguration)
        let loadedDecoder = try model("VAEDecoder.mlmodelc", gpuConfiguration)

        // Optional now: without it the default prompt just goes through the
        // text encoder like any other, costing a load instead of failing.
        var embeds = SDModelStore.promptEmbedsURL(modelDirectory: directory)
            .flatMap { try? loadPromptEmbeds(from: $0) }
        if ProcessInfo.processInfo.environment["BRIEFSHOW_SD_EMBEDS"] == "zero" {
            // Nothing to do with any prompt: zeroed hidden states are the one
            // conditioning that cannot be blamed on the dump tool.
            embeds = try? MLMultiArray(
                shape: [2, NSNumber(value: Self.embedWidth), 1, NSNumber(value: Self.contextLength)],
                dataType: .float16)
            embeds?.withUnsafeMutableBytes { raw, _ in raw.initializeMemory(as: UInt8.self, repeating: 0) }
        }

        unet = loadedUnet
        vaeEncoder = loadedEncoder
        vaeDecoder = loadedDecoder
        promptEmbeds = embeds
    }

    // The blob is already in the UNet's layout — [2, 768, 1, 77] Float16,
    // batch 0 uncond, batch 1 cond — so this is a size check and a copy.
    private func loadPromptEmbeds(from url: URL) throws -> MLMultiArray {
        let data = try Data(contentsOf: url)
        let expected = 2 * Self.embedWidth * Self.contextLength
        guard data.count == expected * MemoryLayout<Float16>.size else {
            throw Failure.badOutput("prompt embeds are \(data.count) bytes, expected \(expected * 2)")
        }
        let array = try MLMultiArray(
            shape: [2, NSNumber(value: Self.embedWidth), 1, NSNumber(value: Self.contextLength)],
            dataType: .float16)
        array.withUnsafeMutableBytes { raw, _ in
            _ = data.copyBytes(to: raw.bindMemory(to: UInt8.self))
        }
        return array
    }

    /// The conditioning for one erase. The default pair comes from the baked
    /// blob; anything else is tokenised and run through the text encoder here,
    /// then cached, so re-erasing with the same custom prompt is free.
    private func embeddings(prompt: String, negative: String) throws -> MLMultiArray {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = negative.trimmingCharacters(in: .whitespacesAndNewlines)
        // BRIEFSHOW_SD_NOBLOB=1 forces even the default prompt through the text
        // encoder, so the baked blob and the live path can be checked against
        // each other — they must produce byte-identical results.
        let allowBlob = ProcessInfo.processInfo.environment["BRIEFSHOW_SD_NOBLOB"] != "1"
        if allowBlob, prompt == Self.defaultPrompt, negative == Self.defaultNegativePrompt, let promptEmbeds {
            return promptEmbeds
        }
        let key = negative + "\u{0}" + prompt
        if let cached = encodedPrompts[key] { return cached }

        guard let directory = SDModelStore.resolve() else { throw Failure.modelsMissing }
        if tokenizer == nil {
            tokenizer = try CLIPTokenizer(directory: directory)
        }
        if textEncoder == nil {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            textEncoder = try MLModel(
                contentsOf: directory.appendingPathComponent("TextEncoder.mlmodelc"),
                configuration: configuration)
        }
        guard let tokenizer, let textEncoder else { throw Failure.modelsMissing }

        // Batch 0 uncond, batch 1 cond -- the order classifier-free guidance
        // assumes, and the reason the converted UNet's batch is fixed at 2.
        let array = try MLMultiArray(
            shape: [2, NSNumber(value: Self.embedWidth), 1, NSNumber(value: Self.contextLength)],
            dataType: .float16)
        for (batch, text) in [negative, prompt].enumerated() {
            let ids = tokenizer.encode(text)
            let input = try MLMultiArray(
                shape: [1, NSNumber(value: Self.contextLength)], dataType: .float32)
            for (index, id) in ids.enumerated() { input[index] = NSNumber(value: Float(id)) }

            let output = try textEncoder.prediction(from: MLDictionaryFeatureProvider(
                dictionary: ["input_ids": MLFeatureValue(multiArray: input)]))
            guard let hidden = output.featureValue(for: "last_hidden_state")?.multiArrayValue,
                  hidden.count == Self.contextLength * Self.embedWidth else {
                throw Failure.badOutput("text encoder gave no usable last_hidden_state")
            }
            // [1, 77, 768] -> [768, 77]: token-major to channel-major, the
            // layout this UNet was converted with.
            hidden.withUnsafeBufferPointer(ofType: Float.self) { source in
                array.withUnsafeMutableBytes { raw, _ in
                    let destination = raw.bindMemory(to: Float16.self)
                    let base = batch * Self.embedWidth * Self.contextLength
                    for token in 0..<Self.contextLength {
                        for channel in 0..<Self.embedWidth {
                            destination[base + channel * Self.contextLength + token] =
                                Float16(source[token * Self.embedWidth + channel])
                        }
                    }
                }
            }
        }
        encodedPrompts[key] = array
        return array
    }

    /// Repairs `buffers` in place: every pixel the mask marks as hole
    /// (`known == 0`) is replaced with model output, everything else is left
    /// byte-identical so the caller's alpha cut still lands on real photo.
    ///
    /// `buffers` must be exactly 512x512 — the caller cuts the region to that
    /// size, because the converted models have no flexible shapes.
    func fill(
        _ buffers: inout ExemplarInpainter.Buffers,
        prompt: String = defaultPrompt,
        negativePrompt: String = defaultNegativePrompt,
        steps: Int = defaultSteps,
        seed: UInt64 = 3,
        progress: ((Int, Int) -> Void)? = nil,
        shouldContinue: () -> Bool = { true }
    ) throws {
        try prepare()
        // Overridable only so the recipe can be swept from the test harness;
        // the shipping defaults are the arguments.
        let guidance = ProcessInfo.processInfo.environment["BRIEFSHOW_SD_GUIDANCE"]
            .flatMap { Float($0) } ?? Self.guidanceScale
        let steps = ProcessInfo.processInfo.environment["BRIEFSHOW_SD_STEPS"]
            .flatMap { Int($0) } ?? steps
        guard let unet, let vaeEncoder, let vaeDecoder else {
            throw Failure.modelsMissing
        }
        let conditioning = try embeddings(prompt: prompt, negative: negativePrompt)
        let side = Self.imageSide
        guard buffers.width == side, buffers.height == side else {
            throw Failure.badOutput("buffers are \(buffers.width)x\(buffers.height), expected \(side)x\(side)")
        }

        // 1. The masked photo, in the [-1, 1] channel-first form the VAE wants,
        //    with the hole flattened to 0 (mid grey) exactly as diffusers does.
        let pixelCount = side * side
        let encoderInput = try MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float16)
        encoderInput.withUnsafeMutableBytes { raw, _ in
            let destination = raw.bindMemory(to: Float16.self)
            for index in 0..<pixelCount {
                let hole = buffers.known[index] == 0
                for channel in 0..<3 {
                    let value = hole
                        ? Float16(0)
                        : Float16(Float(buffers.pixels[index * 4 + channel]) / 127.5 - 1)
                    destination[channel * pixelCount + index] = value
                }
            }
        }
        let encoded = try vaeEncoder.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["x": MLFeatureValue(multiArray: encoderInput)]))
        guard let moments = encoded.featureValue(for: "latent")?.multiArrayValue else {
            throw Failure.badOutput("VAE encoder gave no latent")
        }
        // 8 channels out: the first 4 are the gaussian's mean, the last 4 its
        // log-variance. Taking the mean rather than sampling from it (which is
        // what diffusers does by default) costs nothing — this VAE's variance
        // is tiny — and keeps a seeded removal reproducible.
        let latentCount = Self.latentChannels * Self.latentSide * Self.latentSide
        guard moments.count >= latentCount * 2 else {
            throw Failure.badOutput("VAE encoder gave \(moments.count) values")
        }
        var maskedLatent = [Float](repeating: 0, count: latentCount)
        moments.withUnsafeBufferPointer(ofType: Float.self) { source in
            for index in 0..<latentCount { maskedLatent[index] = source[index] * Self.latentScale }
        }
        Self.report("maskedLatent", maskedLatent)

        // 2. The mask at latent resolution. Max-pooled over each 8x8 block
        //    rather than point-sampled (diffusers uses nearest): a latent cell
        //    that contains ANY of the hole must be marked, or the UNet is told
        //    to keep a cell whose masked-image latent is part grey block, and
        //    that is exactly what leaves a ghost of the removed object.
        // BRIEFSHOW_SD_DEBUG=full masks the entire frame, turning the run into
        // plain text-to-image through this exact loop. If that comes out as a
        // coherent picture, the sampler is right and only the partial-mask
        // case is in question; if it does not, the loop itself is wrong.
        if ProcessInfo.processInfo.environment["BRIEFSHOW_SD_DEBUG"] == "full" {
            for index in 0..<pixelCount { buffers.known[index] = 0 }
            for index in 0..<latentCount { maskedLatent[index] = 0 }
        }
        Self.report("holeFraction", [Float(buffers.known.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }) / Float(pixelCount)])
        var latentMask = [Float](repeating: 0, count: Self.latentSide * Self.latentSide)
        for cellY in 0..<Self.latentSide {
            for cellX in 0..<Self.latentSide {
                var marked: Float = 0
                for y in (cellY * 8)..<(cellY * 8 + 8) where marked == 0 {
                    for x in (cellX * 8)..<(cellX * 8 + 8) where buffers.known[y * side + x] == 0 {
                        marked = 1
                        break
                    }
                }
                latentMask[cellY * Self.latentSide + cellX] = marked
            }
        }

        // BRIEFSHOW_SD_DEBUG=roundtrip skips diffusion entirely and decodes the
        // masked-image latent straight back to pixels. Whatever comes out has
        // been through encode, the 0.18215 scaling, the channel layout and
        // decode -- so if it looks like the photo, everything except the UNet
        // and the scheduler is exonerated in one run.
        if ProcessInfo.processInfo.environment["BRIEFSHOW_SD_DEBUG"] == "roundtrip" {
            try decode(maskedLatent, into: &buffers, everywhere: true, model: vaeDecoder)
            Self.dumpDebugPNG(buffers, named: "sd-roundtrip.png")
            return
        }

        // 3. Denoise. init_noise_sigma is 1 for DDIM, so the starting latent is
        //    plain standard normal.
        var generator = SeededGaussian(seed: seed)
        var latents = generator.fill(latentCount)

        // BRIEFSHOW_SD_SOLVER=ddim falls back to the older, slower solver —
        // kept because it is the one whose correctness can be read straight
        // off the page, so it stays available to check the fast one against.
        let useDDIM = ProcessInfo.processInfo.environment["BRIEFSHOW_SD_SOLVER"] == "ddim"
        var solver = DPMSolverMultistep(steps: steps)
        let ddim = DDIMScheduler(steps: steps)
        let schedule = useDDIM ? ddim.timesteps : solver.timesteps
        let cells = Self.latentSide * Self.latentSide
        let sample = try MLMultiArray(
            shape: [2, 9, NSNumber(value: Self.latentSide), NSNumber(value: Self.latentSide)],
            dataType: .float16)
        let timestepInput = try MLMultiArray(shape: [2], dataType: .float16)
        var guided = [Float](repeating: 0, count: latentCount)

        if Self.debugging {
            print("  [sd] sample strides \(sample.strides.map(\.intValue)) shape \(sample.shape.map(\.intValue))")
            print("  [sd] embeds strides \(conditioning.strides.map(\.intValue)) shape \(conditioning.shape.map(\.intValue))")
        }
        for (index, timestep) in schedule.enumerated() {
            guard shouldContinue() else { return }
            progress?(index, schedule.count)

            // Both halves of the batch get the same 9 channels; only the text
            // embedding differs, which is what makes one pass uncond and the
            // other cond. The converted UNet's batch is fixed at 2 precisely
            // because classifier-free guidance is not optional here.
            sample.withUnsafeMutableBytes { raw, _ in
                let destination = raw.bindMemory(to: Float16.self)
                for batch in 0..<2 {
                    let base = batch * 9 * cells
                    for offset in 0..<latentCount {
                        destination[base + offset] = Float16(latents[offset])
                    }
                    for offset in 0..<cells {
                        destination[base + 4 * cells + offset] = Float16(latentMask[offset])
                    }
                    for offset in 0..<latentCount {
                        destination[base + 5 * cells + offset] = Float16(maskedLatent[offset])
                    }
                }
            }
            timestepInput.withUnsafeMutableBytes { raw, _ in
                let destination = raw.bindMemory(to: Float16.self)
                destination[0] = Float16(timestep)
                destination[1] = Float16(timestep)
            }

            let prediction = try unet.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "sample": MLFeatureValue(multiArray: sample),
                "timestep": MLFeatureValue(multiArray: timestepInput),
                "encoder_hidden_states": MLFeatureValue(multiArray: conditioning)
            ]))
            guard let noise = prediction.featureValue(for: "noise_pred")?.multiArrayValue,
                  noise.count == latentCount * 2 else {
                throw Failure.badOutput("UNet gave no usable noise_pred")
            }
            if Self.debugging, index == 0 {
                print("  [sd] noise strides \(noise.strides.map(\.intValue)) shape \(noise.shape.map(\.intValue))")
            }
            noise.withUnsafeBufferPointer(ofType: Float.self) { source in
                for offset in 0..<latentCount {
                    let uncond = source[offset]
                    let cond = source[latentCount + offset]
                    guided[offset] = uncond + guidance * (cond - uncond)
                }
            }
            if Self.debugging, index % 10 == 0 || index == schedule.count - 1 {
                Self.report("eps t=\(timestep)", guided)
                // At the first step x_t is almost pure noise (alpha is 0.0075),
                // so a sane UNet's epsilon must be nearly x_t itself. Split by
                // mask, because the known half is pinned by the masked-image
                // latents and can look healthy while the free half does not.
                var inHole = [Float](), outside = [Float]()
                var holeIn = [Float](), outIn = [Float]()
                for channel in 0..<Self.latentChannels {
                    for cell in 0..<cells {
                        let at = channel * cells + cell
                        if latentMask[cell] > 0.5 { inHole.append(guided[at]); holeIn.append(latents[at]) }
                        else { outside.append(guided[at]); outIn.append(latents[at]) }
                    }
                }
                func correlation(_ a: [Float], _ b: [Float]) -> Float {
                    guard a.count > 1 else { return .nan }
                    let ma = a.reduce(0, +) / Float(a.count), mb = b.reduce(0, +) / Float(b.count)
                    var num: Float = 0, da: Float = 0, db: Float = 0
                    for i in 0..<a.count {
                        num += (a[i] - ma) * (b[i] - mb)
                        da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb)
                    }
                    return num / (da.squareRoot() * db.squareRoot())
                }
                print(String(format: "  [sd] corr(eps, x_t)  hole %.4f  known %.4f", 
                             correlation(inHole, holeIn), correlation(outside, outIn)))
                Self.report("  latents in hole", holeIn)
                Self.report("  latents outside", outIn)
            }
            latents = useDDIM
                ? ddim.step(sample: latents, noise: guided, timestep: timestep)
                : solver.step(sample: latents, noise: guided, index: index)
            if Self.debugging, index % 10 == 0 || index == schedule.count - 1 {
                Self.report("latents t=\(timestep)", latents)
            }
        }
        guard shouldContinue() else { return }
        progress?(schedule.count, schedule.count)

        // 4. Back to pixels.
        if Self.debugging {
            // The whole frame, not just the hole: if the KNOWN part of the
            // photo comes back intact, denoising works and only the hole's
            // content is in question. If it comes back as noise too, the
            // fault is upstream of any prompt.
            var everything = buffers
            try decode(latents, into: &everything, everywhere: true, model: vaeDecoder)
            Self.dumpDebugPNG(everything, named: "sd-full.png")
        }
        try decode(latents, into: &buffers, everywhere: false, model: vaeDecoder)
    }

    // `everywhere` is only for the round-trip diagnostic; a real erase takes
    // the model's pixels inside the hole and nowhere else.
    private func decode(
        _ latents: [Float],
        into buffers: inout ExemplarInpainter.Buffers,
        everywhere: Bool,
        model vaeDecoder: MLModel
    ) throws {
        let side = Self.imageSide
        let pixelCount = side * side
        let latentCount = Self.latentChannels * Self.latentSide * Self.latentSide
        let decoderInput = try MLMultiArray(
            shape: [1, NSNumber(value: Self.latentChannels),
                    NSNumber(value: Self.latentSide), NSNumber(value: Self.latentSide)],
            dataType: .float16)
        decoderInput.withUnsafeMutableBytes { raw, _ in
            let destination = raw.bindMemory(to: Float16.self)
            for offset in 0..<latentCount { destination[offset] = Float16(latents[offset] / Self.latentScale) }
        }
        let decoded = try vaeDecoder.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["z": MLFeatureValue(multiArray: decoderInput)]))
        guard let image = decoded.featureValue(for: "image")?.multiArrayValue,
              image.count == 3 * pixelCount else {
            throw Failure.badOutput("VAE decoder gave no usable image")
        }

        // Only the hole is taken. Outside it the model's reconstruction is
        // very close to the original but not identical (it has been through
        // the VAE), and letting that spread would show up as a faint
        // rectangle once the layer is composited. That same near-miss on the
        // known pixels is what `toneMatch` below measures the correction from.
        if Self.debugging {
            var decoded = [Float](repeating: 0, count: image.count)
            image.withUnsafeBufferPointer(ofType: Float.self) { source in
                for index in 0..<image.count { decoded[index] = source[index] }
            }
            Self.report("decoded", decoded)
        }
        var pixels = [Float](repeating: 0, count: 3 * pixelCount)
        image.withUnsafeBufferPointer(ofType: Float.self) { source in
            for index in 0..<(3 * pixelCount) { pixels[index] = (source[index] + 1) * 127.5 }
        }

        // `everywhere` is the diagnostic path, which wants the model's raw
        // output — correcting it would hide the very drift it is there to show.
        let correction = everywhere
            ? Array(repeating: (gain: Float(1), offset: Float(0)), count: 3)
            : Self.toneMatch(decoded: pixels, buffers: buffers, side: side)
        for index in 0..<pixelCount where everywhere || buffers.known[index] == 0 {
            for channel in 0..<3 {
                let (gain, offset) = correction[channel]
                let value = gain * pixels[channel * pixelCount + index] + offset
                buffers.pixels[index * 4 + channel] = UInt8(max(0, min(255, value.rounded())))
            }
            buffers.pixels[index * 4 + 3] = 255
        }
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
    private static func toneMatch(
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
                gain = min(max(varianceReal.squareRoot() / varianceModel.squareRoot(), 0.85), 1.18)
            }
            result[channel] = (gain: Float(gain), offset: Float(meanReal - gain * meanModel))
        }

        if debugging {
            let text = result.map { String(format: "x%.3f %+.1f", $0.gain, $0.offset) }.joined(separator: "  ")
            print("  [sd] tone match  \(text)")
        }
        return result
    }
}

// MARK: - The Remove tool's second button

extension InpaintPipeline {

    /// The SD counterpart to `removal(mask:from:context:)`, returning the same
    /// `Removal` so "Erase (AI)" and "Erase (Instant)" are interchangeable at
    /// every call site — both end up as an `ImageLayer` over the untouched
    /// original.
    ///
    /// Same contract as `removal`: `image` must be the FULL, PRE-CROP render.
    static func aiRemoval(
        mask: CIImage,
        from image: CIImage,
        context: CIContext,
        prompt: String = SDInpaintPipeline.defaultPrompt,
        negativePrompt: String = SDInpaintPipeline.defaultNegativePrompt,
        feather: Double = SDInpaintPipeline.defaultFeather,
        steps: Int = SDInpaintPipeline.defaultSteps,
        seed: UInt64 = 3,
        progress: ((Int, Int) -> Void)? = nil,
        shouldContinue: @escaping () -> Bool = { true }
    ) throws -> Removal? {
        let extent = image.extent
        guard extent.width >= 8, extent.height >= 8 else { return nil }

        let grownMask = SubjectMasker.grown(mask, by: max(extent.width, extent.height) * 0.0025)
        guard let maskBox = maskBoundingBox(grownMask, extent: extent, context: context) else {
            return nil
        }

        guard let region = squareRegion(around: maskBox, in: extent) else { return nil }
        let side = SDInpaintPipeline.imageSide
        guard var buffers = makeBuffers(
            image: image, mask: grownMask, region: region,
            width: side, height: side, context: context
        ) else {
            return nil
        }

        let originalKnown = buffers.known
        try SDInpaintPipeline.shared.fill(
            &buffers, prompt: prompt, negativePrompt: negativePrompt,
            steps: steps, seed: seed, progress: progress, shouldContinue: shouldContinue)
        guard shouldContinue() else { return nil }

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
        return package(
            buffers: buffers, originalKnown: originalKnown,
            region: region, imageExtent: extent,
            growRadius: 2, blurRadius: radius)
    }

    /// A square window around the hole, because the converted models only
    /// accept 512x512 and a non-square region would be squashed into it.
    ///
    /// The side is twice the hole's longest edge — the prototype's ratio, and
    /// enough surrounding photo for the model to see what it is continuing —
    /// clamped to the frame and then slid (not shrunk) back inside it, so a
    /// subject against the edge keeps its full context instead of losing half
    /// of it to the crop.
    static func squareRegion(around maskBox: CGRect, in extent: CGRect) -> CGRect? {
        let limit = min(extent.width, extent.height)
        guard limit >= 8 else { return nil }

        // Never SMALLER than the 512 the models run at: a smaller window would
        // be upscaled into them, and the model would be reading a blurred,
        // detail-free version of the photo — which is exactly when SD stops
        // continuing the scene and starts inventing. Twice the hole is the
        // context ratio the prototype used; 512 is the floor.
        let side = min(max(max(maskBox.width, maskBox.height) * 2, CGFloat(SDInpaintPipeline.imageSide)), limit).rounded()
        let centre = CGPoint(x: maskBox.midX, y: maskBox.midY)
        var origin = CGPoint(x: centre.x - side / 2, y: centre.y - side / 2)
        origin.x = min(max(origin.x, extent.minX), extent.maxX - side)
        origin.y = min(max(origin.y, extent.minY), extent.maxY - side)

        let region = CGRect(x: origin.x, y: origin.y, width: side, height: side).integral
        return region.width >= 8 && region.height >= 8 ? region : nil
    }
}
