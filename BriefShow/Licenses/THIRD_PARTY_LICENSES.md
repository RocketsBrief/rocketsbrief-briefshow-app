# Third-Party Licenses — BriefShow

Everything in the app that someone else made, what it is licensed under, and —
where it is not settled — what is still open. Last checked: 31 August 2026,
against app version 6.0.

**This is a working record, not a legal clearance.** Everything below is
settled except one upstream question about the LaMa weights, described in full
in its own section.

The full text of every licence named here ships inside the app, in
`BriefShow.app/Contents/Resources/`, and lives in this folder in the
repository:

- `LaMa-Apache-2.0.txt`
- `StableDiffusion-CreativeML-Open-RAIL-M.txt`
- `CLIP-MIT.txt`
- `Fonts-SIL-OFL-1.1.txt`

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

### 1b. Pre-trained weights (`big-lama`) — 🟡 LIKELY SETTLED, one upstream question

**The weights are published under Apache 2.0, by the route the LaMa authors
themselves specify.** Checked 31 August 2026:

- The official LaMa README (`lama-src/README.md`, line 113, and the current one
  at `github.com/advimman/lama`) gives exactly one download for "The best model
  (Places2, Places Challenge)": `huggingface.co/smartywu/big-lama`. That is the
  authors' own designated link, not a copy someone found elsewhere.
- That Hugging Face repository declares `license: apache-2.0` in its model card
  metadata.
- The current official LaMa README contains **no** licence restriction on the
  models at all — searched for "licen", "commercial", "non-commercial" and
  "copyright": no matches. The repository ships one licence, Apache 2.0, at its
  root.

An earlier revision of this file recorded that no grant had been received and
that the weights were commonly reported as CC BY-NC-SA 4.0. **Both statements
were wrong** and are withdrawn: the first mistook the authors' own download link
for a third-party re-upload, and the second was not supported by anything in the
repository, the README, or the model card.

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

**What is left is one question upstream of Samsung, not a question about what
Samsung granted.** The model was trained on **Places2** (MIT CSAIL), a dataset
distributed for research; its download page still routes legacy access through a
form "for research purposes". Whether a set of trained weights is a derivative
work of the images used to train it — and therefore whether a dataset's terms
reach through to a model — is genuinely unsettled law, not a settled "no". The
Places2 terms could not be confirmed as an explicit non-commercial licence from
the live page on 31 August 2026.

This is the same upstream question that sits under essentially every published
vision model, and it is not specific to LaMa or to this app.

**Reasonable ways to close it**, cheapest first:

1. Keep the record above. Apache 2.0 from the authors is a real commercial
   grant, and it is what a purchaser of the app would be relying on.
2. If certainty is wanted before selling, ask the authors to confirm in writing
   that the Apache 2.0 grant covers the weights, quoting the SHA-256 above, and
   save the answer beside them.
3. Only if that comes back negative: retrain the Apache-2.0 code on data that
   permits commercial use.

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
straightforward of the two models. It carries two obligations, and both are now
✅ MET:

- **A copy of the licence must accompany any distribution of the model.**
  `Licenses/StableDiffusion-CreativeML-Open-RAIL-M.txt` is the verbatim licence
  and is built into the app bundle as a resource.
- **The use restrictions (Attachment A) must be passed on to anyone who
  receives the model.** They are reproduced, in plain language, in the
  "Restrictions on AI use" section of the app's own Disclaimer & Usage Notice,
  which every user can open from the footer — and the notice states that
  agreeing to it includes agreeing to the third-party terms it passes on.

Worth noting: the conversion script this project used sets a `license` field on
the converted model (`torch2coreml.patched.py:458`), so the tooling expected the
licence to travel with the model. It had not been ending up in the shipped
folder; it does now.

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
| LaMa `big-lama` weights | 🟡 Apache 2.0 per the authors' own model card; one upstream dataset question |
| Stable Diffusion 1.5 Inpainting | ✅ Open RAIL-M — commercial use allowed, obligations met |
| CLIP tokenizer data | ✅ MIT |
| Figtree, Unbounded | ✅ SIL OFL 1.1 |
| Lightroom `.xmp` import | ✅ Own implementation; trademark wording to watch |
| Apple frameworks | ✅ Developer Program agreement |

Both models are covered by licences that permit commercial use. The one thing
still worth a written answer is whether the LaMa authors' Apache 2.0 grant is
understood to reach the weights as well as the code — see 1b.
