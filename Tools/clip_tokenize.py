#!/usr/bin/env python3
"""CLIP BPE tokenizer, pure stdlib.

Only exists to feed token ids to dump_prompt_embeds.swift, which bakes the
Remove tool's FIXED prompt pair into a blob the app ships. Nothing here runs
at app runtime -- that is the whole point: no tokenizer, and no 235 MB
TextEncoder, inside BriefShow.

Reads vocab.json / merges.txt straight out of the converted model bundle,
so it can never drift from the text encoder those weights belong to.

  python3 clip_tokenize.py "empty background" "person, people"
"""
import json, os, re, sys, unicodedata

# Same sibling-directory arrangement as convert_lama.py: the vocabulary comes
# out of the converted model bundle, which is too large to keep in this repo.
BUNDLE = os.path.join(
    os.environ.get(
        "BRIEFSHOW_MODELS",
        os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                     "CoreMLModels")),
    "SD15-Inpainting")
CONTEXT = 77          # SD 1.5 text context length
SOT, EOT = "<|startoftext|>", "<|endoftext|>"

# CLIP works on a printable-only view of raw bytes, so every byte survives a
# round trip through str without landing on whitespace or control codepoints.
def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + \
         list(range(ord("\xa1"), ord("\xac") + 1)) + \
         list(range(ord("\xae"), ord("\xff") + 1))
    cs, n = bs[:], 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, (chr(c) for c in cs)))

BYTE_ENCODER = bytes_to_unicode()

# CLIP's own split pattern, translated from \p{...} classes (which `re` lacks)
# to their ASCII-safe equivalents: [^\W\d_] is "unicode letter", \d is a lone
# digit, and the last two alternatives take every non-space character that is
# neither -- punctuation included, which a naive \p{L} translation silently drops.
PAT = re.compile(
    r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d"
    r"|[^\W\d_]+"
    r"|\d"
    r"|[^\s\w]+"
    r"|_+",
    re.IGNORECASE)


def clean(text):
    text = unicodedata.normalize("NFC", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def load():
    with open(os.path.join(BUNDLE, "vocab.json")) as f:
        vocab = json.load(f)
    with open(os.path.join(BUNDLE, "merges.txt"), encoding="utf-8") as f:
        lines = f.read().split("\n")
    # first line is the "#version:" header, last is the trailing blank
    merges = [tuple(l.split()) for l in lines[1:] if len(l.split()) == 2]
    return vocab, {pair: i for i, pair in enumerate(merges)}


def bpe(token, ranks, cache={}):
    if token in cache:
        return cache[token]
    word = tuple(token[:-1]) + (token[-1] + "</w>",)
    while len(word) > 1:
        pair = min(
            ((word[i], word[i + 1]) for i in range(len(word) - 1)),
            key=lambda p: ranks.get(p, float("inf")))
        if pair not in ranks:
            break
        first, second, out, i = pair[0], pair[1], [], 0
        while i < len(word):
            if word[i] == first and i < len(word) - 1 and word[i + 1] == second:
                out.append(first + second)
                i += 2
            else:
                out.append(word[i])
                i += 1
        word = tuple(out)
    cache[token] = word
    return word


def encode(text, vocab, ranks):
    ids = [vocab[SOT]]
    for match in PAT.findall(clean(text)):
        raw = "".join(BYTE_ENCODER[b] for b in match.encode("utf-8"))
        ids.extend(vocab[piece] for piece in bpe(raw, ranks))
    ids.append(vocab[EOT])
    if len(ids) > CONTEXT:                       # truncate, keeping the EOT
        ids = ids[:CONTEXT - 1] + [vocab[EOT]]
    # SD pads with EOT rather than a dedicated pad id
    return ids + [vocab[EOT]] * (CONTEXT - len(ids))


if __name__ == "__main__":
    vocab, ranks = load()
    for text in sys.argv[1:]:
        print(",".join(str(i) for i in encode(text, vocab, ranks)))
