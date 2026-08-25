import Foundation

// CLIP's byte-pair tokenizer, needed the moment the AI Remove prompt became
// editable: a prompt the user typed cannot have its embedding baked ahead of
// time, so the app has to turn text into token ids itself.
//
// A direct port of CoreMLModels/clip_tokenize.py, and it reads the same
// vocab.json / merges.txt out of the model bundle, so the two cannot drift
// apart -- the Python one still bakes the default prompt's embedding, and this
// one handles everything the user types instead.
struct CLIPTokenizer {

    static let contextLength = 77
    private static let startToken = "<|startoftext|>"
    private static let endToken = "<|endoftext|>"

    private let vocabulary: [String: Int32]
    private let ranks: [Pair: Int]
    private let start: Int32
    private let end: Int32

    struct Pair: Hashable {
        let first: String
        let second: String
    }

    enum Failure: Error {
        case missingFiles
    }

    init(directory: URL) throws {
        guard
            let vocabularyData = try? Data(contentsOf: directory.appendingPathComponent("vocab.json")),
            let decoded = try? JSONDecoder().decode([String: Int32].self, from: vocabularyData),
            let mergeText = try? String(contentsOf: directory.appendingPathComponent("merges.txt"), encoding: .utf8),
            let startID = decoded[Self.startToken], let endID = decoded[Self.endToken]
        else {
            throw Failure.missingFiles
        }
        vocabulary = decoded
        start = startID
        end = endID

        // First line is a "#version:" header; every other line is one merge.
        var table = [Pair: Int]()
        for (index, line) in mergeText.split(separator: "\n").dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            table[Pair(first: String(parts[0]), second: String(parts[1]))] = index
        }
        ranks = table
    }

    // CLIP works on a printable-only view of raw bytes, so every byte survives
    // a round trip through a String without landing on whitespace or a control
    // character.
    private static let byteEncoder: [UInt8: Character] = {
        var printable = Array(UInt8(33)...UInt8(126)) + Array(UInt8(161)...UInt8(172)) + Array(UInt8(174)...UInt8(255))
        var mapped = printable.map { Int($0) }
        var next = 0
        for byte in 0...255 where !printable.contains(UInt8(byte)) {
            printable.append(UInt8(byte))
            mapped.append(256 + next)
            next += 1
        }
        var table = [UInt8: Character]()
        for (byte, scalar) in zip(printable, mapped) {
            table[byte] = Character(UnicodeScalar(scalar)!)
        }
        return table
    }()

    // CLIP's own split pattern. \p{...} classes are spelled out the way the
    // Python port does: [^\W\d_] is "unicode letter", \d is a lone digit, and
    // the last two alternatives take every non-space character that is neither
    // -- punctuation included, which a careless translation silently drops.
    private static let pattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[^\W\d_]+|\d|[^\s\w]+|_+"#,
        options: [.caseInsensitive])

    private func bpe(_ token: String) -> [String] {
        var word = token.map(String.init)
        guard let last = word.popLast() else { return [] }
        word.append(last + "</w>")

        while word.count > 1 {
            var bestRank = Int.max
            var bestIndex = -1
            for index in 0..<(word.count - 1) {
                if let rank = ranks[Pair(first: word[index], second: word[index + 1])], rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            word[bestIndex] = word[bestIndex] + word[bestIndex + 1]
            word.remove(at: bestIndex + 1)
        }
        return word
    }

    /// Token ids, always exactly `contextLength` of them: SOT, the text, EOT,
    /// then EOT again as padding (SD pads with the end token, not a dedicated
    /// pad id). Anything longer than the context is truncated, keeping a final
    /// EOT — the same thing diffusers does, and the reason a very long prompt
    /// quietly loses its tail rather than failing.
    func encode(_ text: String) -> [Int32] {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var ids: [Int32] = [start]
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for match in Self.pattern.matches(in: cleaned, range: range) {
            guard let matchRange = Range(match.range, in: cleaned) else { continue }
            let encoded = String(String(cleaned[matchRange]).utf8.compactMap { Self.byteEncoder[$0] })
            for piece in bpe(encoded) {
                if let id = vocabulary[piece] { ids.append(id) }
            }
        }
        ids.append(end)

        if ids.count > Self.contextLength {
            ids = Array(ids.prefix(Self.contextLength - 1)) + [end]
        }
        return ids + Array(repeating: end, count: Self.contextLength - ids.count)
    }
}
