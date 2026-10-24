#!/usr/bin/env python3
"""Run isolated, CPU-only operator comparisons with shared binary inputs."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tempfile
import time
import tomllib

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
CASES = ((1024, 1), (4096, 1), (4096, 8), (4096, 64), (8192, 1), (8192, 32))
RTOL = 1e-5
ATOL = 1e-6
# PyTorch's documented Float32 assert_close defaults. Projection accumulates up
# to 8192 products, so it has a separate budget from the elementwise norm output.
PROJECTION_RTOL = 1.3e-6
PROJECTION_ATOL = 1e-5
METHODS = {
    "julia": {"julia_broadcast_allocating", "julia_unfused_preallocated",
              "julia_fused_preallocated", "julia_fused_allocating"},
    "torch": {"torch_eager_allocating", "torch_compiled_allocating", "torch_compiled_preallocated",
              "torch_julia_bridge_preallocated"},
}


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_hashes():
    selected = [*ROOT.glob("src/*.jl"), *ROOT.glob("benchmarks/*.py"),
                *ROOT.glob("benchmarks/*.jl"), ROOT / "bridge.py", ROOT / "Project.toml", ROOT / "requirements.lock"]
    return {str(path.relative_to(ROOT)): sha256(path) for path in sorted(selected) if path.is_file()}


def make_inputs(root, cases, samples, target_ns):
    rng = np.random.default_rng(81731)
    specs, hashes = [], {}
    lines = ["epsilon = 0.000001", f"samples = {samples}", f"target_sample_ns = {target_ns}"]
    for hidden, tokens in cases:
        spec = dict(id=f"h{hidden}-t{tokens}", hidden=hidden, tokens=tokens, projected=256)
        specs.append(spec)
        case_dir = root / spec["id"]
        case_dir.mkdir()
        arrays = dict(x=rng.standard_normal((tokens, hidden), dtype=np.float32),
                      residual=rng.standard_normal((tokens, hidden), dtype=np.float32),
                      weight=1 + .1 * rng.standard_normal(hidden, dtype=np.float32),
                      projection=rng.standard_normal((hidden, 256), dtype=np.float32) / np.float32(np.sqrt(hidden)))
        for name, values in arrays.items():
            path = case_dir / f"{name}.f32"
            values.astype("<f4", copy=False).tofile(path)
            hashes[str(path.relative_to(root))] = sha256(path)
        lines.extend(["", "[[cases]]", *(f'{key} = "{value}"' if isinstance(value, str) else f"{key} = {value}"
                                           for key, value in spec.items())])
    (root / "cases.toml").write_text("\n".join(lines) + "\n")
    return specs, hashes


def validate_outputs(root, specs, records, expected_methods, expected_samples):
    expected_records = {(spec["id"], stage) for spec in specs for stage in ("norm", "norm_projection")}
    actual_records = [(record["id"], record["stage"]) for record in records]
    if len(actual_records) != len(expected_records) or set(actual_records) != expected_records:
        raise AssertionError("missing or duplicate benchmark cases")
    checked = []
    by_id = {spec["id"]: spec for spec in specs}
    for record in records:
        if set(record["methods"]) != expected_methods:
            raise AssertionError("missing or unexpected benchmark methods")
        spec = by_id[record["id"]]
        case_dir = root / spec["id"]
        tokens, hidden = spec["tokens"], spec["hidden"]
        x = np.fromfile(case_dir / "x.f32", dtype="<f4").reshape(tokens, hidden)
        residual = np.fromfile(case_dir / "residual.f32", dtype="<f4").reshape(tokens, hidden)
        weight = np.fromfile(case_dir / "weight.f32", dtype="<f4").astype(np.float64)
        projection = np.fromfile(case_dir / "projection.f32", dtype="<f4").reshape(hidden, spec["projected"])
        expected_sum = x + residual
        z = expected_sum.astype(np.float64)
        normalized = z / np.sqrt(np.mean(z * z, axis=-1, keepdims=True) + float(np.float32(1e-6))) * weight
        expected = normalized if record["stage"] == "norm" else normalized @ projection.astype(np.float64)
        for name, stats in record["methods"].items():
            outputs = {}
            for suffix, oracle in (("output", expected), ("summed", expected_sum)):
                path = case_dir / f"{name}-{record['stage']}-{suffix}.f32"
                if path.stat().st_size != oracle.size * 4:
                    raise AssertionError(f"incorrect output byte count: {path.name}")
                actual = np.fromfile(path, dtype="<f4").reshape(oracle.shape)
                if suffix == "summed":
                    np.testing.assert_array_equal(actual, oracle)
                else:
                    rtol, atol = ((RTOL, ATOL) if record["stage"] == "norm"
                                  else (PROJECTION_RTOL, PROJECTION_ATOL))
                    try:
                        np.testing.assert_allclose(actual, oracle, rtol=rtol, atol=atol)
                    except AssertionError as error:
                        raise AssertionError(f"{spec['id']}/{record['stage']}/{name}/{suffix}: {error}") from error
                outputs[suffix] = dict(max_absolute_error=float(np.max(np.abs(actual.astype(np.float64) - oracle))),
                                       sha256=sha256(path), elements=int(actual.size))
            if (len(stats["samples_ns"]) != expected_samples
                    or not all(np.isfinite(value) and value > 0 for value in stats["samples_ns"])):
                raise AssertionError("missing or invalid timing samples")
            checked.append(dict(id=spec["id"], stage=record["stage"], method=name, status="PASS", outputs=outputs))
    return checked


def read_optional(path):
    return Path(path).read_text().strip() if Path(path).is_file() else None


def execute(command, env, log_path, timeout):
    start = time.perf_counter_ns()
    with log_path.open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT.parent, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Retire the worker and compiler children it owns, not just its PID.
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    continue
            process.wait()
            raise
    elapsed = time.perf_counter_ns() - start
    if returncode:
        raise RuntimeError(f"worker exit {returncode}; {log_path.read_text()[-6000:]}")
    return elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--julia", default=shutil.which("julia") or "/workspace/toolchains/julia-1.11.7/bin/julia")
    parser.add_argument("--output", type=Path, required=True, help="new receipt path; existing files are never overwritten")
    parser.add_argument("--smoke", action="store_true", help="one odd-width case; correctness and toolchain check only")
    parser.add_argument("--first", choices=("julia", "torch"), default="julia")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output exists; choose a new filename to preserve the previous receipt")
    args.julia = shutil.which(args.julia) or args.julia
    if not Path(args.julia).is_file():
        parser.error("Julia executable not found; install it or pass --julia")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    cache_root = Path("/workspace") if Path("/workspace").is_dir() else ROOT.parent / ".local"
    env = dict(os.environ, SHEN_INFERENCE_JULIA=args.julia, JULIA_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
               MKL_NUM_THREADS="1", TORCHINDUCTOR_COMPILE_THREADS="1", JULIA_PKG_OFFLINE="true")
    env.setdefault("JULIA_DEPOT_PATH", str(cache_root / "julia-depot"))
    env.setdefault("TORCHINDUCTOR_CACHE_DIR", str(cache_root / "tool-cache/torch-inductor"))
    affinity = sorted(os.sched_getaffinity(0))
    os.sched_setaffinity(0, {affinity[0]})
    specs = ((127, 3),) if args.smoke else CASES
    hashes = source_hashes()
    report = dict(schema=1, started_at=datetime.now(timezone.utc).isoformat(), status="RUNNING",
                  purpose="CPU Float32 add + RMSNorm prototype; no full model or GPU benchmark",
                  smoke=args.smoke, source_sha256=hashes, hardware=dict(platform=platform.platform(),
                  cpu=read_optional("/proc/cpuinfo").split("model name", 1)[-1].split("\n", 1)[0].lstrip("\t :"),
                  affinity_before=affinity, pinned_cpu=affinity[0], cpu_quota=read_optional("/sys/fs/cgroup/cpu.max"),
                  memory_limit=read_optional("/sys/fs/cgroup/memory.max"),
                  gpu_device_nodes=[path for path in ("/dev/nvidia0", "/dev/kfd") if Path(path).exists()]),
                  configuration=dict(dtype="float32", epsilon=float(np.float32(1e-6)),
                  threads=1, samples=5 if args.smoke else 21, target_sample_ns=2_000_000,
                  seed=81731, norm_tolerance=dict(rtol=RTOL, atol=ATOL),
                  projection_tolerance=dict(rtol=PROJECTION_RTOL, atol=PROJECTION_ATOL),
                  projected=256), runtimes={}, validation=[],
                  limitations=["Operator and norm-plus-projection only; no attention, model weights, decoding or tokens/sec.",
                      "Host call overhead is included and differs between Julia and Python/PyTorch.",
                      "Warm samples reuse input data and output buffers; not cold-cache streaming.",
                      "Runtime processes are sequential, with randomized method order within each sample round.",
                      "First invocation can reuse process/compiler caches; it is not a clean-machine compile measurement.",
                      "Different BLAS implementations can affect cross-runtime projection timings.",
                      "Python-to-Julia timings include validation, ctypes and temporary Array headers, without tensor-data copies.",
                      "No GPU, FP16/BF16, quantization, gradients, serving integration or full-model acceleration verified."])
    scratch_parent = ROOT.parent / ".local" / "inference-runs"
    scratch_parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="cpu-", dir=scratch_parent) as scratch:
            work = Path(scratch)
            cases, input_hashes = make_inputs(work, specs, report["configuration"]["samples"], 2_000_000)
            report["cases"], report["input_sha256"] = cases, input_hashes
            order = ("julia", "torch") if args.first == "julia" else ("torch", "julia")
            report["runtime_order"] = list(order)
            commands = dict(julia=[args.julia, "--startup-file=no", f"--project={ROOT}",
                                  str(ROOT / "benchmarks/julia_worker.jl"), str(work), str(work / "julia.toml")],
                            torch=[os.sys.executable, str(ROOT / "benchmarks/torch_worker.py"), str(work), str(work / "torch.json")])
            for name in order:
                print(f"Starting {name} ({len(cases)} cases), log {work / (name + '.log')}", flush=True)
                wall = execute(commands[name], env, work / f"{name}.log", 900)
                result = (tomllib.loads((work / "julia.toml").read_text()) if name == "julia"
                          else json.loads((work / "torch.json").read_text()))
                report["runtimes"][name] = dict(process_wall_ns=wall, **result)
                validations = validate_outputs(work, cases, result["records"], METHODS[name],
                                               report["configuration"]["samples"])
                report["validation"].extend(validations)
                print(f"{name}: {len(validations)} method/case correctness checks passed", flush=True)
            report["inputs_unchanged"] = all(sha256(work / name) == digest for name, digest in input_hashes.items())
            if not report["inputs_unchanged"]:
                raise AssertionError("benchmark modified a shared input")
            if hashes != source_hashes():
                raise AssertionError("benchmark source changed during the run")
            report["status"] = "PASS"
    except Exception as error:
        report["status"], report["error"] = "FAIL", f"{type(error).__name__}: {error}"
        raise
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["scratch_removed"] = True
        with args.output.open("x") as stream:
            json.dump(report, stream, indent=2, allow_nan=False)
            stream.write("\n")
        print(f"{report['status']}: {args.output}", flush=True)


if __name__ == "__main__":
    main()
