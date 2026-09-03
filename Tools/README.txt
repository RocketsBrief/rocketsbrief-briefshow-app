These are the build tools for BriefShow's two AI erase models. They live in the
repository; the WEIGHTS they operate on deliberately do not, because GitHub
refuses any single file over 100 MB and SD's UNet alone is 1.6 GB.

Weights and working copies live in a sibling CoreMLModels/ directory beside
this checkout. Nothing there is in git, and nothing there is needed to READ
this repository — only to rebuild the models.

  ⚠️ There is NO BRIEFSHOW_MODELS override. This file claimed one for days and
  the app has never read such a variable — grep the sources and it is not
  there. The path is decided in SDModelStore (DevelopSDInpaint.swift), so
  moving that folder is a code change, not an environment change. Left written
  down rather than quietly deleted, because the claim has already been believed
  once.

  convert_lama.py          big-lama checkpoint -> LaMa.mlpackage (99 MB)
  clip_tokenize.py         CLIP BPE, pure stdlib
  dump_prompt_embeds.swift bakes the default SD prompt into sd_prompt_embeds.bin
  sd_prompt_embeds.bin     that baked prompt (231 KB)
  run-model-load-test.py   times how long the SD weights take to load into
                           Core ML, cold and warm. Reads the model names and
                           compute units out of prepare() so it cannot drift.

Rebuilding LaMa from scratch:
  curl -LJO https://huggingface.co/smartywu/big-lama/resolve/main/big-lama.zip
  unzip big-lama.zip                       # -> big-lama/
  git clone --depth 1 https://github.com/advimman/lama.git lama-src
  python3.11 -m venv .venv
  .venv/bin/pip install torch coremltools omegaconf kornia pytorch-lightning
  .venv/bin/python <repo>/Tools/convert_lama.py
  xcrun coremlcompiler compile LaMa/LaMa.mlpackage LaMa/
  # then copy LaMa.mlpackage into BriefShow/BriefShow/ so Xcode bundles it

--- original notes on the SD conversion follow ---

SD 1.5 Inpainting — Core ML modeli za BriefShow "Erase (AI)"
Konvertovano 25. avgusta 2026.

SD15-Inpainting/   spremni .mlmodelc modeli (fp16, ~2 GB) — ovo troši Swift pipeline.
                   UNet je 9-kanalni (inpainting), provereno: sample [2, 9, 64, 64].
sd_test.py         Python prototip (velika maska / cela osoba)
sd_small.py        Python prototip (sitna figura u pozadini) — ovaj recept radi najbolje
torch2coreml.patched.py  Applov konverter sa zakrpom (diffusionkit import u try/except)

NAMERNO je van BriefShow/BriefShow/ — taj folder je Xcode "file system synchronized
group", pa bi sve unutra automatski ušlo u app bundle (2 GB app).

Ponovna konverzija (ako zatreba, ~10 min; težine su već u ~/.cache/huggingface):
  pip install torch diffusers transformers accelerate safetensors coremltools pytest scipy
  git clone --depth 1 https://github.com/apple/ml-stable-diffusion.git
  # u torch2coreml.py obaviti "from diffusionkit..." u try/except (vidi .patched.py)
  cd ml-stable-diffusion
  python -m python_coreml_stable_diffusion.torch2coreml \
    --convert-unet --convert-vae-decoder --convert-vae-encoder --convert-text-encoder \
    --model-version stable-diffusion-v1-5/stable-diffusion-inpainting \
    --bundle-resources-for-swift-cli -o <out>

Za manju verziju (~700-900 MB) dodati: --quantize-nbits 6

--- dodato 25. avgusta 2026 (Swift integracija) ---
clip_tokenize.py         CLIP BPE u čistom stdlib Pythonu (čita vocab/merges iz
                         SD15-Inpainting/, pa ne može da odluta od tih težina)
dump_prompt_embeds.swift peče fiksni prompt u sd_prompt_embeds.bin [2,768,1,77]
                         fp16, batch 0 = uncond. Zbog toga TextEncoder (235 MB)
                         NE ide u app.
sd_prompt_embeds.bin     231 KB; regenerisati posle svake promene prompta:
  NEG=$(python3 clip_tokenize.py "<negative>")
  POS=$(python3 clip_tokenize.py "<positive>")
  swift dump_prompt_embeds.swift "$NEG" "$POS" SD15-Inpainting sd_prompt_embeds.bin
  cp sd_prompt_embeds.bin SD15-Inpainting/

Upečeni prompt ("empty background, seamless continuation, no people") je
POTVRĐEN kao ispravan. Ako ga menjaš: CLIP čita prompt kao spisak stvari koje
treba naslikati, ne kao instrukciju — imenuj ono što treba da bude tu, nemoj
pisati naredbu tipa "remove the object and match the lighting" (to daje table
sa tekstom i stock teksture). Vidi "KORAK 3" u BRIEFSHOW_DEVELOP_NOTES.md.
