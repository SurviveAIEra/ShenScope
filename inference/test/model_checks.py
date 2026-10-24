"""Integration tests with random tiny Llama weights; not a pretrained benchmark."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
import torch
from transformers import LlamaConfig, LlamaForCausalLM, PreTrainedTokenizerFast
from tokenizers import Tokenizer
from tokenizers.models import WordLevel
from tokenizers.pre_tokenizers import Whitespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge import JuliaRMSNorm
from models.adapter import ResidualNormAdapter
from models.prepare import verify_cache
from models.run import compare_triplet, CONDITIONS, run_worker


class ModelChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)
        cls.bridge = JuliaRMSNorm()

    def setUp(self):
        torch.manual_seed(81731)
        config = LlamaConfig(vocab_size=97, hidden_size=64, intermediate_size=128,
                             num_hidden_layers=2, num_attention_heads=4, num_key_value_heads=2,
                             max_position_embeddings=512, attention_dropout=0.)
        config._attn_implementation = "sdpa"
        self.model = LlamaForCausalLM(config).eval().requires_grad_(False)
        self.ids = torch.randint(0, 97, (1, 13))

    def evaluate(self):
        with torch.inference_mode():
            result = self.model(self.ids, use_cache=True)
            first = result.logits.clone()
            continued = self.model(torch.tensor([[7]]), past_key_values=result.past_key_values, use_cache=True)
        return first, continued.logits.clone()

    def test_control_preserves_original_prefill_and_kv_decode_exactly(self):
        expected = self.evaluate()
        adapter = ResidualNormAdapter(self.model, "control")
        actual = self.evaluate()
        for reference, result in zip(expected, actual):
            self.assertTrue(torch.equal(reference, result))
        self.assertEqual(adapter.calls, 4)
        adapter.restore()
        for reference, result in zip(expected, self.evaluate()):
            self.assertTrue(torch.equal(reference, result))

    def test_real_julia_and_native_paths_preserve_logits_and_model_weights(self):
        expected = self.evaluate()
        before = {key: tensor.clone() for key, tensor in self.model.state_dict().items()}
        for mode in ("torch_native", "julia"):
            adapter = ResidualNormAdapter(self.model, mode, self.bridge)
            for reference, result in zip(expected, self.evaluate()):
                torch.testing.assert_close(result, reference, rtol=1e-4, atol=1e-4)
                self.assertTrue(torch.equal(result.argmax(-1), reference.argmax(-1)))
            self.assertEqual(adapter.calls, 4)
            self.assertEqual(adapter.layout_copies, 0)
            adapter.restore()
        self.assertTrue(all(torch.equal(tensor, before[key]) for key, tensor in self.model.state_dict().items()))

    def test_training_and_grad_enabled_execution_are_rejected(self):
        self.model.train()
        with self.assertRaises(ValueError):
            ResidualNormAdapter(self.model, "julia", self.bridge)
        self.model.eval()
        adapter = ResidualNormAdapter(self.model, "julia", self.bridge)
        with self.assertRaisesRegex(RuntimeError, "inference_mode"):
            self.model(self.ids)
        adapter.restore()

    def test_four_torch_threads_keep_cache_and_julia_outputs_correct(self):
        expected = self.evaluate()
        adapter = ResidualNormAdapter(self.model, "julia", self.bridge)
        try:
            torch.set_num_threads(4)
            for reference, actual in zip(expected, self.evaluate()):
                torch.testing.assert_close(actual, reference, rtol=1e-4, atol=1e-4)
                self.assertTrue(torch.equal(actual.argmax(-1), reference.argmax(-1)))
        finally:
            adapter.restore()
            torch.set_num_threads(1)

    def test_missing_weights_never_turn_into_random_model_results(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                verify_cache(Path(directory))

    def test_comparison_detects_diverging_tokens_and_logits(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = {name: Path(temporary) / name for name in CONDITIONS}
            receipts = {}
            for name, path in paths.items():
                path.mkdir()
                records = []
                for prompt in ("short", "medium", "long"):
                    for suffix in ("prefill", "final"):
                        np.array([1., 2., 3.], dtype="<f4").tofile(path / f"{prompt}-{suffix}.f32")
                    records.append(dict(prompt=prompt, input_ids=[1, 2], token_ids=[3, 4]))
                receipts[name] = dict(model_id="fixture", model_revision="a"*40, dtype="float32",
                    attention="sdpa", threads=1, parameter_count=12, adapter_calls=1, records=records)
            self.assertTrue(all(row["passed"] for row in compare_triplet(receipts, paths)))
            receipts["julia"]["records"][0]["token_ids"] = [3, 5]
            self.assertFalse(all(row["passed"] for row in compare_triplet(receipts, paths)))
            receipts["julia"]["records"][0]["token_ids"] = [3, 4]
            np.array([9., 2., 3.], dtype="<f4").tofile(paths["julia"] / "short-prefill.f32")
            self.assertFalse(all(row["passed"] for row in compare_triplet(receipts, paths)))
            for condition in CONDITIONS:
                np.array([float('inf'), 2., 3.], dtype="<f4").tofile(paths[condition] / "short-prefill.f32")
            self.assertFalse(all(row["passed"] for row in compare_triplet(receipts, paths)))

    def test_saved_random_fixture_exercises_real_loader_and_all_generation_paths(self):
        # Explicitly random test weights. These transient worker timings never
        # enter the pretrained-model report and are not performance evidence.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_dir = root / "random-fixture"
            self.model.save_pretrained(model_dir, safe_serialization=True)
            vocab = {"[UNK]": 0, "[PAD]": 1, "[EOS]": 2,
                     **{f"word{i}": i+3 for i in range(94)}}
            backend = Tokenizer(WordLevel(vocab, unk_token="[UNK]"))
            backend.pre_tokenizer = Whitespace()
            tokenizer = PreTrainedTokenizerFast(tokenizer_object=backend, unk_token="[UNK]",
                                               pad_token="[PAD]", eos_token="[EOS]")
            tokenizer.save_pretrained(model_dir)
            (model_dir / "model-manifest.json").write_text(json.dumps({"model_id":"TEST_ONLY_RANDOM_WEIGHTS", "revision":"0"*40}))
            env = dict(os.environ, JULIA_NUM_THREADS="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                       JULIA_DEPOT_PATH="/workspace/julia-depot", OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
                       PYTHONDONTWRITEBYTECODE="1")
            receipts, paths = {}, {}
            for condition in CONDITIONS:
                path = root / condition
                command = [sys.executable, str(Path(__file__).resolve().parents[1] / "models/worker.py"),
                           "--model-dir", str(model_dir), "--condition", condition, "--threads", "1",
                           "--cpus", str(min(os.sched_getaffinity(0))), "--artifacts", str(path)]
                run_worker(command, env, root / f"{condition}.log", timeout=60)
                receipt = json.loads((path / "receipt.json").read_text())
                self.assertEqual(receipt["model_id"], "TEST_ONLY_RANDOM_WEIGHTS")
                if condition != "original":
                    self.assertEqual(receipt["adapter_calls"], 208)
                receipts[condition], paths[condition] = receipt, path
            self.assertTrue(all(check["passed"] for check in compare_triplet(receipts, paths)))
            with self.assertRaises(ValueError):
                verify_cache(model_dir)


if __name__ == "__main__":
    unittest.main()
