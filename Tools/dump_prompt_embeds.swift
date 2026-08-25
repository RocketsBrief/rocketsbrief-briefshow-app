// One-shot build tool: bakes the Remove tool's FIXED prompt pair into the
// blob BriefShow ships, so the app needs neither a BPE tokenizer nor the
// 235 MB TextEncoder at runtime. Re-run it whenever the prompt is tuned.
//
//   python3 clip_tokenize.py "<negative>" "<positive>"   # ids, in that order
//   swift dump_prompt_embeds.swift <negIds> <posIds> SD15-Inpainting out.bin
//
// Output layout is the UNet's, not the text encoder's: [2, 768, 1, 77] of
// Float16, batch 0 = uncond, batch 1 = cond -- the order classifier-free
// guidance assumes, and the reason the converted UNet has a fixed batch of 2.

import CoreML
import Foundation

let context = 77, width = 768

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 5 else {
    fail("usage: dump_prompt_embeds.swift <negIds> <posIds> <bundleDir> <out.bin>")
}
let bundle = URL(fileURLWithPath: args[3])
let output = URL(fileURLWithPath: args[4])

let prompts: [[Int32]] = args[1...2].map { list in
    let ids = list.split(separator: ",").compactMap { Int32($0) }
    guard ids.count == context else { fail("expected \(context) ids, got \(ids.count)") }
    return ids
}

let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndGPU   // one-off; ANE buys nothing here
let model = try MLModel(contentsOf: bundle.appendingPathComponent("TextEncoder.mlmodelc"),
                        configuration: configuration)

// [2, 768, 1, 77], flat
var packed = [Float](repeating: 0, count: 2 * width * context)

for (batch, ids) in prompts.enumerated() {
    let input = try MLMultiArray(shape: [1, NSNumber(value: context)], dataType: .float32)
    for (i, id) in ids.enumerated() { input[i] = NSNumber(value: Float(id)) }

    let out = try model.prediction(from: try MLDictionaryFeatureProvider(
        dictionary: ["input_ids": MLFeatureValue(multiArray: input)]))
    guard let hidden = out.featureValue(for: "last_hidden_state")?.multiArrayValue else {
        fail("model gave no last_hidden_state")
    }
    guard hidden.count == context * width else {
        fail("unexpected last_hidden_state count \(hidden.count)")
    }

    // [1, 77, 768] -> [768, 77], i.e. token-major to channel-major.
    hidden.withUnsafeBufferPointer(ofType: Float.self) { source in
        let base = batch * width * context
        for token in 0..<context {
            for channel in 0..<width {
                packed[base + channel * context + token] = source[token * width + channel]
            }
        }
    }
}

var halves = packed.map { Float16($0) }
let data = halves.withUnsafeBufferPointer { Data(buffer: $0) }
try data.write(to: output)

let magnitude = packed.map { abs($0) }.max() ?? 0
print("wrote \(data.count) bytes to \(output.path)  (peak |value| \(magnitude))")
