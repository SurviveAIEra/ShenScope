"""Check that corrupt or incomplete benchmark runs cannot become PASS receipts."""
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

import numpy as np

spec = importlib.util.spec_from_file_location("inference_benchmark", Path(__file__).resolve().parents[1] / "benchmarks/run.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class ReceiptChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.specs, _ = benchmark.make_inputs(self.root, ((31, 3),), 3, 1)
        case = self.root / self.specs[0]["id"]
        x = np.fromfile(case / "x.f32", dtype="<f4").reshape(3, 31)
        r = np.fromfile(case / "residual.f32", dtype="<f4").reshape(3, 31)
        w = np.fromfile(case / "weight.f32", dtype="<f4")
        p = np.fromfile(case / "projection.f32", dtype="<f4").reshape(31, 256)
        summed = x + r
        z = summed.astype(np.float64)
        out = z / np.sqrt(np.mean(z * z, axis=1, keepdims=True) + float(np.float32(1e-6))) * w
        self.records = []
        for stage, values in (("norm", out), ("norm_projection", out @ p.astype(np.float64))):
            for suffix, value in (("output", values), ("summed", summed)):
                value.astype("<f4").tofile(case / f"control-{stage}-{suffix}.f32")
            self.records.append(dict(id=self.specs[0]["id"], stage=stage,
                                     methods=dict(control=dict(samples_ns=[1, 2, 3]))))

    def tearDown(self):
        self.temp.cleanup()

    def check(self, records=None):
        return benchmark.validate_outputs(self.root, self.specs,
                                          self.records if records is None else records, {"control"}, 3)

    def test_complete_real_outputs(self):
        result = self.check()
        self.assertEqual(len(result), 2)
        self.assertTrue(all(item["status"] == "PASS" for item in result))

    def test_missing_or_duplicate_cases(self):
        for records in ([], self.records[:1], self.records + self.records[:1]):
            with self.assertRaisesRegex(AssertionError, "missing or duplicate"):
                self.check(records)

    def test_missing_methods_cannot_pass_vacuously(self):
        records = copy.deepcopy(self.records)
        records[0]["methods"] = {}
        with self.assertRaisesRegex(AssertionError, "methods"):
            self.check(records)

    def test_incorrect_output_and_residual(self):
        for suffix in ("output", "summed"):
            path = self.root / self.specs[0]["id"] / f"control-norm-{suffix}.f32"
            original = path.read_bytes()
            corrupted = np.fromfile(path, dtype="<f4")
            corrupted[0] += 1
            corrupted.tofile(path)
            with self.assertRaises(AssertionError):
                self.check()
            path.write_bytes(original)

    def test_truncated_output(self):
        path = self.root / self.specs[0]["id"] / "control-norm-output.f32"
        path.write_bytes(path.read_bytes()[:-4])
        with self.assertRaisesRegex(AssertionError, "byte count"):
            self.check()

    def test_missing_or_nonfinite_timings(self):
        for samples in ([], [1], [1, 2, float("nan")], [1, 0, 2]):
            records = copy.deepcopy(self.records)
            records[0]["methods"]["control"]["samples_ns"] = samples
            with self.assertRaisesRegex(AssertionError, "timing samples"):
                self.check(records)

    def test_worker_failure_preserves_exit_status(self):
        with self.assertRaisesRegex(RuntimeError, "worker exit 9"):
            benchmark.execute([sys.executable, "-c", "raise SystemExit(9)"], os.environ,
                              self.root / "exit.log", 5)

    def test_timeout_retires_owned_descendant(self):
        heartbeat = self.root / "heartbeat"
        child = "import pathlib,time,sys; p=pathlib.Path(sys.argv[1]);\nwhile True: p.write_text(str(time.time_ns())); time.sleep(.01)"
        parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]]); time.sleep(20)"
        with self.assertRaises(subprocess.TimeoutExpired):
            benchmark.execute([sys.executable, "-c", parent, child, str(heartbeat)], os.environ,
                              self.root / "timeout.log", 1)
        self.assertTrue(heartbeat.exists(), "grandchild must actually have run")
        value = heartbeat.read_text()
        time.sleep(.08)
        self.assertEqual(value, heartbeat.read_text(), "timed-out grandchild must stop writing")


if __name__ == "__main__":
    unittest.main()
