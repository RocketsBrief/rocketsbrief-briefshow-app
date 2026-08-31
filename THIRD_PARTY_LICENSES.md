# Third-Party Licenses — BriefShow

Everything in the app that someone else made, what it is licensed under, and —
where it is not settled — what is still open. Last checked: 31 August 2026,
against app version 6.0.

**This is a working record, not a legal clearance.** Two entries below are
marked ⚠️ OPEN. They are open because nothing in this project grants the right
in writing, not because the answer is likely to be bad. They should be closed
before the app is sold.

---

## 1. LaMa — inpainting model ("Quick AI Clean Up", and the base of Generative)

### 1a. Source code — ✅ SETTLED

**Apache License 2.0.** Verified: `CoreMLModels/lama-src/LICENSE` is the full
Apache 2.0 text.

> LaMa — *Resolution-robust Large Mask Inpainting with Fourier Convolutions*
> Roman Suvorov, Elizaveta Logacheva, Anton Mashikhin, Anastasia Remizova,
> Arsenii Ashukha, Aleksei Silvestrov, Naejin Kong, Harshith Goka,
> Kiwoong Park, Victor Lempitsky — Samsung AI Center, WACV 2022.
> https://github.com/advimman/lama

Apache 2.0 permits commercial use, modification and distribution. Its
conditions — keep the licence and the notices with any redistribution, state
what was changed — are met by shipping this file.

### 1b. Pre-trained weights (`big-lama`) — ⚠️ OPEN

**No licence document was received with these weights.** There is no LICENSE,
NOTICE or model card in `CoreMLModels/big-lama/`; the Apache 2.0 file above sits
in `lama-src/` and covers the CODE.

**Exactly which weights these are** (so the question can be asked precisely):

| | |
|---|---|
| Run title | `b18_ffc075_batch8x15` |
| Training experiment | `r.suvorov_2021-04-30_14-41-12_train_simple_pix2pix2_gap_sdpl_novgg_large_b18_ffc075_batch8x15` |
| Trained by | Samsung AI Center — internal volume `/group-volume/User-Driven-Content-Generation/`, author directory `r.suvorov` (Roman Suvorov, first author of the paper) |
| Trained | 30 April 2021 |
| Training resolution | 256 px (`out_size: 256`) |
| Checkpoint | `big-lama/models/best.ckpt`, 410,046,389 bytes |
| SHA-256 (checkpoint) | `fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423` |
| SHA-256 (`big-lama.zip`) | `f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6` |

That is the official Samsung-trained `big-lama` — the model the LaMa paper and
README describe as the best one, trained on **Places2 / Places-Challenge**.

**Why this is open, and it is not the usual "grey area" framing.** The LaMa
README fetches these weights from `https://huggingface.co/smartywu/big-lama`,
which is a **third-party re-upload**, not a Samsung or advimman channel. A
re-uploader cannot grant a licence they do not hold, so no grant has been
received here at all. Separately, the LaMa project's own terms for its
pre-trained models are commonly reported as **CC BY-NC-SA 4.0
(non-commercial)**, and the Places2 dataset the model was trained on is itself
distributed for research use — but neither of those has been confirmed against
the primary source for this project.

**To close it**, one of:

1. Confirm the weights' licence at the primary source (the `advimman/lama`
   repository and its model card, or Samsung directly), quoting the SHA-256
   above, and save the answer in this repository next to the weights.
2. Obtain a commercial grant.
3. Fine-tune or retrain the Apache-2.0 code on data that permits commercial use.

⚠️ Option 3 changes what the model produces, and the quality of the AI Clean Up
result is recorded as 🟢 LOCKED in `BRIEFSHOW_DEVELOP_NOTES.md`. It is not a
drop-in substitution.

