# First CPU inference operator experiment

The prototype runs a Julia residual-add/RMSNorm operator on existing PyTorch CPU
buffer storage. Fixed-size tests show some gains, without establishing full-model
inference acceleration.

## Implementation and validation

- Independent Julia package with allocating and in-place APIs; the warmed Julia in-place API has zero scratch allocation.
- One embedded Julia runtime per process; synchronous C ABI calls check shapes, dtype, overlap and runtime/thread ownership.
- 146 Julia assertions, 8 benchmark receipt tests and 7 real bridge tests passed.
- Each full trial checks 96 method/case outputs; both trials total 192 checks. Residual sums match exactly and input files remain unchanged.
- Each method retains 21 samples and first-invocation timings. Temporary input/output files are removed.

Hardware: an AMD EPYC 9V74 VM with 5 visible CPUs, timed work pinned to one core
with one thread. Julia 1.11.7, PyTorch 2.14.1+cpu, NumPy 2.2.6. No GPU is attached.

## Calling Julia from PyTorch

Each process reports a median of 21 samples; the tables average the two process
medians. The fastest PyTorch baseline is the minimum aggregate time among native
eager, compiled allocating and compiled preallocated methods. The two trials
reverse runtime order; runtime processes execute sequentially without another
benchmark running concurrently.

Residual addition and normalization:

| Hidden | Tokens | Fastest PyTorch / µs | Python→Julia / µs | Time reduction |
| ---: | ---: | ---: | ---: | ---: |
| 1024 | 1 | 11.055 | 9.810 | 11.3% |
| 4096 | 1 | 12.235 | 10.417 | 14.9% |
| 4096 | 8 | 28.449 | 17.584 | 38.2% |
| 4096 | 64 | 137.729 | 84.175 | 38.9% |
| 8192 | 1 | 14.138 | 11.163 | 21.0% |
| 8192 | 32 | 131.231 | 85.018 | 35.2% |

Normalization followed by the same PyTorch matrix multiplication to 256 features:

| Hidden | Tokens | Fastest PyTorch / µs | Python→Julia / µs | Time reduction |
| ---: | ---: | ---: | ---: | ---: |
| 1024 | 1 | 45.351 | 42.252 | 6.8% |
| 4096 | 1 | 120.210 | 118.758 | 1.2% |
| 4096 | 8 | 356.299 | 337.427 | 5.3% |
| 4096 | 64 | 1708.794 | 1644.662 | 3.8% |
| 8192 | 1 | 232.314 | 225.503 | 2.9% |
| 8192 | 32 | 2204.972 | 2099.958 | 4.8% |

Times include Python validation, ctypes and Julia wrapping. Projection uses the
same PyTorch multiplication in both conditions, avoiding a cross-BLAS comparison.
Average gains do not mean every individual trial or size improves; small
percentage differences need more hardware and real workloads before a general claim.

## Fusion itself

Within the same Julia process, preallocated unfused/fused normalization time ratios
range from 1.009 to 1.159.
This is a modest optimization. Adding Julia's own projection makes some cases
slower; differences are mostly a few percent. See [summary.json](results/summary.json)
and the original receipts.

Dividing Python dispatch time by very small direct Julia timings would not isolate
kernel speed. Tensor data is shared, but Python objects and Julia Array headers
still allocate. Embedded runtime initialization and callback preparation took
0.339 / 0.327 seconds, separately from warm calls. First-call and compiler-cache
information is retained; clean-machine startup was not measured.

## Numerical checks and retained failures

An independent NumPy Float64 oracle checks actual binary outputs. Normalization
uses `rtol=1e-5, atol=1e-6`; projection uses PyTorch's default Float32 tolerances,
`rtol=1.3e-6, atol=1e-5`. Across the final two trials, maximum absolute errors are
7.61285448e-07 for normalization and 9.29633335e-06 for projection.

The [initial trial](results/cpu-first.json) failed when projection used the smaller
absolute tolerance and is excluded from passing counts. An [independent control](results/float32-projection-roundoff.json)
reproduced the issue with ordinary NumPy Float32 multiplication. Projection then
received the standard Float32 tolerance; the operator formula was unchanged.

Initial PyTorch 2.8 receipts remain in `cpu-forward.json` / `cpu-reverse.json` and
`cpu-bridge-forward.json` / `cpu-bridge-reverse.json`. After checking the official
CPU index, current requirements and trials moved to 2.14.1. Older results are not
pooled into these tables. `cpu-pytorch214-forward.json` retains an earlier 2.14.1
trial before duplicate-initialization protection; only the final `cpu-current-*`
pair supplies the tables.

## Reproduce

From the repository root:

```bash
bash inference/scripts/setup.sh
/workspace/toolchains/inference-python/bin/python inference/benchmarks/run.py \
  --output inference/results/new-forward.json
/workspace/toolchains/inference-python/bin/python inference/benchmarks/run.py \
  --first torch --output inference/results/new-reverse.json
python3 inference/scripts/summarize.py \
  inference/results/new-forward.json inference/results/new-reverse.json
```

Existing receipts cannot be overwritten. Input, source and dependency SHA-256
hashes are recorded. Setup reuses one Julia toolchain and Python environment,
without repository copies, model downloads or model API credentials.

## Limits and next step

Attention, KV caches, low-precision weights, quantization, decoding, serving and
GPU kernels are absent. Projection uses random weights, not a loaded model layer.
Model quality, tokens per second, first-token latency and concurrent throughput
are unmeasured. Warm tests reuse data and do not measure sustained cold-cache streams.

This checkpoint establishes executable code, real cross-language calls and a
repeatable comparison. The next step is profiling a real model to select a
material bottleneck; GPU comparisons require separate hardware. These results do
not support a general inference-engine speedup claim.
