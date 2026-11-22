"""Builds LyricsAligner.mlpackage, the Core ML model the Lyrics Alignment sync engine loads.

Converts the MMS forced-aligner (MahmoudAshraf/mms-300m-1130-forced-aligner, CTC over 31 romanized
letters) for a fixed 24 s window of 16 kHz mono audio, with 8-bit weights (about 300 MB).
The caller normalizes each window to zero mean and unit variance; doing it in the model overflows fp16.

usage:
  python3 -m venv .venv && .venv/bin/pip install torch transformers coremltools
  .venv/bin/python scripts/convert-lyrics-aligner.py <out-dir>
Tested with torch 2.15, transformers 5.24 and coremltools 9.0.
Publish the zipped package as the `lyrics-aligner-model-N` pre-release and update `LyricsAlignerModel.downloadSHA256`.
"""
import sys

import coremltools as ct
import coremltools.optimize as cto
import torch
from transformers import Wav2Vec2ForCTC

MODEL = "MahmoudAshraf/mms-300m-1130-forced-aligner"
WINDOW_SAMPLES = 24 * 16000


class LogProbs(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, audio):
        return torch.log_softmax(self.model(audio).logits, dim=-1)


def main(out_dir):
    model = Wav2Vec2ForCTC.from_pretrained(MODEL, attn_implementation="eager").eval()
    with torch.inference_mode():
        traced = torch.jit.trace(LogProbs(model).eval(), torch.zeros(1, WINDOW_SAMPLES))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, WINDOW_SAMPLES))],
        outputs=[ct.TensorType(name="logprobs")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    config = cto.coreml.OptimizationConfig(global_config=cto.coreml.OpLinearQuantizerConfig(mode="linear_symmetric"))
    cto.coreml.linear_quantize_weights(mlmodel, config).save(f"{out_dir}/LyricsAligner.mlpackage")


if __name__ == "__main__":
    main(sys.argv[1])
