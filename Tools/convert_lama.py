#!/usr/bin/env python3
"""big-lama -> Core ML, for BriefShow's "Quick AI Clean Up".

LaMa is not a diffusion model: one forward pass, no prompt, no sampler. That
is the whole reason it is here — it runs in about a second on any Mac,
including Intel machines that have no Neural Engine and where SD is
unusable.

Deliberately loads only the GENERATOR out of the training checkpoint. The
.ckpt is a PyTorch Lightning bundle carrying discriminators, the perceptual
loss network and optimiser state; none of that is inference, and dragging it
along would triple the size of what we ship.

  ../../CoreMLModels/.venv/bin/python convert_lama.py
"""
import os
import sys

import torch
from omegaconf import OmegaConf

# The weights and the cloned LaMa source are NOT in this repository — GitHub
# refuses single files over 100 MB and the checkpoints are far past that. They
# live in a sibling CoreMLModels directory, which this script both reads from
# and writes to; BRIEFSHOW_MODELS overrides it.
WORK = os.environ.get(
    "BRIEFSHOW_MODELS",
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                 "CoreMLModels"))
sys.path.insert(0, os.path.join(WORK, "lama-src"))
from saicinpainting.training.modules.ffc import FFCResNetGenerator  # noqa: E402

SIDE = 512                      # fixed, like the SD models: Core ML wants a shape
CHECKPOINT = os.path.join(WORK, "big-lama/models/best.ckpt")
CONFIG = os.path.join(WORK, "big-lama/config.yaml")
OUT = os.path.join(WORK, "LaMa/LaMa.mlpackage")


class Inpainter(torch.nn.Module):
    """Image + mask in, finished image out.

    The masking and the concatenation live INSIDE the traced graph on purpose:
    they are two lines that are easy to get subtly wrong on the Swift side
    (which channel order, is the mask 1-for-hole or 1-for-keep, is the hole
    zeroed before or after), and baking them in makes the Core ML model's
    contract simply "here is a photo and a mask".
    """

    def __init__(self, generator):
        super().__init__()
        self.generator = generator

    def forward(self, image, mask):
        # image: [1,3,H,W] in 0..1. mask: [1,1,H,W], 1 = repaint this.
        masked = image * (1 - mask)
        return self.generator(torch.cat([masked, mask], dim=1))


def main():
    config = OmegaConf.load(CONFIG)
    kwargs = OmegaConf.to_container(config.generator, resolve=True)
    kwargs.pop("kind")

    generator = FFCResNetGenerator(**kwargs)

    state = torch.load(CHECKPOINT, map_location="cpu", weights_only=False)["state_dict"]
    weights = {k[len("generator."):]: v for k, v in state.items() if k.startswith("generator.")}
    missing, unexpected = generator.load_state_dict(weights, strict=True), None
    generator.eval()
    print("generator loaded: %d tensors, %.1f M params"
          % (len(weights), sum(p.numel() for p in generator.parameters()) / 1e6))

    model = Inpainter(generator).eval()

    image = torch.rand(1, 3, SIDE, SIDE)
    mask = (torch.rand(1, 1, SIDE, SIDE) > 0.5).float()
    with torch.no_grad():
        reference = model(image, mask)
    print("torch output", tuple(reference.shape),
          "range %.3f..%.3f" % (reference.min(), reference.max()))

    traced = torch.jit.trace(model, (image, mask), check_trace=False)

    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=image.shape, dtype=float),
                ct.TensorType(name="mask", shape=mask.shape, dtype=float)],
        outputs=[ct.TensorType(name="output", dtype=float)],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "LaMa big-lama inpainting (Apache-2.0, Samsung Research)"
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    mlmodel.save(OUT)
    print("saved", OUT)

    # Same input through Core ML: a conversion that silently changed the graph
    # would still save fine, so it has to be checked against torch, not assumed.
    out = mlmodel.predict({"image": image.numpy(), "mask": mask.numpy()})
    got = torch.tensor(list(out.values())[0])
    delta = (got - reference).abs()
    print("coreml vs torch: max diff %.4f, mean %.5f" % (delta.max(), delta.mean()))


if __name__ == "__main__":
    main()
