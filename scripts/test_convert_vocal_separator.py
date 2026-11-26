"""Run with the converter's dependencies: python -m unittest discover -s scripts."""
import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "convert_vocal_separator", Path(__file__).with_name("convert-vocal-separator.py")
)
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)


class VocalCheckpointTests(unittest.TestCase):
    def test_rejects_bad_checkpoint_before_loading(self):
        for cached in (True, False):
            with self.subTest(cached=cached), tempfile.TemporaryDirectory() as cache:
                checkpoint = Path(cache) / "checkpoints" / converter.CHECKPOINT_NAME
                if cached:
                    checkpoint.parent.mkdir()
                    checkpoint.write_bytes(b"bad weights")

                def write_bad_download(url, path, *, hash_prefix):
                    self.assertEqual(url, converter.CHECKPOINT_URL)
                    self.assertEqual(hash_prefix, converter.CHECKPOINT_SHA256)
                    Path(path).write_bytes(b"bad weights")

                with (
                    patch.object(converter.torch.hub, "get_dir", return_value=cache),
                    patch.object(converter.torch.hub, "download_url_to_file", side_effect=write_bad_download) as download,
                    patch.object(converter.torch, "load") as load,
                ):
                    with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                        converter.load_vocal_model()
                    self.assertEqual(download.call_count, 0 if cached else 1)
                    load.assert_not_called()

    def test_loads_verified_bytes_with_cpu_weights_only(self):
        weights = b"verified fixture"
        digest = hashlib.sha256(weights).hexdigest()
        weight = object()
        state = dict.fromkeys(("sample_rate", "stft.window", "transform.0.window"))
        state["fc1.weight"] = weight
        with tempfile.TemporaryDirectory() as cache:
            checkpoint = Path(cache) / "checkpoints" / converter.CHECKPOINT_NAME
            checkpoint.parent.mkdir()
            checkpoint.write_bytes(weights)
            with (
                patch.object(converter, "CHECKPOINT_SHA256", digest),
                patch.object(converter.torch.hub, "get_dir", return_value=cache),
                patch.object(converter.torch, "load", return_value=state) as load,
                patch.object(converter, "OpenUnmix") as constructor,
            ):
                model = converter.load_vocal_model()

        self.assertEqual(load.call_args.args[0].read(), weights)
        self.assertEqual(load.call_args.kwargs, {"map_location": "cpu", "weights_only": True})
        constructor.assert_called_once_with(
            nb_bins=2049, nb_channels=2, hidden_size=512,
            nb_layers=3, unidirectional=False, max_bin=1487,
        )
        model.load_state_dict.assert_called_once_with({"fc1.weight": weight}, strict=True)
