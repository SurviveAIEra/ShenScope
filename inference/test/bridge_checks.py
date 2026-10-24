"""Exercise real embedded Julia calls against PyTorch and the buffer contract."""
import os
import importlib.util
from pathlib import Path
import sys
import threading
import unittest

import torch
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge import JuliaRMSNorm


class BridgeChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)
        cls.bridge = JuliaRMSNorm()

    def setUp(self):
        torch.manual_seed(81731)
        self.x = torch.randn(3, 127)
        self.r = torch.randn_like(self.x)
        self.w = torch.randn(127)
        self.out, self.summed = torch.full_like(self.x, 9), torch.full_like(self.x, 8)

    def call(self, **changes):
        args = dict(x=self.x, residual=self.r, weight=self.w, out=self.out, summed=self.summed)
        args.update(changes)
        return self.bridge.add_rmsnorm_into(**args)

    def test_real_zero_copy_output_and_input_preservation(self):
        originals = [tensor.clone() for tensor in (self.x, self.r, self.w)]
        addresses = [tensor.data_ptr() for tensor in (self.x, self.r, self.w, self.out, self.summed)]
        result = self.call()
        self.assertIs(result[0], self.out)
        self.assertIs(result[1], self.summed)
        self.assertEqual(addresses, [tensor.data_ptr() for tensor in (self.x, self.r, self.w, self.out, self.summed)])
        torch.testing.assert_close(self.out, F.rms_norm(self.x + self.r, [127], self.w, 1e-6), rtol=1e-5, atol=1e-6)
        torch.testing.assert_close(self.summed, self.x + self.r, rtol=0, atol=0)
        for actual, original in zip((self.x, self.r, self.w), originals):
            self.assertTrue(torch.equal(actual, original))

    def test_invalid_buffers_never_write(self):
        invalid = [dict(x=self.x.double()), dict(x=self.x.T), dict(x=self.x.clone().requires_grad_()),
                   dict(residual=torch.randn(4, 127)), dict(weight=torch.ones(128)),
                   dict(x="not a tensor"), dict(epsilon=0), dict(epsilon=float("nan")), dict(epsilon=1e-60)]
        for args in invalid:
            with self.subTest(args=list(args)):
                with self.assertRaises((TypeError, ValueError)):
                    self.call(**args)
                self.assertTrue(torch.all(self.out == 9))
                self.assertTrue(torch.all(self.summed == 8))

    def test_exact_and_partial_overlaps_rejected(self):
        storage = torch.empty(self.x.numel() + 1)
        for args in (dict(out=self.x), dict(out=self.summed),
                     dict(x=storage[:-1].reshape_as(self.x), out=storage[1:].reshape_as(self.x))):
            with self.assertRaisesRegex(ValueError, "overlap"):
                self.call(**args)

    def test_empty_batch(self):
        empty = torch.empty(0, 127)
        out, summed = self.call(x=empty, residual=empty, out=empty, summed=empty)
        self.assertEqual(out.numel(), 0)
        self.assertEqual(summed.numel(), 0)

    def test_other_python_thread_rejected(self):
        errors = []
        def other():
            try:
                self.call()
            except RuntimeError as error:
                errors.append(str(error))
        thread = threading.Thread(target=other)
        thread.start()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(errors), 1)
        self.assertIn("initializing thread", errors[0])

    def test_second_instance_reuses_runtime(self):
        other = JuliaRMSNorm()
        self.assertIs(other._backend, self.bridge._backend)

    def test_existing_runtime_cannot_be_initialized_twice(self):
        # A second module instance represents another integration in the same
        # process. It must fail before calling jl_init, which is not repeatable.
        spec = importlib.util.spec_from_file_location("other_inference_bridge",
                    Path(__file__).resolve().parents[1] / "bridge.py")
        other = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(other)
        with self.assertRaisesRegex(RuntimeError, "already initialized"):
            other.JuliaRMSNorm()


if __name__ == "__main__":
    unittest.main()