⚠️ Removing LaMa is also not a one-line change, and the project's own
measurements say so: Quick AI Clean Up **is** LaMa, Generative Clean Up now
starts from LaMa's fill rather than from noise (STEP 40), and Stable Diffusion
alone was measured and found unable to replace it (STEP 39, "Result 3 — LaMa on
the same mask: clean").

---

## 2. Stable Diffusion v1.5 Inpainting — "Generative Clean Up"

**CreativeML Open RAIL-M.** Source model: `stable-diffusion-v1-5/
stable-diffusion-inpainting` (see `CoreMLModels/sd_small.py`), converted to Core
ML with Apple's `ml-stable-diffusion` conversion script
(`CoreMLModels/torch2coreml.patched.py`). Shipped as
`CoreMLModels/SD15-Inpainting/` — `TextEncoder`, `Unet`, `VAEDecoder`,
`VAEEncoder`.

**Open RAIL-M does permit commercial use**, which makes this the more
straightforward of the two models. It carries obligations, and they are
currently ⚠️ NOT MET:

- A copy of the licence must accompany any distribution of the model or its
  derivatives. There is no licence file in `CoreMLModels/SD15-Inpainting/`.
- The use restrictions (Attachment A of the licence) must be passed on to
  anyone who receives the model — in practice, reproduced in the app's terms of
  use.

Worth noting: the conversion script this project used sets a `license` field on
the converted model (`torch2coreml.patched.py:458`), so the tooling expects the
licence to travel with the model. It did not end up in the shipped folder.

**To close it:** add the licence text to the repository and to the shipped app,
and put Attachment A's restrictions into the end-user terms. This is a small
job and it settles the entry completely.

### 2a. CLIP tokenizer data

`SD15-Inpainting/vocab.json` and `merges.txt` are OpenAI CLIP's tokenizer data,
carried through the same conversion. OpenAI's CLIP is released under the **MIT
License**.

---

## 3. Fonts — ✅ SETTLED

Both bundled in `BriefShow/Fonts/` and registered at launch by
`BriefShowApp.registerBundledFonts()`.

| Font | Licence |
|---|---|
| **Figtree** (Erik Kennedy) | SIL Open Font License 1.1 |
| **Unbounded** (Alexandru Nedelcu / Google Fonts) | SIL Open Font License 1.1 |

The OFL permits bundling in and distribution with an application, including a
commercial one. Its conditions — the fonts are not sold on their own, the
licence travels with them, and the reserved names are not used for modified
versions — are met by shipping them unmodified inside the app.

---

## 4. Adobe Lightroom preset import — ✅ SETTLED

The app reads Lightroom / Camera Raw preset files (`.xmp`). No Adobe code,
binaries or assets are used, copied or distributed. The reader was written from
the file format, and every adjustment it drives is this project's own
implementation.

XMP is an ISO standard (ISO 16684-1). Field names, value ranges and default
values read out of a file are facts about that file rather than protected
expression.

Notes for the product side rather than the licence side:

- **Adobe®, Lightroom® and Camera Raw® are trademarks of Adobe Inc.** Use them
  only descriptively, to say what the feature reads. Do not use Adobe branding,
  logos or trade dress, and do not imply endorsement, affiliation or
  certification.
- **Do not bundle other people's presets with the app.** A client importing
  presets they already own is theirs to do; redistributing a preset pack is a
  different act entirely.

---

## 5. Apple frameworks

SwiftUI, AppKit, Core Image, Core ML, Vision, ImageIO, AVFoundation and
ImageCaptureCore are used under the Apple Developer Program License Agreement.
Nothing to reproduce here.

---

## Summary

| Item | State |
|---|---|
| LaMa source code | ✅ Apache 2.0 |
| **LaMa `big-lama` weights** | ⚠️ **OPEN — no grant received; identified above by SHA-256** |
| **Stable Diffusion 1.5 Inpainting** | ⚠️ **OPEN — commercial use allowed, obligations not yet met** |
| CLIP tokenizer data | ✅ MIT |
| Figtree, Unbounded | ✅ SIL OFL 1.1 |
| Lightroom `.xmp` import | ✅ Own implementation; trademark wording to watch |
| Apple frameworks | ✅ Developer Program agreement |

Item 2 is the cheap one and closes completely. Item 1b is the one that decides
whether the app can be sold as it stands.
