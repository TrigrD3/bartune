"""Builds the 8-bit vocals-only Open-Unmix UMX-HQ Core ML package for macOS 14 and later.

Input and output are stereo magnitude spectra. BarTune handles STFT, overlap, and iSTFT.

usage:
  python3 -m venv .venv && .venv/bin/pip install openunmix==1.3.0 torch==2.7.0 coremltools==9.0 numpy==2.3.5
  .venv/bin/python scripts/convert-vocal-separator.py <out-dir>
Tested with openunmix 1.3.0, torch/torchaudio 2.7.0 and coremltools 9.0.
Zip the package with its top-level directory and the upstream MIT license.
Pin the archive SHA-256 in VocalSeparatorModel.
"""
import hashlib
import io
import sys
from pathlib import Path

import coremltools as ct
import coremltools.optimize as cto
import numpy as np
import torch
from openunmix.model import OpenUnmix

# 272 frames with 16 frames of overlap cover a 12 s excerpt in two predictions.
WINDOW_FRAMES = 272
NB_BINS = 1487
FULL_OUTPUT_BINS = 2049
SHAPE = (1, WINDOW_FRAMES, 2, NB_BINS)

# SigSep's UMX-HQ vocals checkpoint from Open-Unmix v1.3.0.
# https://github.com/sigsep/open-unmix-pytorch/blob/v1.3.0/openunmix/__init__.py#L88-L115
CHECKPOINT_NAME = "vocals-b62c91ce.pth"
CHECKPOINT_URL = f"https://zenodo.org/records/3370489/files/{CHECKPOINT_NAME}"
CHECKPOINT_SHA256 = "b62c91cedbc7a066f1778ead5b5cecb377aa3a46a31af1cce7c5c8769339d083"
CHECKPOINT_SIZE = 35_637_796


def load_vocal_model():
    cache_dir = Path(torch.hub.get_dir()) / "checkpoints"
    cache_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = cache_dir / CHECKPOINT_NAME
    if not checkpoint.exists():
        torch.hub.download_url_to_file(CHECKPOINT_URL, str(checkpoint), hash_prefix=CHECKPOINT_SHA256)

    # Give PyTorch the same bytes that were hashed, even if the cache changes.
    with checkpoint.open("rb") as checkpoint_file:
        weights = checkpoint_file.read(CHECKPOINT_SIZE + 1)
    if hashlib.sha256(weights).hexdigest() != CHECKPOINT_SHA256:
        raise ValueError(f"SHA-256 mismatch for {checkpoint}. Remove the cached file and retry.")
    state = torch.load(io.BytesIO(weights), map_location="cpu", weights_only=True)

    # The original checkpoint includes frontend buffers. BarTune handles the STFT.
    for name in ("sample_rate", "stft.window", "transform.0.window"):
        del state[name]
    model = OpenUnmix(
        nb_bins=FULL_OUTPUT_BINS, nb_channels=2, hidden_size=512,
        nb_layers=3, unidirectional=False, max_bin=NB_BINS,
    )
    model.load_state_dict(state, strict=True)
    return model


class VocalMagnitude(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, magnitude):
        # Open-Unmix takes [batch, channels, bins, frames].
        return self.model(magnitude.permute(0, 2, 3, 1)).permute(0, 3, 1, 2).contiguous()


def restrict_output_band(model):
    # The encoder ignores bins above 16 kHz. Strip those bins from the
    # independent output rows and normalization parameters for both channels.
    keep = torch.arange(2 * model.nb_output_bins).reshape(2, -1)[:, :NB_BINS].reshape(-1)
    weight = model.fc3.weight.detach()
    normalization = model.bn3
    model.fc3 = torch.nn.Linear(model.fc3.in_features, keep.numel(), bias=False)
    model.fc3.weight = torch.nn.Parameter(weight[keep])
    model.bn3 = torch.nn.BatchNorm1d(keep.numel(), eps=normalization.eps)
    model.bn3.load_state_dict({
        name: value[keep] if value.ndim else value for name, value in normalization.state_dict().items()
    })
    model.output_scale = torch.nn.Parameter(model.output_scale[:NB_BINS].detach().clone())
    model.output_mean = torch.nn.Parameter(model.output_mean[:NB_BINS].detach().clone())
    model.nb_output_bins = NB_BINS


def main(out_dir):
    model = load_vocal_model()
    restrict_output_band(model)
    with torch.inference_mode():
        traced = torch.jit.trace(VocalMagnitude(model).eval(), torch.zeros(SHAPE))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix_magnitude", shape=SHAPE, dtype=np.float32)],
        outputs=[ct.TensorType(name="vocal_magnitude", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        skip_model_load=True,
    )
    mlmodel.author = "SigSep"
    mlmodel.license = "MIT"
    # Near-zero fc2 rows can underflow their fp16 quantization scales.
    # Core ML Tools may warn before storing those rows as zero.
    config = cto.coreml.OptimizationConfig(
        global_config=cto.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
    )
    output = Path(out_dir)
    output.mkdir(parents=True, exist_ok=True)
    cto.coreml.linear_quantize_weights(mlmodel, config).save(str(output / "VocalSeparator.mlpackage"))


if __name__ == "__main__":
    main(sys.argv[1])
