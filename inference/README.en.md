# Julia inference kernel experiments

[简体中文](README.md)

This independent Julia package starts with **fused residual addition and RMSNorm
on the CPU**. The first question is narrow: does combining residual addition,
storage and the sum-of-squares reduction reduce execution time?

It does not load the existing agent or need model credentials. The current machine
has no GPU. GPU performance, full-model generation and inference serving have not
been tested.
See the [experiment report](REPORT.en.md) for measurements, retained failures and reproduction commands.

## Operation

For each token, compute and retain both outputs:

```text
s = x + residual
y = weight * s / sqrt(mean(s²) + epsilon)
```

The first pass writes the residual sum and accumulates its squared norm. The
second pass writes the normalized output. The warmed in-place API allocates no
scratch memory. This applies an established fusion technique; it is not a new
RMSNorm algorithm.

```julia
using ShenInferenceKernels

# Column-major (hidden, tokens): each token occupies contiguous memory.
x = randn(Float32, 4096, 8)
residual = randn(Float32, 4096, 8)
weight = ones(Float32, 4096)
y, summed = add_rmsnorm(x, residual, weight)

# Exact input/output identities are supported; outputs cannot overlap each other.
add_rmsnorm!(x, residual, x, residual, weight; epsilon=1f-6)
```

The current API accepts dense CPU `Matrix{Float32}` inputs and `Vector{Float32}`
weights. The hidden dimension must be positive; empty token batches are allowed.
Reduction uses Float32 and can overflow on extreme inputs. Gradients, GPU kernels,
low-precision formats and quantization are not implemented.

## Call from PyTorch

The experimental adapter wraps existing CPU tensor pointers through Julia's
C ABI without copying tensor data. Outputs remain usable by PyTorch; the
comparison uses this path followed by the same PyTorch matrix projection.

```python
# Set PYTHONPATH=inference when running from the repository root.
import torch
from bridge import JuliaRMSNorm

kernel = JuliaRMSNorm()  # Julia initializes once per process.
x = torch.randn(8, 4096, dtype=torch.float32)
residual = torch.randn_like(x)
weight = torch.ones(4096)
y, summed = torch.empty_like(x), torch.empty_like(x)
kernel.add_rmsnorm_into(x, residual, weight, y, summed)
```

Calls are synchronous and restricted to the initializing thread. Gradients and
output/input overlap are rejected. Callers must exclude concurrent buffer
mutation or resizing. The adapter allocates small Python objects and Julia Array
headers; zero scratch allocation inside the Julia kernel does not mean zero
allocation across the bridge. Initialization and compilation are reported
separately; per-call validation and ctypes overhead are included in timings.
The operator report measures integration costs. A new [full-model workflow](models/README.en.md)
reuses Transformers attention, KV caches and decoding; checkpoint download is
blocked and full-model performance remains unmeasured.

## Run

With Julia 1.11, run from the repository root; no external Julia packages are needed:

```bash
julia --startup-file=no --project=inference inference/test/runtests.jl
```

For this cloud environment, use the shared Julia 1.11.7 toolchain and CPU-only
comparison environment:

```bash
bash inference/scripts/setup.sh
/workspace/toolchains/inference-python/bin/python inference/benchmarks/run.py \
  --output inference/results/my-cpu-run.json
```

Setup verifies the pinned official Julia OCI layer SHA-256 and installs from the
official PyTorch CPU index using a hash-locked requirements file. It downloads no
models or CUDA runtime and creates no repository copies. Existing result receipts
are never overwritten. Add `--smoke` for one small correctness/toolchain case.

## Comparison

The full suite fixes six `(hidden, tokens)` cases:
`(1024, 1)`, `(4096, 1)`, `(4096, 8)`, `(4096, 64)`, `(8192, 1)`, `(8192, 32)`.
Each measures normalization alone and normalization followed by a 256-dimensional
matrix projection.

- Julia: allocating broadcasts, preallocated separate passes, preallocated fusion,
  and an allocating fusion wrapper.
- PyTorch 2.14.1 CPU: native `rms_norm`, Inductor-compiled functional code and
  compiled preallocated code.
- Python-to-Julia: validate existing PyTorch buffers, execute the real Julia
  operator and reuse the same PyTorch matrix multiplication for projection.
- Identical Float32 binary inputs; an independent NumPy Float64 oracle checks
  actual outputs. Residual sums must match elementwise exactly.
- One thread pinned to one CPU; shuffled method order per sampling round,
  21 timing samples, first-invocation timings and Julia allocation counts.

Normalization uses `rtol=1e-5, atol=1e-6`. Projection uses PyTorch's default
Float32 tolerances, `rtol=1.3e-6, atol=1e-5`. Initially applying the smaller
absolute tolerance to projection failed; ordinary independent Float32 matrix
multiplication reproduced this roundoff issue. The failed receipt and diagnostic
remain in `results/cpu-first.json` and `results/float32-projection-roundoff.json`;
they are not counted as passing performance trials.
The initial PyTorch 2.8 results and `requirements-pytorch28.lock` are retained
separately. Current trials and requirements use 2.14.1, whose native RMSNorm
already dispatches to a fused implementation. Older-version gains do not
establish an advantage over current PyTorch.

Timings include host-language call overhead. Python/PyTorch and Julia have
different dispatch costs, especially for small operators; cross-runtime ratios
do not isolate kernel throughput. Projection also uses different BLAS libraries.
The most direct fusion comparison is between the preallocated unfused and fused
Julia methods in the same process.

Warm inputs and buffers are reused. First calls can reuse existing compiler
caches. Cold-cache streaming, Python-to-Julia integration and integration into an
established inference engine have not been measured. Norm plus projection is a
computation fragment, not a full-model tokens-per-second benchmark.

## References and license

Reviewed the [PyTorch v2.8.0 RMSNorm definition and dtype handling](https://github.com/pytorch/pytorch/blob/v2.8.0/aten/src/ATen/native/layer_norm.cpp)
and the current [v2.14.1 fused dispatch](https://github.com/pytorch/pytorch/blob/v2.14.1/aten/src/ATen/native/layer_norm.cpp)
to check the mathematical definition, epsilon and Float32 arithmetic. No upstream
implementation is copied here. Download URLs, hashes and review conclusions are
recorded in [references.json](references.json).
The bridge follows [Julia 1.11.7 embedding documentation](https://github.com/JuliaLang/julia/blob/v1.11.7/doc/src/manual/embedding.md)
for initialization, callback and thread ownership restrictions.

Original code uses the repository's [restricted contribution license](../LICENSE).
Julia, PyTorch, NumPy and other dependencies retain their respective licenses.
