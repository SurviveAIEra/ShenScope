"""Actual PyTorch eager and Inductor calls; no mocked operator timing."""
import json
import os
from pathlib import Path
import random
import sys
import time
import tomllib

import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge import JuliaRMSNorm


def functional_norm(x, residual, weight, epsilon):
    summed = x + residual
    return F.rms_norm(summed, [x.shape[-1]], weight, epsilon), summed


def norm_into(x, residual, weight, out, summed, epsilon):
    torch.add(x, residual, out=summed)
    scale = torch.rsqrt((summed * summed).mean(dim=-1, keepdim=True) + epsilon)
    torch.mul(summed, scale, out=out)
    torch.mul(out, weight, out=out)
    return out, summed


def functional_projection(x, residual, weight, projection, epsilon):
    out, summed = functional_norm(x, residual, weight, epsilon)
    return out @ projection.T, summed


def projection_into(x, residual, weight, projection, out, summed, projected, epsilon):
    norm_into(x, residual, weight, out, summed, epsilon)
    torch.mm(out, projection.T, out=projected)
    return projected, summed


def bridge_projection(bridge, x, residual, weight, projection, out, summed, projected, epsilon):
    bridge.add_rmsnorm_into(x, residual, weight, out, summed, epsilon)
    torch.mm(out, projection.T, out=projected)
    return projected, summed


def measure(operations, samples, target_ns):
    counts, values = {}, {name: [] for name in operations}
    for name, fn in operations.items():
        for _ in range(5):
            fn()
        start = time.perf_counter_ns()
        for _ in range(10):
            fn()
        counts[name] = min(10000, max(1, int(target_ns / max(1, (time.perf_counter_ns() - start) / 10))))
    rng = random.Random(631)
    for _ in range(samples):
        names = sorted(operations)
        rng.shuffle(names)
        for name in names:
            fn, count = operations[name], counts[name]
            start = time.perf_counter_ns()
            for _ in range(count):
                fn()
            values[name].append((time.perf_counter_ns() - start) / count)
    result = {}
    for name, timings in values.items():
        ordered = sorted(timings)
        result[name] = dict(median_ns=ordered[len(ordered) // 2], min_ns=min(ordered),
                            p90_ns=ordered[min(len(ordered) - 1, int(np.ceil(.9 * len(ordered))) - 1)],
                            samples_ns=timings, iterations_per_sample=counts[name])
    return result


def main(root, result_path):
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    torch._inductor.config.compile_threads = 1
    bridge = JuliaRMSNorm()
    config = tomllib.loads((root / "cases.toml").read_text())
    compiled_norm = torch.compile(functional_norm, fullgraph=True, dynamic=False)
    compiled_into = torch.compile(norm_into, fullgraph=True, dynamic=False)
    compiled_projection = torch.compile(functional_projection, fullgraph=True, dynamic=False)
    compiled_projection_into = torch.compile(projection_into, fullgraph=True, dynamic=False)
    records = []
    with torch.inference_mode():
        for case in config["cases"]:
            case_dir = root / case["id"]
            hidden, tokens, projected_size = case["hidden"], case["tokens"], case["projected"]
            def read(name, shape):
                return torch.from_numpy(np.fromfile(case_dir / (name + ".f32"), dtype="<f4").reshape(shape))
            x, residual = read("x", (tokens, hidden)), read("residual", (tokens, hidden))
            weight = read("weight", (hidden,))
            # Julia's (projected, hidden) column-major matrix has this byte layout.
            projection = read("projection", (hidden, projected_size)).T
            out, summed = torch.empty_like(x), torch.empty_like(x)
            projected = torch.empty((tokens, projected_size), dtype=torch.float32)
            epsilon = config["epsilon"]
            for stage in ("norm", "norm_projection"):
                if stage == "norm":
                    operations = {
                        "torch_eager_allocating": lambda: functional_norm(x, residual, weight, epsilon),
                        "torch_compiled_allocating": lambda: compiled_norm(x, residual, weight, epsilon),
                        "torch_compiled_preallocated": lambda: compiled_into(x, residual, weight, out, summed, epsilon),
                        "torch_julia_bridge_preallocated": lambda: bridge.add_rmsnorm_into(x, residual, weight, out, summed, epsilon),
                    }
                else:
                    operations = {
                        "torch_eager_allocating": lambda: functional_projection(x, residual, weight, projection, epsilon),
                        "torch_compiled_allocating": lambda: compiled_projection(x, residual, weight, projection, epsilon),
                        "torch_compiled_preallocated": lambda: compiled_projection_into(x, residual, weight, projection, out, summed, projected, epsilon),
                        "torch_julia_bridge_preallocated": lambda: bridge_projection(bridge, x, residual, weight, projection, out, summed, projected, epsilon),
                    }
                cold = {}
                for name, fn in operations.items():
                    start = time.perf_counter_ns()
                    outputs = fn()
                    cold[name] = time.perf_counter_ns() - start
                    for suffix, value in zip(("output", "summed"), outputs):
                        value.numpy().astype("<f4", copy=False).tofile(case_dir / f"{name}-{stage}-{suffix}.f32")
                stats = measure(operations, config["samples"], config["target_sample_ns"])
                for name, data in stats.items():
                    data["first_invocation_ns"] = cold[name]
                records.append(dict(id=case["id"], stage=stage, methods=stats))
                print(f"finished {case['id']} {stage}", flush=True)
    result_path.write_text(json.dumps(dict(runtime=dict(torch_version=torch.__version__,
        numpy_version=np.__version__, intraop_threads=torch.get_num_threads(),
        interop_threads=torch.get_num_interop_threads(), cuda_available=torch.cuda.is_available(),
        configuration=torch.__config__.show(), compile_backend="inductor", fullgraph=True,
        compiler_threads=1, inductor_cache=os.environ.get("TORCHINDUCTOR_CACHE_DIR", "default")),
        julia_bridge_startup_ns=bridge.startup_ns,
        records=records), indent=2, allow_nan=False) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
