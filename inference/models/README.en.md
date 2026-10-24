# Real-model CPU comparison

[简体中文](README.md)

This workflow checks whether a Julia operator improves complete model execution.
It uses one public SmolLM2-135M checkpoint for original Transformers, native
PyTorch RMSNorm and Julia fused residual/RMSNorm conditions.

**There are no full-model performance results yet.** Official metadata, config
and some tokenizer files are available, but the weight download redirects to
`us.aws.cdn.hf.co`, which the current cloud proxy rejects with a tunnel 403.
Required domains are saved in the environment draft; review, save and publish
the settings to activate them. No GPU or model API key is required.

## Fixed plan

Model: `HuggingFaceTB/SmolLM2-135M`, revision
`93efa2f097d58c2a74874c7e644dbc9b0cee75a2`.
[model-spec.json](model-spec.json) records official sizes, Git blob hashes and the
LFS SHA-256. The checkpoint is 269,060,552 bytes; all conditions load CPU Float32.

| Setting | Value |
| --- | --- |
| Inputs | Three fixed texts truncated to 24, 96 and 256 tokens |
| Outputs | 32 greedy tokens, EOS ignored for equal fixed work |
| Batch | 1 |
| Threads | 1 and 4, pinned to the corresponding number of available CPUs |
| Conditions | Original, native PyTorch norm, Julia fusion |
| Repeats | Three rounds rotating condition order; 18 independent processes |
| Profiling | Separate original-model processes after all timing trials |

Julia replaces one post-attention residual-add/RMSNorm boundary per layer.
Attention, RoPE, KV updates, MLPs, final normalization and the language head use
the existing modules. The native condition calls `torch.nn.functional.rms_norm`
at the same boundary. The original model is unpatched. A control integration
test checks exact agreement when the adapter calls the original norm module.

## Measurements

- Time to compute the first token, including input processing and token selection.
- Decode throughput for the subsequent 31 tokens, plus total throughput for all 32.
- Imports, checkpoint loading, Julia initialization, peak RSS and final RSS.
- Every generated token, and full prefill/final-step logit vectors.

Tokenization and text decoding are outside model timing. Each request starts a
new KV cache and reuses it during decoding. Tokenizer, revision, dtype, attention
and weights must agree. Julia validation, foreign calls and necessary layout
copies are included.

Generated token IDs must match exactly. Logits use `rtol=1e-4, atol=1e-4`;
nonfinite outputs fail. This does not replace broad model-quality evaluation.

The initial investment gate is at least 10% geometric-mean decode throughput
gain across six workloads over the fastest existing baseline, at most 10% peak
RSS increase, and all output checks passing. These are project criteria, not
industry standards. Startup is reported separately, without assuming a universal
amortization period.

## Run

From the repository root:

```bash
bash inference/scripts/setup-model.sh
/workspace/toolchains/inference-python/bin/python inference/models/prepare.py
/workspace/toolchains/inference-python/bin/python inference/models/run.py \
  --output inference/results/my-full-model-run.json
```

[model-requirements.lock](../model-requirements.lock) pins versions and hashes.
One checkpoint cache lives at `/workspace/model-cache/SmolLM2-135M`; conditions do
not copy it. Preparation resumes only verified files and preserves unknown
content. Existing result files cannot be overwritten. Execution loads local
safetensors without remote repository code or pickle checkpoints. Temporary
logit vectors, process logs and random integration fixtures are cleaned up.

The smaller `setup.sh` synchronizes the operator-only environment and removes
model dependencies. Use `setup-model.sh` for model work; both reuse one Python
environment.

## Current evidence and limits

Random tiny configurations test original/control equivalence, real Julia calls,
one/four threads, cached decoding, unchanged weights, actual safetensors loading
and all three generation paths. Artifact tests cover hashes, verified resume and
unknown-file preservation. These are integration checks; **random-weight timings
are never used as pretrained-model performance evidence.**

The [first download receipt](../results/model-download.json) retains a 503.
A [subsequent attempt](../results/model-download-retry.json) records a weight-CDN
tunnel 403. The [preflight receipt](../results/full-model-attempt.json) contains no
inference trials and has status `BLOCKED_MODEL_DOWNLOAD`. None counts as a
successful model benchmark.

llama.cpp, quantization, concurrency, GPU and cross-machine comparisons are absent.
Whether this implementation merits further investment remains unverified until
the checkpoint is downloaded and the actual model trials complete.
